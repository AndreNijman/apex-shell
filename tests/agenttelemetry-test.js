#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
//  Claude's status-line telemetry, over the records the runtime writes
//  (P1-021).
//
//      node tests/agenttelemetry-test.js
//      node tests/agenttelemetry-test.js --selftest   (mutants; also run by default)
//      APEX_SHELL_SRC=/path/to/other/src node tests/agenttelemetry-test.js
//
//  ── The three things this defends ───────────────────────────────────────────
//
//  1. A rate-limit window belongs to the ACCOUNT. Six sessions on one login
//     report the same 62%, and drawing it on six rows is one fact repeated
//     until the reader stops seeing it. That is the same failure P1-022 was
//     written for; this is it on a second surface, and section 3 is the guard.
//
//  2. An observation has an age. A status line runs on a timer, so a session
//     that went quiet an hour ago last reported an hour ago — and the fleet
//     reading has to come from the FRESHEST session rather than from the first
//     one in the list, or the page shows an hour-old number while a current
//     one is sitting two rows down.
//
//  3. A missing number is not a zero. `telemetry` is absent until a status
//     line has run at all, and `rate_limits` is absent for anyone not on a
//     plan that has them. A bar drawn at 0% for either is a claim the shell
//     cannot support — the same absent-is-not-empty rule agentgraph.js turns
//     on, and section 1 is where it is checked.
//
//  ── Where the fixture comes from ────────────────────────────────────────────
//
//  The records are the shape `apex agent list --json` emits after apex-os
//  `task/p1-020-agent-graph-daemon`, whose `Telemetry` is parsed straight out
//  of Claude's own status-line document — the same document Andre's
//  ~/.claude/statusline.sh has been reading on this machine.
//
//  Section 0 asserts the fixture is non-trivial before anything is measured.
// ─────────────────────────────────────────────────────────────────────────────
"use strict";

const fs = require("fs");
const path = require("path");
const os = require("os");
const { execFileSync } = require("child_process");

const SRC = process.env.APEX_SHELL_SRC || path.join(__dirname, "..", "src");

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("  PASS  " + name); }
    else { failed++; console.log("  FAIL  " + name + (detail ? "  [" + detail + "]" : "")); }
}

const NOW = 1_757_200_000;

function session(id, telemetry) {
    const s = {
        id: id, agent: "claude", program: "claude", args: [],
        cwd: "/var/home/andre/Projects/apex", project_name: "apex",
        state: "working", paused: false, sandbox: "project",
        pid: 1000 + id, started: NOW - 3600, last_activity: NOW - 5,
        exit_code: null, exit_signal: null, attached: 0, children: []
    };
    if (telemetry !== undefined) s.telemetry = telemetry;
    return s;
}

// Six agents on one login, which is the run this was written during. Every one
// of them reports the SAME account-wide windows, observed at different times
// as each status line happened to refresh.
function fleet() {
    return [
        // 1. No status line has ever run. A generic adapter, a user with none
        //    configured, or a runtime older than P1-021.
        session(1),

        // 2-4. Working agents, each with its own model, context and branch,
        //      and each carrying the same account windows from a different
        //      moment. Session 3 is the freshest.
        session(2, {
            model: "Opus 4.5", context_pct: 41.5, branch: "task/p1-020-agent-graph",
            five_hour_pct: 61.0, five_hour_reset: NOW + 8000,
            seven_day_pct: 18.0, seven_day_reset: NOW + 300000,
            observed_at: NOW - 240
        }),
        session(3, {
            model: "Opus 4.5", context_pct: 88.2, branch: "task/p1-044-firewall-live",
            five_hour_pct: 62.5, five_hour_reset: NOW + 7900,
            seven_day_pct: 18.5, seven_day_reset: NOW + 299900,
            observed_at: NOW - 20
        }),
        session(4, {
            model: "Sonnet 4.5", context_pct: 12.0, branch: "roadmap/v2.2",
            five_hour_pct: 60.0, five_hour_reset: NOW + 8100,
            seven_day_pct: 17.5, seven_day_reset: NOW + 300100,
            observed_at: NOW - 400
        }),

        // 5. A status line that ran but reported no windows — the shape for a
        //    user who is not on a plan that has them.
        session(5, {
            model: "Opus 4.5", context_pct: 5.0, branch: null,
            five_hour_pct: null, five_hour_reset: null,
            seven_day_pct: null, seven_day_reset: null,
            observed_at: NOW - 10
        }),

        // 6. An exited session whose last reading is old. It must not be the
        //    one the header speaks from.
        session(6, {
            model: "Opus 4.5", context_pct: 99.0, branch: "old",
            five_hour_pct: 5.0, five_hour_reset: NOW - 100,
            seven_day_pct: 3.0, seven_day_reset: NOW + 1000,
            observed_at: NOW - 40000
        })
    ];
}

