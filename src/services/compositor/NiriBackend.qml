import QtQuick
import Quickshell
import Quickshell.Io
import "../../"
import "boxes.js" as Boxes

// ─── NiriBackend ──────────────────────────────────────────────────────────────
// CompositorService's niri adapter. Almost all of the state comes from
// NiriService, which was already a complete niri IPC client before this facade
// existed: one socket, one EventStream request, and no polling at all — the
// initial burst of events *is* the state fetch.
//
// So this file is deliberately thin. It maps NiriService's model into the shape
// CompositorService publishes and owns the action verbs, which NiriService did
// not have beyond focusWorkspace. Duplicating the event handling here to make
// the backend look substantial would mean two clients on one socket.
//
// Actions go out through `niri msg action`, not the socket. The socket carries
// an event stream that this shell must not interleave requests into, and the CLI
// is niri's own supported entry point for one-shot actions.
// ──────────────────────────────────────────────────────────────────────────────

QtObject {
    id: root

    // niri is ready when its event stream has replied, not when this object is
    // constructed: reading workspaces before then gives an empty list, and a
    // workspace strip that renders empty and then pops is worse than one that
    // waits.
    readonly property bool ready: NiriService.ready

    readonly property var capabilities: ({
        workspaces:           true,
        workspaceSwitch:      true,
        // niri has no scratchpad concept at all.
        specialWorkspace:     false,
        windows:              true,
        // The window events carry no absolute screen box, so a picker would be
        // pointing slurp at zeros. False here means the caller falls back to a
        // plain drag-a-rectangle slurp, which is what it did before.
        windowGeometry:       false,
        outputGeometry:       true,
        windowFocus:          true,
        windowMove:           true,
        windowClose:          true,
        overview:             true,
        // Border colour and gaps are config.kdl, reloaded from disk — there is
        // no live keyword equivalent of `hyprctl keyword`.
        accentBorder:         false,
        gaps:                 false,
        // No submap equivalent: niri cannot be told to route every key to one
        // client, so keybind capture stays off here.
        keyboardInterception: false
    })

    // Nothing here costs anything — the event stream runs for the workspace
    // strip regardless — so demand is accepted and ignored.
    property bool windowsWanted: false
    property bool titleWanted:   false

    // ── State, straight from the event stream ─────────────────────────────────
    readonly property var    workspaces:         NiriService.workspaces
    readonly property var    windows:            NiriService.windows
    readonly property string focusedTitle:       NiriService.focusedTitle
    readonly property int    focusedWorkspaceId: NiriService.focusedWorkspaceId

    // The focused output is whichever workspace holds focus. niri reports the
    // output per workspace, so there is no separate query for it.
    readonly property string focusedOutput: {
        const ws = NiriService.workspaces
        for (let i = 0; i < ws.length; i++)
            if (ws[i].id === NiriService.focusedWorkspaceId)
                return ws[i].output || ""
        return ""
    }

    readonly property string windowBoxScript: ""            // no geometry
    readonly property string outputBoxScript: Boxes.WLR_OUTPUTS

    // ── Actions ───────────────────────────────────────────────────────────────
    property Process _proc: Process { command: []; running: false }

    function _action(argv) {
        root._proc.command = ["niri", "msg", "action"].concat(argv)
        root._proc.running = false
        root._proc.running = true
    }

    // ref is the 1-based workspace index from the model's `idx`, which is what
    // niri's FocusWorkspace Index reference wants — not the `id`.
    function focusWorkspace(ref) { NiriService.focusWorkspace(ref) }

    function toggleSpecialWorkspace(name) { /* unreachable: capability is false */ }

    function focusWindow(handle) {
        root._action(["focus-window", "--id", String(handle)])
    }

    function closeWindow(handle) {
        root._action(["close-window", "--id", String(handle)])
    }

    function moveWindowToWorkspace(handle, ws) {
        root._action(["move-window-to-workspace", "--window-id", String(handle), String(ws)])
    }

    function toggleOverview() { root._action(["toggle-overview"]) }

    function setAccentBorder(hex)        { /* unreachable: capability is false */ }
    function setGaps(inner, outer)       { /* unreachable: capability is false */ }
    function setKeyboardInterception(on) { /* unreachable: capability is false */ }
}
