// ─── agentgraph.js ───────────────────────────────────────────────────────────
// What a session STARTED, read out of the runtime's own record (roadmap
// P1-020).
//
// A session is not one thing. Claude delegates to subagents, and every adapter
// forks MCP servers, language servers and whatever a tool call runs. Until the
// daemon grew `SessionInfo.children` the Agent Center had no way to tell an
// agent that had six subagents working from one sitting idle: both were one
// row saying "working".
//
// Pure, like agentstate.js and notifybus.js and for the same reason — this is
// the part with the edge cases, and tests/agentgraph-test.js drives THIS file,
// the one the shell loads, rather than a copy of it. Nothing here does I/O,
// nothing here holds a colour, and every function is data → data so a node
// process can exercise all of them.
//
// ── THE RULE THAT MATTERS MOST: ABSENT IS NOT EMPTY ─────────────────────────
//
// `children` is missing entirely from a record written by a daemon that
// predates the graph — which is every daemon in the shipped image today. It is
// an EMPTY ARRAY on a daemon that has the graph and found nothing.
//
// Those are different facts and the page must say different things. Reading
// the absence as "no subagents" would put a confident "0 subagents" under an
// agent that has six, on the only machine anybody is running. So
// [`supported`] is a three-valued question and the row draws nothing at all
// when the answer is "this runtime cannot tell".
//
// ── AND LIVENESS IS DERIVED, NEVER READ ─────────────────────────────────────
//
// No node carries a state. A child is running when nothing has recorded it
// stopping AND the session it belongs to is still running — asked here, every
// time, out of `ended` and the parent's exit status.
//
// The reason is a failure that happened. A status field is a claim that was
// true when it was written, and a subagent whose `SubagentStop` never arrived
// (the turn was interrupted, the agent was killed, the hook timed out) would
// keep claiming it was working for as long as the record survived. A graph
// that shows a dead agent as alive is worse than one that shows nothing,
// because the person reading it stops checking it.
//
// ── THE THREE WAYS A CHILD CAN END ARE THREE DIFFERENT SENTENCES ────────────
//
// The daemon records WHY a child stopped, and the words differ because the
// facts do:
//
//   reported      the agent published subagent_stop      "finished"
//   parent_stop   the turn ended with it still open      "ended with the turn"
//   parent_exit   the session's process is gone          "ended with the session"
//
// Only the first is a subagent that finished. The other two are the runtime
// saying it can no longer tell — a subagent CAN outlive the turn that
// delegated it, so `parent_stop` is a provisional close the daemon overwrites
// if the real report turns up later. Rendering all three as "finished" would
// be the status-field bug again, one layer up.
//
// ── WHY THE PROCESS TREE IS SUMMARISED AND NOT LISTED ───────────────────────
//
// A confined session's pid is the `bwrap` wrapper, so the agent's own binary
// is a CHILD in the process tree, and under it sit the MCP servers, the
// language servers, and every `apex agent hook` the bridge has ever run. A
// literal list would open with a row called "claude" underneath a row called
// "Claude", which reads as a bug.
//
// So [`processRoots`] lifts the agent's own node out of the way — the one
// whose command name matches the program the session was started with — and
// reports what IT started, each with its own subtree rolled into it. Nothing
// is hidden: the count and the memory of a lifted node's descendants are still
// in its summary. The lift is a heuristic and it is written as one: when the
// name does not match, nothing moves and the tree is drawn as it is.

"use strict"

// A child that nothing has recorded stopping.
function isOpen(child) {
    return !child || child.ended === null || child.ended === undefined
}

// Whether the SESSION is still running. The same rule SessionRow uses, kept
// here so the two cannot drift: a session is live while the runtime has
// recorded neither an exit code nor a signal.
function sessionLive(session) {
    return !!session
        && (session.exit_code === null || session.exit_code === undefined)
        && (session.exit_signal === null || session.exit_signal === undefined)
}

// Three-valued, and the whole point of the file.
//
//   "unknown"  the runtime predates the graph and cannot tell
//   "none"     the runtime looked and this session has started nothing
//   "some"     there is something to draw
function supported(session) {
    if (!session || !Array.isArray(session.children)) return "unknown"
    return session.children.length === 0 ? "none" : "some"
}