const F = fleet();
const byId = (n) => F.find(s => s.id === n);

// ── 0. The fixture is worth measuring ───────────────────────────────────────
function fixture(T) {
    console.log("── 0. the fixture is not trivial ──");
    check("a session that has never reported", F.some(s => !("telemetry" in s)));
    check("more than one session reporting the same account windows",
          F.filter(s => s.telemetry && s.telemetry.five_hour_pct !== null).length >= 3);
    check("their observations are at different times",
          new Set(F.filter(s => s.telemetry)
                   .map(s => s.telemetry.observed_at)).size >= 4);
    check("the freshest is not the first in the list",
          F.findIndex(s => s.telemetry && s.telemetry.observed_at === NOW - 20) > 1);
    check("a status line that reported no windows",
          F.some(s => s.telemetry && s.telemetry.five_hour_pct === null
                      && s.telemetry.model));
    check("more than one model", new Set(F.filter(s => s.telemetry)
                                          .map(s => s.telemetry.model)).size > 1);
    check("an observation older than the stale threshold",
          F.some(s => s.telemetry && (NOW - s.telemetry.observed_at) > T.STALE_SECS));
}

// ── 1. Absent is not zero ───────────────────────────────────────────────────
function absence(T) {
    console.log("\n── 1. nothing reported is not a number ──");
    check("a session with no telemetry has none", T.has(byId(1)) === false);
    check("and produces no line at all", T.sessionLine(byId(1), NOW) === null);
    check("a session with telemetry has some", T.has(byId(2)) === true);
    check("a null percentage stays null and does not become 0",
          T.pct(null) === null && T.pct(undefined) === null);
    check("a real zero survives as zero", T.pct(0) === 0);
    check("a non-number is not a number", T.pct("62%") === null && T.pct(NaN) === null);
    check("a percentage past its own range is clamped",
          T.pct(140) === 100 && T.pct(-4) === 0);
    check("a telemetry with nothing in it draws no line",
          T.sessionLine(session(9, { observed_at: NOW }), NOW) === null);
    check("an unknown percentage gets the muted token, not the good one",
          T.tokenFor(null) === "subtext");
}

// ── 2. Per session: what actually differs between two agents ────────────────
function perSession(T) {
    console.log("\n── 2. the row says what this session is doing it with ──");
    const line = T.sessionLine(byId(3), NOW);
    check("model, context and branch",
          line.text === "Opus 4.5  ·  88% context  ·  \u{f062c} task/p1-044-firewall-live",
          line.text);
    check("the context percentage is exposed as a number for the bar",
          line.contextPct === 88.2, String(line.contextPct));
    check("a session with no branch does not print an empty one",
          T.sessionLine(byId(5), NOW).text.indexOf("\u{f062c}") < 0,
          T.sessionLine(byId(5), NOW).text);
    check("NO rate-limit number reaches the row",
          F.every(s => {
              const l = T.sessionLine(s, NOW);
              return l === null || (l.text.indexOf("5h") < 0 && l.text.indexOf("7d") < 0);
          }),
          "an account-wide window is being drawn per session");
}

// ── 3. Across the fleet: one window, said once ──────────────────────────────
function acrossFleet(T) {
    console.log("\n── 3. an account-wide window is one fact, not six ──");
    const f = T.fleet(F, NOW);
    check("the fleet has one reading", f !== null);
    check("it comes from the FRESHEST session, not the first",
          f.fiveHour === 62.5, String(f.fiveHour));
    check("and not from the highest or the lowest",
          f.sevenDay === 18.5, String(f.sevenDay));
    check("the reset time travels with it",
          f.fiveHourReset === NOW + 7900, String(f.fiveHourReset));
    check("a fleet where nobody reported windows has no reading",
          T.fleet([byId(1), byId(5)], NOW) === null);
    check("an empty fleet has no reading",
          T.fleet([], NOW) === null && T.fleet(null, NOW) === null);
    check("a session with no windows cannot become the fleet's answer",
          T.fleet([byId(5), byId(4)], NOW).fiveHour === 60.0,
          "the freshest session had no windows and was chosen anyway");
}

