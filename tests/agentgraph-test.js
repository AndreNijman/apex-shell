#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
//  The agent/subagent graph, against records the runtime actually writes
//  (P1-020).
//
//      node tests/agentgraph-test.js
//      node tests/agentgraph-test.js --selftest    (mutants; also run by default)
//      APEX_SHELL_SRC=/path/to/other/src node tests/agentgraph-test.js
//
//  ── What this is defending ──────────────────────────────────────────────────
//
//  Two things, and they are the two the roadmap program itself got wrong on
//  the night this was written.
//
//  A fleet of six agents was being tracked by hand out of ROADMAP/state, and
//  the harness reported the same agents as failed AND as still running,
//  because the notifications arrived out of order. The one thing that was
//  right was ROADMAP/resume.sh, which judges by when output was last written
//  rather than by a status field. So: no node in this graph carries a state,
//  and liveness is derived from `ended` and the parent's exit status every
//  time it is asked. A graph that shows a dead agent as alive is worse than
//  one that shows nothing.
//
//  The second is quieter and would ship. `children` is ABSENT from a record
//  written by a daemon that predates the graph — which is every daemon in the
//  image today — and an EMPTY ARRAY on one that looked and found nothing.
//  Reading the absence as "no subagents" puts a confident "0 subagents" under
//  an agent that has six, on the only machine anybody is running. Section 1
//  is that distinction and nothing else.
//
//  ── Where the fixture comes from ────────────────────────────────────────────
//
//  The records are the shape `apex agent list --json` emits after
//  apex-os `task/p1-020-agent-graph-daemon`: SessionInfo verbatim, with
//  `children` carrying { id, kind, label, started, ended, ended_by, parent,
//  pid, rss_kb }. The process trees are the shape a CONFINED session has,
//  which is the one that catches people out — the session's pid is the bwrap
//  wrapper, so the agent's own binary is a child in the tree and its MCP
//  servers are grandchildren.
//
//  Section 0 asserts the fixture is non-trivial before anything is measured.
//  A recent test on this program handed every case an empty document and
//  proved nothing while passing; that is guarded here rather than hoped for.
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

// ── The fleet ───────────────────────────────────────────────────────────────
//
// NOW is the clock every duration below is measured against.
const NOW = 1_757_200_000;

function sub(id, label, started, ended, endedBy) {
    return {
        id: id, kind: "subagent", label: label, started: started,
        ended: ended === undefined ? null : ended,
        ended_by: endedBy === undefined ? null : endedBy,
        parent: null, pid: null, rss_kb: null
    };
}

function proc(pid, label, parent, rssKb, started) {
    return {
        id: "pid:" + pid, kind: "process", label: label,
        started: started === undefined ? NOW - 300 : started,
        ended: null, ended_by: null,
        parent: parent === undefined ? null : parent,
        pid: pid, rss_kb: rssKb
    };
}

function session(over) {
    const base = {
        id: 1, agent: "claude", program: "claude", args: [],
        cwd: "/var/home/andre/Projects/apex", project_name: "apex",
        state: "working", detail: null, paused: false, sandbox: "project",
        pid: 1000, started: NOW - 3600, last_activity: NOW - 5,
        exit_code: null, exit_signal: null, attached: 0
    };
    return Object.assign(base, over);
}

