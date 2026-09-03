import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "../../"
import "boxes.js" as Boxes

// ─── HyprlandBackend ──────────────────────────────────────────────────────────
// CompositorService's Hyprland adapter. Loaded by URL and only on Hyprland, so
// `import Quickshell.Hyprland` above never resolves anywhere else — which is the
// whole reason the consumers no longer need `target: isHyprland ? Hyprland : null`
// scattered through them. Resolving that singleton is what constructs it, and
// constructing it off Hyprland logs.
//
// ── Two dialects ─────────────────────────────────────────────────────────────
// Hyprland can be configured in its own .conf format or, with the Lua plugin, in
// Lua. Dispatch syntax differs between them and ShellState.configProvider says
// which one this machine uses. Every dispatch in this file goes through
// _dispatch()/_keyword() so the branch exists once rather than at nine call
// sites, which is how the Lua path drifted last time.
//
// ── What costs something ─────────────────────────────────────────────────────
// Workspaces and the focused monitor are pushed by the Quickshell.Hyprland
// singleton and cost nothing. Window enumeration and the focused window title
// need `hyprctl`, so both are refcounted: CompositorService pushes windowsWanted
// and titleWanted in, and nothing spawns while nobody is looking.
// ──────────────────────────────────────────────────────────────────────────────

