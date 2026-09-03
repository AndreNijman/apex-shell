import QtQuick
import "../search.js" as Search

// CommandsProvider — the rows that DO something to the machine.
//
// "restart Bluetooth" is §15's own example, and it is the reason this whole
// feature needed a class system: a command surface reached by fuzzy match while
// typing can put "Restart" one keystroke away from "Restore session".
//
// This provider offers the actions that take NO argument. Everything that needs
// one — install a package, open a device, attach to a session — is offered by
// the provider that knows the arguments, because a row reading "Install a
// package" with nothing to install is not a result.
//
// It invents nothing. The titles, the keywords, the class, the privilege and
// the argv all come out of search.js's ACTIONS table, which is the only place
// in this feature that knows how to run anything. A provider that could name
// its own command would be the `system` permission the plugin platform refuses,
// arrived at from the inside.

QtObject {
    id: p

    property var    api:   null
    property string query: ""

    readonly property var _parsed: Search.parseQuery(p.query)

    // The badge glyph. A command row has to be distinguishable from a search
    // result AT A GLANCE, which is §15's third requirement about this class of
    // row — the launcher additionally renders the class label, but a shape the
    // eye catches before it reads is what stops the near-miss.
    function _glyph(klass) {
        if (klass === Search.KLASS.DESTRUCTIVE) return "󰀦"
        if (klass === Search.KLASS.CHANGES)     return "󰑓"
        return "󰘳"
    }

    readonly property var results: {
        if (p.query === "" || p._parsed.term === "")
            return []
        const term = p._parsed.term
        const out = []

        for (const id of Search.ACTION_IDS) {
            const a = Search.ACTIONS[id]
            // Argument-taking actions belong to the providers that can fill
            // them in. Explicitly `!== ""` rather than a truthiness test.
            if (a.arg !== "")
                continue
            const s = Search.scoreFields(a.title, a.keywords, term)
            if (s <= 0)
                continue
            out.push({
                "name":   a.title,
                "detail": Search.KLASS_LABELS[a.klass] === ""
                              ? a.permission
                              : Search.KLASS_LABELS[a.klass] + " · " + a.permission,
                "glyph":  p._glyph(a.klass),
                "action": id,
                "score":  s
            })
        }

        // ── The AI hand-off ──────────────────────────────────────────────────
        // §15 lists "Claude: explain this screenshot". That is a screen
        // capture, an image upload and a model call — §14's surface and a
        // feature in its own right, not a launcher row. Building a second,
        // worse version of it behind a search box would repeat the mistake §3
        // names about the Agent Center being "a supervisor and navigator, not a
        // replacement for the terminal". So the launcher navigates to where
        // sessions actually live, and the gap is documented rather than papered
        // over. See AI_HANDOFF in search.js.
        const ai = Search.AI_HANDOFF
        const aiScore = Search.scoreFields(ai.name, ai.keywords, term)
        if (aiScore > 0)
            out.push({ "name": ai.name, "detail": ai.detail, "glyph": "󰚩",
                       "payload": "agents", "score": aiScore })

        return out
    }
}
