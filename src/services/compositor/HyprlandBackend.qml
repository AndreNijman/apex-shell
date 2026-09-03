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

    signal focusMoved()

    // The raw events that mean focus actually moved. `activewindow` is
    // deliberately absent: Hyprland fires it for title changes too, so a
    // browser switching tabs would count as the user looking elsewhere.
    readonly property var _FOCUS_EVENTS: [
        "workspace", "activemonitor", "activespecial", "openwindow", "focusedmon"
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
        keyboardInterception: true
    })

    property bool windowsWanted: false
    property bool titleWanted:   false
    property bool layoutWanted:  false

    // ── Dialect ───────────────────────────────────────────────────────────────
    readonly property bool _lua: ShellState.configProvider === "lua"

    property Process _proc: Process { command: []; running: false }

    function _run(argv) {
        root._proc.command = argv
        root._proc.running = false
        root._proc.running = true
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
        if (root._lua) root._run(["hyprctl", "eval", luaExpr])
        else           root._run(["hyprctl", "keyword", path, value])
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
        root._run(["bash", "-c",
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

    function readGaps(callback) {
        // A second read while one is in flight would drop the first caller's
        // callback on the floor. Refuse instead — the caller gets an answer.
        if (root._gapsCallback !== null) { callback(false, null); return }
        root._gapsCallback = callback
        root._gapsProc.running = false
        root._gapsProc.running = true
    }

    // Hyprland submaps: a named mode with no binds in it, so every key falls
    // through to the focused surface. That surface is the shell while it is
    // capturing a keybind.
    function setKeyboardInterception(on) {
        const target = on ? "ApexShell_clean" : "reset"
        root._run(root._lua
            ? ["hyprctl", "dispatch", `hl.dsp.submap('${target}')`]
            : ["hyprctl", "dispatch", "submap", target])
    }
}