// ── 4. An observation has an age ────────────────────────────────────────────
function ages(T) {
    console.log("\n── 4. how old is this number ──");
    check("a reading from twenty seconds ago is fresh",
          T.freshness(byId(3).telemetry, NOW) === "fresh");
    check("one from seven minutes ago is aging, not flagged and not current",
          T.freshness(byId(4).telemetry, NOW) === "aging",
          T.freshness(byId(4).telemetry, NOW));
    check("one from eleven hours ago is stale",
          T.freshness(byId(6).telemetry, NOW) === "stale");
    check("a record with no observed_at is stale, never fresh",
          T.freshness({ model: "x" }, NOW) === "stale");
    check("the threshold is one and a half refresh intervals",
          T.FRESH_SECS === 90, String(T.FRESH_SECS));
    check("age never runs backwards when a clock moves",
          T.age({ observed_at: NOW + 500 }, NOW) === 0);
    check("just now", T.agoLabel(20) === "just now");
    check("minutes", T.agoLabel(300) === "5m ago");
    check("hours", T.agoLabel(7200) === "2h ago");
    check("days", T.agoLabel(200000) === "2d ago");
}

// ── 5. Words a person reads ─────────────────────────────────────────────────
function words(T) {
    console.log("\n── 5. what it says ──");
    check("hours and minutes to a reset",
          T.untilReset(NOW + 8100, NOW) === "2h 15m", T.untilReset(NOW + 8100, NOW));
    check("minutes", T.untilReset(NOW + 600, NOW) === "10m");
    check("under a minute", T.untilReset(NOW + 30, NOW) === "<1m");
    check("days for the weekly window",
          T.untilReset(NOW + 300000, NOW) === "3d 11h", T.untilReset(NOW + 300000, NOW));
    check("a reset already in the past is not drawn as negative time",
          T.untilReset(NOW - 100, NOW) === "", T.untilReset(NOW - 100, NOW));
    check("a missing reset time is not drawn either",
          T.untilReset(null, NOW) === "");

    check("a window line names itself, its number and its reset",
          T.windowLine("5h", 62.5, NOW + 7900, NOW) === "5h  63%  ·  2h 11m left",
          T.windowLine("5h", 62.5, NOW + 7900, NOW));
    check("and drops the reset when there is not one",
          T.windowLine("7d", 18, null, NOW) === "7d  18%");
    check("a window nobody reported has no line",
          T.windowLine("5h", null, NOW + 10, NOW) === "");

    check("under seventy is fine", T.tokenFor(69) === "success");
    check("seventy is worth noticing", T.tokenFor(70) === "warning");
    check("ninety is worth acting on", T.tokenFor(90) === "danger");
    check("the thresholds match the terminal status line's own",
          T.tokenFor(89) === "warning" && T.tokenFor(100) === "danger");
}

