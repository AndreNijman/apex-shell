#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
//  Notification deduplication, replayed against a real six-agent fleet (P1-022).
//
//      node tests/notifybus-test.js
//      node tests/notifybus-test.js --selftest     (mutants; also run by default)
//
//  ── Why the fixture is a transcript and not a table ─────────────────────────
//
//  The property this file exists to prove is "six agents do not produce a
//  notification each time one of them pauses". That is a property of a
//  SEQUENCE, and a test that feeds decide() one event at a time proves nothing
//  about it — the interesting behaviour only exists across a run.
//
//  A recent agent on this program shipped a property test in which every case
//  was handed an empty document, so the property it existed to prove was never
//  exercised and two mutants passed. The guard against that here is
//  section 0: the fixture is asserted to be non-trivial (enough polls, enough
//  distinct sessions, enough state changes, and at least one of each shape the
//  later sections claim to cover) BEFORE anything is measured, and those
//  assertions are counted like every other. An empty or flattened fixture
//  fails this file rather than sailing through it.
//
//  ── Where the timeline comes from ───────────────────────────────────────────
//
//  Not invented. It is the shape of the run that was live while this was
//  written: six agents dispatched against one repository
//  (ROADMAP/state/dispatch.json), each a Claude session under apex-agentd,
//  each pausing between tool calls for longer than apexd's
//  IDLE_TO_WAITING_SECS = 10 and therefore flapping working →
//  waiting_for_user → working, and one of them asking for a privilege
//  decision, which arrives BOTH as a session state and as a record in
//  `apex request pending`.
//
//  The numbers below are the point of the file:
//
//      raw     what AgentService did before this — one notify-send per
//              transition into an attention state, plus one per pending
//              request
//      deduped what the same timeline produces through notifybus.js
// ─────────────────────────────────────────────────────────────────────────────
"use strict";

const fs = require("fs");
const path = require("path");
const os = require("os");
const { execFileSync } = require("child_process");

const SRC = process.env.APEX_SHELL_SRC
    || path.join(__dirname, "..", "src");

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("  PASS  " + name); }
    else { failed++; console.log("  FAIL  " + name + (detail ? "  [" + detail + "]" : "")); }
}

// ── The timeline ────────────────────────────────────────────────────────────
//
// Six agents, 40 minutes, one second per step is far too slow to write out, so
// each entry is (t seconds, session id, state). Between entries a session holds
// the state it was last given — which is exactly how `apex agent list` reads.
//
// Sessions 1-4 flap. Session 5 asks for a privilege decision and the pending
// request lands a second later. Session 6 runs to completion and then a second
// run of the same id fails, so the outcome class is exercised in both
// directions.
const PAUSES = 8;

function timeline() {
    const ev = [];
    // Four agents, each working a long turn made of tool calls with thinking
    // between them. A think that outlives apexd's IDLE_TO_WAITING_SECS = 10
    // is promoted to `waiting_for_user`, and the next PreToolUse hook pulls it
    // back to `working` — so a normal, healthy turn produces a run of
    // transitions into an attention state that nobody needs to be told about.
    //
    // Thirty-five seconds apart, which is what the pauses in a real turn
    // looked like on the machine this was written on: a tool call, a model
    // response, another tool call. Staggered per session so the four fleets do
    // not land on the same tick, because a dedup rule that only works when
    // events collide exactly is not a dedup rule.
    for (let s = 1; s <= 4; s++) {
        for (let p = 0; p < PAUSES; p++) {
            const at = 60 + s * 7 + p * 35;
            ev.push([at, s, "waiting_for_user"]);
            ev.push([at + 14, s, "working"]);
        }
    }
    // Session 5: a real question. Asked once, and it stays asked.
    ev.push([300, 5, "permission_request"]);
    // Session 6: finished, then a later run of the same session failed.
    ev.push([900, 6, "complete"]);
    ev.push([1500, 6, "failed"]);
    ev.sort((a, b) => a[0] - b[0]);
    return ev;
}

// The pending-privilege-request feed, which is a SEPARATE poll in AgentService
// and the second of the three paths that carry one piece of news. Its text is
// richer than the state change's — it knows the operation — which is what
// "enriched, not duplicated" has to mean in practice: the standing
// notification is rewritten with the better sentence rather than joined by a
// second one.
const PENDING = [{ at: 302, id: "r1", session: 5, verb: "install", packages: ["clang"] }];

