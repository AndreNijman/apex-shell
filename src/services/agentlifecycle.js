// ─── agentlifecycle.js ───────────────────────────────────────────────────────
// WHICH KIND OF AGENT a row is, as opposed to what state it is in (roadmap
// P1-029, ROADMAP.md §19).
//
// §19 asks the Agent Center to distinguish eight kinds and closes with the
// instruction this file exists to follow: "Do not treat all of these as one
// process-state model." Today it treats seven of them as one. A session driven
// from Claude Remote Control, a session a timer started with nobody present, an
// MCP server acting on a session's behalf and a cloud job all draw the
// identical row as a person's terminal, and the only kinds the page can tell
// apart are the three it happens to have separate delegates for.
//
// Pure, like agentgraph.js and agentstate.js and for the same reason: this is
// the part with the edge cases, and tests/agent-lifecycle-test.js drives THIS
// file, the one the shell loads, rather than a copy of it. Data in, data out.
// No colours, no I/O, no Theme.
//
// ── THE FIELD IS ALREADY ON THE WIRE. THAT WAS THE SURPRISE ─────────────────
//
// apex-agentd has reported `request_origin` on every session record since §7,
// with seven values, and the shell reads NONE of them: `git grep request_origin
// -- src/` on roadmap/v2.2 @ 690014a returns nothing. So most of P1-029 is not
// a daemon change at all. Measured against apex-agent-core/src/policy.rs's
// `RequestOrigin::as_str`, the vocabulary is exactly:
//
//     local-terminal  apex-shell  claude-remote-control
//     scheduled-job   mcp         subagent   cloud-job
//
// ── WHY THIS IS NOT A LOOKUP TABLE ON THAT FIELD ────────────────────────────
//
// Because of "remote-host agent", which is §19's eighth kind and is NOT an
// origin value. A session running on another machine reports its own origin
// from ITS point of view, and that origin is `local-terminal` — a person is
// sitting in front of a terminal, just not this one. Classifying by the field
// alone would label every remote-host agent a local PTY, which is precisely
// the confusion §19 is asking to end, and it would do it on the records where
// the mistake is least visible.
//
// So the kind is a function of the record AND of where the record came from.
// `source` is which listing produced it, which the caller always knows and the
// record cannot: the local daemon, or another host's listing. Both are passed
// by a real caller — SessionRow and RemoteSessionRow — so neither branch here
// is reachable only from a test.
//
// There is deliberately NO third source for a parent's child graph, and the
// reason is a bug this file nearly shipped. agentgraph.js's children carry two
// kinds, "subagent" and "process", and a forked language server is not a
// subagent. A source that stamped SUBAGENT on everything a parent reported
// would mislabel every one of those, so children stay agentgraph's job and
// this file classifies SESSIONS. §19's "subagent" kind arrives the same way
// the other five do, from the runtime's own `subagent` origin value on a
// session record.
//
// ── ABSENT IS NOT LOCAL ─────────────────────────────────────────────────────
//
// `request_origin` is missing from a record written by a daemon that predates
// origin tracking, and apex-agentd is explicit that this is not a measurement:
// policy.rs refuses to default it to `local-terminal` precisely because that
// is the origin §7 reserves root for. The same rule applies one layer up, so an
// absent or unrecognised origin resolves to UNKNOWN and the row is expected to
// draw nothing rather than assert a kind. A confident "local PTY" on a session
// nobody classified is the failure this repository has already shipped once,
// in the form of a failed stat reported as a checked fact.
//
// ── WHERE THE DAEMON GENUINELY CANNOT ANSWER, AND WHY IT IS NOT FAKED ───────
//
// §19 lists "recurring local task" AND "scheduled local task" as two kinds.
// The runtime has ONE value, `scheduled-job`, and nothing on the record says
// whether the timer repeats. The roadmap YAML's own acceptance line lists seven
// kinds rather than §19's eight and merges exactly this pair, so the yaml
// already agrees with what is buildable. Inferring "recurring" from a name, a
// cadence or a count of previous runs would be a guess wearing a label, so
// there is one kind here, SCHEDULED, and [`gap`] reports the merge in words. A
// kind the runtime cannot see is a daemon change, not a QML change.

var LOCAL       = "local-pty";
var REMOTE_CTL  = "remote-controlled";
var SCHEDULED   = "scheduled";
var CLOUD       = "cloud-job";
var REMOTE_HOST = "remote-host";
var SUBAGENT    = "subagent";
var SIDECAR     = "mcp-sidecar";
var UNKNOWN     = "unknown";

// Every kind this build can distinguish, in the order §19 lists them. A test
// that has to hold for all of them says so rather than listing six and missing
// the seventh somebody adds.
var KINDS = [LOCAL, REMOTE_CTL, SCHEDULED, CLOUD, REMOTE_HOST, SUBAGENT, SIDECAR];

// The listings a record can come from. Not a free string: a caller that passed
// "remote" and meant REMOTE_HOST would silently get a local PTY, so an
// unrecognised source is treated as unclassified rather than as local.
var FROM_DAEMON = "daemon";
var FROM_HOST   = "host";
var SOURCES = [FROM_DAEMON, FROM_HOST];

// apex-agent-core/src/policy.rs `RequestOrigin::as_str`, and its `parse`
// accepts "remote-control" as well as the canonical spelling, so both are
// mapped here. Anything not in this table is UNKNOWN by omission, which is the
// behaviour that has to hold for a value a NEWER daemon invents.
var ORIGINS = {
    "local-terminal":        LOCAL,
    // A session the Agent Center started is still a local PTY. §19 does not
    // separate "started from the shell" from "started in a terminal", and
    // inventing a kind the roadmap does not ask for would be as wrong as
    // collapsing two it does.
    "apex-shell":            LOCAL,
    "claude-remote-control": REMOTE_CTL,
    "remote-control":        REMOTE_CTL,
    "scheduled-job":         SCHEDULED,
    "mcp":                   SIDECAR,
    "subagent":              SUBAGENT,
    "cloud-job":             CLOUD
};