// ── 6. The shell actually loads it ──────────────────────────────────────────
function wiring() {
    console.log("\n── 6. the shell uses this file ──");
    const strip = path.join(SRC, "services", "agents", "TelemetryStrip.qml");
    const row = path.join(SRC, "services", "agents", "SessionRow.qml");
    const qmldir = fs.readFileSync(path.join(SRC, "services", "qmldir"), "utf8");
    check("TelemetryStrip.qml exists", fs.existsSync(strip));
    const stripText = fs.existsSync(strip) ? fs.readFileSync(strip, "utf8") : "";
    const rowText = fs.readFileSync(row, "utf8");
    check("it is registered in src/services/qmldir",
          /^TelemetryStrip /m.test(qmldir),
          "an unregistered component fails the whole shell, not just the page");
    check("the strip reads agenttelemetry.js",
          /agenttelemetry\.js["'] as/.test(stripText));
    check("the session row reads it too",
          /agenttelemetry\.js["'] as/.test(rowText));
    check("no rate-limit window is drawn per session",
          !/five_hour|seven_day|fiveHour|sevenDay/.test(rowText),
          "SessionRow draws an account-wide number on every row");
    check("the strip asks for the fleet reading rather than picking a session",
          /\.fleet\(/.test(stripText));
    check("no new translucent-white foreground",
          !/Qt\.rgba\(1,\s*1,\s*1,/.test(stripText));
}

// ── Mutants ─────────────────────────────────────────────────────────────────
function selftest() {
    console.log("\n── self-test: break it on purpose ──");
    const file = path.join(SRC, "services", "agenttelemetry.js");
    const original = fs.readFileSync(file, "utf8");
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "apex-tel-mut-"));
    let sp = 0, sf = 0;

    function expect(name, mutated, want) {
        const alt = path.join(dir, "src", "services");
        fs.mkdirSync(alt, { recursive: true });
        fs.writeFileSync(path.join(alt, "agenttelemetry.js"), mutated);
        let code = 0;
        try {
            execFileSync(process.execPath, [__filename, "--child"], {
                env: Object.assign({}, process.env, {
                    APEX_TELEMETRY_MODULE: path.join(alt, "agenttelemetry.js")
                }),
                stdio: "pipe"
            });
        } catch (e) { code = e.status === undefined ? 1 : e.status; }
        const got = code === 0 ? "green" : "red";
        if (got === want) { sp++; console.log("  PASS  " + name); }
        else { sf++; console.log("  FAIL  " + name + "  [wanted " + want + ", got " + got + "]"); }
    }

    // 1. The fleet reading comes from whichever session happens to be first,
    //    so the header shows an hour-old number with a current one two rows
    //    below it.
    expect("taking the first session's windows instead of the freshest is caught",
           original.replace(/if \(best === null \|\| \(t\.observed_at \|\| 0\) > \(best\.observed_at \|\| 0\)\) best = t/,
                            "if (best === null) best = t"),
           "red");

    // 2. A session that reported no windows can become the fleet's answer, so
    //    the header goes blank for a user who has them.
    expect("letting a session with no windows answer for the fleet is caught",
           original.replace(/if \(pct\(t\.five_hour_pct\) === null && pct\(t\.seven_day_pct\) === null\) continue\n/,
                            ""),
           "red");

    // 3. A missing percentage becomes zero, so the page draws an empty bar and
    //    calls it a measurement.
    expect("turning an unknown percentage into zero is caught",
           original.replace(/if \(typeof v !== "number" \|\| !isFinite\(v\)\) return null/,
                            'if (typeof v !== "number" || !isFinite(v)) return 0'),
           "red");

    // 4. THE ONE THIS FILE EXISTS FOR. The rate-limit windows are drawn on the
    //    session line, so six agents on one login repeat the same number six
    //    times.
    expect("drawing an account-wide window on every row is caught",
           original.replace(/if \(t\.branch\) bits\.push\("\\u\{f062c\} " \+ String\(t\.branch\)\)/,
                            'if (t.branch) bits.push("\\u{f062c} " + String(t.branch))\n'
                            + '    if (t.five_hour_pct !== null) bits.push("5h " + t.five_hour_pct + "%")'),
           "red");

    // 5. A reset that has already happened is rendered as negative time left.
    expect("rendering a past reset as time remaining is caught",
           original.replace(/if \(secs <= 0\) return ""/, 'if (secs <= -99999) return ""'),
           "red");

    // 6. Freshness stops depending on the clock, so an eleven-hour-old reading
    //    is presented as current.
    expect("calling every observation fresh is caught",
           original.replace(/if \(age <= FRESH_SECS\) return "fresh"/,
                            'return "fresh"\n    if (age <= FRESH_SECS) return "fresh"'),
           "red");

    // 7. The thresholds drift away from the terminal status line's, so the two
    //    surfaces disagree about when a window is worth worrying about.
    expect("moving the amber threshold is caught",
           original.replace(/if \(percent >= 70\) return "warning"/,
                            'if (percent >= 80) return "warning"'),
           "red");

    // 8. The inverse mutant. Prose must not be what makes anything pass.
    expect("a copy with every comment stripped is still green",
           original.split("\n").filter(l => !/^\s*\/\//.test(l)).join("\n"),
           "green");

    fs.rmSync(dir, { recursive: true, force: true });
    console.log("\n  self-test: passed=" + sp + " failed=" + sf);
    return sf;
}

// ─────────────────────────────────────────────────────────────────────────────
const MODULE = process.env.APEX_TELEMETRY_MODULE
    || path.join(SRC, "services", "agenttelemetry.js");
const T = require(MODULE);

fixture(T);
absence(T);
perSession(T);
acrossFleet(T);
ages(T);
words(T);

const child = process.argv.includes("--child");
if (!child) wiring();

const selfFailed = child ? 0 : selftest();

console.log(`\nagenttelemetry: passed=${passed} failed=${failed}`);
process.exit(failed === 0 && selfFailed === 0 ? 0 : 1);
