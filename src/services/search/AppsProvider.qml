import QtQuick
import Quickshell
import "../search.js" as Search
import "../"

// AppsProvider — the application half of the surface.
//
// The index is Quickshell's own DesktopEntries, which watches the XDG
// directories and keeps parsed entries live. It replaced a Python script that
// rescanned every applications directory on every launcher open, and CI has an
// invariant about that never coming back; nothing here spawns anything.
//
// ── Ranking ─────────────────────────────────────────────────────────────────
// The tiered matcher in search.js, plus a frecency bonus from LauncherState.
// The bonus is CAPPED at 60, which is less than the distance between two tiers
// (100). That cap is the whole design: an app you use daily should win a tie,
// and it should never beat an app whose name you actually typed the start of.
// Uncapped frecency is how a launcher ends up opening your terminal when you
// typed the first three letters of something else.

QtObject {
    id: p

    property var    api:   null
    property string query: ""

    readonly property var _parsed: Search.parseQuery(p.query)

    // Every visible application, alphabetical. Rebuilt only when the
    // DesktopEntries index itself changes, not on a keystroke.
    readonly property var _all: {
        const out = []
        for (const e of DesktopEntries.applications.values) {
            if (e.noDisplay)
                continue
            const nm = (e.name ?? "").trim()
            if (nm === "")
                continue
            out.push({
                "name": nm,
                "icon": e.icon ?? "",
                // Stable key for pinning and history: the .desktop basename,
                // which survives renames of the visible Name and locale changes.
                "payload": e.id ?? "",
                "entry": e,
                "detail": (e.comment ?? "").trim(),
                "_meta": ((e.keywords ?? "") + " " + (e.comment ?? "")
                          + " " + (e.categories ?? "")).trim()
            })
        }
        out.sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()))
        return out
    }

    readonly property var _byId: {
        const m = ({})
        for (const a of p._all)
            m[a.payload] = a
        return m
    }

    // What an empty query shows. Pinned first, then frecency-ranked recents,
    // then everything else alphabetically — an alphabetical list starting at
    // "Alacritty" is useless as a default view. Read by SearchService as
    // `restingRows`; it is not part of `results`, because a resting view is not
    // an answer to a query and must not be ranked against one.
    readonly property var resting: {
        const seen = ({})
        const out = []
        for (const id of LauncherState.pinned) {
            const a = p._byId[id]
            if (a && !seen[id]) { seen[id] = true; out.push(p._tag(a, "Pinned")) }
        }
        for (const id of LauncherState.topRecent(6)) {
            const a = p._byId[id]
            if (a && !seen[id]) { seen[id] = true; out.push(p._tag(a, "Recent")) }
        }
        for (const a of p._all)
            if (!seen[a.payload]) out.push(a)
        return out
    }

    function _tag(a, tier) {
        return { "name": a.name, "icon": a.icon, "payload": a.payload,
                 "entry": a.entry, "detail": tier, "_meta": a._meta }
    }

    readonly property var results: {
        if (p.query === "" || p._parsed.term === "")
            return []
        const term = p._parsed.term
        const out = []
        for (const a of p._all) {
            let s = Search.scoreFields(a.name, a._meta, term)
            if (s <= 0)
                continue
            // Capped, and deliberately smaller than one tier. See the header.
            s += Math.min(60, LauncherState.score(a.payload) * 6)
            out.push({ "name": a.name, "icon": a.icon, "payload": a.payload,
                       "entry": a.entry, "detail": a.detail, "score": s })
        }
        return out
    }
}