function fleet() {
    return [
        // 1. A daemon that predates the graph. No `children` key AT ALL —
        //    this is what the shipped image writes today.
        session({ id: 1 }),

        // 2. The graph, empty. The daemon looked; this session has started
        //    nothing.
        session({ id: 2, children: [] }),

        // 3. Delegating right now: two finished and reported, one running.
        session({
            id: 3,
            children: [
                sub("agent-a", "Explore", NOW - 900, NOW - 780, "reported"),
                sub("agent-b", "general-purpose", NOW - 700, NOW - 400, "reported"),
                sub("agent-c", "Plan", NOW - 200)
            ]
        }),

        // 4. The turn ended with a subagent still open. `parent_stop` is a
        //    PROVISIONAL close — a subagent can outlive the turn that
        //    delegated it — and the session is still very much alive, so
        //    "finished" would be a claim nothing supports.
        session({
            id: 4, state: "waiting_for_user",
            children: [sub("agent-d", "Explore", NOW - 600, NOW - 300, "parent_stop")]
        }),

        // 5. Exited, with a child the daemon never got to sweep. The record
        //    is from a daemon that died; the shell must not report a subagent
        //    working under an agent that is gone.
        session({
            id: 5, state: "exited", exit_code: 0, last_activity: NOW - 20000,
            children: [sub("agent-e", "Explore", NOW - 30000)]
        }),

        // 6. A CONFINED session's process tree. `pid` is the bwrap wrapper, so
        //    the agent's own binary is a child and the MCP servers are
        //    grandchildren. No subagents.
        session({
            id: 6, program: "/usr/bin/claude", pid: 2000,
            children: [
                proc(2001, "claude", null, 420_000),
                proc(2002, "node", "pid:2001", 96_000),
                proc(2003, "rust-analyzer", "pid:2001", 310_000),
                proc(2004, "rg", "pid:2002", 4_200)
            ]
        }),

        // 7. Both halves at once, unconfined: the session's pid IS the agent,
        //    so nothing needs lifting and the MCP server is a direct child.
        session({
            id: 7, agent: "opencode", program: "opencode", pid: 3000,
            children: [
                sub("agent-f", "Explore", NOW - 120),
                proc(3001, "node", null, 64_000)
            ]
        })
    ];
}

const F = fleet();
const byId = (n) => F.find(s => s.id === n);

// ── 0. The fixture is worth measuring ───────────────────────────────────────
function fixture(G) {
    console.log("── 0. the fixture is not trivial ──");
    check("a session with NO children key at all",
          F.some(s => !("children" in s)));
    check("a session with an empty children array",
          F.some(s => Array.isArray(s.children) && s.children.length === 0));
    check("a subagent that finished and said so",
          F.some(s => (s.children || []).some(c => c.ended_by === "reported")));
    check("a subagent a turn ending closed",
          F.some(s => (s.children || []).some(c => c.ended_by === "parent_stop")));
    check("a subagent left open under a session that exited",
          F.some(s => !G.sessionLive(s) && (s.children || []).some(c => c.ended === null)));
    check("a process tree at least three deep",
          (byId(6).children || []).some(c => {
              const p = byId(6).children.find(x => x.id === c.parent);
              return p && p.parent;
          }));
    check("more than one adapter", new Set(F.map(s => s.agent)).size > 1);
}

// ── 1. Absent is not empty ──────────────────────────────────────────────────
function tristate(G) {
    console.log("\n── 1. a runtime that cannot tell is not a session with nothing ──");
    check("no children key reads as unknown",
          G.supported(byId(1)) === "unknown", G.supported(byId(1)));
    check("an empty array reads as none",
          G.supported(byId(2)) === "none", G.supported(byId(2)));
    check("a populated array reads as some",
          G.supported(byId(3)) === "some", G.supported(byId(3)));
    check("an unknown runtime draws no summary at all",
          G.summary(byId(1), NOW) === "", JSON.stringify(G.summary(byId(1), NOW)));
    check("a session with nothing started also draws no summary",
          G.summary(byId(2), NOW) === "");
    check("a null children value is treated as unknown, not as empty",
          G.supported(session({ children: null })) === "unknown");
    check("accounting says whether it knows",
          G.account(byId(1), NOW).known === false
          && G.account(byId(2), NOW).known === true);
}

// ── 2. Liveness is derived ──────────────────────────────────────────────────
function liveness(G) {
    console.log("\n── 2. liveness comes from evidence, never from a field ──");
    const running = byId(3).children[2];
    check("an open child of a live session is running",
          G.childLive(running, byId(3)) === true);
    check("a closed child of a live session is not",
          G.childLive(byId(3).children[0], byId(3)) === false);

    const orphan = byId(5).children[0];
    check("an open child of an EXITED session is not running",
          G.childLive(orphan, byId(5)) === false);
    check("and it is not called finished either",
          G.endWord(orphan, byId(5)) === "unknown",
          G.endWord(orphan, byId(5)));
    check("nor is it given a duration that kept counting",
          G.subagentLine(orphan, byId(5), NOW).age === "",
          G.subagentLine(orphan, byId(5), NOW).age);

    check("a session with an exit signal is dead even with no exit code",
          G.sessionLive(session({ exit_code: null, exit_signal: 9 })) === false);
    check("a live session has neither",
          G.sessionLive(session({})) === true);
    check("no node in the whole fleet carries a state field",
          F.every(s => (s.children || []).every(c => !("state" in c))));
}

