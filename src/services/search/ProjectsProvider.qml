import QtQuick
import "../search.js" as Search

// ProjectsProvider — "open project apex-os", from §15's example list.
//
// ── This provider owns no Process ───────────────────────────────────────────
// It declares nothing to run and cannot ask for anything to be run. The host
// decides — Search.requestArgv("projects", …) returns
// `apex project list --json` — runs it, and writes the output into `data`.
// A static check asserts that no file in this directory so much as names
// `Process`, `Quickshell.Io`, `FileView` or `Socket`, which is what makes
// "providers do not spawn" structural rather than reviewed.
//
// ── One subprocess per launcher session, not per keystroke ──────────────────
// The argv is the same for every query, and the scheduler's cache is keyed by
// argv, so the first keystroke that reaches this provider pays for the listing
// and every later one is a cache hit. Typing "apex-os" is one process, not
// seven.
//
// ── A missing runtime is a normal state ─────────────────────────────────────
// `apex project list` exits non-zero when the agent runtime is not installed,
// and the runtime is opt-in. `data` is then empty, this returns no rows, and
// nothing is logged: a warning per launcher open about something working as
// designed is how a log becomes unreadable.

QtObject {
    id: p

    property var    api:   null
    property string query: ""

    // Written by the host with the output of the read it performed on this
    // provider's behalf. The one thing a built-in gets that a plugin cannot —
    // see SearchService's header for why that asymmetry is deliberate.
    property string data: ""

    readonly property var _parsed: Search.parseQuery(p.query)
    readonly property var _list: Search.parseProjectList(p.data)

    readonly property var results: {
        if (p.query === "" || p._parsed.term === "")
            return []
        if (!p._list.ok)
            return []
        const term = p._parsed.term
        const out = []
        for (const pr of p._list.projects) {
            const meta = pr.slug + " " + pr.root + " " + pr.languages.join(" ")
            const sc = Search.scoreFields(pr.name, meta, term)
            if (sc <= 0)
                continue
            out.push({
                "name":   "Go to " + pr.name,
                "detail": "Project · " + (pr.languages.length > 0
                              ? pr.languages.join(", ") + " · " : "") + pr.root,
                "glyph":  "󰉋",
                "action": "project.open",
                "arg":    pr.slug,
                "score":  sc
            })
        }
        return out
    }
}
