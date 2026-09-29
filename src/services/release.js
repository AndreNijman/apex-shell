// ─── release.js ─────────────────────────────────────────────────────────────
// What the shell does about the release it booted: open that release's page on
// rimeos.com once, say nothing, or say it rolled back. Pure, so
// tests/release-test.js drives the file ReleaseService.qml loads.
//
// Andre, 2026-09-29: "every update from now on after updating opens a page in
// your default browser on the website that has the update and what this update
// has". The contract is rimeos.com's master spec §7:
//
//   * the image carries /usr/share/rime/release.json { id, notes, … } (rime-os
//     files/scripts/stamp-release);
//   * on the first desktop session after booting a new deployment, compare the
//     booted ID with this user's state (~/.local/state/rime/releases.json):
//       forward update ..... open <notes>?from=<the last release they saw>, once
//       same release ...... nothing
//       rollback .......... no "what's new"; a small notice names what booted
//       first install ..... nothing (first-run owns that session)
//       notes turned off .. a notification with "See what changed" instead
//   * per user, not per machine: on a shared machine each user sees it once.
//
// Two things the spec does not say, decided here:
//   * No state yet is either a first install or the first update to an image
//     that has release.json at all (every image before it had none). The
//     machine tells them apart: after an update there is a previous deployment
//     to roll back to, after an install there is not (`hasRollback`).
//   * The page is opened only once it answers (ReleaseService probes it): the
//     site publishes on its own schedule, and a laptop can boot offline. Until
//     then the release is PENDING, retried on the next start and on a slow
//     timer, and superseded by a newer release if one arrives first — which
//     then opens with ?from= the last page actually seen, so nothing crossed is
//     missed.
// ────────────────────────────────────────────────────────────────────────────

// "YYYY.MM.DD" or "YYYY.MM.DD.N" (N >= 2): [0, y, m, d, n]. The pre-rename
// "apex-vX.Y.Z": [-1, x, y, z, 0] — older than any date ID. Anything else
// ("dev", a label, garbage): null.
function parseId(id) {
    var s = String(id || "");
    var m = /^(\d{4})\.(\d{2})\.(\d{2})(?:\.(\d+))?$/.exec(s);
    if (m) {
        var n = m[4] === undefined ? 1 : parseInt(m[4], 10);
        if (m[4] !== undefined && n < 2) return null;
        return [0, parseInt(m[1], 10), parseInt(m[2], 10), parseInt(m[3], 10), n];
    }
    m = /^apex-v(\d+)\.(\d+)\.(\d+)$/.exec(s);
    if (m) return [-1, parseInt(m[1], 10), parseInt(m[2], 10), parseInt(m[3], 10), 0];
    return null;
}

// <0, 0, >0 as a is older than, the same as, newer than b; NaN when either is
// not a release ID.
function compare(a, b) {
    var pa = parseId(a), pb = parseId(b);
    if (!pa || !pb) return NaN;
    for (var i = 0; i < 5; i++) if (pa[i] !== pb[i]) return pa[i] - pb[i];
    return 0;
}

// The page to open: the release's canonical notes URL, with ?from= when there
// is a release before it that this user saw.
function notesUrl(notes, from) {
    var u = String(notes || "");
    if (u === "") return "";
    return from && parseId(from) ? u + (u.indexOf("?") >= 0 ? "&" : "?") + "from=" + encodeURIComponent(from) : u;
}

function _state(s) {
    return {
        lastBooted:      (s && s.lastBooted) || "",
        lastOpenedNotes: (s && s.lastOpenedNotes) || "",
        pending:         (s && s.pending) || ""
    };
}

// decide(booted, state, hasRollback, autoOpen) → { action, url, from, state }
//   booted       the image's release.json ({ id, notes }), or null
//   state        this user's releases.json, or null when there is none
//   hasRollback  the machine has a previous deployment (it was updated)
//   autoOpen     the user wants the page opened (Settings, default on)
// action: "none"     nothing to do (state may still be updated: save `state`)
//         "record"   first install — save `state`, show nothing
//         "open"     open `url` once it answers; then call opened()
//         "notify"   notes are turned off: a notification offering `url`
//         "rollback" an older release booted: a small notice, no page
function decide(booted, state, hasRollback, autoOpen) {
    var id = booted ? booted.id : "";
    var notes = booted ? booted.notes : "";
    var st = _state(state);
    if (!parseId(id) || !notes) return { action: "none", url: "", from: "", state: state ? st : null };

    var announce = function (from) {
        var next = { lastBooted: id, lastOpenedNotes: st.lastOpenedNotes, pending: id };
        return { action: autoOpen === false ? "notify" : "open", url: notesUrl(notes, from), from: from || "", state: next };
    };

    if (!state) {
        if (!hasRollback)
            return { action: "record", url: "", from: "", state: { lastBooted: id, lastOpenedNotes: id, pending: "" } };
        // The first update to an image that says what it is: there is no
        // earlier ID to count from, so the page alone.
        return announce("");
    }

    var cmpBooted = st.lastBooted ? compare(id, st.lastBooted) : 1;
    if (isNaN(cmpBooted)) cmpBooted = 1;   // an unreadable lastBooted is treated as older

    if (cmpBooted < 0) {
        // Booted something older: a rollback (or an older channel). No "what's
        // new"; a pending newer page is dropped with the release it was for.
        var keep = st.pending && compare(st.pending, id) <= 0 ? st.pending : "";
        return { action: "rollback", url: notesUrl(notes, ""), from: "",
                 state: { lastBooted: id, lastOpenedNotes: st.lastOpenedNotes, pending: keep } };
    }

    // Already seen this one (or something newer): rolling forward again after
    // a rollback does not replay a page.
    var seen = st.lastOpenedNotes && compare(id, st.lastOpenedNotes) <= 0;
    if (seen) return { action: "none", url: "", from: "", state: { lastBooted: id, lastOpenedNotes: st.lastOpenedNotes, pending: "" } };

    if (cmpBooted === 0 && st.pending !== id) {
        // Same release, nothing outstanding.
        return { action: "none", url: "", from: "", state: st };
    }

    // A forward update, or this release's page is still pending: count from
    // the last page this user actually saw, else from what they were running.
    var from = st.lastOpenedNotes || (cmpBooted > 0 ? st.lastBooted : "");
    return announce(from);
}

// The state after the page was opened (or the notification shown).
function opened(state, id) {
    var st = _state(state);
    return { lastBooted: st.lastBooted || id, lastOpenedNotes: id, pending: st.pending === id ? "" : st.pending };
}

if (typeof module !== "undefined" && module.exports)
    module.exports = { parseId: parseId, compare: compare, notesUrl: notesUrl, decide: decide, opened: opened };