// ── 3. The three ways a child can end are three sentences ───────────────────
function words(G) {
    console.log("\n── 3. finished, and the two that are not ──");
    check("a reported stop is finished",
          G.endWord(byId(3).children[0], byId(3)) === "finished");
    check("the turn ending is NOT finished",
          G.endWord(byId(4).children[0], byId(4)) === "ended with the turn",
          G.endWord(byId(4).children[0], byId(4)));
    check("the session ending is its own sentence",
          G.endWord(sub("x", "Explore", 1, 2, "parent_exit"), byId(3))
              === "ended with the session");
    check("a running child says so",
          G.endWord(byId(3).children[2], byId(3)) === "running");
    check("only a reported end is certain",
          G.endIsCertain(byId(3).children[0]) === true
          && G.endIsCertain(byId(4).children[0]) === false);
    check("an ended_by this build has not been taught is not guessed at",
          G.endWord(sub("x", "Explore", 1, 2, "teleported"), byId(3)) === "ended");
    check("the three words are all different",
          new Set(Object.keys(G.END_WORDS).map(k => G.END_WORDS[k])).size === 3);
}

// ── 4. Accounting follows the graph ─────────────────────────────────────────
function accounting(G) {
    console.log("\n── 4. task and resource accounting ──");
    const a = G.account(byId(3), NOW);
    check("three subagents counted", a.total === 3, String(a.total));
    check("one of them running", a.open === 1, String(a.open));
    check("delegated wall time is summed across all three",
          a.seconds === 120 + 300 + 200, String(a.seconds));

    const dead = G.account(byId(5), NOW);
    check("an open child of a dead parent counts no time",
          dead.seconds === 0, String(dead.seconds));
    check("and is not counted as running", dead.open === 0);
    check("but is still counted as delegated", dead.total === 1);

    const confined = G.account(byId(6), NOW);
    check("resident memory sums the whole process tree",
          confined.procsRss === 420_000 + 96_000 + 310_000 + 4_200,
          String(confined.procsRss));
    check("four processes counted", confined.procs === 4, String(confined.procs));
    check("a subagent contributes no memory of its own",
          G.account(byId(3), NOW).procsRss === 0);

    // Defensive, and exercised rather than asserted in a comment. The daemon
    // reads /proc only for a session it believes is live, so it does not emit
    // this record today — and `account` is a function over a record that any
    // caller can hand anything to, including one it assembled itself. Memory
    // of processes belonging to an agent that is gone is not memory in use.
    const stale = session({
        exit_code: 0,
        children: [proc(9001, "node", null, 250_000)]
    });
    check("a process under a session that has exited counts no memory",
          G.account(stale, NOW).procsRss === 0,
          String(G.account(stale, NOW).procsRss));
    check("and is not counted as a running process",
          G.account(stale, NOW).procs === 0);

    check("the summary names both halves",
          G.summary(byId(7), NOW) === "1 of 1 subagent running  ·  1 process  ·  63 MB",
          G.summary(byId(7), NOW));
    check("a fleet with nothing running says how many there were",
          G.summary(byId(5), NOW) === "1 subagent", G.summary(byId(5), NOW));
}

// ── 5. The process tree, and the row that would say "claude" under "Claude" ──
function tree(G) {
    console.log("\n── 5. the agent is not drawn underneath itself ──");
    const roots = G.processRoots(byId(6));
    const labels = roots.map(r => r.label).sort();
    check("a confined session's roots are what the AGENT started",
          JSON.stringify(labels) === JSON.stringify(["node", "rust-analyzer"]),
          JSON.stringify(labels));
    check("the agent's own process is not one of them",
          !roots.some(r => r.label === "claude"));

    const unconfined = G.processRoots(byId(7));
    check("an unconfined session needs no lifting",
          unconfined.length === 1 && unconfined[0].label === "node");

    const node = roots.find(r => r.label === "node");
    const s = G.processSummary(byId(6), node);
    check("a summarised node stands for its whole subtree",
          s.count === 2 && s.rssKb === 96_000 + 4_200,
          JSON.stringify(s));
    check("nothing is lost by lifting: the counts still add up",
          G.processRoots(byId(6))
              .reduce((n, r) => n + G.processSummary(byId(6), r).count, 0) === 3);

    check("a name the kernel truncated to fifteen characters still matches",
          G.processRoots(session({
              program: "/usr/lib/some-very-long-agent-name",
              children: [proc(1, "some-very-long-", null, 10),
                         proc(2, "node", "pid:1", 20)]
          })).map(r => r.label).join() === "node");
    check("a name that does not match lifts nothing",
          G.processRoots(session({
              program: "claude",
              children: [proc(1, "bash", null, 10)]
          })).map(r => r.label).join() === "bash");
    check("a cycle in the process table does not hang the walk",
          G.subtree(session({
              children: [proc(1, "a", "pid:2", 1), proc(2, "b", "pid:1", 1)]
          }), proc(1, "a", "pid:2", 1)).length === 2);
}

