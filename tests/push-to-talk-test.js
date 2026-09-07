#!/usr/bin/env node
// Drives src/services/pushtotalk.js — the file the shell loads, not a copy of
// it — over every path P1-023 and ROADMAP.md §8.2 care about.
//
//   node tests/push-to-talk-test.js
//
// ── Why this suite mutates itself ────────────────────────────────────────────
//
// A state machine is the easiest thing in a codebase to test into a green that
// means nothing: assert the happy path, watch it pass, ship a machine that
// cannot refuse. So the battery below is run twice — once against the real
// module, and once per mutant against a rewritten copy in a temp file, where a
// mutant that survives is reported as a failure of THIS FILE rather than a
// property of the code. Each mutant is checked to have actually changed the
// source before it is loaded; a mutant that did not apply proves nothing and
// says so.
//
// The mutants are chosen to be the plausible defects, not typos: the cap that
// never fires, the refusal that falls through to recording anyway, the pinned
// target that silently degrades to the focused one, the second keypress that
// throws away a transcript in flight.

"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");

const SRC = path.join(__dirname, "..", "src", "services", "pushtotalk.js");

// ── the battery ──────────────────────────────────────────────────────────────
// Takes a module, returns the list of assertion names that failed. Run against
// the real file it must come back empty; run against a mutant it must not.

