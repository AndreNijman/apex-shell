import QtQuick
import "../search.js" as Search

// FilesProvider — "~/School/Physics", from §15's example list.
//
// ── What this is, and what it deliberately is not ───────────────────────────
// It is PATH NAVIGATION: type "~/", get the contents of your home directory,
// keep typing to walk down it. Enter on a directory continues into it; Enter on
// a file hands it to the desktop's default handler.
//
// It is NOT a fuzzy index of everything under $HOME. That needs an index —
// plocate's database, or a persistent walk — and APEX ships neither. The
// alternatives are worse than the gap: walking $HOME on a keystroke is exactly
// the "process per provider per keystroke" this design exists to prevent, and a
// launcher that silently built an index of a user's home directory is a
// launcher that made a decision on their behalf about a database of every file
// they own. So the shallow, honest version ships and the gap is written down
// rather than filled with something that would have to be undone.
//
// ── Why typing inside a directory is free ───────────────────────────────────
// The command the host runs is the DIRECTORY's listing, and the leaf the user
// is still spelling is matched here. So "~/Doc" → "~/Documents/pro" →
// "~/Documents/projects" is two listings, not eighteen: the argv only changes
// when the directory does, and the scheduler's cache is keyed by argv.

QtObject {
    id: p

    property var    api:   null
    property string query: ""
    property string data:  ""

    readonly property var _parsed: Search.parseQuery(p.query)
    readonly property var _split: Search.splitPath(p._parsed.term)

    readonly property var results: {
        if (p.query === "" || p.data === "")
            return []
        if (p._parsed.scope !== Search.SCOPE.FILES)
            return []

        const dir = p._split.dir
        const leaf = p._split.leaf
        const out = []

        for (const f of Search.parseDirListing(p.data)) {
            // With nothing typed after the "/" every entry is shown, so a bare
            // "~/" is a directory listing rather than an empty result.
            const sc = leaf === "" ? Search.TIER.WORD - f.name.length
                                   : Search.score(f.name, leaf)
            if (sc <= 0)
                continue
            const shown = dir + f.name + (f.dir ? "/" : "")
            out.push({
                "name":   shown,
                "detail": f.dir ? "Folder · Enter opens it here"
                                : "File · Enter opens it",
                "glyph":  f.dir ? "󰉋" : "󰈔",
                "action": "file.open",
                // The absolute path for the action; the ~-form for the launcher,
                // which puts it back in the search box when the row is a folder.
                "arg":    Search.expandHome(dir, p.api ? p.api.home : "") + f.name,
                "payload": shown,
                "score":  sc
            })
        }
        return out
    }
}