// ── 6. Words a person reads ─────────────────────────────────────────────────
function rendering(G) {
    console.log("\n── 6. what it says ──");
    check("seconds", G.shortDuration(45) === "45s", G.shortDuration(45));
    check("minutes", G.shortDuration(600) === "10m", G.shortDuration(600));
    check("hours and minutes", G.shortDuration(3900) === "1h 5m", G.shortDuration(3900));
    check("a negative duration is not rendered as one",
          G.shortDuration(-5) === "0s", G.shortDuration(-5));
    check("kilobytes stay kilobytes", G.memoryLabel(512) === "512 KB");
    check("megabytes get one decimal while they are small",
          G.memoryLabel(4300) === "4.2 MB", G.memoryLabel(4300));
    check("and lose it once they are not",
          G.memoryLabel(420_000) === "410 MB", G.memoryLabel(420_000));
    check("gigabytes", G.memoryLabel(3_000_000) === "2.9 GB", G.memoryLabel(3_000_000));

    const line = G.subagentLine(byId(3).children[2], byId(3), NOW);
    check("a running subagent's row says what it is and how long",
          line.label === "Plan" && line.state === "running"
          && line.live === true && line.age === "3m",
          JSON.stringify(line));
    check("a subagent with no label of its own is still named",
          G.subagentLine(sub("x", "", 1, 2, "reported"), byId(3), NOW).label
              === "subagent");
}

