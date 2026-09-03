import QtQuick
import "../search.js" as Search

// PackagesProvider — "install Blender", from §15's example list.
//
// ── THE ONLY PROVIDER THAT CAN REACH THE NETWORK, AND THE ONLY ONE BEHIND ───
// ── A VERB THE USER TYPED ON PURPOSE ────────────────────────────────────────
//
// `apex search` runs `dnf5 search` and `flatpak search`. Flatpak's is a local
// AppStream cache and costs nothing offline — apex-pkg says so in its own
// comment — but dnf5 may refresh repository metadata, which is a network
// request. §15's constraint is that no provider may reach the network
// implicitly, so this one is unreachable from a plain query: it answers only
// SCOPE.PACKAGES, which parseQuery produces only for a literal "install ",
// "remove ", "uninstall ", "search " or "pkg " prefix.
//
// Typing "blender" alone therefore searches applications, windows and settings
// and touches nothing outside this machine. Typing "install blender" is the
// user asking.
//
// ── The rows are offers, not transactions ───────────────────────────────────
// Installing needs root and removing is irreversible, so both rows carry a
// non-safe class and Enter will not run either. The preview a commit gesture is
// asked for is not prose this shell wrote: it is `apex resolve <name>`, which
// exists for exactly this and says so — "Read-only, so it needs no root: 'what
// would this do' should never cost a password."

QtObject {
    id: p

    property var    api:   null
    property string query: ""
    property string data:  ""

    readonly property var _parsed: Search.parseQuery(p.query)

    readonly property var results: {
        if (p.query === "" || p.data === "")
            return []
        if (p._parsed.scope !== Search.SCOPE.PACKAGES)
            return []

        // "remove blender" offers to remove; everything else offers to install.
        // The intent comes from the verb the user typed, never from ranking:
        // guessing which of two opposite operations somebody meant is not a
        // thing to be clever about.
        const removing = p._parsed.intent === "remove"
        const action = removing ? "pkg.remove" : "pkg.install"
        const verb = removing ? "Remove " : "Install "

        const out = []
        for (const pkg of Search.parsePackageSearch(p.data)) {
            const sc = Search.scoreFields(pkg.name, pkg.summary, p._parsed.term)
            if (sc <= 0)
                continue
            out.push({
                "name":   verb + pkg.name,
                "detail": (pkg.source === "flatpak" ? "Flatpak" : "Package")
                          + (pkg.summary === "" ? "" : " · " + pkg.summary),
                "glyph":  removing ? "󰀦" : "󰏔",
                "action": action,
                "arg":    pkg.name,
                "score":  sc
            })
        }
        return out
    }
}
