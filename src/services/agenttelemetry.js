// ─── agenttelemetry.js ───────────────────────────────────────────────────────
// What Claude's own status line last reported (roadmap P1-021).
//
// The runtime records it per session: the model the session is on, how full
// its context window is, the branch it is working on, and how much of the
// account's five-hour and seven-day rate-limit windows is gone.
//
// Pure, like agentstate.js, notifybus.js and agentgraph.js, and for the same
// reason: this is the part with the edge cases, and tests/agenttelemetry-test.js
// drives THIS file rather than a copy of it.
//
// ── THE 5h AND 7d WINDOWS BELONG TO THE ACCOUNT, NOT THE SESSION ────────────
//
// This is the design decision the whole file is arranged around. A rate-limit
// window is a fact about the login, so six sessions on one machine report the
// same number six times. Drawing it on six rows is not six pieces of
// information; it is one, repeated until the reader stops seeing it — which is
// exactly the failure P1-022 was written for, one surface over.
//
// So [`fleet`] collapses the whole list to ONE observation, and the rows carry
// only what genuinely differs per session: the model, the context window and
// the branch.
//
// ── AND AN OBSERVATION HAS AN AGE ───────────────────────────────────────────
//
// A status line runs on a timer and on events. A session that has been idle
// for an hour last reported an hour ago, and a page that draws "62% used" from
// that with no qualification is stating something it cannot support. Every
// record carries `observed_at`, [`freshness`] turns it into one of three
// words, and the fleet reading is taken from the FRESHEST session rather than
// from the first, the last, or an average of numbers measured at different
// times.
//
// ── AND A MISSING NUMBER IS NOT A ZERO ──────────────────────────────────────
//
// `telemetry` is absent until a status line has run: an agent that is not
// Claude, a user who has no status line configured, a session that has not
// refreshed yet, a runtime older than P1-021. Rate limits are absent again for
// anyone who is not on a Pro or Max plan. Every one of those is "we do not
// know", and a progress bar drawn at 0% for them would be a claim — the same
// absent-is-not-empty rule agentgraph.js turns on.

"use strict"

// How old an observation may be before the page stops presenting it as
// current.
//
// Ninety seconds because Claude's own default cadence, and the one Andre has
// configured, is `refreshInterval: 60`: a reading that is under a minute and a
// half old is one refresh, and anything past that means a refresh did not
// happen. Not a round number for its own sake — it is one and a half of the
// interval the thing is actually on.
var FRESH_SECS = 90

// And how old before it stops being worth drawing at all. A quarter of an
// hour is well past any refresh cadence, and a context percentage from before
// then describes a conversation that has since moved on.
var STALE_SECS = 900

function has(session) {
    return !!(session && session.telemetry && typeof session.telemetry === "object")
}

function of(session) {
    return has(session) ? session.telemetry : null
}

// "fresh" | "aging" | "stale", from when it was observed.
//
// Three rather than two because the middle one is the common case for a
// working agent and does not deserve a warning: a session between refreshes is
// perfectly healthy and its numbers are a minute old, which is worth saying
// quietly and not worth flagging.
function freshness(t, now) {
    if (!t || typeof t.observed_at !== "number") return "stale"
    var age = Math.max(0, (now || 0) - t.observed_at)
    if (age <= FRESH_SECS) return "fresh"
    if (age <= STALE_SECS) return "aging"
    return "stale"
}

function age(t, now) {
    if (!t || typeof t.observed_at !== "number") return 0
    return Math.max(0, (now || 0) - t.observed_at)
}

// A percentage the runtime actually reported, or null.
//
// Null and zero are different answers and the caller must be able to tell:
// zero is "none of the window used", null is "nobody has told us". A bar drawn
// at 0% for the second is a claim the shell cannot support.
function pct(v) {
    if (typeof v !== "number" || !isFinite(v)) return null
    return Math.max(0, Math.min(100, v))
}

// ── Per session ─────────────────────────────────────────────────────────────

// What the row shows: the things that genuinely differ between two sessions on
// one machine. The rate-limit windows are deliberately NOT here — see the
// header.
function sessionLine(session, now) {
    var t = of(session)
    if (!t) return null
    var bits = []
    if (t.model) bits.push(String(t.model))
    var ctx = pct(t.context_pct)
    if (ctx !== null) bits.push(Math.round(ctx) + "% context")
    if (t.branch) bits.push("\u{f062c} " + String(t.branch))
    if (bits.length === 0) return null
    return {
        text:      bits.join("  ·  "),
        model:     t.model || "",
        contextPct: ctx,
        branch:    t.branch || "",
        freshness: freshness(t, now),
        ageSecs:   age(t, now)
    }
}

