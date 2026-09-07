// ─── pushtotalk.js ───────────────────────────────────────────────────────────
// When the microphone is open, whose session the words are going to, and what
// closes the microphone again. Roadmap P1-023, specified in ROADMAP.md §8.2:
// a compositor-neutral global push-to-talk route to the active project or the
// focused agent session, with a clear microphone indicator, an explicit
// routing target, and no permanent microphone access for agents.
//
// Kept out of the QML for the reason src/services/agentstate.js and
// src/services/remoteagents.js are: this is the part with the edge cases, and
// tests/push-to-talk-test.js drives THIS file — the one the shell loads — not
// a copy of it. Nothing here does I/O, nothing here holds a colour, and
// nothing here opens an audio device. It is a reducer over a state object, so
// a node process can drive every path including the ones a person cannot
// reproduce on purpose.
//
// ── Why this is a toggle and not hold-to-talk ────────────────────────────────
//
// ROADMAP.md:122 records hold-to-talk as a profile assumption, and the first
// instinct is to bind press and release. Read against the three compositors
// APEX actually supports, that only works on two of them:
//
//   Hyprland 0.56.2  `bindr` fires on release.
//   labwc 0.9.6      `<keybind key="..." onRelease="yes">` fires on release.
//   niri 26.04       nothing fires on release. The complete set of bind
//                    properties is repeat, cooldown-ms, hotkey-overlay-title,
//                    allow-when-locked and allow-inhibiting.
//
// The acceptance criterion is "works in Hyprland/niri/Floating", so a design
// that is hold on two backends and toggle on the third meets it in letter and
// fails it in use: the key you hold down on one machine starts a recording you
// have to remember to stop on another. One semantic, everywhere, is toggle.
//
// Toggle has its own failure, and it is the serious one: a microphone left
// open because you forgot. That is why `MAX_MS` exists and why the indicator
// is part of the acceptance rather than decoration. The cap is not a
// convenience. It is the thing that bounds the damage of the design choice
// above, so it is asserted in the tests rather than left to the UI.
//
// ── The microphone is never open without a named destination ─────────────────
//
// `resolveTarget` runs BEFORE the recorder starts, and a refusal keeps the
// phase at idle. This is the invariant the whole file exists to hold: there is
// no reachable path on which `phase === "recording"` and `target === null`.
// A recording with nowhere to go is a hot microphone with a reason to feel
// fine about itself.
//
// The target is frozen when recording starts. Focus moves while a person is
// talking — that is what talking to a computer looks like — and a route that
// re-resolved on delivery would send the words to whichever window happened to
// be focused when they stopped speaking.

"use strict";

// How long a single recording may run before it stops itself, in
// milliseconds. Ninety seconds is longer than any prompt a person says out
// loud in one breath and short enough that a microphone left open by accident
// is an embarrassment rather than an incident.
var MAX_MS = 90000;

var PHASES = ["idle", "recording", "transcribing", "delivering", "error"];

// ── Target resolution ────────────────────────────────────────────────────────
// §8.2 routes to "the active project or focused agent session", so a focused
// session is a named destination and not a guess. The order is deliberate: a
// pinned target is something the user chose and it outranks whatever they
// happen to be looking at.
//
// Returns { ok, id, label, why }. On a refusal `why` says which arm failed,
// because "push-to-talk did nothing" is the report this would otherwise
// generate.
function resolveTarget(env) {
    var e = env || {};
    var sessions = Array.isArray(e.sessions) ? e.sessions : [];

    var live = {};
    for (var i = 0; i < sessions.length; i++) {
        var s = sessions[i];
        if (!s || s.id === undefined || s.id === null) continue;
        if (s.live === false) continue;
        live[String(s.id)] = s;
    }

    var pinned = e.pinned === undefined || e.pinned === null ? null : String(e.pinned);
    if (pinned !== null) {
        if (live[pinned])
            return { ok: true, id: pinned, label: labelFor(live[pinned]), why: "pinned" };
        // A pinned session that has exited is not a reason to fall through to
        // whatever is focused. The user named a destination and it is gone;
        // say that instead of quietly picking a different one.
        return { ok: false, id: null, label: "", why: "the pinned session is no longer running" };
    }

    var focused = e.focused === undefined || e.focused === null ? null : String(e.focused);
    if (focused !== null && live[focused])
        return { ok: true, id: focused, label: labelFor(live[focused]), why: "focused" };

    return { ok: false, id: null, label: "", why: "no session pinned, none focused" };
}

function labelFor(s) {
    if (!s) return "";
    if (s.label) return String(s.label);
    var agent = s.agent ? String(s.agent) : "session";
    var project = s.project ? String(s.project) : "";
    return project ? agent + " · " + project : agent;
}