function battery(P) {
    const bad = [];
    function check(name, got, want) {
        if (JSON.stringify(got) !== JSON.stringify(want)) bad.push({ name, got, want });
    }

    const SESSIONS = [
        { id: 1, agent: "claude", project: "apex-shell", live: true },
        { id: 2, agent: "codex", project: "apex-os", live: true },
        { id: 3, agent: "claude", project: "old", live: false }
    ];
    const env = extra => Object.assign(
        { sessions: SESSIONS, pinned: null, focused: null, sttConfigured: true }, extra || {});

    // ── target resolution ────────────────────────────────────────────────────
    check("a pinned live session is the target",
          P.resolveTarget(env({ pinned: 2 })).id, "2");
    check("the pinned target is named as pinned",
          P.resolveTarget(env({ pinned: 2 })).why, "pinned");
    check("a focused session is a target, not a fallback to refuse",
          P.resolveTarget(env({ focused: 1 })).ok, true);
    check("pinned outranks focused",
          P.resolveTarget(env({ pinned: 2, focused: 1 })).id, "2");
    check("nothing pinned and nothing focused is a refusal",
          P.resolveTarget(env({})).ok, false);
    check("the refusal says which arm failed",
          P.resolveTarget(env({})).why, "no session pinned, none focused");
    check("a dead session cannot be the focused target",
          P.resolveTarget(env({ focused: 3 })).ok, false);
    check("a pinned session that exited does NOT degrade to the focused one",
          P.resolveTarget(env({ pinned: 3, focused: 1 })).ok, false);
    check("an id that names no session at all is a refusal",
          P.resolveTarget(env({ pinned: 99 })).ok, false);
    check("a target carries a label a person can read",
          P.resolveTarget(env({ pinned: 1 })).label, "claude · apex-shell");
    check("no sessions at all is a refusal and not a crash",
          P.resolveTarget({ sessions: [], pinned: null, focused: null }).ok, false);
    check("a null environment is a refusal and not a crash",
          P.resolveTarget(null).ok, false);

    // ── the machine ──────────────────────────────────────────────────────────
    const idle = P.initial();
    check("a fresh machine is idle", idle.phase, "idle");
    check("a fresh machine holds no target", idle.target, null);

    const rec = P.reduce(idle, { type: "toggle", now: 1000 }, env({ focused: 1 }));
    check("the keybind starts a recording", rec.phase, "recording");
    check("the recording froze its target", rec.target.id, "1");
    check("the microphone is open exactly while recording", P.micOpen(rec), true);
    check("the indicator names where the words are going",
          P.indicatorLabel(rec), "Listening → claude · apex-shell");

    // The invariant the file exists to hold.
    const refused = P.reduce(idle, { type: "toggle", now: 0 }, env({}));
    check("no target means no recording", refused.phase !== "recording", true);
    check("a refusal is reported, not swallowed", refused.phase, "error");
    check("the microphone never opens without a target", P.micOpen(refused), false);
    check("the refusal reaches the indicator",
          P.indicatorLabel(refused), "Push-to-talk: no session pinned, none focused");

    const noStt = P.reduce(idle, { type: "toggle", now: 0 },
                           env({ focused: 1, sttConfigured: false }));
    check("an unconfigured transcriber refuses instead of recording",
          noStt.phase, "error");
    check("the unconfigured transcriber says so",
          noStt.error, "no speech-to-text command is configured");

    const stopped = P.reduce(rec, { type: "toggle", now: 5000 }, env({ focused: 1 }));
    check("pressing again stops the recording", stopped.phase, "transcribing");
    check("a user-stopped recording is recorded as such", stopped.stoppedBy, "user");
    check("the microphone closes when the recording stops", P.micOpen(stopped), false);
    check("the target survives the stop", stopped.target.id, "1");

    // Focus moves while a person is talking. The words still go where the
    // indicator said they would.
    const stoppedElsewhere = P.reduce(rec, { type: "toggle", now: 5000 }, env({ focused: 2 }));
    check("focus moving mid-sentence does not redirect the words",
          stoppedElsewhere.target.id, "1");

    check("a third press during transcription is ignored",
          P.reduce(stopped, { type: "toggle", now: 6000 }, env({ focused: 1 })).phase,
          "transcribing");
    check("an ignored press does not discard the target",
          P.reduce(stopped, { type: "toggle", now: 6000 }, env({ focused: 1 })).target.id,
          "1");

    const delivering = P.reduce(stopped, { type: "transcript", text: "run the tests" }, env());
    check("a transcript moves to delivery", delivering.phase, "delivering");
    check("the transcript is carried, not re-derived", delivering.text, "run the tests");
    check("a press during delivery is ignored",
          P.reduce(delivering, { type: "toggle", now: 9000 }, env({ focused: 1 })).phase,
          "delivering");
    check("delivery returns to idle",
          P.reduce(delivering, { type: "delivered" }, env()).phase, "idle");
    check("delivery clears the target",
          P.reduce(delivering, { type: "delivered" }, env()).target, null);

    check("an empty transcript sends nothing",
          P.reduce(stopped, { type: "transcript", text: "   " }, env()).phase, "idle");
    check("an empty transcript is not an error",
          P.reduce(stopped, { type: "transcript", text: "" }, env()).error, "");

    // ── the cap ──────────────────────────────────────────────────────────────
    // The thing that bounds the cost of choosing toggle over hold.
    check("the cap has not fired one millisecond early",
          P.reduce(rec, { type: "tick", now: 1000 + P.MAX_MS - 1 }, env()).phase, "recording");
    check("the cap stops the recording on time",
          P.reduce(rec, { type: "tick", now: 1000 + P.MAX_MS }, env()).phase, "transcribing");
    check("a capped recording is distinguishable from a stopped one",
          P.reduce(rec, { type: "tick", now: 1000 + P.MAX_MS }, env()).stoppedBy, "cap");
    check("the cap keeps the target so the words still arrive",
          P.reduce(rec, { type: "tick", now: 1000 + P.MAX_MS }, env()).target.id, "1");
    check("a tick does not start a recording",
          P.reduce(idle, { type: "tick", now: 999999 }, env({ focused: 1 })).phase, "idle");
    check("time remaining counts down",
          P.remainingMs(rec, 1000 + 30000), P.MAX_MS - 30000);
    check("time remaining never goes negative",
          P.remainingMs(rec, 1000 + P.MAX_MS * 3), 0);
    check("an idle machine has no time remaining", P.remainingMs(idle, 5000), 0);

    // ── failures ─────────────────────────────────────────────────────────────
    const failed = P.reduce(delivering, { type: "fail", error: "the session is gone" }, env());
    check("a failure is a state, not a silence", failed.phase, "error");
    check("a failure closes the microphone", P.micOpen(failed), false);
    check("a failure names itself", failed.error, "the session is gone");
    check("the next press clears the error and records again",
          P.reduce(failed, { type: "toggle", now: 20000 }, env({ focused: 1 })).phase,
          "recording");

    // ── purity ───────────────────────────────────────────────────────────────
    const frozen = P.reduce(idle, { type: "toggle", now: 1000 }, env({ focused: 1 }));
    P.reduce(frozen, { type: "toggle", now: 2000 }, env({ focused: 1 }));
    check("reduce does not mutate the state it was given", frozen.phase, "recording");

    check("an unknown event changes nothing",
          P.reduce(rec, { type: "nonsense" }, env()).phase, "recording");
    check("a null event changes nothing", P.reduce(rec, null, env()).phase, "recording");
    check("an idle machine shows no indicator", P.indicatorLabel(idle), "");

    return bad;
}