// ── Across the fleet ────────────────────────────────────────────────────────

// The account's rate-limit windows, taken from the freshest session that has
// them.
//
// The freshest, not the highest and not an average. Every session is reporting
// the same underlying counter at a different moment, so the newest reading is
// simply the most correct one; a maximum would latch onto whichever session
// happened to observe last and then never come down after a window reset, and
// a mean would be an average of one number with itself.
//
// Returns null when nobody has reported any, which is the whole answer for a
// user who is not on a plan that has them.
function fleet(sessions, now) {
    var best = null
    var list = Array.isArray(sessions) ? sessions : []
    for (var i = 0; i < list.length; i++) {
        var t = of(list[i])
        if (!t) continue
        if (pct(t.five_hour_pct) === null && pct(t.seven_day_pct) === null) continue
        if (best === null || (t.observed_at || 0) > (best.observed_at || 0)) best = t
    }
    if (best === null) return null
    return {
        fiveHour:      pct(best.five_hour_pct),
        fiveHourReset: typeof best.five_hour_reset === "number" ? best.five_hour_reset : null,
        sevenDay:      pct(best.seven_day_pct),
        sevenDayReset: typeof best.seven_day_reset === "number" ? best.seven_day_reset : null,
        observedAt:    best.observed_at || 0,
        freshness:     freshness(best, now),
        ageSecs:       age(best, now)
    }
}

// ── Words ───────────────────────────────────────────────────────────────────

// Time until a window resets, coarse and short.
//
// Empty string once it is in the past. A reset that has already happened is
// not news — the window is open again — and "-3m left" is the kind of line
// that makes a reader distrust everything beside it.
function untilReset(resetAt, now) {
    if (typeof resetAt !== "number" || !isFinite(resetAt)) return ""
    var secs = Math.floor(resetAt - (now || 0))
    if (secs <= 0) return ""
    if (secs < 60) return "<1m"
    if (secs < 3600) return Math.floor(secs / 60) + "m"
    var h = Math.floor(secs / 3600)
    var m = Math.floor((secs % 3600) / 60)
    if (h < 24) return m > 0 ? h + "h " + m + "m" : h + "h"
    var d = Math.floor(h / 24)
    return d + "d " + (h % 24) + "h"
}

// How old an observation is, for the cases where the page has to say so.
function agoLabel(secs) {
    var s = Math.max(0, Math.floor(secs || 0))
    if (s < 60) return "just now"
    if (s < 3600) return Math.floor(s / 60) + "m ago"
    var h = Math.floor(s / 3600)
    if (h < 24) return h + "h ago"
    return Math.floor(h / 24) + "d ago"
}

// One window, as a header line: "5h  62%  ·  2h 14m left".
//
// The label first, because the reader is scanning for which window this is;
// the percentage second, because that is the number; the reset last, because
// it only matters once the number is high.
function windowLine(label, percent, resetAt, now) {
    if (percent === null || percent === undefined) return ""
    var out = label + "  " + Math.round(percent) + "%"
    var left = untilReset(resetAt, now)
    if (left !== "") out += "  ·  " + left + " left"
    return out
}

// The tone a percentage deserves, as a THEME TOKEN NAME rather than a colour.
// This file never sees a hex, for the reason agentstate.js does not: the
// palette moves under it and a light scheme must cost nothing here.
//
// The thresholds are the ones Andre's own status line already uses — green
// under 70, amber under 90, red at or above — so the shell and the terminal
// agree about when a window is worth worrying about. Two surfaces disagreeing
// about that is worse than either threshold being slightly off.
function tokenFor(percent) {
    if (percent === null || percent === undefined) return "subtext"
    if (percent >= 90) return "danger"
    if (percent >= 70) return "warning"
    return "success"
}

if (typeof module !== "undefined" && module.exports)
    module.exports = {
        FRESH_SECS: FRESH_SECS,
        STALE_SECS: STALE_SECS,
        has: has,
        of: of,
        freshness: freshness,
        age: age,
        pct: pct,
        sessionLine: sessionLine,
        fleet: fleet,
        untilReset: untilReset,
        agoLabel: agoLabel,
        windowLine: windowLine,
        tokenFor: tokenFor
    }
