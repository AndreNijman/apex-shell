import QtQuick
import "../search.js" as Search
import "../../nexus"

// SettingsProvider — "APEX setting: 144 Hz", which is §15's example and is a
// search for a VALUE rather than for a page title.
//
// Nothing in PageRegistry contains the string "144 Hz"; the page is called
// "Display". So the index is search.js's SETTINGS table — the settings a person
// goes looking for, each pointing at the page that holds it, each carrying the
// words they would actually type. PageRegistry stays the single definition of
// what a page IS; this only decides which one a query lands on.
//
// ── It points at a page. It does not change a value. ────────────────────────
// Deliberate, and it is the same rule the action classes encode: a launcher
// that could set a refresh rate from a fuzzy match would be changing hardware
// state on Enter. Every row here is safe because every row only navigates.

QtObject {
    id: p

    property var    api:   null
    property string query: ""

    readonly property var _parsed: Search.parseQuery(p.query)

    readonly property var results: {
        if (p.query === "" || p._parsed.term === "")
            return []
        const term = p._parsed.term
        const out = []

        for (const s of Search.SETTINGS) {
            // A table entry naming a page that no longer exists would open
            // nothing. The suite asserts every page id resolves; this is the
            // runtime half of the same rule, so a row is never offered for a
            // page the shell cannot show.
            if (!PageRegistry.has(s.page))
                continue
            const page = PageRegistry.pageFor(s.page)
            const sc = Search.scoreFields(s.name, s.keywords + " " + page.title, term)
            if (sc <= 0)
                continue
            out.push({ "name": s.name, "detail": "Settings · " + page.title,
                       "glyph": page.icon, "payload": s.page, "score": sc })
        }

        // The pages themselves, so "keybinds" finds the Keybinds page even
        // though no SETTINGS row is called that.
        for (const page of PageRegistry.pages) {
            const sc = Search.scoreFields(page.title, page.subtitle, term)
            if (sc <= 0)
                continue
            out.push({ "name": page.title, "detail": "Settings · " + page.subtitle,
                       "glyph": page.icon, "payload": page.id, "score": sc - 20 })
        }
        return out
    }
}
