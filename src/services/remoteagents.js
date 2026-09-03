// ─── remoteagents.js ─────────────────────────────────────────────────────────
// Pure logic behind RemoteAgentService (roadmap §20, P2 phase 9.3): reading
// `apex host list --json`, deciding which trusted devices are worth an ssh
// connection, and turning one query's exit status into a state a status list
// can render.
//
// Kept out of the QML for the same reason src/services/answer.js is: this is
// the part with edge cases, and tests/remote-agents-test.js exercises THIS
// file — the one the shell loads — rather than a copy of it. Nothing here does
// I/O, nothing here knows about Theme, and every function is data → data or
// data → plain string, so a node process can drive all of it. The icons stay
// in QML, next to the ones AgentService already publishes.
//
// ── The three shapes of "we do not know" ────────────────────────────────────
//
// APEX-OS's rule is that a capability which cannot be demonstrated is reported
// absent rather than defaulted, and this file is where that rule is spent. A
// host can be unknown in three genuinely different ways and collapsing them is
// a lie in every direction:
//
//   caps === null          the device has never been probed. We do not know
//                          whether it has an agent runtime. NOT "no".
//   caps.agentd === false  it was probed and it does not have one. Known.
//   never queried yet      it has one, and this session has not asked it yet.
//                          NOT "unreachable" — that is a claim about the
//                          network we have not earned.
//
// ── agentd IS A BINARY, NOT A DAEMON ────────────────────────────────────────
//
// `caps.agentd` records whether the agent runtime is INSTALLED on that device,
// not whether it is running. The runtime is deliberately opt-in — `systemctl
// --user enable --now apex-agentd` — so "installed and not running" is its
// normal state, not a fault. That is why `agentd: true` means only "worth
// asking" here and never "has sessions": the question is answered by the
// query, and a device whose daemon is simply off comes back as NO_RUNTIME,
// which is a state and not an error. Reading `agentd` as "has agents" would
// make every APEX box on the LAN look broken.
//
// ── Why the caps record is rebuilt key by key ───────────────────────────────
//
// `apex host list --json` omits optional fields entirely: `HostCaps` carries
// `skip_serializing_if = "Option::is_none"` on `apex_version`, `variant`, `os`,
// `cpus`, `memory_mib` and `free_mib`, and `skip_serializing_if = "Vec::is_
// empty"` on `gpus` and `accel`. So a legitimately probed host arrives with
// most keys simply missing, and a missing key in JavaScript reads as
// `undefined` — which is truthy-adjacent in enough places that this shell has
// a CompositorService comment about it. normalizeCaps() therefore returns a
// record with every key present, always, and no `undefined` anywhere in it.
// ─────────────────────────────────────────────────────────────────────────────

// ── Per-host query status ────────────────────────────────────────────────────
// UNREACHABLE is a NORMAL state, not an error state: a laptop is off the LAN
// most of the time. Nothing in this file or its callers escalates it to a
// notification, and one dead host never prevents the others being shown.
var STATUS = {
    NOT_PROBED:  "not_probed",   // caps === null; nothing has ever been asked
    NO_AGENTD:   "no_agentd",    // probed, and it has no agent runtime
    UNKNOWN:     "unknown",      // has one; not asked yet this session
    QUERYING:    "querying",     // the ssh is in flight right now
    OK:          "ok",           // it answered with a session list
    UNREACHABLE: "unreachable",  // ssh could not get there, or we gave up
    NO_APEX:     "no_apex",      // connected, but `apex` is not on that box
    NO_RUNTIME:  "no_runtime",   // `apex` ran and the runtime did not answer
    UNREADABLE:  "unreadable"    // exit 0 and the output is not a session list
}

// What each status says to a person. Deliberately none of them say "error".
var STATUS_LABELS = {
    not_probed:  "not probed",
    no_agentd:   "no agent runtime",
    unknown:     "not checked yet",
    querying:    "checking…",
    ok:          "",                          // the session count speaks instead
    unreachable: "unreachable",
    no_apex:     "apex not installed there",
    // We got there, `apex` ran, and it could not reach its own daemon. Almost
    // always because the runtime is opt-in and nobody enabled it on that box —
    // so this is worded as the state it usually is, in the same words the local
    // page uses, rather than as a failure.
    no_runtime:  "agent runtime not running",
    unreadable:  "unreadable reply"
}

// True for the statuses where the honest thing to add is what to do about it.
var STATUS_HINTS = {
    not_probed: "apex host probe",
    no_agentd:  "",
    unreachable: ""
}

// ssh's own exit code for its own failures — a refused connection, a timeout,
// an unknown host key. `apex host run` execs ssh, so this reaches us verbatim.
// Everything else in a non-zero exit came from the far side.
var SSH_FAILED = 255