// Replay the timeline the way AgentService polls: every two seconds, look at
// the whole session list, notice what changed.
function replay(bus, opts) {
    const ev = timeline();
    const sessions = new Map();          // id -> state
    const seen = Object.create(null);
    let raw = 0, emitted = 0, replaced = 0, retracted = 0, forgotten = 0;
    let nextId = 1;
    const log = [];

    const END = 1800;
    let ei = 0;
    for (let now = 0; now <= END; now += 2) {
        while (ei < ev.length && ev[ei][0] <= now) {
            sessions.set(ev[ei][1], ev[ei][2]);
            ei++;
        }
        // Which notifications the OLD code would have raised at this tick:
        // one per transition into a notifiable state. Reconstructed from the
        // events rather than from the map, because a transition is what
        // AgentService._noticeChanges compares.
        const fired = ev.filter(e => e[0] > now - 2 && e[0] <= now);
        const news = [];
        for (const [, sid, state] of fired) {
            const kind = bus.kindForState(state);
            if (kind === null) continue;
            raw++;
            news.push({ kind, subject: sid, summary: "Claude " + kind,
                        body: "session " + sid + " " + state });
        }
        for (const p of PENDING) {
            if (p.at > now - 2 && p.at <= now) {
                raw++;
                // The SAME news as session 5's permission_request, arriving by
                // the other path two seconds later. Keyed by session, not by
                // request id — that is the collision this file is about.
                news.push({ kind: "permission", subject: p.session,
                            summary: "Claude requests privilege",
                            body: "apex " + p.verb + " " + p.packages.join(" ") });
            }
        }

        for (const n of news) {
            const d = bus.decide(seen, n, now, opts && opts.window);
            if (!d.emit) { log.push([now, d.key, "suppressed:" + d.reason]); continue; }
            emitted++;
            if (d.replaceId) replaced++;
            log.push([now, d.key, d.reason]);
            seen[d.key] = { at: now, id: d.replaceId || nextId++,
                            kind: n.kind, body: n.body, open: true };
        }

        // Retraction runs on every poll, from the session list as it is now.
        const live = bus.liveKeys([...sessions.entries()]
            .map(([id, state]) => ({ id, state })));
        for (const k of bus.retractions(seen, live)) {
            retracted++;
            log.push([now, k, "retracted"]);
            seen[k].open = false;
            seen[k].id = 0;
        }
        for (const k of bus.stale(seen, now, opts && opts.window)) {
            forgotten++;
            delete seen[k];
        }
    }
    return { raw, emitted, replaced, retracted, forgotten, seen, log };
}