function children(session) {
    return (session && Array.isArray(session.children)) ? session.children : []
}

// A child is running when nothing said it stopped AND its session is alive.
// Both halves: a record whose parent died without the sweep reaching it would
// otherwise report a subagent working under an agent that is gone.
function childLive(child, session) {
    return isOpen(child) && sessionLive(session)
}

// What to CALL the end. See the header for why these are four sentences and
// not one boolean.
var END_WORDS = {
    reported:    "finished",
    parent_stop: "ended with the turn",
    parent_exit: "ended with the session"
}

function endWord(child, session) {
    if (childLive(child, session)) return "running"
    if (isOpen(child)) {
        // Open under a parent that is gone. The daemon sweeps on exit, so this
        // is a record it never got to — an older daemon, or a crash between
        // the last write and the process dying. "Unknown" is the honest word;
        // "finished" would be a guess and "running" would be a lie.
        return "unknown"
    }
    return END_WORDS[child.ended_by] || "ended"
}

// True while the end is something the runtime OBSERVED rather than inferred.
// The page leans on this to decide whether a finished subagent deserves the
// success tone or the muted one.
function endIsCertain(child) {
    return !isOpen(child) && child.ended_by === "reported"
}

function subagents(session) {
    return children(session).filter(function(c) { return c.kind === "subagent" })
}

function processes(session) {
    return children(session).filter(function(c) { return c.kind === "process" })
}

// ── Accounting (P1-020 criterion 2) ─────────────────────────────────────────
//
// Mirrors apex-agent-core's `graph::account` deliberately, including the two
// awkward parts, because the shell and `apex agent list` disagreeing about how
// much work a session delegated would be worse than either number alone.
//
//   * wall time is SUMMED across children that overlap, so the total can
//     exceed the session's own age. That is the honest answer to "how much
//     work was delegated"; the union of the intervals answers "how long was
//     the session busy", which the session's elapsed time already says.
//   * a child left open under a dead parent contributes NO time. Otherwise a
//     session that exited last week reports a subagent that has been running
//     for a week.
//   * resident memory is processes only. A subagent runs inside the agent's
//     own process and its cost is already in the parent's; a number there
//     would be invented.
function account(session, now) {
    var live = sessionLive(session)
    var acc = {
        known:    supported(session) !== "unknown",
        total:    0,
        open:     0,
        seconds:  0,
        procs:    0,
        procsRss: 0
    }
    var kids = children(session)
    for (var i = 0; i < kids.length; i++) {
        var c = kids[i]
        var open = isOpen(c) && live
        if (c.kind === "subagent") {
            acc.total += 1
            if (open) acc.open += 1
            acc.seconds += (isOpen(c) && !live)
                ? 0
                : Math.max(0, (c.ended === null || c.ended === undefined ? now : c.ended)
                              - (c.started || 0))
        } else {
            if (!open) continue
            acc.procs += 1
            acc.procsRss += (typeof c.rss_kb === "number" ? c.rss_kb : 0)
        }
    }
    return acc
}

// ── The process tree, one level deep ────────────────────────────────────────

function basename(p) {
    if (!p) return ""
    var parts = String(p).replace(/\/+$/, "").split("/")
    return parts[parts.length - 1] || String(p)
}

// The nodes drawn directly under the session, after the agent's own process is
// lifted out of the way. See the header.
//
// The match is a prefix comparison, not an equality: a process's command name
// is what `/proc` reports and the kernel truncates it to fifteen characters,
// so a program called `language-server-x` arrives as `language-server`.
function processRoots(session) {
    var procs = processes(session)
    var top = procs.filter(function(c) { return !c.parent })
    var self = basename(session && session.program).toLowerCase()
    var lifted = []
    for (var i = 0; i < top.length; i++) {
        var node = top[i]
        var name = String(node.label || "").toLowerCase()
        var isSelf = self.length > 0 && name.length > 0
                     && (self === name || self.indexOf(name) === 0)
        if (isSelf) {
            lifted = lifted.concat(procs.filter(function(c) {
                return c.parent === node.id
            }))
        } else {
            lifted.push(node)
        }
    }
    return lifted
}

