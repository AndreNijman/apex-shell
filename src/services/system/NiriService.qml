pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../../"

// ─── NiriService ──────────────────────────────────────────────────────────────
// niri IPC client. Connects to $NIRI_SOCKET (Compositor.niriSocket) and issues a
// single EventStream request. niri replies  {"Ok":"Handled"}  then streams
// newline-delimited JSON events, one per line. The initial burst carries the
// complete current state, so there is no polling — the event stream IS the
// initial state fetch plus every subsequent update.
//
// Protocol verified against:
//   https://github.com/YaLTeR/niri/wiki/IPC
//   https://github.com/YaLTeR/niri  →  niri-ipc/src/lib.rs  (Request/Response/Event)
//
// Requests sent (serde external tagging — unit variants are bare JSON strings):
//   "EventStream"                                    → {"Ok":"Handled"} then events
//   niri msg action focus-workspace <idx>            → focus a workspace (1-based Index)
//
// Events consumed (exact serde variant names → single-key objects):
//   {"WorkspacesChanged":{"workspaces":[Workspace,…]}}
//   {"WorkspaceActivated":{"id":u64,"focused":bool}}
//   {"WorkspaceUrgencyChanged":{"id":u64,"urgent":bool}}
//   {"WindowsChanged":{"windows":[Window,…]}}
//   {"WindowOpenedOrChanged":{"window":Window}}
//   {"WindowClosed":{"id":u64}}
//   {"WindowFocusChanged":{"id":Option<u64>}}
//
//   Workspace = { id, idx, name?, output?, is_urgent, is_active, is_focused, … }
//   Window    = { id, title?, app_id?, workspace_id?, is_focused, is_urgent, … }
//
// Only active when Compositor.isNiri; entirely inert on Hyprland.
// ──────────────────────────────────────────────────────────────────────────────