// The shell's exit code for "command not found", which is what a host whose
// cached probe is out of date and no longer has `apex` looks like.
var COMMAND_NOT_FOUND = 127

// How old a probe may be before it is worth mentioning, in seconds.
//
// Seven days, which is `PROBE_FRESH_SECS` in apexd/apex/src/host.rs. Copied
// rather than chosen: the CLI already marks a probe stale at this age in its
// own `apex host list` output, and a shell that drew the line somewhere else
// would disagree with the tool the user reads next.
var PROBE_FRESH_SECS = 7 * 24 * 60 * 60

// Most sessions to render under one host before collapsing the rest into a
// count. A build box that has run forty agents this week is not a reason for
// the Agent Center to become forty rows tall.
var SESSION_DISPLAY_CAP = 6

// ── caps ─────────────────────────────────────────────────────────────────────

// Every key `HostCaps` can carry, with the value a *missing* key means.
//
// This is the same trick as CompositorService's `_CAPS`: the schema is the
// all-absent default, so a field the CLI did not print degrades to a definite
// "we do not know" instead of `undefined`. The booleans default to false
// because `#[serde(default)]` on the Rust side means a probed host always
// prints them — so a missing one is a malformed reply, and false is the safe
// reading of a malformed reply about whether a machine can run agents.
var CAPS_SCHEMA = {
    probed_at:    0,
    apex_version: null,
    variant:      null,
    os:           null,
    cpus:         null,
    memory_mib:   null,
    free_mib:     null,
    gpus:         [],
    accel:        [],
    agentd:       false,
    ai:           false,
    podman:       false
}

// Turn whatever arrived into a record with every schema key present.
// Returns null for a host that has never been probed — the caller must keep
// that distinct from a probe that came back all-false.
function normalizeCaps(raw) {
    if (raw === null || raw === undefined || typeof raw !== "object"
        || Array.isArray(raw))
        return null

    var out = {}
    var keys = Object.keys(CAPS_SCHEMA)
    for (var i = 0; i < keys.length; i++) {
        var k = keys[i]
        var fallback = CAPS_SCHEMA[k]
        var v = raw[k]

        if (typeof fallback === "boolean") {
            // Explicitly `=== true`, never a truthiness test: a string "false"
            // from a hand-edited cache file is truthy.
            out[k] = v === true
        } else if (Array.isArray(fallback)) {
            out[k] = Array.isArray(v) ? v.map(String) : []
        } else if (k === "probed_at") {
            out[k] = typeof v === "number" && isFinite(v) ? v : 0
        } else if (typeof fallback === "object") {
            // The nullable scalars. A wrong type is absent, not coerced.
            out[k] = (typeof v === "number" && isFinite(v)) ? v
                   : (typeof v === "string" && v !== "") ? v
                   : null
        }
    }
    return out
}

// ── the registry ─────────────────────────────────────────────────────────────

// Read `apex host list --json`.
//
// It prints a JSON OBJECT KEYED BY HOST NAME, not an array — the Rust builds a
// `serde_json::Map` from the registry's own map. That matters because the house
// pattern next door is `if (Array.isArray(fresh))` (AgentService does it twice)
// and writing that here by reflex leaves the section permanently empty with
// nothing logged. A top-level array is therefore rejected *by name* below, so
// that if the CLI ever changes shape it fails loudly rather than quietly.
//
// Returns { ok, reason, hosts } where hosts is sorted by name and every entry
// has the full record shape.
function parseHostList(text) {
    var raw = String(text === undefined || text === null ? "" : text).trim()
    if (raw === "")
        return { ok: false, reason: "empty", hosts: [] }

    var doc
    try {
        doc = JSON.parse(raw)
    } catch (e) {
        return { ok: false, reason: "unparsable", hosts: [] }
    }

    if (Array.isArray(doc))
        return { ok: false, reason: "array-not-object", hosts: [] }
    if (doc === null || typeof doc !== "object")
        return { ok: false, reason: "not-an-object", hosts: [] }

    var names = Object.keys(doc).sort()
    var hosts = []
    for (var i = 0; i < names.length; i++) {
        var name = names[i]
        var entry = doc[name]
        if (entry === null || typeof entry !== "object" || Array.isArray(entry))
            continue
        var caps = normalizeCaps(entry.caps)
        hosts.push({
            name:    name,
            ssh:     typeof entry.ssh === "string" && entry.ssh !== ""
                         ? entry.ssh : name,
            port:    typeof entry.port === "number" ? entry.port : null,
            note:    typeof entry.note === "string" ? entry.note : "",
            probed:  caps !== null,
            caps:    caps === null ? normalizeCaps({}) : caps,
            // The one question this whole service turns on, answered once here
            // so no call site has to remember the three-way distinction.
            agentd:  caps !== null && caps.agentd === true
        })
    }
    return { ok: true, reason: "", hosts: hosts }
}