QtObject {
    id: root

    readonly property bool ready: true

    readonly property string displayName: "Hyprland"

    // `hyprctl version` prints "Hyprland 0.56.2 built from branch …"; the
    // facade takes the first x.y.z off stdout. Nothing else in this file needs
    // to know how it is spelled, and no consumer does.
    readonly property var versionCommand: ["hyprctl", "version"]

    signal focusMoved()

    // ── What counts as "the user is now looking somewhere else" ───────────────
    // The raw events that mean focus actually moved. `activewindow` is
    // deliberately absent: Hyprland fires it for title changes too, so a
    // browser switching tabs would count as the user looking elsewhere.
    //
    // `focusedmon` IS included, and that is a decision rather than an
    // oversight, because it has a visible cost. Hyprland's `follow_mouse` is on
    // by default, so on a multi-monitor session merely moving the cursor across
    // a monitor boundary now fires this and PopupDismiss closes every open
    // popup. It did not before. Single-monitor sessions — this shell's usual
    // case — are unaffected, because the event never fires there.
    //
    // It is kept because CompositorService defines focusMoved as "a different
    // workspace, a different window, a different monitor", and the other two
    // backends already honour the monitor half: niri fires on
    // focusedWorkspaceId (which changes when monitor focus does, since each
    // output shows its own workspace) and labwc on activeToplevelChanged.
    // Dropping it here would make Hyprland the one backend that silently
    // narrows the contract it is implementing, and `Popups.closeAll()` is
    // global — the popup sits on the monitor the user just left.
    //
    // `activemonitor` used to be in this list and was never an event. Hyprland's
    // IPC event names are compiled into the binary; `focusedmon` and
    // `focusedmonv2` are there, and the only occurrence of "activemonitor"
    // anywhere in it is `workspace.activemonitor`, a Lua hook name — checked
    // with `strings /usr/bin/Hyprland`. So it matched nothing and the monitor
    // half of the contract was in fact unimplemented until `focusedmon` landed.
    readonly property var _FOCUS_EVENTS: [
        "workspace", "activespecial", "openwindow", "focusedmon"
    ]

    readonly property var capabilities: ({
        workspaces:           true,
        workspaceSwitch:      true,
        specialWorkspace:     true,
        windows:              true,
        windowGeometry:       true,
        outputGeometry:       true,
        windowFocus:          true,
        windowMove:           true,
        windowClose:          true,
        // Hyprland has no built-in overview dispatch — hyprexpo is a plugin and
        // APEX does not ship it. Declared false rather than dispatching into a
        // plugin that is probably not loaded.
        overview:             false,
        accentBorder:         true,
        gaps:                 true,
        tilingLayout:         true,
        keyboardInterception: true,
        screenShader:         true,
        nightLight:           true
    })

    property bool windowsWanted: false
    property bool titleWanted:   false
    property bool layoutWanted:  false

    // ── What the refcounts actually buy ───────────────────────────────────────
    // True because enumerating windows and reading the focused title each cost
    // a `hyprctl` here: nothing runs while nobody holds a ref, and the list and
    // title fall back to empty/"Desktop" the moment the last ref is handed
    // back. On the wlroots backends the same data arrives over a protocol the
    // compositor pushes, so it is live whether anyone asked or not.
    //
    // Declared rather than left as prose because the two are behaviourally
    // different and the facade suite has to know which contract to assert. See
    // the note in check-compositor-backends.sh on why this is not a capability.
    readonly property bool windowsPolled: true
    readonly property bool titlePolled:   true

    // ── Dialect ───────────────────────────────────────────────────────────────
    readonly property bool _lua: ShellState.configProvider === "lua"

    // ── One Process per concern, deliberately not one shared Process ──────────
    // `running = false; running = true` on a Process TERMINATES whatever it is
    // currently running. Consolidating the four commands below onto one shared
    // Process — which is what the first draft of this file did — made them able
    // to kill each other, and they could not before: they used to live in four
    // separate files with four separate Process objects.
    //
    // Verified against a live Quickshell: start `bash -c "sleep 1; echo FIRST"`,
    // reassign and restart 200 ms later with `echo SECOND`, and only SECOND
    // runs.
    //
    // The one that makes this severe rather than untidy is the submap. If a
    // concurrent border retint or layout change kills `hyprctl dispatch submap
    // reset`, Hyprland stays in ApexShell_clean and EVERY KEY falls through to
    // the shell until Hyprland is restarted. A wallpaper apply landing while
    // focus mode is mid-write is the mundane version: gaps half-applied.
    property Process _keywordProc: Process { command: []; running: false }
    property Process _gapsWriteProc: Process { command: []; running: false }
    property Process _submapProc:  Process { command: []; running: false }
    property Process _shaderApplyProc: Process {
        command: []
        running: false
        // The apply is a keyword write plus a damage cycle; re-read afterwards
        // so the tile reflects what Hyprland actually ended up with rather than
        // what was asked for.
        onRunningChanged: if (!running) root.refreshScreenShader()
    }
    property Process _nightLightKillProc: Process { command: []; running: false }

    function _start(proc, argv) {
        proc.command = argv
        proc.running = false
        proc.running = true
    }

    // A dispatcher call. `conf` takes the verb and its arguments positionally;
    // `lua` takes one expression string.
    function _dispatch(confArgs, luaExpr) {
        if (root._lua) Hyprland.dispatch(luaExpr)
        else           Hyprland.dispatch(confArgs)
    }

    // A config keyword write. hyprctl rather than the dispatch socket because
    // `keyword` is not a dispatcher.
    function _keyword(path, value, luaExpr) {
        if (root._lua) root._start(root._keywordProc, ["hyprctl", "eval", luaExpr])
        else           root._start(root._keywordProc, ["hyprctl", "keyword", path, value])
    }

    // ── Workspaces ────────────────────────────────────────────────────────────
    // Hyprland pushes these; no polling. `id` is the identity a caller passes
    // back to focusWorkspace().
    readonly property var workspaces: {
        const out = []
        const src = Hyprland.workspaces ? Hyprland.workspaces.values : []
        const focusedId = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
        for (let i = 0; i < src.length; i++) {
            const w = src[i]
            out.push({
                id:        w.id,
                idx:       w.id,
                ref:       w.id,          // focusWorkspace() takes the id here
                name:      w.name || String(w.id),
                output:    w.monitor ? w.monitor.name : "",
                isActive:  w.active === true || w.id === focusedId,
                isFocused: w.id === focusedId,
                isUrgent:  w.urgent === true,
                occupied:  true           // it is in the list because it exists
            })
        }
        out.sort(function (a, b) { return a.id - b.id })
        return out
    }

    readonly property int focusedWorkspaceId:
        Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1

    // Hyprland presents a fixed 1..10 grid; a workspace that holds nothing is
    // still a place you can switch to, and the bar has always shown it as an
    // empty dot.
    readonly property int workspaceSlots: 10

    // The scratchpad. `activespecial` carries "workspaceName,monitorName" and an
    // empty name means it just closed.
    property bool specialWorkspaceOpen: false

    readonly property string focusedOutput:
        Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""

    // ── Focused window title ──────────────────────────────────────────────────
    // `hyprctl activewindow -j` on every raw event, but only while somebody
    // holds a title ref. Hyprland emits a raw event for essentially every state
    // change, so this is push-driven rather than polled.
    property string focusedTitle:   "Desktop"

    // Hyprland's `initialTitle` is the title the window had when it was mapped,
    // which for almost every toolkit is the bare application name — "kitty",
    // "Mozilla Firefox". That is what the notch wants, and it is what this shell
    // has always displayed there, so the mapping is preserved rather than
    // "improved" into `class`.
    property string focusedAppName: "Desktop"

    property Process _titleProc: Process {
        command: ["hyprctl", "activewindow", "-j"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                // Same race as the window list: a title landing after the ref
                // was released would overwrite the placeholder.
                if (!root.titleWanted) return
                let t = ""
                let a = ""
                try {
                    const d = JSON.parse(this.text)
                    // `{}` is what Hyprland returns with nothing focused.
                    t = (d && d.title)        ? d.title        : ""
                    a = (d && d.initialTitle) ? d.initialTitle : ""
                } catch (e) { t = ""; a = "" }
                root.focusedTitle   = t !== "" ? t : "Desktop"
                root.focusedAppName = a !== "" ? a : "Desktop"
            }
        }
    }

    function _refreshTitle() {
        if (!root.titleWanted) return
        root._titleProc.running = false
        root._titleProc.running = true
    }

    onTitleWantedChanged: {
        if (root.titleWanted) {
            root._refreshTitle()
        } else {
            root.focusedTitle   = "Desktop"
            root.focusedAppName = "Desktop"
        }
    }

    // ── Window list ───────────────────────────────────────────────────────────
    property var windows: []

    property Process _clientsProc: Process {
        command: ["hyprctl", "-j", "clients"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                // The ref can be handed back while this query is still in
                // flight, in which case onWindowsWantedChanged has already
                // cleared the list and this result would refill it — a poller
                // that "stopped" but left stale data behind. Discard it.
                if (!root.windowsWanted) return
                let out = []
                try {
                    const list = JSON.parse(this.text) || []
                    for (let i = 0; i < list.length; i++) {
                        const c = list[i]
                        if (!c.mapped) continue
                        out.push({
                            handle:      c.address,
                            title:       c.title || "",
                            appId:       c.class || "",
                            workspaceId: c.workspace ? c.workspace.id : -1,
                            output:      c.monitor !== undefined ? String(c.monitor) : "",
                            focused:     false,
                            x:           c.at   ? c.at[0]   : 0,
                            y:           c.at   ? c.at[1]   : 0,
                            width:       c.size ? c.size[0] : 0,
                            height:      c.size ? c.size[1] : 0
                        })
                    }
                } catch (e) { out = [] }
                root.windows = out
            }
        }
    }

    function _refreshWindows() {
        if (!root.windowsWanted) return
        root._clientsProc.running = false
        root._clientsProc.running = true
    }

    onWindowsWantedChanged: {
        if (root.windowsWanted) root._refreshWindows()
        else                    root.windows = []
    }

    // One listener for both. Hyprland's raw event stream fires on window and
    // workspace changes alike; each refresh is a no-op unless its ref is held.
    property Connections _events: Connections {
        target: Hyprland
        function onRawEvent(event) {
            root._refreshTitle()
            root._refreshWindows()
            root._refreshLayout()
            if (root._FOCUS_EVENTS.indexOf(event.name) !== -1) root.focusMoved()

            if (event.name === "activespecial" || event.name === "activespecialv2")
                root.specialWorkspaceOpen = String(event.data).split(",")[0] !== ""
            else if (event.name === "destroyworkspace")
                root.specialWorkspaceOpen = false
        }
    }

    Component.onCompleted: {
        root._refreshTitle()
        root._refreshWindows()

        // Two one-shot probes at startup — one `hyprctl getoption`, one
        // `pgrep`. They used to run from QuickSettings.Component.onCompleted
        // instead, so the same two forks happened on first dashboard open. Same
        // count per session, moved earlier, and the properties are now honest
        // from the start rather than reading false until somebody looks. These
        // are one-shots, not the refcounted pollers: nothing repeats.
        root.refreshScreenShader()
        root._nightLightProbeProc.running = true
    }

    // ── Tiling layout ─────────────────────────────────────────────────────────
    // `hyprctl -j activeworkspace` reports the workspace's layout and window
    // count. Refreshed on raw events, with a slow safety timer for the one case
    // events do not cover: changing the layout on an empty workspace, where
    // nothing else happens afterwards to trigger a read.
    //
    // Both are refcounted now. The old indicator ran its 4-second timer for the
    // entire session whether or not the bar was on screen.
    property string layoutName:        ""
    property int    layoutWindowCount: 0

    readonly property var layouts: ["dwindle", "master", "monocle", "scrolling"]

    property Process _layoutProc: Process {
        command: ["hyprctl", "-j", "activeworkspace"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const d = JSON.parse(this.text)
                    if (d && d.tiledLayout) {
                        root.layoutName        = String(d.tiledLayout).toLowerCase()
                        root.layoutWindowCount = d.windows > 0 ? d.windows : 0
                    }
                } catch (e) {
                    // Malformed JSON: keep the last known layout rather than
                    // flashing the indicator to "Unknown".
                }
            }
        }
    }

    function _refreshLayout() {
        if (!root.layoutWanted) return
        if (!root._layoutProc.running) root._layoutProc.running = true
    }

    onLayoutWantedChanged: if (root.layoutWanted) root._refreshLayout()

    property Timer _layoutSafety: Timer {
        interval: 4000
        repeat:   true
        running:  root.layoutWanted
        onTriggered: root._refreshLayout()
    }

    function setLayout(name) {
        root._keyword("general:layout", name,
                      `hl.config({ general = { layout = "${name}" } })`)
        // Optimistic, so the indicator changes under the cursor rather than on
        // the next poll.
        root.layoutName = name
    }

    // ── Screenshot picker boxes ───────────────────────────────────────────────
    readonly property string windowBoxScript: Boxes.HYPR_WINDOWS
    readonly property string outputBoxScript: Boxes.HYPR_OUTPUTS

    // ── Actions ───────────────────────────────────────────────────────────────
    function focusWorkspace(ref) {
        root._dispatch("workspace " + ref, `hl.dsp.focus({ workspace = "${ref}" })`)
    }

    function toggleSpecialWorkspace(name) {
        root._dispatch("togglespecialworkspace " + name,
                       `hl.dsp.workspace.toggle_special("${name}")`)
    }

    function focusWindow(handle) {
        root._dispatch("focuswindow address:" + handle,
                       `hl.dsp.focus({ window = "address:${handle}" })`)
    }

    function closeWindow(handle) {
        root._dispatch("closewindow address:" + handle,
                       `hl.dsp.close({ window = "address:${handle}" })`)
    }

    function moveWindowToWorkspace(handle, ws) {
        root._dispatch(`movetoworkspacesilent ${ws},address:${handle}`,
                       `hl.dsp.window.move_to_workspace({ workspace = "${ws}", window = "address:${handle}" })`)
    }

    function toggleOverview() { /* unreachable: capabilities.overview is false */ }

    function setAccentBorder(hex) {
        root._keyword("general:col.active_border", `rgb(${hex})`,
                      `hl.config({ general = { ["col.active_border"] = { colors = { "rgb(${hex})" } } } })`)
    }

    function setGaps(inner, outer) {
        // Both in one shell so the two writes cannot be seen half-applied.
        root._start(root._gapsWriteProc, ["bash", "-c",
                    `hyprctl keyword general:gaps_in ${inner} && ` +
                    `hyprctl keyword general:gaps_out ${outer}`])
    }

    // Both gaps in one call. This used to be two chained Processes in
    // QuickSettings, each with its own python one-liner, sequenced by
    // onRunningChanged — three subprocesses to read two integers, and no way to
    // tell "the read failed" from "the gaps really are zero".
    property var _gapsCallback: null

    property Process _gapsProc: Process {
        command: ["bash", "-c",
            "hyprctl -j getoption general:gaps_in; hyprctl -j getoption general:gaps_out"]
        running: false
        onRunningChanged: if (!running) root._gapsSettle.restart()
        stdout: StdioCollector {
            onStreamFinished: {
                const cb = root._gapsCallback
                root._gapsCallback = null
                if (!cb) return

                // Two JSON objects back to back. `custom` is the "5 5 5 5" form
                // Hyprland reports for a CSS-style gap, and `int` is the plain
                // one; take the first number of whichever is present.
                const nums = []
                const parts = this.text.split("}")
                for (let i = 0; i < parts.length; i++) {
                    const chunk = parts[i] + "}"
                    let v = NaN
                    try {
                        const d = JSON.parse(chunk.trim())
                        if (d.custom !== undefined && d.custom !== "")
                            v = parseInt(String(d.custom).trim().split(/\s+/)[0])
                        else if (d.int !== undefined)
                            v = parseInt(d.int)
                    } catch (e) { v = NaN }
                    if (!isNaN(v)) nums.push(v)
                }

                if (nums.length >= 2) cb(true, { inner: nums[0], outer: nums[1] })
                else                  cb(false, null)
            }
        }
    }

    // A binary that cannot be executed emits NEITHER streamFinished NOR exited —
    // only runningChanged. Without this, one failed exec leaves _gapsCallback
    // non-null and every later readGaps is refused for the life of the session,
    // and focus mode never flips because its callback never runs.
    //
    // The facade carries the same guard for outputState/inputState; it was
    // identified there and not applied here.
    property Timer _gapsSettle: Timer {
        interval: 150
        repeat: false
        onTriggered: {
            const cb = root._gapsCallback
            if (!cb) return
            root._gapsCallback = null
            cb(false, null)
        }
    }

    function readGaps(callback) {
        // A second read while one is in flight would drop the first caller's
        // callback on the floor. Refuse instead — the caller gets an answer.
        if (root._gapsCallback !== null) { callback(false, null); return }
        root._gapsCallback = callback
        root._gapsProc.running = false
        root._gapsProc.running = true
    }

    // ── Screen shader ─────────────────────────────────────────────────────────
    // `decoration:screen_shader` is a fullscreen fragment shader Hyprland runs
    // over the composited output — the Filter tile's night-vision, protanopia
    // and so on. Nothing else APEX ships has an equivalent: niri and labwc have
    // no shader hook at all, which is why this is a capability rather than
    // something every backend pretends to.
    //
    // The whole implementation used to live in QuickSettings, including the
    // .conf/lua dialect split, which meant the tile was the only consumer left
    // in the shell that knew what hyprctl was.
    //
    // Reported as a basename without its extension — "protanopia", not
    // "/usr/share/hyprshade/shaders/protanopia.glsl" — because that is what the
    // picker lists and what the tile shows. "" means no shader.
    property string screenShader: ""

    property Process _shaderReadProc: Process {
        command: ["hyprctl", "getoption", "decoration:screen_shader", "-j"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                // Parsed here rather than through the `python3 -c` one-liner
                // this replaced: same JSON, one fewer interpreter per read.
                let s = ""
                try {
                    const d = JSON.parse(this.text)
                    s = (d && d.str) ? String(d.str).trim() : ""
                } catch (e) { s = "" }
                // `[[EMPTY]]` is how Hyprland's .conf dialect spells "unset".
                root.screenShader = (s === "" || s === "[[EMPTY]]")
                    ? "" : root._shaderName(s)
            }
        }
    }

    function _shaderName(path) {
        return String(path).replace(/^.*\//, "").replace(/\.[^.]*$/, "")
    }

    // No settle timer here, unlike readGaps: this is a property refresh and not
    // a callback, so a hyprctl that cannot exec leaves the value stale rather
    // than leaving a caller waiting on a reply that can never come.
    function refreshScreenShader() {
        root._shaderReadProc.running = false
        root._shaderReadProc.running = true
    }

    // path is absolute, or "" to turn the shader off. Resolving a picker entry
    // to a file is the caller's job — this backend does not search the disk.
    function setScreenShader(path) {
        const off = String(path) === ""

        // ── The DPMS damage cycle ────────────────────────────────────────────
        // Hyprland only re-runs the shader where it has damage, so applying one
        // to an otherwise idle screen does nothing visible until something else
        // happens to redraw. Cycling DPMS off and on forces a full redraw of
        // every output.
        //
        // Carried over verbatim from QuickSettings, where it was written and
        // proven on hardware. It is not obvious and it is not decorative; do
        // not "simplify" it into a single dispatch.
        const damage = root._lua
            ? ` && hyprctl dispatch 'hl.dsp.dpms({ action = "disable" })'`
              + ` && hyprctl dispatch 'hl.dsp.dpms({ action = "enable" })'`
            : ` && hyprctl dispatch dpms off && hyprctl dispatch dpms on`

        // The path goes in as a positional argument, never spliced into the
        // script: it comes off the user's disk and may contain anything a
        // filename may contain.
        const write = off
            ? (root._lua
                ? `hyprctl eval "hl.config({ decoration = { screen_shader = '' } })"`
                : `hyprctl keyword decoration:screen_shader '[[EMPTY]]'`)
            : (root._lua
                ? `hyprctl eval "hl.config({ decoration = { screen_shader = '$1' } })"`
                : `hyprctl keyword decoration:screen_shader "$1"`)

        root._start(root._shaderApplyProc,
                    ["bash", "-c", write + damage, "--", String(path)])

        // Optimistic, so the tile changes under the cursor rather than after
        // the re-read lands. _shaderApplyProc corrects it either way.
        root.screenShader = off ? "" : root._shaderName(path)
    }

    // ── Night light ───────────────────────────────────────────────────────────
    // hyprsunset, and it belongs in the capability map even though it is a
    // separate daemon rather than a compositor feature: it shifts the colour
    // temperature through `hyprland-ctm-control-v1`, a Hyprland-only protocol,
    // so it does nothing whatsoever on niri or labwc. The tile has to hide on
    // *something*, and hiding it on a capability means the day somebody wires
    // wlsunset up for the wlroots backends is one `true` in one file.
    property bool nightLightActive: false

    property Process _nightLightProc: Process {
        command: ["hyprsunset", "-t", "5600"]
        running: false
    }

    // Adopts a hyprsunset the user (or a previous shell) already started, so
    // the tile does not offer to turn on something that is already on.
    property Process _nightLightProbeProc: Process {
        command: ["pgrep", "-x", "hyprsunset"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                if (this.text.trim() !== "") root.nightLightActive = true
            }
        }
    }

    function setNightLight(on) {
        if (on) {
            root._nightLightProc.running = true
        } else {
            root._nightLightProc.running = false
            root._start(root._nightLightKillProc, ["pkill", "hyprsunset"])
        }
        root.nightLightActive = on
    }

    // Hyprland submaps: a named mode with no binds in it, so every key falls
    // through to the focused surface. That surface is the shell while it is
    // capturing a keybind.
    function setKeyboardInterception(on) {
        const target = on ? "ApexShell_clean" : "reset"
        root._start(root._submapProc, root._lua
            ? ["hyprctl", "dispatch", `hl.dsp.submap('${target}')`]
            : ["hyprctl", "dispatch", "submap", target])
    }
}