// ── 7. The shell actually loads it ──────────────────────────────────────────
function wiring() {
    console.log("\n── 7. the shell uses this file ──");
    const row = path.join(SRC, "services", "agents", "SubagentRow.qml");
    const sessionRow = path.join(SRC, "services", "agents", "SessionRow.qml");
    check("SubagentRow.qml exists", fs.existsSync(row));
    const rowText = fs.existsSync(row) ? fs.readFileSync(row, "utf8") : "";
    const srText = fs.readFileSync(sessionRow, "utf8");
    check("SubagentRow imports agentgraph.js",
          /agentgraph\.js["'] as/.test(rowText));
    check("SessionRow imports agentgraph.js",
          /agentgraph\.js["'] as/.test(srText));
    check("SessionRow asks agentgraph.js whether there IS a graph",
          /Graph\.supported\(/.test(srText), "no three-valued guard in the row");
    check("and never reads session.children itself",
          !/session\.children/.test(srText),
          "SessionRow inspects the array instead of asking, so it cannot tell "
          + "an absent key from an empty one");
    check("the row does not decide liveness for itself",
          !/\.ended\s*===\s*null/.test(srText),
          "SessionRow reimplements the rule instead of asking agentgraph.js");
    check("no new translucent-white foreground",
          !/Qt\.rgba\(1,\s*1,\s*1,/.test(rowText) && !/Qt\.rgba\(1,\s*1,\s*1,/.test(srText));
}

// ── Mutants ─────────────────────────────────────────────────────────────────
//
// Every claim above is worth exactly as much as its ability to fail. Each
// mutant below is a plausible edit — several are what the file looked like
// before a review — and the run is repeated against a patched copy.
function selftest() {
    console.log("\n── self-test: break it on purpose ──");
    const file = path.join(SRC, "services", "agentgraph.js");
    const original = fs.readFileSync(file, "utf8");
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "apex-graph-mut-"));
    let sp = 0, sf = 0;

    function expect(name, mutated, want) {
        const alt = path.join(dir, "src", "services");
        fs.mkdirSync(alt, { recursive: true });
        fs.writeFileSync(path.join(alt, "agentgraph.js"), mutated);
        // The QML the wiring section reads lives in the real tree; only the
        // module under test is swapped, which is what makes a mutant a
        // statement about THIS file.
        let code = 0;
        try {
            execFileSync(process.execPath, [__filename, "--child"], {
                env: Object.assign({}, process.env, {
                    APEX_GRAPH_MODULE: path.join(alt, "agentgraph.js")
                }),
                stdio: "pipe"
            });
        } catch (e) { code = e.status === undefined ? 1 : e.status; }
        const got = code === 0 ? "green" : "red";
        if (got === want) { sp++; console.log("  PASS  " + name); }
        else { sf++; console.log("  FAIL  " + name + "  [wanted " + want + ", got " + got + "]"); }
    }

    // 1. The bug that would ship. An absent `children` is read as an empty
    //    one, so every session on the shipped image reports "no subagents"
    //    with nothing behind it.
    expect("treating an absent children key as an empty one is caught",
           original.replace(/if \(!session \|\| !Array\.isArray\(session\.children\)\) return "unknown"/,
                            'if (!session) return "unknown"\n    if (!Array.isArray(session.children)) return "none"'),
           "red");

    // 2. Liveness stops asking whether the SESSION is alive, so a subagent
    //    under an agent that exited is reported as running. This is the
    //    failure the whole file exists for.
    expect("dropping the parent's exit status from liveness is caught",
           original.replace(/return isOpen\(child\) && sessionLive\(session\)/,
                            "return isOpen(child)"),
           "red");

    // 3. The three ends collapse to one word, so a provisional close reads as
    //    a subagent that finished.
    expect("calling every close 'finished' is caught",
           original.replace(/return END_WORDS\[child\.ended_by\] \|\| "ended"/,
                            'return "finished"'),
           "red");

    // 4. Accounting lets an open child of a dead parent keep counting, so a
    //    session that exited last week reports a week of delegated work.
    expect("letting a dead parent's open child keep counting is caught",
           original.replace(/acc\.seconds \+= \(isOpen\(c\) && !live\)\n\s*\? 0\n\s*:/,
                            "acc.seconds +="),
           "red");

    // 5. The agent's own process is not lifted, so a confined Claude session
    //    draws a row called "claude" underneath a row called "Claude".
    expect("drawing the agent underneath itself is caught",
           original.replace(/var isSelf = self\.length > 0[\s\S]*?self\.indexOf\(name\) === 0\)/,
                            "var isSelf = false"),
           "red");

    // 6. The subtree walk forgets what it has seen, so a recycled pid that
    //    closes a cycle hangs the shell.
    expect("dropping the cycle guard is caught",
           original.replace(/if \(c\.parent !== id \|\| seen\[c\.id\]\) continue/,
                            "if (c.parent !== id) continue"),
           "red");

    // 7. Memory is summed over children that have stopped as well, so a
    //    session reports the memory of processes that have exited.
    expect("counting a finished process's memory is caught",
           original.replace(/if \(!open\) continue\n            acc\.procs \+= 1/,
                            "acc.procs += 1"),
           "red");

    // 8. The inverse mutant. Prose must not be what makes anything pass: a
    //    copy with every comment stripped has to stay green, or an assertion
    //    is reading documentation instead of code.
    expect("a copy with every comment stripped is still green",
           original.split("\n").filter(l => !/^\s*\/\//.test(l)).join("\n"),
           "green");

    fs.rmSync(dir, { recursive: true, force: true });
    console.log("\n  self-test: passed=" + sp + " failed=" + sf);
    return sf;
}

// ─────────────────────────────────────────────────────────────────────────────
const MODULE = process.env.APEX_GRAPH_MODULE
    || path.join(SRC, "services", "agentgraph.js");
const G = require(MODULE);

fixture(G);
tristate(G);
liveness(G);
words(G);
accounting(G);
tree(G);
rendering(G);

const child = process.argv.includes("--child");
if (!child) wiring();

const selfFailed = child ? 0 : selftest();

console.log(`\nagentgraph: passed=${passed} failed=${failed}`);
process.exit(failed === 0 && selfFailed === 0 ? 0 : 1);