// Which hosts are worth an ssh connection: the ones a probe has actually shown
// to have the agent runtime INSTALLED. Whether it is running is what the query
// answers; see the header.
//
// A never-probed host is NOT queried. Guessing costs an 8-second ssh timeout
// per sweep on a machine that may not even be an APEX box, to find out
// something `apex host probe` answers properly and once.
function queryTargets(hosts) {
    var out = []
    for (var i = 0; i < (hosts || []).length; i++)
        if (hosts[i] && hosts[i].agentd === true)
            out.push(hosts[i].name)
    return out
}

// The status a host sits at before anything has been asked of it. This is the
// "do not invent capability" rule as a function.
function restingStatus(host) {
    if (!host) return STATUS.UNKNOWN
    if (host.probed !== true)   return STATUS.NOT_PROBED
    if (host.agentd !== true)   return STATUS.NO_AGENTD
    return STATUS.UNKNOWN
}

// ── one query's result ───────────────────────────────────────────────────────

// Read what `apex host run <name> -- apex agent list --all --json` did.
//
// `exitCode` is the remote command's own status, because `apex host run` execs
// ssh rather than wrapping it. A negative code means the shell gave up on the
// query itself (the watchdog fired, or demand went away) — which is the same
// information as a connection that never completed, so it reads as unreachable.
function readSessions(exitCode, text) {
    var code = typeof exitCode === "number" ? exitCode : -1

    if (code < 0)                   return { status: STATUS.UNREACHABLE, sessions: [] }
    if (code === SSH_FAILED)        return { status: STATUS.UNREACHABLE, sessions: [] }
    if (code === COMMAND_NOT_FOUND) return { status: STATUS.NO_APEX,     sessions: [] }
    if (code !== 0)                 return { status: STATUS.NO_RUNTIME,  sessions: [] }

    var raw = String(text === undefined || text === null ? "" : text).trim()
    if (raw === "")
        return { status: STATUS.UNREADABLE, sessions: [] }

    var doc
    try {
        doc = JSON.parse(raw)
    } catch (e) {
        // Exit zero with unreadable output is the one case that IS a bug rather
        // than a state — an ssh banner or a shell profile writing to stdout.
        return { status: STATUS.UNREADABLE, sessions: [] }
    }
    if (!Array.isArray(doc))
        return { status: STATUS.UNREADABLE, sessions: [] }

    return { status: STATUS.OK, sessions: sortSessions(doc) }
}

// A session is live while the runtime has recorded neither an exit code nor a
// signal. Same test SessionRow and AgentService use; duplicated here rather
// than imported because this file must stay loadable by node alone.
function isLive(s) {
    return !!s && s.exit_code === null && s.exit_signal === null
}

function liveCount(sessions) {
    var n = 0
    for (var i = 0; i < (sessions || []).length; i++)
        if (isLive(sessions[i])) n++
    return n
}

// Live first, then most recently active. The same comparator the Agent Center
// uses on local sessions, so a remote list reads the same way as a local one.
function sortSessions(sessions) {
    return (sessions || []).slice().sort(function (a, b) {
        var aLive = isLive(a)
        var bLive = isLive(b)
        if (aLive !== bLive) return aLive ? -1 : 1
        return ((b && b.last_activity) || 0) - ((a && a.last_activity) || 0)
    })
}

// Split a sorted list into what to render and how many were left out.
function visibleSessions(sessions, cap) {
    var all = sessions || []
    var limit = typeof cap === "number" && cap > 0 ? cap : SESSION_DISPLAY_CAP
    return {
        shown:  all.slice(0, limit),
        hidden: Math.max(0, all.length - limit)
    }
}

// ── display strings ──────────────────────────────────────────────────────────

function statusLabel(status) {
    var s = STATUS_LABELS[status]
    return s === undefined ? String(status) : s
}

// Whether a probe is old enough to say so. Reported, never acted on: a stale
// probe is still the best information there is.
function probeIsStale(caps, nowSecs) {
    if (!caps || typeof caps.probed_at !== "number" || caps.probed_at <= 0)
        return false
    return (nowSecs - caps.probed_at) > PROBE_FRESH_SECS
}

// "62 GiB", "20 cores" — the two numbers worth putting on one line about a
// machine you are dispatching work to. Absent values produce nothing at all
// rather than a zero.
function describeHardware(caps) {
    if (!caps) return ""
    var bits = []
    if (typeof caps.cpus === "number" && caps.cpus > 0)
        bits.push(caps.cpus + " core" + (caps.cpus === 1 ? "" : "s"))
    if (typeof caps.memory_mib === "number" && caps.memory_mib > 0)
        bits.push(Math.round(caps.memory_mib / 1024) + " GiB")
    if (caps.accel && caps.accel.length > 0)
        bits.push(caps.accel.join("+"))
    return bits.join("  ·  ")
}