// ─────────────────────────────────────────────────────────────────────────────
function run(bus, quiet) {
    const say = quiet ? () => {} : console.log;
    const ev = timeline();

    // ── 0. The fixture is not empty, flat, or trivial ────────────────────────
    //
    // Every assertion below is about a timeline. If the timeline degenerates,
    // they all pass for the wrong reason. These run first and count.
    check("fixture: the timeline has events at all", ev.length > 0, String(ev.length));
    check("fixture: at least six distinct sessions",
          new Set(ev.map(e => e[1])).size >= 6,
          String(new Set(ev.map(e => e[1])).size));
    check("fixture: at least thirty state changes",
          ev.length >= 30, String(ev.length));
    check("fixture: it contains a flap (a session leaves and re-enters waiting)",
          (() => {
              const s1 = ev.filter(e => e[1] === 1).map(e => e[2]);
              return s1.filter(x => x === "waiting_for_user").length >= 2
                  && s1.includes("working");
          })());
    check("fixture: it contains an attention state, an outcome, and a failure",
          ev.some(e => e[2] === "permission_request")
          && ev.some(e => e[2] === "complete")
          && ev.some(e => e[2] === "failed"));
    check("fixture: the pending-request feed carries the same news as a session state",
          PENDING.length > 0
          && ev.some(e => e[1] === PENDING[0].session && e[2] === "permission_request"));

    const r = replay(bus);

    // ── 1. The reduction, as a number ────────────────────────────────────────
    say("\n  raw notifications      " + r.raw);
    say("  after deduplication    " + r.emitted
        + "  (" + r.replaced + " rewritten in place, " + r.retracted + " retracted, "
        + r.forgotten + " forgotten)");

    check("the raw timeline is genuinely noisy (>30 notifications)",
          r.raw > 30, String(r.raw));
    // A ratio, not a magic number: a change that merely halves the noise has
    // not fixed anything a person would notice.
    check("deduplication cuts it by at least two thirds",
          r.emitted <= r.raw / 3, r.emitted + " of " + r.raw);
    // The property a person actually has: no single agent interrupts more than
    // a handful of times across half an hour, however hard it flaps. This is
    // the assertion that would survive a rewrite of everything above it.
    for (let s = 1; s <= 4; s++) {
        const n = r.log.filter(l => l[1] === "needs-you:" + s
                                 && !String(l[2]).startsWith("suppressed")
                                 && l[2] !== "retracted").length;
        check("agent " + s + " interrupts at most three times in half an hour",
              n <= 3, String(n));
    }
    check("the history does not grow without bound",
          r.forgotten > 0 && Object.keys(r.seen).length <= 8,
          r.forgotten + " forgotten, " + Object.keys(r.seen).length + " held");

    // ── 2. Identity: two paths, one piece of news ────────────────────────────
    const permKeys = r.log.filter(l => l[1] === "permission:5");
    check("the permission request and its pending record share one key",
          permKeys.length >= 2, JSON.stringify(permKeys));
    check("and the second one does not raise a second notification",
          permKeys.filter(l => l[2] === "new").length === 1,
          JSON.stringify(permKeys.map(l => l[2])));
    check("it is rewritten in place rather than dropped, so the text stays current",
          permKeys.some(l => l[2] === "restate"),
          JSON.stringify(permKeys.map(l => l[2])));

    // ── 3. Refractory memory survives retraction ─────────────────────────────
    //
    // The bug this section exists for was in the first version of the module,
    // and it is the subtle one: retraction deleted the record of having just
    // interrupted someone, so the next pause thirty seconds later read as the
    // first. The suppression that catches it has its own reason code, which is
    // asserted rather than merely counted — a reduction that came entirely
    // from somewhere else would satisfy a count.
    const afterRetraction = r.log.filter(
        l => l[2] === "suppressed:refractory-after-retraction");
    check("a pause that follows a retraction is suppressed by the window, not re-announced",
          afterRetraction.length > 0, String(afterRetraction.length));
    for (let s = 1; s <= 4; s++) {
        const mine = r.log.filter(l => l[1] === "needs-you:" + s
                                    && l[2] !== "retracted"
                                    && !String(l[2]).startsWith("suppressed"));
        check("session " + s + "'s " + PAUSES + " pauses do not produce " + PAUSES
              + " notifications",
              mine.length < PAUSES,
              mine.length + ": " + JSON.stringify(mine.map(l => l[2])));
    }

    // ── 4. Retraction: nothing stale is left on the bus ──────────────────────
    check("something was actually retracted", r.retracted > 0, String(r.retracted));
    const open = Object.keys(r.seen).filter(k => r.seen[k].open);
    check("no 'needs you' is left on the bus for an agent that went back to work",
          open.every(k => !k.startsWith("needs-you:")), JSON.stringify(open));
    check("but the unanswered question is still there",
          open.includes("permission:5"), JSON.stringify(open));

    // ── 5. An outcome is never suppressed for being recent ───────────────────
    //
    // The failure mode this guards is the one that would make the whole
    // feature worse than nothing: a refractory window that swallows "it
    // failed" because something else happened moments earlier.
    const st = Object.create(null);
    st["failed:9"] = { at: 100, id: 7, kind: "failed", body: "old" };
    const later = bus.decide(st, { kind: "failed", subject: 9, body: "old" }, 101);
    check("the same failure is not reported twice",
          later.emit === false, JSON.stringify(later));
    const fresh = bus.decide(Object.create(null),
                             { kind: "failed", subject: 10, body: "x" }, 101);
    check("a DIFFERENT failure one second later is not suppressed",
          fresh.emit === true, JSON.stringify(fresh));
    check("an outcome is never retracted, however long it stands",
          bus.retractions(st, []).length === 0);

    // ── 6. An unknown kind is news, not silence ──────────────────────────────
    check("a kind this build has not been taught is emitted, not dropped",
          bus.decide(Object.create(null),
                     { kind: "quota-exhausted", subject: 3, body: "b" }, 0).emit === true);
    check("and it is treated as an outcome, so nothing suppresses it for recency",
          bus.kindClass("quota-exhausted") === "outcome");

    // ── 7. The window is a parameter, and it does something ──────────────────
    //
    // Without this the refractory assertions above could pass on a build where
    // the window is zero and the reduction comes entirely from retraction.
    const wide = replay(bus, { window: 100000 });
    const none = replay(bus, { window: 0 });
    check("a wider window suppresses at least as much as a zero one",
          wide.emitted <= none.emitted, wide.emitted + " vs " + none.emitted);
    check("and a zero window is measurably noisier, so the window is load-bearing",
          none.emitted > wide.emitted, none.emitted + " vs " + wide.emitted);

    return r;
}

