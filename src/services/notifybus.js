// ─── notifybus.js ────────────────────────────────────────────────────────────
// Which of the notifications the shell is about to raise a person should
// actually see (roadmap P1-022).
//
// Pure: no I/O, no Process, no Theme. `tests/notifybus-test.js` drives THIS
// file — the one the shell loads — the same way tests/agent-state-test.js
// drives agentstate.js. A copy under test is a test of the copy.
//
// ── THE PROBLEM, MEASURED ON THE MACHINE THIS WAS WRITTEN ON ────────────────
//
// Six agents were running against this repository while this was written. One
// event — "an agent wants a permission decision" — reaches the shell three
// separate ways, and before this file every one of them raised its own
// desktop notification:
//
//   1. AgentService._noticeChanges sees the session's state become
//      `permission_request` and notifies.
//   2. AgentService._noticeRequests sees the matching record appear in
//      `apex request pending` and notifies again. Same agent, same decision,
//      two toasts, a second apart.
//   3. Claude's own `PermissionRequest` hook published the state in (1), and
//      its `Notification` hook publishes `waiting_for_user` for the same
//      moment when the request is not a privilege escalation.
//
// And a fourth. This one is flapping rather than duplication, and it is the
// worse of the two. apexd's PTY fallback promotes a silent session to
// `waiting_for_user` after IDLE_TO_WAITING_SECS = 10
// (apex-agent-core/src/session.rs). An agent that
// thinks for twelve seconds between two tool calls therefore goes
// working → waiting_for_user → working, and `_noticeChanges` fires on
// transitions, so that is one CRITICAL notification per pause. Over a long
// turn a single agent can produce a dozen.
//
// A surface that does that gets muted, and a muted notifier is worse than no
// notifier: it is the same absence, plus the belief that you would have been
// told.
//
// ── WHAT THIS FILE DOES ABOUT IT ────────────────────────────────────────────
//
// Three rules, in order of how much they matter.
//
// IDENTITY. Every notification carries a key, and the key is what the news is
// ABOUT, never which code path noticed it. "Session 4 needs you" is
// `needs-you:4` whether it arrived as a state change, as a pending request or
// as a hook. Two notifications with one key are one notification: the second
// replaces the first in place rather than stacking under it.
//
// REFRACTORY. A key that fired recently does not fire again. The standing
// notification is updated instead, so the news stays current without a second
// interruption. This is what turns the idle-rule flap into one toast.
//
//   Attention is refractory; an OUTCOME is not, and the distinction is the
//   whole reason `kindClass` exists. "It needs you" is a condition that
//   persists and can be restated. "It failed" happens once, and a run that
//   completed inside a refractory window opened by an earlier one must not be
//   swallowed — that would be a notifier quietly losing the only event the
//   person actually needed. Outcomes are still keyed, so the same session
//   cannot report the same completion twice; they are simply never suppressed
//   for being recent.
//
// RETRACTION. When the condition ends, the notification goes. An agent that
// asked a question and then got on with it should not leave a "needs you"
// sitting on a lock screen for an hour, and coming back to six stale ones for
// agents that are all working again is exactly how a person learns to sweep
// the whole stack away unread.
//
// ── WHY THE MAP IS A HISTORY AND NOT A SCREEN ───────────────────────────────
//
// The first version of this file kept one map of what was currently on screen,
// and retraction deleted from it. That looked right and was wrong, and the
// test found it: a flapping agent is retracted the moment it goes back to
// work, which erased the record of having just interrupted someone, so the
// next pause fired as if it were the first. Five pauses, five notifications —
// the exact defect the refractory rule exists to stop, reintroduced by the
// retraction rule.
//
// So an entry survives its own retraction. `open` says whether a notification
// is on the bus; `at` says when this key last interrupted a person, and
// nothing but a fresh interruption moves it. Retraction closes; only [`prune`]
// forgets, and only once the window has lapsed and there is nothing left to
// suppress.
//
// ── WHAT IT DELIBERATELY DOES NOT DO ────────────────────────────────────────
//
// It never drops a kind it does not recognise. A shell that is older than the
// runtime it is watching will see event kinds this table has not been taught,
// and silence about something unknown is the failure mode this whole file
// exists to prevent. Unknown kinds are emitted, keyed by their own name, and
// treated as outcomes — the class that is never suppressed.

"use strict"

// How long a standing attention notification suppresses a repeat of itself.
//
// Longer than apexd's IDLE_TO_WAITING_SECS (10) by enough that the flap it
// exists to absorb cannot outlive it, and short enough that a genuinely new
// question asked five minutes later still interrupts. A pause long enough to
// re-fire at 180s is a pause a person would call "it is still stuck", which is
// news.
var ATTENTION_REFRACTORY_SECS = 180

// The kinds the shell raises, and what each one is.
//
//   attention  a CONDITION that is true until it stops being true. Repeatable,
//              refractory, and retracted when it ends.
//   outcome    an EVENT that happened once. Never suppressed for recency,
//              never retracted — you cannot un-finish.
var KIND_CLASS = {
    "needs-you":  "attention",
    "permission": "attention",
    "finished":   "outcome",
    "failed":     "outcome"
}

function kindClass(kind) {
    // Unknown kinds are outcomes: emitted, never suppressed. See the header.
    return KIND_CLASS[kind] || "outcome"
}

// The identity of a piece of news.
//
// `subject` is the session id for everything that is about a session, so the
// state-change path and the pending-request path collide on purpose. A
// privilege request is keyed by its SESSION and not by its request id, because
// a person asked twice about one agent has been interrupted twice about one
// agent.
function key(kind, subject) {
    return String(kind) + ":" + String(subject)
}