QtObject {
    id: root

    // ── Public state ──────────────────────────────────────────────────────────
    // Workspace dots read this: [{ id, idx, name, output, isActive, isFocused, isUrgent }]
    property var    workspaces:          []
    property int    focusedWorkspaceId:  -1
    // Active window title for the center notch (falls back to "Desktop").
    property string focusedTitle:        "Desktop"
    // True once the event stream is live (first EventStream reply received).
    property bool   ready:               false

    // Every open window, in CompositorService's shape:
    //   [{ handle, title, appId, workspaceId, output, focused, x, y, w, h }]
    // Built from the same event stream that already maintains _windows, so it
    // costs nothing beyond the array allocation. Geometry is zero because niri's
    // window events do not carry absolute screen boxes — the niri backend
    // declares windowGeometry: false to say so, rather than shipping zeros that
    // a screenshot picker would treat as real.
    readonly property var windows: {
        const out = []
        const m   = root._windows
        const ids = Object.keys(m)
        for (let i = 0; i < ids.length; i++) {
            const id = ids[i]
            out.push({
                handle:      id,
                title:       m[id].title,
                appId:       m[id].appId,
                workspaceId: m[id].workspaceId,
                output:      "",
                focused:     Number(id) === root.focusedWindowId,
                x: 0, y: 0, width: 0, height: 0
            })
        }
        return out
    }

    // ── Internals ─────────────────────────────────────────────────────────────
    property int  focusedWindowId: -1
    property var  _windows:        ({})   // id → { title, appId, workspaceId }
    readonly property bool _active: Compositor.isNiri
    property int  _backoff: 500            // reconnect backoff (ms), capped below

    // ── Socket — event stream ─────────────────────────────────────────────────
    property Socket _sock: Socket {
        path: Compositor.niriSocket
        connected: false                   // toggled on by _sync() when isNiri

        parser: SplitParser {
            // niri emits one JSON object per line (default "\n" split marker).
            onRead: function(line) { root._onLine(line) }
        }

        onConnectionStateChanged: {
            if (connected) {
                root._backoff = 500
                // Request the event stream (unit variant → bare JSON string).
                write("\"EventStream\"\n")
                flush()
            } else {
                root.ready = false
                if (root._active) root._reconnectTimer.restart()
            }
        }

        onError: {
            root.ready = false
            if (root._active) root._reconnectTimer.restart()
        }
    }

    // Reconnect-on-drop with capped exponential backoff.
    property Timer _reconnectTimer: Timer {
        repeat: false
        interval: root._backoff
        onTriggered: {
            if (!root._active) return
            root._backoff = Math.min(root._backoff * 2, 5000)
            root._sock.connected = false
            root._sock.connected = true
        }
    }

    // ── Activation — start/stop with the compositor selection ─────────────────
    function _sync() {
        if (root._active && root._sock.path !== "") {
            if (!root._sock.connected) root._sock.connected = true
        } else {
            if (root._sock.connected) root._sock.connected = false
        }
    }

    property Connections _compConn: Connections {
        target: Compositor
        function onNameChanged()       { root._sync() }
        function onNiriSocketChanged()  { root._sync() }
    }

    Component.onCompleted: _sync()

    // ── Line handler ──────────────────────────────────────────────────────────
    function _onLine(line) {
        var t = (line || "").trim()
        if (t === "") return
        var msg
        try { msg = JSON.parse(t) }
        catch (e) { return }

        // Reply to our EventStream request: {"Ok":"Handled"} (or {"Err":…}).
        if (msg.Ok !== undefined || msg.Err !== undefined) {
            if (msg.Ok !== undefined) root.ready = true
            return
        }

        // Otherwise an Event — a single-key object {EventName: payload}.
        var name = Object.keys(msg)[0]
        var d    = msg[name]
        switch (name) {
            case "WorkspacesChanged":        root._onWorkspaces(d.workspaces);         break
            case "WorkspaceActivated":       root._onWsActivated(d.id, d.focused);     break
            case "WorkspaceUrgencyChanged":  root._onWsUrgency(d.id, d.urgent);        break
            case "WindowsChanged":           root._onWindows(d.windows);               break
            case "WindowOpenedOrChanged":    root._onWindow(d.window);                 break
            case "WindowClosed":             root._onWindowClosed(d.id);               break
            case "WindowFocusChanged":       root._onFocusChanged(d.id);               break
            default: /* WorkspaceActiveWindowChanged, layout, casts, … — ignored */    break
        }
    }

    // ── Workspace events ──────────────────────────────────────────────────────
    function _onWorkspaces(list) {
        if (!list) return
        var arr = []
        var focused = -1
        for (var i = 0; i < list.length; i++) {
            var w = list[i]
            arr.push({
                id:        w.id,
                idx:       w.idx,
                name:      w.name   || "",
                output:    w.output || "",
                isActive:  !!w.is_active,
                isFocused: !!w.is_focused,
                isUrgent:  !!w.is_urgent
            })
            if (w.is_focused) focused = w.id
        }
        arr.sort(function(a, b) { return a.idx - b.idx })
        root.workspaces = arr
        if (focused !== -1) root.focusedWorkspaceId = focused
    }

    function _onWsActivated(id, focused) {
        var arr = root.workspaces.slice()
        var out = ""
        for (var i = 0; i < arr.length; i++)
            if (arr[i].id === id) out = arr[i].output
        for (var j = 0; j < arr.length; j++) {
            var w = arr[j]
            if (w.output === out) w.isActive = (w.id === id)
            if (focused)          w.isFocused = (w.id === id)
        }
        root.workspaces = arr
        if (focused) root.focusedWorkspaceId = id
    }

    function _onWsUrgency(id, urgent) {
        var arr = root.workspaces.slice()
        for (var i = 0; i < arr.length; i++)
            if (arr[i].id === id) arr[i].isUrgent = !!urgent
        root.workspaces = arr
    }

    // ── Window events ─────────────────────────────────────────────────────────
    function _onWindows(list) {
        if (!list) return
        var m   = ({})
        var fid = -1
        for (var i = 0; i < list.length; i++) {
            var w = list[i]
            m[w.id] = {
                title:       w.title  || "",
                appId:       w.app_id || "",
                workspaceId: w.workspace_id !== undefined && w.workspace_id !== null
                             ? w.workspace_id : -1
            }
            if (w.is_focused) fid = w.id
        }
        root._windows = m
        if (fid !== -1) root.focusedWindowId = fid
        root._refreshTitle()
    }

    // Rebuilt rather than mutated in place. A `var` property assigned the object
    // it already holds is not reliably a change, so the `windows` binding above
    // would keep showing the previous list while `_windows` quietly moved on.
    function _copyWindows() {
        var out = ({})
        var ids = Object.keys(root._windows)
        for (var i = 0; i < ids.length; i++) out[ids[i]] = root._windows[ids[i]]
        return out
    }

    function _onWindow(w) {
        if (!w) return
        var m = root._copyWindows()
        m[w.id] = {
            title:       w.title  || "",
            appId:       w.app_id || "",
            workspaceId: w.workspace_id !== undefined && w.workspace_id !== null
                         ? w.workspace_id : -1
        }
        root._windows = m
        if (w.is_focused) root.focusedWindowId = w.id
        if (w.id === root.focusedWindowId) root._refreshTitle()
    }

    function _onWindowClosed(id) {
        if (root._windows[id] !== undefined) {
            var m = root._copyWindows()
            delete m[id]
            root._windows = m
        }
        if (id === root.focusedWindowId) { root.focusedWindowId = -1; root._refreshTitle() }
    }

    function _onFocusChanged(id) {
        root.focusedWindowId = (id === null || id === undefined) ? -1 : id
        root._refreshTitle()
    }

    function _refreshTitle() {
        var id = root.focusedWindowId
        if (id === -1 || id === null || !root._windows[id]) {
            root.focusedTitle = "Desktop"
            return
        }
        var t = root._windows[id].title
        root.focusedTitle = (t && t !== "") ? t : "Desktop"
    }

    // ── Actions ───────────────────────────────────────────────────────────────
    property Process _actionProc: Process { command: []; running: false }

    // Focus a workspace by its 1-based index (niri FocusWorkspace / Index reference).
    // idx comes straight from the workspace model — coerced to a positional arg.
    function focusWorkspace(idx) {
        if (!root._active) return
        root._actionProc.command = ["niri", "msg", "action", "focus-workspace", String(idx)]
        root._actionProc.running = false
        root._actionProc.running = true
    }
}
