import QtQuick
import "../search.js" as Search
import "../../"

// ClipboardProvider — "recent clipboard", from §15's example list.
//
// Reads ClipboardService.entries, which cliphist fills. The list is refreshed
// ONCE when the launcher opens — SearchService calls load() on demand, not on a
// keystroke — so typing costs nothing and a closed launcher costs nothing.
//
// ── What is not offered ─────────────────────────────────────────────────────
// Image entries. cliphist stores them as a binary blob with a "[[ binary data
// … ]]" placeholder for a preview, and a row whose visible text is that
// placeholder is a row nobody can search for. They stay in the clipboard popup,
// which can actually render them.
//
// ── Clipboard text is the most hostile input on this surface ────────────────
// It is whatever was last copied, from any page on any site. Control characters
// are stripped and the length is capped by the same sanitiser a plugin's rows
// go through — a newline here would draw over the row beneath it, which on a
// list where the next row might be "Restart" is not a cosmetic problem.

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
        for (const e of ClipboardService.entries) {
            if (!e || e.isImage)
                continue
            const preview = String(e.preview ?? "")
            if (preview === "")
                continue
            const sc = Search.score(preview, term)
            if (sc <= 0)
                continue
            out.push({ "name": preview, "detail": "Clipboard · Enter copies it",
                       "glyph": "󰅍", "payload": String(e.id ?? ""),
                       // Below an application of the same match quality: the
                       // launcher is an app launcher first, and a clipboard
                       // entry that happens to contain the word "firefox" must
                       // not sit above Firefox.
                       "score": sc - 30 })
        }
        return out
    }
}