// ── The machine ──────────────────────────────────────────────────────────────
// One reducer, no timers, no processes. The QML layer turns `phase` into a
// recorder that runs or does not, and feeds events back in.

function initial() {
    return {
        phase: "idle",
        target: null,      // { id, label } frozen at the moment recording began
        startedAt: 0,
        text: "",
        error: "",
        stoppedBy: ""      // "user" or "cap", so the UI can explain itself
    };
}

// `reduce(state, event, env)` -> a NEW state. Never mutates its argument.
//
// Events:
//   { type: "toggle", now }        the keybind fired
//   { type: "tick", now }          time passed; only the cap cares
//   { type: "transcript", text }   the STT hook returned
//   { type: "delivered" }          the text reached the session
//   { type: "fail", error }        anything went wrong
//
// `env` carries the world: { sessions, pinned, focused, sttConfigured }.
function reduce(state, event, env) {
    var st = state && state.phase ? copy(state) : initial();
    var ev = event || {};
    var e = env || {};
    var now = typeof ev.now === "number" ? ev.now : 0;

    switch (ev.type) {
    case "toggle":
        if (st.phase === "recording") {
            st.phase = "transcribing";
            st.stoppedBy = "user";
            return st;
        }
        // Transcribing and delivering are not interruptible. A second press
        // while the words are still in flight is a person checking that the
        // first one worked, and starting a fresh recording is the last thing
        // they meant. It is also how the previous transcript gets lost.
        if (st.phase === "transcribing" || st.phase === "delivering") return st;

        // idle, or clearing a previous error.
        if (!e.sttConfigured) {
            st.phase = "error";
            st.target = null;
            st.error = "no speech-to-text command is configured";
            return st;
        }
        var t = resolveTarget(e);
        if (!t.ok) {
            st.phase = "error";
            st.target = null;
            st.error = t.why;
            return st;
        }
        st.phase = "recording";
        st.target = { id: t.id, label: t.label };
        st.startedAt = now;
        st.text = "";
        st.error = "";
        st.stoppedBy = "";
        return st;

    case "tick":
        if (st.phase !== "recording") return st;
        if (now - st.startedAt < MAX_MS) return st;
        st.phase = "transcribing";
        st.stoppedBy = "cap";
        return st;

    case "transcript":
        if (st.phase !== "transcribing") return st;
        var text = ev.text === undefined || ev.text === null ? "" : String(ev.text);
        if (!text.trim()) {
            // Silence is not a failure. Nothing is sent and nothing is
            // reported, because a person who pressed the key twice by accident
            // does not need an error about it.
            return reset(st);
        }
        st.phase = "delivering";
        st.text = text;
        return st;

    case "delivered":
        if (st.phase !== "delivering") return st;
        return reset(st);

    case "fail":
        st.phase = "error";
        st.error = ev.error ? String(ev.error) : "push-to-talk failed";
        st.target = null;
        st.text = "";
        return st;
    }
    return st;
}

function reset(st) {
    var out = initial();
    return out;
}

function copy(st) {
    return {
        phase: st.phase,
        target: st.target ? { id: st.target.id, label: st.target.label } : null,
        startedAt: st.startedAt || 0,
        text: st.text || "",
        error: st.error || "",
        stoppedBy: st.stoppedBy || ""
    };
}

// ── What the indicator says ──────────────────────────────────────────────────
// "Microphone indicator visible" is an acceptance criterion, and an indicator
// that says "recording" without saying where is the half of it that matters
// least. The target is named while the microphone is open.
function indicatorLabel(st) {
    var s = st && st.phase ? st : initial();
    switch (s.phase) {
    case "recording":
        return s.target ? "Listening → " + s.target.label : "Listening";
    case "transcribing":
        return "Transcribing";
    case "delivering":
        return s.target ? "Sending → " + s.target.label : "Sending";
    case "error":
        return s.error ? "Push-to-talk: " + s.error : "Push-to-talk failed";
    }
    return "";
}

// True exactly when the shell's own recorder process should be running. The
// indicator binds to the recorder, not to the Pipewire node: muting the
// default source when idle would mute every other application on the machine.
function micOpen(st) {
    return !!(st && st.phase === "recording");
}

// Milliseconds left before the cap stops the recording, or 0 when not
// recording. The UI counts this down; the machine enforces it.
function remainingMs(st, now) {
    if (!st || st.phase !== "recording") return 0;
    var left = MAX_MS - ((now || 0) - (st.startedAt || 0));
    return left > 0 ? left : 0;
}

if (typeof module !== "undefined" && module.exports)
    module.exports = {
        MAX_MS: MAX_MS,
        PHASES: PHASES,
        resolveTarget: resolveTarget,
        labelFor: labelFor,
        initial: initial,
        reduce: reduce,
        indicatorLabel: indicatorLabel,
        micOpen: micOpen,
        remainingMs: remainingMs
    };