// ── run 1: the real module ───────────────────────────────────────────────────

const P = require(SRC);
const failures = battery(P);
const total = 51;
for (const f of failures)
    console.error(`FAIL ${f.name}\n  got:  ${JSON.stringify(f.got)}\n  want: ${JSON.stringify(f.want)}`);
console.log(`push-to-talk: passed=${total - failures.length} failed=${failures.length}`);

// ── run 2: the mutants ───────────────────────────────────────────────────────

const source = fs.readFileSync(SRC, "utf8");
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ptt-mutants-"));

const MUTANTS = [
    ["the cap never fires",
     s => s.replace("if (now - st.startedAt < MAX_MS) return st;",
                    "if (true) return st;")],
    ["the cap fires a millisecond early",
     s => s.replace("if (now - st.startedAt < MAX_MS) return st;",
                    "if (now - st.startedAt < MAX_MS - 1) return st;")],
    ["a refused target records anyway",
     s => s.replace("if (!t.ok) {", "if (false) {")],
    ["an unconfigured transcriber records anyway",
     s => s.replace("if (!e.sttConfigured) {", "if (false) {")],
    ["a pinned session that exited degrades to the focused one",
     s => s.replace('return { ok: false, id: null, label: "", why: "the pinned session is no longer running" };',
                    "pinned = null;")],
    ["focused outranks pinned",
     s => s.replace("if (pinned !== null) {", "if (false) {")],
    ["a dead session is a valid target",
     s => s.replace("if (s.live === false) continue;", "")],
    ["a press during transcription starts a new recording",
     s => s.replace('if (st.phase === "transcribing" || st.phase === "delivering") return st;',
                    "")],
    ["the target is re-resolved when the recording stops",
     s => s.replace('st.phase = "transcribing";\n            st.stoppedBy = "user";',
                    'st.phase = "transcribing";\n            st.stoppedBy = "user";\n            var rt = resolveTarget(e); if (rt.ok) st.target = { id: rt.id, label: rt.label };')],
    ["the indicator stops naming the target",
     s => s.replace('return s.target ? "Listening → " + s.target.label : "Listening";',
                    'return "Listening";')],
    ["the microphone reads as open while transcribing",
     s => s.replace('return !!(st && st.phase === "recording");',
                    'return !!(st && st.phase !== "idle");')],
    ["an empty transcript is delivered",
     s => s.replace("if (!text.trim()) {", "if (false) {")],
    ["reduce mutates its argument",
     s => s.replace("var st = state && state.phase ? copy(state) : initial();",
                    "var st = state && state.phase ? state : initial();")]
];

let caught = 0, survived = 0, unapplied = 0;
console.log("\nself-test: each mutant must make the battery above go red");
MUTANTS.forEach(([name, apply], i) => {
    const mutated = apply(source);
    if (mutated === source) {
        console.error(`  ${name.padEnd(58)} DID NOT APPLY`);
        unapplied++;
        return;
    }
    const file = path.join(dir, `m${i}.js`);
    fs.writeFileSync(file, mutated);
    let bad;
    try {
        bad = battery(require(file));
    } catch (err) {
        // A mutant that cannot even load is caught; a crash is a failure too.
        bad = [{ name: "threw: " + err.message }];
    }
    if (bad.length > 0) {
        console.log(`  ${name.padEnd(58)} caught (${bad.length})`);
        caught++;
    } else {
        console.error(`  ${name.padEnd(58)} SURVIVED`);
        survived++;
    }
});

fs.rmSync(dir, { recursive: true, force: true });
console.log(`\nself-test: mutants=${MUTANTS.length} caught=${caught} survived=${survived} unapplied=${unapplied}`);

if (failures.length > 0 || survived > 0 || unapplied > 0) {
    console.error(`\n${failures.length} assertion(s) failed, ${survived} mutant(s) survived, ${unapplied} did not apply`);
    process.exit(1);
}
console.log("\nall assertions passed");
