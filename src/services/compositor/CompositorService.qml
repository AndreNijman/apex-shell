pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../../"

// ─── CompositorService ────────────────────────────────────────────────────────
// The one surface the rest of the shell talks to about windows, workspaces and
// compositor state. Roadmap §17: "APEX Shell should be a real desktop shell with
// compositor adapters. Hyprland, niri and labwc should be implementations
// underneath one APEX UX."
//
// ── What this replaces ───────────────────────────────────────────────────────
// Before this, 33 files branched on Compositor.isHyprland / .isNiri / .isLabwc
// and each one spawned its own hyprctl or reached into the Quickshell.Hyprland
// singleton directly. That is the technical debt §17 names, and it has a
// specific failure mode that already bit this shell twice: every new consumer
// has to independently remember that `Hyprland` must not be *resolved* off
// Hyprland (resolving constructs it, and constructing it logs), and that a
// negative guard like `!isNiri` sends sway, river and KDE down the Hyprland
// path. Both rules now live in one place.
//
//   Compositor        — WHICH compositor is running (detection + override)
//   CompositorService — WHAT it can do and how to ask it (this file)
//
// Compositor stays: this service consumes it to choose a backend. Consumers
// that only want to know the name (a labwc-specific layout tweak, say) keep
// using Compositor. Consumers that want an *action* or *window data* use this.
//
// ── Capabilities, not compositor names ───────────────────────────────────────
// Ask `CompositorService.can.overview`, never `Compositor.isNiri`. The point of
// the capability map is that a fourth compositor is a new backend file and zero
// changes anywhere else. Every key is declared by every backend, so a missing
// capability is a deliberate `false` and not a typo that reads as undefined.
//
// Every action returns true if it was actually carried out and false if the
// backend cannot do it. Nothing throws and nothing spawns a doomed process:
// asking labwc to set a Hyprland border colour is a no-op that says so.
//
// ── The §17 surface ──────────────────────────────────────────────────────────
//   windows()      → property `windows`, refcounted (it costs a poll)
//   workspaces()   → property `workspaces`, free (the backends stream it)
//   focus()        → focusWorkspace / focusWindow
//   moveWindow()   → moveWindowToWorkspace
//   overview()     → toggleOverview
//   screenshot()   → windowBoxCommand / outputBoxCommand (the picker is what
//                    varies; grim itself is compositor-neutral wlroots)
//   outputState()  → below; already compositor-neutral via apex-display-apply
//   inputState()   → below; already compositor-neutral via apex-input-apply
//
// Plus what this shell genuinely needs on top: special workspaces, accent
// borders, gaps, keyboard interception (Hyprland submaps), the fullscreen
// screen shader behind the Filter tile, and night light.
// ──────────────────────────────────────────────────────────────────────────────

