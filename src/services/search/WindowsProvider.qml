import QtQuick
import "../search.js" as Search
import "../../"

// WindowsProvider — the windows that are open right now.
//
// Reads CompositorService.windows, the adapter surface all three sessions
// answer, so this file names no compositor. Each record is
// { handle, title, appId, workspaceId, output, focused, … }.
//
// ── Titles are hostile input ────────────────────────────────────────────────
// A window title is whatever an application chose to print — a page title from
// any site, the subject line of any message. It goes through the same
// sanitiser a plugin's strings do, and for the same reason: a newline in a row
// draws over two lines and can impersonate the row beneath it.
//
// ── Why enumerating them costs nothing here ─────────────────────────────────
// Window tracking costs a subprocess on Hyprland, so CompositorService gates it
// on a refcount. AppLauncher holds `CompositorService.windowsRef` while the
// launcher is genuinely on screen and hands it back when it is not — this
// provider reads the list and does not make it exist.

QtObject {
    id: p

    property var    api:   null
    property string query: ""

    readonly property var _parsed: Search.parseQuery(p.query)

    readonly property var results: {
        if (p.query === "" || p._parsed.term === "")
            return []
        if (!CompositorService.can.windows)
            return []

        const term = p._parsed.term
        const out = []
        for (const w of CompositorService.windows) {
            if (!w)
                continue
            const title = String(w.title ?? "")
            const app = String(w.appId ?? "")
            const s = Search.scoreFields(title === "" ? app : title, app, term)
            if (s <= 0)
                continue
            const shown = title === "" ? app : title
            // The compositor handle, opaque to search.js. Focus and close both
            // go through the adapter rather than an argv, which is why
            // window.close declares no argv() — see COMPOSITOR_ACTIONS.
            const handle = String(w.handle ?? "")
            if (handle === "")
                continue

            out.push({
                "name":   shown,
                "detail": app + (w.focused ? " · focused" : ""),
                "glyph":  "󰖲",
                "payload": handle,
                "score":  s
            })

            // Closing is a separate row rather than a modifier on the first
            // one, so it can carry its own class. It is not destructive — the
            // application decides what to do about unsaved work, the same as
            // its own close button — but it is not safe either, and Enter on a
            // fuzzy match must not be what closes the window you were reading.
            if (CompositorService.can.windowClose)
                out.push({
                    "name":   "Close " + shown,
                    "detail": app + " · asks the window to close",
                    "glyph":  "󰅖",
                    "action": "window.close",
                    "arg":    handle,
                    // Always below the focus row for the same query. A fixed
                    // offset rather than a second matcher run, so the two can
                    // never swap places.
                    "score":  s - 40
                })
        }
        return out
    }
}