var LABELS = {
    "local-pty":         "Terminal",
    "remote-controlled": "Remote Control",
    "scheduled":         "Scheduled",
    "cloud-job":         "Cloud job",
    "remote-host":       "Remote host",
    "subagent":          "Subagent",
    "mcp-sidecar":       "MCP sidecar",
    "unknown":           ""
};

// One glyph each, from the font the rest of the Agent Center uses. UNKNOWN has
// none on purpose: there is nothing to draw when the answer is "this runtime
// cannot tell", and a question mark would read as a fault in the session.
var ICONS = {
    "local-pty":         "",
    "remote-controlled": "󰅺",
    "scheduled":         "󰖔",
    "cloud-job":         "󰃉",
    "remote-host":       "󰍼",
    "subagent":          "󰜈",
    "mcp-sidecar":       "󰈮",
    "unknown":           ""
};

// What each kind means, for a tooltip. Written for somebody who is looking at
// a row and wondering why it is not their terminal.
var MEANINGS = {
    "local-pty":         "A terminal on this machine, started by you.",
    "remote-controlled": "A terminal on this machine being driven from somewhere else.",
    "scheduled":         "Started by a timer, with nobody present.",
    "cloud-job":         "Running on a cloud connector, not on this machine.",
    "remote-host":       "Running on another machine you registered.",
    "subagent":          "Delegated by another session on this machine.",
    "mcp-sidecar":       "An MCP server acting on a session's behalf.",
    "unknown":           "This runtime did not record where this session came from."
};

/// The origin string a record carries, or "" when it carries none.
///
/// Absent and empty are folded together here and only here: both mean the
/// record does not say, which is the one thing [`kindOf`] must not read as
/// local.
function originOf(session) {
    if (!session) return "";
    var o = session.request_origin;
    if (o === undefined || o === null) return "";
    return String(o);
}

/// Which of §19's kinds this record is, given the listing it came from.
///
/// `source` is "daemon" or "host" and is not optional. A caller that does not
/// know where its own records came from cannot classify them, and defaulting
/// it would put the remote-host mistake back.
function kindOf(session, source) {
    if (SOURCES.indexOf(source) === -1) return UNKNOWN;

    // Where the record came from OUTRANKS what it says about itself, and this
    // ordering is the whole design. A remote machine's session reports
    // `local-terminal`, because from its own point of view that is true.
    if (source === FROM_HOST) return REMOTE_HOST;

    var origin = originOf(session);
    if (origin === "") return UNKNOWN;
    var mapped = ORIGINS[origin];
    return mapped === undefined ? UNKNOWN : mapped;
}

/// Whether a row should draw a kind at all.
///
/// False for UNKNOWN, which is what keeps an unclassified session from
/// claiming to be a terminal. The three-valued shape agentgraph.js uses for
/// `children`, applied to the same class of problem.
function known(kind) {
    return KINDS.indexOf(kind) !== -1;
}

function label(kind)   { return LABELS[kind]   === undefined ? "" : LABELS[kind]; }
function icon(kind)    { return ICONS[kind]    === undefined ? "" : ICONS[kind]; }
function meaning(kind) { return MEANINGS[kind] === undefined ? "" : MEANINGS[kind]; }

/// The pill's text: glyph and word, or "" when there is nothing to say.
function badge(session, source) {
    var kind = kindOf(session, source);
    if (!known(kind)) return "";
    return icon(kind) + " " + label(kind);
}

/// What this build cannot distinguish, in words, so the limitation is readable
/// rather than implied by an absence.
///
/// Returned as data rather than printed: the settings page and the help guide
/// are both entitled to say it, and neither should retype it.
function gap() {
    return "This build cannot tell a recurring task from a one-off scheduled " +
           "one: the runtime records both as scheduled and nothing on the " +
           "record says whether the timer repeats.";
}

/// Group a daemon listing by kind, newest last within each kind.
///
/// The Agent Center sorts by state and lifts the two states that want the
/// user; this is the other axis, for a page that wants to show the kinds
/// apart. Stable, and it never drops a session: an unclassified one lands
/// under UNKNOWN rather than vanishing, which is the failure mode of every
/// group-by written as a filter chain.
function groupByKind(sessions, source) {
    var out = {};
    var i;
    for (i = 0; i < KINDS.length; i++) out[KINDS[i]] = [];
    out[UNKNOWN] = [];
    if (!sessions) return out;
    for (i = 0; i < sessions.length; i++) {
        var kind = kindOf(sessions[i], source);
        if (out[kind] === undefined) out[kind] = [];
        out[kind].push(sessions[i]);
    }
    return out;
}

if (typeof module !== "undefined" && module.exports)
    module.exports = {
        LOCAL: LOCAL,
        REMOTE_CTL: REMOTE_CTL,
        SCHEDULED: SCHEDULED,
        CLOUD: CLOUD,
        REMOTE_HOST: REMOTE_HOST,
        SUBAGENT: SUBAGENT,
        SIDECAR: SIDECAR,
        UNKNOWN: UNKNOWN,
        KINDS: KINDS,
        SOURCES: SOURCES,
        FROM_DAEMON: FROM_DAEMON,
        FROM_HOST: FROM_HOST,
        ORIGINS: ORIGINS,
        originOf: originOf,
        kindOf: kindOf,
        known: known,
        label: label,
        icon: icon,
        meaning: meaning,
        badge: badge,
        gap: gap,
        groupByKind: groupByKind
    }
