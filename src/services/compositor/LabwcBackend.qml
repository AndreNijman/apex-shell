import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.WindowManager
import "../../"
import "boxes.js" as Boxes

// ─── LabwcBackend ─────────────────────────────────────────────────────────────
// CompositorService's labwc adapter — APEX Floating.
//
// labwc has no IPC socket and never will: that is a design decision upstream,
// not a gap. It is controllable only through Wayland protocols, so this backend
// is built entirely out of them:
//
//   ext-workspace-v1                    workspaces (list, active, activate)
//   wlr-foreign-toplevel-management      windows (list, activate, close)
//   wlr-output-management (wlr-randr)    output boxes
//
// That is more capability than "no IPC" suggests and less than Hyprland's. The
// honest shape is a capability map with real trues in it, which is exactly why
// consumers ask `can.windowMove` rather than `isLabwc` — half of what they used
// to skip on labwc actually works.
//
// ── Identity is the list position ────────────────────────────────────────────
// labwc leaves ext-workspace's id empty, so there is nothing stable to key on.
// The index into `workspaces` is the identity, and it is what focusWorkspace()
// takes. This is the one backend where a workspace ref is positional, which is
// why callers must take refs from CompositorService.workspaces rather than
// making them up.
// ──────────────────────────────────────────────────────────────────────────────

QtObject {
    id: root

    // The windowset list populates a moment after startup rather than at
    // construction, so readiness is "there is something to show".
    readonly property bool ready: WindowManager.windowsets !== null

    readonly property var capabilities: ({
        workspaces:           true,
        workspaceSwitch:      true,
        specialWorkspace:     false,
        windows:              true,
        // foreign-toplevel reports title and app id but no geometry.
        windowGeometry:       false,
        outputGeometry:       true,
        windowFocus:          true,
        // ext-workspace can activate a workspace and foreign-toplevel can
        // activate a window, but no protocol moves a window between workspaces.
        windowMove:           false,
        windowClose:          true,
        overview:             false,
        // The border colour lives in themerc-override, which matugen generates
        // from the wallpaper. There is no live keyword equivalent, and having
        // two writers for one file is how the generated one wins at random.
        accentBorder:         false,
        gaps:                 false,
        keyboardInterception: false
    })

    // Both feeds are protocol objects the compositor pushes. Nothing polls, so
    // demand is accepted and ignored.
    property bool windowsWanted: false
    property bool titleWanted:   false

    // ── Workspaces ────────────────────────────────────────────────────────────
    readonly property var workspaces: {
        const out = []
        const src = WindowManager.windowsets || []
        for (let i = 0; i < src.length; i++) {
            const w = src[i]
            out.push({
                id:        i,                    // positional; see the header
                idx:       i,
                name:      (w && w.name) ? w.name : String(i + 1),
                output:    "",
                isActive:  !!(w && w.active),
                isFocused: !!(w && w.active),
                isUrgent:  false
            })
        }
        return out
    }

    readonly property int focusedWorkspaceId: {
        const ws = root.workspaces
        for (let i = 0; i < ws.length; i++)
            if (ws[i].isActive) return ws[i].id
        return -1
    }

    // ── Windows ───────────────────────────────────────────────────────────────
    // The handle IS the toplevel object: foreign-toplevel has no id, and the
    // object is what activate() and close() are called on. It is opaque and
    // valid only for this session, which is what CompositorService documents a
    // handle to be.
    readonly property var windows: {
        const out = []
        const src = (ToplevelManager.toplevels && ToplevelManager.toplevels.values) || []
        const active = ToplevelManager.activeToplevel
        for (let i = 0; i < src.length; i++) {
            const t = src[i]
            if (!t || t.parent) continue          // skip dialogs owned by a window
            out.push({
                handle:      t,
                title:       t.title || "",
                appId:       (t.appId || "").trim(),
                workspaceId: -1,                  // not reported by the protocol
                output:      "",
                focused:     t === active,
                x: 0, y: 0, width: 0, height: 0
            })
        }
        return out
    }

    readonly property string focusedTitle: {
        const t = ToplevelManager.activeToplevel
        return (t && t.title && t.title !== "") ? t.title : "Desktop"
    }

    readonly property string focusedAppName: {
        const t = ToplevelManager.activeToplevel
        if (!t) return "Desktop"
        const a = (t.appId || "").trim()
        return a !== "" ? a : ((t.title && t.title !== "") ? t.title : "Desktop")
    }

    // foreign-toplevel gives a screen list per window, so the focused output is
    // the screen the active window is on. With no active window there is nothing
    // to report — the bar falls back to its own screen name.
    readonly property string focusedOutput: {
        const t = ToplevelManager.activeToplevel
        if (!t || !t.screens || t.screens.length === 0) return ""
        return t.screens[0].name || ""
    }

    readonly property string windowBoxScript: ""            // no geometry
    readonly property string outputBoxScript: Boxes.WLR_OUTPUTS

    // ── Actions ───────────────────────────────────────────────────────────────
    function focusWorkspace(ref) {
        const src = WindowManager.windowsets || []
        const ws = src[ref]
        if (ws && ws.canActivate) ws.activate()
    }

    function focusWindow(handle) {
        if (handle && typeof handle.activate === "function") handle.activate()
    }

    function closeWindow(handle) {
        if (handle && typeof handle.close === "function") handle.close()
    }

    function toggleSpecialWorkspace(name)      { /* unreachable: capability is false */ }
    function moveWindowToWorkspace(handle, ws) { /* unreachable: capability is false */ }
    function toggleOverview()                  { /* unreachable: capability is false */ }
    function setAccentBorder(hex)              { /* unreachable: capability is false */ }
    function setGaps(inner, outer)             { /* unreachable: capability is false */ }
    function readGaps(callback)                { callback(false, null) }
    function setKeyboardInterception(on)       { /* unreachable: capability is false */ }
}