// ── The decision ────────────────────────────────────────────────────────────
//
// `seen` is a map of key → { at, id, kind, body, open }: what this shell has
// raised, whether it is still on the bus, and when it last interrupted anyone.
// `evt` is what is about to be raised: { kind, subject, summary, body }.
//
// Returns { emit, replaceId, reason }.
//
//   emit=true, replaceId=0      a new interruption
//   emit=true, replaceId=<id>   the one already on the bus is rewritten in
//                               place, which is what "enriched, not
//                               duplicated" means: the person sees one
//                               notification whose text is current, not two
//                               whose texts disagree
//   emit=false                  nothing reaches the bus
//
// `now` is seconds. Passed in rather than read, so the tests can drive a clock
// and the whole file stays pure.
function decide(seen, evt, now, refractorySecs) {
    var window = (refractorySecs === undefined)
        ? ATTENTION_REFRACTORY_SECS : refractorySecs
    var k = key(evt.kind, evt.subject)
    var prev = seen ? seen[k] : undefined

    if (prev === undefined)
        return { emit: true, replaceId: 0, key: k, reason: "new" }

    // An outcome that repeats is the same outcome. A session completes once;
    // a poll that reports the completion twice is the poller's problem, and
    // telling the user twice is not a fix for it.
    if (kindClass(evt.kind) === "outcome")
        return { emit: false, replaceId: 0, key: k, reason: "outcome-already-told" }

    // Still on the bus and the text has changed, so what the person can read
    // right now is WRONG. Rewrite it whatever the clock says: replacing in
    // place costs no second interruption on any server that honours
    // replaces_id, and a stale body is worse than a repeated one.
    if (prev.open && prev.body !== evt.body)
        return { emit: true, replaceId: prev.id || 0, key: k, reason: "restate" }

    // The refractory rule reads `at`, which survives retraction. A session
    // that goes quiet, is announced, goes back to work, and goes quiet again
    // thirty seconds later has not produced a second piece of news — it has
    // produced the same one twice, and the person has already been told.
    if ((now - prev.at) < window)
        return { emit: false, replaceId: 0, key: k,
                 reason: prev.open ? "refractory" : "refractory-after-retraction" }

    // The condition has outlasted the window. Say so again — in place if the
    // old notification is still up, as a fresh one if it was retracted.
    return { emit: true, replaceId: prev.open ? (prev.id || 0) : 0,
             key: k, reason: "still-true" }
}

// ── Retraction ──────────────────────────────────────────────────────────────
//
// `live` is the set of keys whose condition is still true right now, derived
// from the current session list. Anything OPEN that is an attention and is not
// in that set has ended, and what is on the bus is now a stale claim about the
// present.
//
// Outcomes are never retracted. "It failed" stays true.
//
// The caller closes the entry rather than deleting it — see the header. This
// function only says which.
function retractions(seen, live) {
    var out = []
    if (!seen) return out
    for (var k in seen) {
        if (!Object.prototype.hasOwnProperty.call(seen, k)) continue
        if (!seen[k].open) continue
        if (kindClass(seen[k].kind) !== "attention") continue
        if (live && live.indexOf(k) !== -1) continue
        out.push(k)
    }
    return out
}

// ── Forgetting ──────────────────────────────────────────────────────────────
//
// An entry is only safe to forget once it is closed AND old enough that it can
// no longer suppress anything, because forgetting early is precisely the bug
// described in the header. Returns the keys to drop; the caller drops them.
//
// Without this the map grows for the life of the session, one entry per
// session per kind. That is small, but "small and unbounded" is how a shell
// that runs for a month ends up holding a session list from three weeks ago.
function stale(seen, now, refractorySecs) {
    var window = (refractorySecs === undefined)
        ? ATTENTION_REFRACTORY_SECS : refractorySecs
    var out = []
    if (!seen) return out
    for (var k in seen) {
        if (!Object.prototype.hasOwnProperty.call(seen, k)) continue
        if (seen[k].open) continue
        if ((now - seen[k].at) < window) continue
        out.push(k)
    }
    return out
}

// ── What the runtime's states mean to this file ─────────────────────────────
//
// One place, so the emit path and the retraction path cannot disagree about
// what "needs you" is. agentstate.js already answers this for COLOUR; this is
// the same question for NOISE, and the two are deliberately separate: a state
// can be worth drawing differently without being worth waking someone for.
function kindForState(state) {
    switch (state) {
        case "permission_request": return "permission"
        case "waiting_for_user":   return "needs-you"
        case "complete":           return "finished"
        case "failed":             return "failed"
        default:                   return null      // not news
    }
}

// Every key that should be standing, given the sessions as they are now.
// The input is the session list exactly as `apex agent list --json` returns
// it, so nothing upstream has to pre-digest it.
function liveKeys(sessions) {
    var out = []
    if (!sessions) return out
    for (var i = 0; i < sessions.length; i++) {
        var kind = kindForState(sessions[i].state)
        if (kind === null) continue
        if (kindClass(kind) !== "attention") continue
        out.push(key(kind, sessions[i].id))
    }
    return out
}

if (typeof module !== "undefined" && module.exports)
    module.exports = {
        ATTENTION_REFRACTORY_SECS: ATTENTION_REFRACTORY_SECS,
        KIND_CLASS: KIND_CLASS,
        kindClass: kindClass,
        key: key,
        decide: decide,
        retractions: retractions,
        stale: stale,
        kindForState: kindForState,
        liveKeys: liveKeys
    }