// Everything at or under `node`, so a summarised row can say what it stands
// for. Iterative and bounded by the list it walks, because the daemon reads
// /proc without a lock and a recycled pid could in principle close a cycle.
function subtree(session, node) {
    var procs = processes(session)
    var out = [node]
    var frontier = [node.id]
    var seen = {}
    seen[node.id] = true
    while (frontier.length > 0) {
        var id = frontier.shift()
        for (var i = 0; i < procs.length; i++) {
            var c = procs[i]
            if (c.parent !== id || seen[c.id]) continue
            seen[c.id] = true
            out.push(c)
            frontier.push(c.id)
        }
    }
    return out
}

// One process node, with its whole subtree folded into it.
function processSummary(session, node) {
    var all = subtree(session, node)
    var rss = 0
    for (var i = 0; i < all.length; i++)
        rss += (typeof all[i].rss_kb === "number" ? all[i].rss_kb : 0)
    return { label: node.label || "process", count: all.length, rssKb: rss }
}

// ── Words ───────────────────────────────────────────────────────────────────

// Coarse and short, the way a supervisor reads a status list. Matches
// AgentService.elapsed so a subagent's age and its session's age are written
// the same way.
function shortDuration(secs) {
    var s = Math.max(0, Math.floor(secs || 0))
    if (s < 60)   return s + "s"
    if (s < 3600) return Math.floor(s / 60) + "m"
    var h = Math.floor(s / 3600)
    var m = Math.floor((s % 3600) / 60)
    return m > 0 ? h + "h " + m + "m" : h + "h"
}

// Kilobytes as the runtime reports them. Binary units, because this is
// resident memory and every other tool that reports it uses them.
function memoryLabel(kb) {
    var k = Math.max(0, Math.floor(kb || 0))
    if (k < 1024) return k + " KB"
    var mb = k / 1024
    if (mb < 1024) return (mb < 10 ? mb.toFixed(1) : Math.round(mb)) + " MB"
    var gb = mb / 1024
    return (gb < 10 ? gb.toFixed(1) : Math.round(gb)) + " GB"
}

function plural(n, word) {
    return n + " " + word + (n === 1 ? "" : "s")
}

// The one line the session row shows when it is not expanded.
//
// Empty string for a runtime that cannot tell, and empty for a session that
// has started nothing — a row that said "0 subagents" under every agent would
// make the list harder to scan to say nothing at all.
function summary(session, now) {
    if (supported(session) === "unknown") return ""
    var acc = account(session, now)
    var bits = []
    if (acc.total > 0) {
        bits.push(acc.open > 0
            ? acc.open + " of " + plural(acc.total, "subagent") + " running"
            : plural(acc.total, "subagent"))
    }
    if (acc.procs > 0)
        bits.push(plural(acc.procs, "process") + "  ·  " + memoryLabel(acc.procsRss))
    return bits.join("  ·  ")
}

// One subagent, as a row reads it.
function subagentLine(child, session, now) {
    var end = endWord(child, session)
    var secs = (child.ended === null || child.ended === undefined ? now : child.ended)
               - (child.started || 0)
    // A child of a dead parent that nobody closed has no honest duration: the
    // clock kept running and the work did not.
    var age = (isOpen(child) && !sessionLive(session)) ? "" : shortDuration(secs)
    return {
        label:   child.label || "subagent",
        state:   end,
        live:    childLive(child, session),
        certain: endIsCertain(child),
        age:     age
    }
}

if (typeof module !== "undefined" && module.exports)
    module.exports = {
        END_WORDS: END_WORDS,
        isOpen: isOpen,
        sessionLive: sessionLive,
        supported: supported,
        children: children,
        childLive: childLive,
        endWord: endWord,
        endIsCertain: endIsCertain,
        subagents: subagents,
        processes: processes,
        account: account,
        basename: basename,
        processRoots: processRoots,
        subtree: subtree,
        processSummary: processSummary,
        shortDuration: shortDuration,
        memoryLabel: memoryLabel,
        summary: summary,
        subagentLine: subagentLine
    }