QtObject {
    id: root

    // ── Backend selection ─────────────────────────────────────────────────────
    // Loaded by URL, not by type name. CompositorService is reached THROUGH
    // src/qmldir, so this directory is not on the import path and
    // `HyprlandBackend {}` would fail with "is not a type" — the same trap the
    // Agent Center hit. A Loader source is resolved relative to this file, so it
    // works regardless of how the singleton was imported.
    //
    // It also means the Hyprland backend file — and therefore
    // `import Quickshell.Hyprland` — is only ever *loaded* on Hyprland. That is
    // strictly better than the `target: isHyprland ? Hyprland : null` dance the
    // consumers currently do, because the import never resolves at all.
    readonly property string _backendUrl:
          Compositor.isHyprland ? "HyprlandBackend.qml"
        : Compositor.isNiri     ? "NiriBackend.qml"
        : Compositor.isLabwc    ? "LabwcBackend.qml"
        :                         "NullBackend.qml"

    property Loader _loader: Loader {
        source: root._backendUrl
        asynchronous: false        // consumers read state during startup
    }

    readonly property var backend: root._loader.item

    // Name of the active backend, for diagnostics and the Config → Misc page.
    readonly property string name: Compositor.name

    // True once the backend has real data. Hyprland and labwc are ready
    // immediately; niri is ready when its event stream connects.
    readonly property bool ready: root.backend ? root.backend.ready : false

    // ── Capabilities ──────────────────────────────────────────────────────────
    // Every backend declares every one of these keys. `_CAPS` is the schema and
    // the all-false default, so a backend that forgets a key degrades to "cannot
    // do it" instead of `undefined`, which is truthy-adjacent and would silently
    // enable a broken path.
    readonly property var _CAPS: ({
        workspaces:           false,   // can enumerate workspaces
        workspaceSwitch:      false,   // can focus a workspace
        specialWorkspace:     false,   // has a scratchpad concept
        windows:              false,   // can enumerate windows (title + app id)
        windowGeometry:       false,   // those windows carry x/y/width/height
        outputGeometry:       false,   // can enumerate output boxes
        windowFocus:          false,
        windowMove:           false,   // can move a window between workspaces
        windowClose:          false,
        overview:             false,
        accentBorder:         false,   // can retheme the active-window border
        gaps:                 false,   // can change window gaps at runtime
        tilingLayout:         false,   // has named tiling layouts to cycle
        keyboardInterception: false,   // can grab all keys (Hyprland submaps)
        screenShader:         false,   // can run a fullscreen fragment shader
        nightLight:           false    // has a colour-temperature shifter
    })

    readonly property var can: {
        const out = {}
        const keys = Object.keys(root._CAPS)
        const declared = (root.backend && root.backend.capabilities) || {}
        for (let i = 0; i < keys.length; i++)
            out[keys[i]] = declared[keys[i]] === true
        return out
    }

    // ── Live state ────────────────────────────────────────────────────────────
    // [{ id, idx, ref, name, output, isActive, isFocused, isUrgent, occupied }]
    //
    // `ref` is what to hand back to focusWorkspace(), and it is NOT the same
    // kind of value on every compositor — a Hyprland workspace id, a niri index,
    // a labwc list position. Carrying it in the model is what lets a caller pass
    // it on without knowing which of those it got.
    //
    // KNOWN LIMITATION, niri, multi-monitor. niri's index is PER MONITOR — its
    // own docs: "this index refers to whichever workspace currently happens to
    // be at this position on the focused monitor". NiriService lists workspaces
    // from every output sorted by idx, so on two monitors the strip reads
    // 1,1,2,2,3,3… and clicking the second monitor's workspace 2 focuses the
    // FIRST monitor's workspace 2. Pre-existing — the code this replaced passed
    // the same value — but `ref` should not be described as an identity without
    // saying where it is not one. move-window-to-workspace inherits it.
    readonly property var workspaces: root.backend ? root.backend.workspaces : []

    // How many workspace slots the compositor presents whether or not they hold
    // anything. Hyprland is a fixed 1..10 grid, which is why its bar shows empty
    // dots; niri and labwc create and destroy workspaces on demand, so their
    // lists are exactly what exists. 0 means dynamic.
    //
    // A view wanting the Hyprland look builds slots 1..N and marks each occupied
    // or not from `workspaces`; a dynamic list renders as-is.
    readonly property int workspaceSlots:
        root.backend ? root.backend.workspaceSlots : 0

    // Whether a scratchpad / special workspace is currently showing. Only
    // meaningful where can.specialWorkspace is true; false everywhere else.
    readonly property bool specialWorkspaceOpen:
        root.backend ? root.backend.specialWorkspaceOpen : false

    // ── Tiling layout ─────────────────────────────────────────────────────────
    // The named layout of the focused workspace — "dwindle", "master" and so on
    // — for the bar's layout indicator. Only Hyprland has the concept: niri is
    // scrollable tiling with nothing to choose between, and labwc floats.
    //
    // Refcounted, because keeping it current costs a poll.
    readonly property string layoutName:
        root.backend ? root.backend.layoutName : ""
    readonly property int layoutWindowCount:
        root.backend ? root.backend.layoutWindowCount : 0
    readonly property var layouts:
        root.backend ? root.backend.layouts : []

    property int layoutRefCount: 0
    readonly property var layoutRef: QtObject {
        property alias refCount: root.layoutRefCount
    }

    function setLayout(name) { return root._act("tilingLayout", "setLayout", [name]) }

    // [{ handle, title, appId, workspaceId, output, focused, x, y, width, height }]
    // Geometry is present only when can.windowGeometry; otherwise all four are 0.
    readonly property var windows: root.backend ? root.backend.windows : []

    readonly property string focusedTitle:
        root.backend ? root.backend.focusedTitle : "Desktop"

    // The name to show a human — an application, not a document. The bar's
    // centre notch wants "Firefox", not "(147) YouTube — Mozilla Firefox".
    // Separate from focusedTitle because the two genuinely differ and the shell
    // had drifted into using one on Hyprland and the other on niri.
    readonly property string focusedAppName:
        root.backend ? root.backend.focusedAppName : "Desktop"
    readonly property string focusedOutput:
        root.backend ? root.backend.focusedOutput : ""
    readonly property int focusedWorkspaceId:
        root.backend ? root.backend.focusedWorkspaceId : -1

    // ── focusMoved ────────────────────────────────────────────────────────────
    // "The user is now looking somewhere else" — a different workspace, a
    // different window, a different monitor. Popups close on it.
    //
    // Deliberately NOT derived from focusedTitle: a browser changing tabs
    // rewrites the title without the focus going anywhere, and popups that
    // vanish when a background tab finishes loading are worse than popups that
    // linger. Each backend emits it from its own native focus events, which are
    // free on all three — Hyprland's raw event stream, niri's event stream and
    // labwc's foreign-toplevel — so there is no refcount on this one.
    //
    // "A different monitor" is load-bearing and costs something on Hyprland:
    // with `follow_mouse` on, a cursor crossing a monitor boundary fires it and
    // closes every open popup. That is deliberate — see _FOCUS_EVENTS in
    // HyprlandBackend.qml, which records the decision and what it replaced.
    signal focusMoved()

    property Connections _backendFocus: Connections {
        target: root.backend
        ignoreUnknownSignals: true
        function onFocusMoved() { root.focusMoved() }
    }

    // ── Refcounts ─────────────────────────────────────────────────────────────
    // Window and title tracking cost a subprocess on Hyprland, so they follow
    // the ServiceRef convention rather than running forever. Workspaces are free
    // on every backend (Hyprland and labwc push them, niri streams them), so
    // there is no refcount for those.
    //
    //   ServiceRef { service: CompositorService.windowsRef; active: onScreen }
    property int windowsRefCount: 0
    property int titleRefCount:   0

    // ServiceRef requires an object with `refCount`; these adapt this singleton's
    // two independent counters to that shape without giving consumers a handle
    // on the whole service.
    readonly property var windowsRef: QtObject {
        property alias refCount: root.windowsRefCount
    }
    readonly property var titleRef: QtObject {
        property alias refCount: root.titleRefCount
    }

    // Whether holding the ref is what makes the data exist, or only what would
    // make it exist if it cost anything. True on Hyprland (a `hyprctl` per
    // refresh, and the list empties when the last ref goes); false on niri and
    // labwc, where the compositor pushes both and they stay live.
    //
    // A consumer should ignore these and hold a ref regardless — that is the
    // contract, and it is the same on every backend. They exist because the
    // facade suite cannot otherwise tell "the refcount works" from "there was
    // never anything to gate", and asserting Hyprland's emptiness everywhere is
    // exactly the false universal this replaced.
    readonly property bool windowsPolled:
        root.backend ? root.backend.windowsPolled === true : false
    readonly property bool titlePolled:
        root.backend ? root.backend.titlePolled === true : false

    // Demand is pushed INTO the backend rather than pulled out of this singleton.
    // A backend that imported CompositorService to read the counters would be a
    // singleton cycle — the facade constructs the backend, so the backend cannot
    // safely resolve the facade while that construction is in flight.
    property Binding _windowsWanted: Binding {
        target:   root.backend
        property: "windowsWanted"
        value:    root.windowsRefCount > 0
        when:     root.backend !== null
    }
    property Binding _titleWanted: Binding {
        target:   root.backend
        property: "titleWanted"
        value:    root.titleRefCount > 0
        when:     root.backend !== null
    }
    property Binding _layoutWanted: Binding {
        target:   root.backend
        property: "layoutWanted"
        value:    root.layoutRefCount > 0
        when:     root.backend !== null
    }

    // ── Actions ───────────────────────────────────────────────────────────────
    // Each returns true when the backend carried it out. A false is a capability
    // answer, not an error: nothing is logged and nothing is spawned.
    function _act(capability, method, args) {
        if (!root.can[capability]) return false
        if (!root.backend || typeof root.backend[method] !== "function") return false
        root.backend[method].apply(root.backend, args || [])
        return true
    }

    // ref is whatever the backend's workspace model calls an identity: a
    // Hyprland workspace id, a niri 1-based index, or a labwc list position.
    // Take it from CompositorService.workspaces — never construct one.
    function focusWorkspace(ref)        { return root._act("workspaceSwitch",  "focusWorkspace", [ref]) }
    function toggleSpecialWorkspace(n)  { return root._act("specialWorkspace", "toggleSpecialWorkspace", [n]) }

    function focusWindow(handle)        { return root._act("windowFocus", "focusWindow", [handle]) }
    function closeWindow(handle)        { return root._act("windowClose", "closeWindow", [handle]) }
    function moveWindowToWorkspace(handle, ws) {
        return root._act("windowMove", "moveWindowToWorkspace", [handle, ws])
    }

    function toggleOverview()           { return root._act("overview", "toggleOverview", []) }

    // hex is six digits, no leading '#'.
    function setAccentBorder(hex)       { return root._act("accentBorder", "setAccentBorder", [hex]) }
    function setGaps(inner, outer)      { return root._act("gaps", "setGaps", [inner, outer]) }

    // Current gaps, so a caller that changes them can put them back. Focus mode
    // is the only user: it shrinks the gaps and has to restore whatever the user
    // actually had, not a hardcoded default.
    //
    //     CompositorService.readGaps(function (ok, g) { … g.inner, g.outer … })
    //
    // The callback gets (false, null) where gaps are not a runtime concept —
    // which is everywhere except Hyprland.
    function readGaps(callback) {
        if (!root.can.gaps || !root.backend
            || typeof root.backend.readGaps !== "function") {
            callback(false, null)
            return false
        }
        root.backend.readGaps(callback)
        return true
    }

    // Route every key to the shell (Hyprland submap) and back again.
    function setKeyboardInterception(on) {
        return root._act("keyboardInterception", "setKeyboardInterception", [on])
    }

    // ── Screen shader ─────────────────────────────────────────────────────────
    // The Filter tile. A fullscreen fragment shader over the composited output;
    // only Hyprland has a hook for one, so the tile hides on `can.screenShader`
    // rather than on a compositor name.
    //
    // Reported as a basename without its extension — "protanopia" — because
    // that is what the picker lists and the tile shows. "" means none.
    //
    // A property rather than a read-with-callback on purpose: the backend keeps
    // it current (it re-reads after every apply), so a caller binds to it and a
    // failed read leaves a stale value instead of a callback that never fires.
    readonly property string screenShader:
        root.backend ? root.backend.screenShader : ""

    // path is ABSOLUTE, or "" to turn the shader off. Finding a shader file on
    // disk is the caller's job — shader directories are a user-config concern
    // and have nothing to do with which compositor is running.
    function setScreenShader(path) {
        return root._act("screenShader", "setScreenShader", [path])
    }

    // For the cases where something outside the shell may have changed it — a
    // config reload, a wallpaper apply that reloads Hyprland.
    function refreshScreenShader() {
        return root._act("screenShader", "refreshScreenShader", [])
    }

    // ── Night light ───────────────────────────────────────────────────────────
    // hyprsunset. A daemon rather than a compositor feature, but it shifts the
    // colour temperature through `hyprland-ctm-control-v1` and so does nothing
    // at all anywhere else, which makes it exactly the kind of thing this map
    // exists to answer honestly.
    readonly property bool nightLightActive:
        root.backend ? root.backend.nightLightActive : false

    function setNightLight(on) {
        return root._act("nightLight", "setNightLight", [on])
    }

    // ── screenshot(): the picker, not the capture ─────────────────────────────
    // grim and slurp are wlroots protocols and work on all three compositors, so
    // capture needs no adapter. What differs is feeding slurp a box list so the
    // user can click a window or an output instead of dragging a rectangle.
    //
    // Each is a *shell fragment* that prints "x,y WxH" lines on stdout, for the
    // caller to pipe into slurp:
    //
    //     const s = CompositorService.windowBoxScript
    //     cmd = s === "" ? ["slurp"] : ["bash", "-c", s + " | slurp"]
    //
    // "" means the backend cannot enumerate those boxes, and plain interactive
    // slurp — drag a rectangle — is the fallback that always works. A fragment
    // rather than an argv because the consumer has to build a pipeline out of
    // it, and splicing argv into a pipeline is where quoting bugs live.
    readonly property string windowBoxScript:
        (root.can.windowGeometry && root.backend) ? root.backend.windowBoxScript : ""
    readonly property string outputBoxScript:
        (root.can.outputGeometry && root.backend) ? root.backend.outputBoxScript : ""

    // ── outputState() / inputState() ──────────────────────────────────────────
    // These two are already compositor-neutral and have been since §18: the OS
    // ships adapter helpers that speak hyprctl, wlr-randr, kanshi, niri KDL or
    // labwc <libinput> as appropriate, and the shell only ever sees their JSON.
    // They are exposed here so §17's surface is complete in one place and so a
    // consumer never has to know which helper to call.
    //
    //   CompositorService.outputState(function (ok, data) { … })
    //
    // The callback gets (false, null) when the helper is missing or fails —
    // the same contract DisplayService and InputService already implement
    // against these binaries.
    // Writable, not readonly, so a test can point them at a stub. There is no
    // other way to prove the (false, null) failure contract: on a developer box
    // the real helpers may be absent, which makes "the callback never fired"
    // and "the callback reported failure" look identical.
    property string displayEngine: "/usr/libexec/apex-display-apply"
    property string inputEngine:   "/usr/libexec/apex-input-apply"

    property var _stateCallbacks: ({})

    property Process _outputProc: Process {
        command: []
        running: false
        stdout: StdioCollector {
            onStreamFinished: root._deliver("output", this.text)
        }
        onExited: function (code) {
            if (code !== 0) root._deliver("output", "")
        }
        // A binary that does not exist never exits, because it never starts:
        // Quickshell logs "Process failed to start" and `running` drops back to
        // false with no exit code. Without this the callback would sit pending
        // forever and the caller would wait on a reply that cannot come — and
        // these helpers legitimately go missing, because the shell is a $HOME
        // checkout that updates independently of the OS image that ships them.
        onRunningChanged: if (!running) root._outputSettle.restart()
    }

    property Process _inputProc: Process {
        command: []
        running: false
        stdout: StdioCollector {
            onStreamFinished: root._deliver("input", this.text)
        }
        onExited: function (code) {
            if (code !== 0) root._deliver("input", "")
        }
        onRunningChanged: if (!running) root._inputSettle.restart()
    }

    // One timer per stream, each settling only its own callback.
    //
    // A single shared timer restarted by BOTH processes and settling BOTH
    // callbacks meant a fast-failing input helper could settle a slow-but-
    // working output call: the output helper succeeded, its real result was
    // discarded, and its caller was told (false, null). Reproduced with a
    // 600 ms stub and a failing stub 50 ms apart.
    //
    // The delay itself is still needed — a binary that cannot exec emits
    // neither streamFinished nor exited, only runningChanged — so this gives
    // the normal paths a turn to land before declaring failure.
    property Timer _outputSettle: Timer {
        interval: 150
        repeat: false
        onTriggered: root._deliver("output", "")
    }
    property Timer _inputSettle: Timer {
        interval: 150
        repeat: false
        onTriggered: root._deliver("input", "")
    }

    function _deliver(which, text) {
        const cb = root._stateCallbacks[which]
        if (!cb) return
        root._stateCallbacks[which] = null
        let parsed = null
        try { parsed = text && text !== "" ? JSON.parse(text) : null }
        catch (e) { parsed = null }
        cb(parsed !== null, parsed)
    }

    function outputState(callback) {
        root._stateCallbacks["output"] = callback
        root._outputProc.command = [root.displayEngine, "list"]
        root._outputProc.running = false
        root._outputProc.running = true
    }

    function inputState(callback) {
        root._stateCallbacks["input"] = callback
        root._inputProc.command = [root.inputEngine, "list"]
        root._inputProc.running = false
        root._inputProc.running = true
    }
}