// ── The shell must actually use it ──────────────────────────────────────────
//
// Every assertion above is about notifybus.js in isolation. None of them would
// notice AgentService importing it and then ignoring it, which is why these
// three are here rather than only in check-agent-notifications.sh: this file
// runs in CI on a runner with nothing installed, and the shell script needs a
// checkout it can grep either way.
function wiring() {
    const svc = fs.readFileSync(path.join(SRC, "services", "AgentService.qml"), "utf8");
    const code = svc.split("\n").filter(l => !/^\s*\/\//.test(l)).join("\n");

    check("AgentService imports notifybus.js",
          /import\s+"notifybus\.js"\s+as\s+\w+/.test(code));
    check("and asks it before every notification it raises",
          /NotifyBus\.decide\(/.test(code));
    check("and retracts what has stopped being true",
          /NotifyBus\.retractions\(/.test(code) && /NotifyBus\.liveKeys\(/.test(code));

    // The defect this whole item started from. A single Process object cannot
    // carry two notifications, because `notify-send --wait` blocks until the
    // notification is dismissed and Quickshell ignores a command change on a
    // running Process — so the second notification is silently lost. Measured
    // in tests/run-notify-spawn-test.sh; asserted here so a revert is caught
    // on a runner with no compositor.
    check("notifications are not funnelled through one shared Process",
          !/_notifyProc/.test(code));
    check("they are spawned detached, so a blocked one cannot swallow the next",
          /Quickshell\.execDetached\(/.test(code));

    // The key has to travel WITH the notification, or the dedup rule can only
    // ever see notifications this file raised. The shell is the notification
    // server for the whole session, so that would leave out every other source
    // of "an agent needs you" — which is most of the point.
    check("the key is put on the wire as a hint",
          /--hint=string:x-apex-key:/.test(code));
    check("and a replace id is passed, so a repeat rewrites rather than stacks",
          /--replace-id/.test(code));

    const ns = fs.readFileSync(
        path.join(SRC, "services", "notifications", "NotificationService.qml"), "utf8");
    const nsCode = ns.split("\n").filter(l => !/^\s*\/\//.test(l)).join("\n");

    // Quickshell exposes only the hints a server names. Without this line the
    // lookups below always answer "no such notification", which reads exactly
    // like a shell that is not the notification server at all — a silent
    // failure, and the reason it is asserted rather than assumed.
    check("the notification server passes that hint through rather than dropping it",
          /extraHints:\s*\[[^\]]*"x-apex-key"/.test(nsCode));
    check("it can find a standing notification by key",
          /function byKey\(/.test(nsCode) && /x-apex-key/.test(nsCode));
    check("and retract one whose condition has ended",
          /function retract\(/.test(nsCode) && /\.dismiss\(\)/.test(nsCode));
}

// ── Self-test: mutants ──────────────────────────────────────────────────────
//
// Same discipline as tests/check-remote-agents.sh. Each mutant is a regression
// somebody could plausibly write; each is diffed against its source so a sed
// that matched nothing is a hard failure rather than a quiet pass; and the
// baseline is run first so a mutant that came out red because the copy was
// broken cannot read as a working assertion.
function selftest() {
    console.log("\n── self-test: mutants ──");
    const srcFile = path.join(SRC, "services", "notifybus.js");
    const original = fs.readFileSync(srcFile, "utf8");
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "notifybus-mut-"));
    let sp = 0, sf = 0;

    function verdict(text) {
        const f = path.join(dir, "notifybus.js");
        fs.writeFileSync(f, text);
        delete require.cache[require.resolve(f)];
        const bus = require(f);
        const savedPassed = passed, savedFailed = failed;
        passed = 0; failed = 0;
        const log = console.log;
        console.log = () => {};
        try { run(bus, true); } catch (e) { failed++; }
        console.log = log;
        const n = failed;
        passed = savedPassed; failed = savedFailed;
        return n;
    }

    function expect(desc, text, wanted, maxBroken) {
        if (wanted === "red" && text === original) {
            console.log("  FAIL  " + desc + " (the mutant did not apply)");
            sf++; return;
        }
        const n = verdict(text);
        const got = n === 0 ? "green" : "red";
        if (got !== wanted) {
            console.log("  FAIL  " + desc + " (wanted " + wanted + ", got " + got
                        + " with " + n + " broken)");
            sf++; return;
        }
        if (wanted === "red" && maxBroken && n > maxBroken) {
            console.log("  FAIL  " + desc + " (red, but broke " + n
                        + " — the copy is damaged, not the invariant)");
            sf++; return;
        }
        console.log("  PASS  " + desc + (got === "red" ? " (=> red, " + n + " broken)"
                                                       : " (=> green)"));
        sp++;
    }

    expect("an unmutated copy is green", original, "green");

    // 1. The window stops suppressing. This is the flap coming back.
    expect("a refractory window of zero is caught",
           original.replace(/var ATTENTION_REFRACTORY_SECS = \d+/,
                            "var ATTENTION_REFRACTORY_SECS = 0"),
           "red");

    // 2. The key carries the request id rather than the session, so the two
    //    paths stop colliding and one decision is announced twice.
    expect("keying a request by its own id instead of its session is caught",
           original.replace(/return String\(kind\) \+ ":" \+ String\(subject\)/,
                            'return String(kind) + ":" + String(subject) + ":" + Math.random()'),
           "red");

    // 3. Nothing is ever retracted, so stale "needs you" claims pile up for
    //    agents that went back to work an hour ago.
    expect("dropping retraction is caught",
           original.replace(/if \(!seen\[k\]\.open\) continue\n        if \(kindClass/,
                            "if (true) continue\n        if (kindClass"),
           "red");

    // 3b. THE BUG THIS MODULE SHIPPED AND THE TEST FOUND. An entry is
    //     forgotten the moment it is retracted, which erases the record of
    //     having just interrupted somebody — so the next pause thirty seconds
    //     later reads as the first one and the flap comes straight back.
    expect("forgetting a retracted key immediately is caught",
           original.replace(/if \(\(now - seen\[k\]\.at\) < window\) continue\n        out\.push\(k\)/,
                            "out.push(k)"),
           "red");

    // 4. THE ONE THAT MATTERS. Outcomes become refractory too, so a failure
    //    inside the window of another notification is swallowed.
    expect("suppressing an outcome for being recent is caught",
           original.replace(/return KIND_CLASS\[kind\] \|\| "outcome"/,
                            'return "attention"'),
           "red");

    // 5. An unknown kind is dropped rather than emitted — silence about
    //    something a newer runtime knows and this shell does not.
    expect("dropping an unrecognised kind is caught",
           original.replace(/function kindForState\(state\) \{\n\s*switch \(state\) \{/,
                            "function kindForState(state) {\n    return null\n    switch (state) {"),
           "red");

    // 6. waiting_for_user stops being news at all.
    expect("silencing waiting_for_user is caught",
           original.replace(/case "waiting_for_user":   return "needs-you"/,
                            'case "waiting_for_user":   return null'),
           "red");

    // 7. The inverse mutant. Prose alone must not satisfy anything here: a
    //    copy whose every comment is deleted must still be green, or some
    //    assertion is reading documentation instead of code.
    expect("a copy with every comment stripped is still green",
           original.split("\n").filter(l => !/^\s*\/\//.test(l)).join("\n"),
           "green");

    fs.rmSync(dir, { recursive: true, force: true });
    console.log("\n  self-test: passed=" + sp + " failed=" + sf);
    return sf;
}

// ─────────────────────────────────────────────────────────────────────────────
const bus = require(path.join(SRC, "services", "notifybus.js"));
console.log("── notification deduplication ──");
run(bus, false);
console.log("\n── the shell uses it ──");
wiring();
const selfFailed = selftest();

console.log(`\nnotifybus: passed=${passed} failed=${failed}`);
process.exit(failed === 0 && selfFailed === 0 ? 0 : 1);
