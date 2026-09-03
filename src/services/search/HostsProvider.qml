import QtQuick
import "../search.js" as Search

// HostsProvider — "SSH homelab", from §15's example list.
//
// ── IT LISTS. IT DOES NOT PROBE. ────────────────────────────────────────────
// This is the constraint that shaped the whole provider. §20's `apex host list`
// reads a local TOML registry and a local capability cache; it opens no
// connection. So does this. A device is offered as a row, and an ssh connection
// is made only when the user commits the action, in a terminal they can see.
// A provider that probed reachability while somebody typed would be sending
// packets to other people's machines on a keystroke, over whatever network the
// laptop happens to be on.
//
// The registry's own `caps` answers "does this device have the agent runtime",
// and this provider does not care: it offers a terminal, which every ssh
// destination can give. It still reports whether a probe has happened, because
// presenting a never-probed device as a known-good one would be inventing
// capability.
//
// ── The shape trap ──────────────────────────────────────────────────────────
// `apex host list --json` prints an OBJECT KEYED BY HOST NAME, not an array.
// The house pattern next door is `if (Array.isArray(fresh))` — AgentService
// does it twice — and writing that here by reflex leaves the section
// permanently empty with nothing logged. Search.parseHostRegistry refuses a
// top-level array BY NAME so a change of shape fails loudly instead.
//
// ── The subcommand does not exist yet on this machine ───────────────────────
// `apex host` lands with §20 and today's installed apex answers
// "unrecognized subcommand". That is a NORMAL state: `data` stays empty, this
// returns no rows, and nothing is logged.

QtObject {
    id: p

    property var    api:   null
    property string query: ""
    property string data:  ""

    readonly property var _parsed: Search.parseQuery(p.query)
    readonly property var _reg: Search.parseHostRegistry(p.data)

    readonly property var results: {
        if (p.query === "" || p._parsed.term === "")
            return []
        if (!p._reg.ok)
            return []
        const term = p._parsed.term
        const out = []
        for (const h of p._reg.hosts) {
            const sc = Search.scoreFields(h.name, h.ssh + " " + h.note + " ssh device remote",
                                          term)
            if (sc <= 0)
                continue
            out.push({
                "name":   "SSH " + h.name,
                "detail": "Device · " + h.ssh
                          + (h.probed ? (h.apex ? " · APEX runtime" : " · probed")
                                      : " · not probed yet"),
                "glyph":  "󰢹",
                "action": "host.terminal",
                "arg":    h.name,
                "score":  sc
            })
        }
        return out
    }
}
