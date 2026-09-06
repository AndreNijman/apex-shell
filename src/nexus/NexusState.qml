pragma Singleton
import QtQuick
import Quickshell
import "../"

// ─────────────────────────────────────────────────────────────────────────────
// NexusState — open/close and current page for the standalone settings window.
//
// Kept separate from Popups for a reason: everything in Popups is a transient
// surface anchored to the bar that closes on click-outside and on any compositor
// focus change. Nexus is not that. It is a window you leave open while you work,
// and the popup auto-dismiss machinery would close it constantly.
//
// One window per screen exists (like the dashboard), so `screenName` records
// which one owns the current session.
// ─────────────────────────────────────────────────────────────────────────────

QtObject {
    id: root

    property bool open: false

    // Which output the window is showing on. Set at open time from the focused
    // screen so it appears where the user is looking.
    property string screenName: ""

    // …and where it actually shows, once the output it was opened on may have
    // gone. Applying a display layout can disable the very monitor the settings
    // window is on; the window for that output is destroyed with it, and a
    // screenName naming an output that no longer exists matched nothing, so
    // Settings vanished for the rest of the session with no way to reopen it on
    // the same page. Falling back to the first live output keeps the window —
    // and the display confirmation that was inside it — reachable.
    readonly property string effectiveScreen: {
        const want = root.screenName
        const live = Quickshell.screens
        for (let i = 0; i < live.length; i++)
            if (live[i].name === want) return want
        return live.length > 0 ? live[0].name : want
    }

    property string page: "appearance"

    function openAt(pageId, screen) {
        if (pageId && pageId !== "" && PageRegistry.has(pageId))
            root.page = pageId
        if (screen && screen !== "")
            root.screenName = screen
        root.open = true
    }

    function close() {
        root.open = false
    }

    function toggle(pageId, screen) {
        // Re-invoking with a DIFFERENT page while already open switches page
        // rather than closing: a keybind for "open Nexus at Keybinds" that
        // closed the window when you were already on Appearance would be
        // useless.
        if (root.open && (!pageId || pageId === "" || pageId === root.page)) {
            root.close()
            return
        }
        root.openAt(pageId, screen)
    }
}