// The one line under a host's name.
//
// Order is deliberate: what we know about the AGENTS first, because that is
// what the page is for, and the hardware second. A host we could not reach
// says so and stops — appending "20 cores  ·  62 GiB" to "unreachable" would
// be describing a machine from a week-old cache as though it were present.
function hostSummary(host, result, nowSecs) {
    var status = (result && result.status) || restingStatus(host)
    var bits = []

    if (status === STATUS.OK) {
        var live = liveCount(result.sessions)
        var total = (result.sessions || []).length
        if (total === 0)
            bits.push("no agent sessions")
        else if (live === total)
            bits.push(live + " running")
        else if (live === 0)
            bits.push(total + " finished")
        else
            bits.push(live + " running  ·  " + (total - live) + " finished")
        var hw = describeHardware(host && host.caps)
        if (hw !== "") bits.push(hw)
    } else {
        var label = statusLabel(status)
        if (label !== "") bits.push(label)
        if (status === STATUS.NOT_PROBED)
            bits.push("apex host probe " + ((host && host.name) || ""))
        else if (status === STATUS.NO_AGENTD || status === STATUS.UNKNOWN
                 || status === STATUS.QUERYING) {
            var hw2 = describeHardware(host && host.caps)
            if (hw2 !== "") bits.push(hw2)
        }
    }

    if (host && host.probed === true && probeIsStale(host.caps, nowSecs))
        bits.push("probe over a week old")

    return bits.join("  ·  ")
}

// The command that gets a person to a remote session, for the one line of
// guidance the section carries. There is no button: attaching means a terminal
// on the far side of an ssh, and this page is a supervisor, not a terminal.
function attachCommand(hostName, sessionId) {
    return "apex host run -t " + String(hostName)
         + " -- apex agent attach " + String(sessionId)
}

// ── the whole picture, for the section header and the one-shot log line ─────
function overview(hosts, results) {
    var list = hosts || []
    var map = results || {}
    var out = {
        hosts: list.length,
        withRuntime: 0,
        reachable: 0,
        unreachable: 0,
        notProbed: 0,
        live: 0,
        sessions: 0
    }
    for (var i = 0; i < list.length; i++) {
        var h = list[i]
        if (!h) continue
        if (h.probed !== true) out.notProbed++
        if (h.agentd === true) out.withRuntime++
        var r = map[h.name]
        if (!r) continue
        if (r.status === STATUS.OK) {
            out.reachable++
            out.sessions += (r.sessions || []).length
            out.live += liveCount(r.sessions)
        } else if (r.status === STATUS.UNREACHABLE || r.status === STATUS.NO_APEX
                   || r.status === STATUS.NO_RUNTIME) {
            out.unreachable++
        }
    }
    return out
}

// What the section heading says. Nothing about failure: the per-host rows carry
// that, and a heading that counts dead laptops is a heading that nags.
function overviewLabel(o) {
    if (!o || o.hosts === 0) return ""
    if (o.live > 0)
        return o.live + " agent" + (o.live === 1 ? "" : "s")
             + " running on " + o.reachable
             + " device" + (o.reachable === 1 ? "" : "s")
    if (o.reachable > 0) return "nothing running"
    return ""
}

// Node (tests) sees `module`; the QML engine does not, and ignores this.
if (typeof module !== "undefined" && module.exports)
    module.exports = {
        STATUS: STATUS,
        STATUS_LABELS: STATUS_LABELS,
        STATUS_HINTS: STATUS_HINTS,
        CAPS_SCHEMA: CAPS_SCHEMA,
        PROBE_FRESH_SECS: PROBE_FRESH_SECS,
        SESSION_DISPLAY_CAP: SESSION_DISPLAY_CAP,
        SSH_FAILED: SSH_FAILED,
        COMMAND_NOT_FOUND: COMMAND_NOT_FOUND,
        normalizeCaps: normalizeCaps,
        parseHostList: parseHostList,
        queryTargets: queryTargets,
        restingStatus: restingStatus,
        readSessions: readSessions,
        isLive: isLive,
        liveCount: liveCount,
        sortSessions: sortSessions,
        visibleSessions: visibleSessions,
        statusLabel: statusLabel,
        probeIsStale: probeIsStale,
        describeHardware: describeHardware,
        hostSummary: hostSummary,
        attachCommand: attachCommand,
        overview: overview,
        overviewLabel: overviewLabel
    }
