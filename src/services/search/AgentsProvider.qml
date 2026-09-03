import QtQuick
import "../search.js" as Search
import "../"

// AgentsProvider — the agent sessions the runtime is supervising (§2, §3).
//
// Reads AgentService, which already polls: fast while something holds a
// reference, slow otherwise, and never stopping entirely because a notification
// has to arrive when nothing is on screen. So this provider adds no cost at
// all — it turns a list the shell already has into rows.
//
// ── Two rows per session, and why the second one is destructive ─────────────
// Attaching opens the session's real terminal, which is §3's rule that the
// graphical surface is "a supervisor and navigator, not a replacement for the
// terminal". Stopping one kills its process tree, and whatever it was part-way
// through is not resumed — so it is classed destructive and Enter will not do
// it. That is not caution for its own sake: "kill" and "attach" both start with
// a letter the user is going to type, and the whole point of the class system
// is that the wrong one being under Enter cannot matter.

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

        for (const s of AgentService.sessions) {
            if (!s)
                continue
            const who = String(s.agent ?? "agent")
            const where = String(s.project_name ?? "")
            const label = who + (where === "" ? "" : " · " + where)
            const meta = where + " " + who + " " + String(s.state ?? "")
            const sc = Search.scoreFields(label, meta + " agent session attach", term)
            if (sc <= 0)
                continue
            const id = String(s.id ?? "")
            if (id === "")
                continue

            out.push({ "name": "Attach to " + label,
                       "detail": "Agent · " + AgentService.stateLabel(s.state),
                       "glyph": AgentService.stateIcon(s.state),
                       "action": "agent.attach", "arg": id, "score": sc })
            out.push({ "name": "Stop " + label,
                       "detail": "Agent · ends the session",
                       "glyph": "󰀦",
                       "action": "agent.kill", "arg": id,
                       // Below the attach row for the same query, always. A
                       // fixed offset rather than a separate matcher run, so
                       // the two can never swap places.
                       "score": sc - 40 })
        }
        return out
    }
}
