#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
//  Which KIND of agent a row is (P1-029, ROADMAP.md §19).
//
//      node tests/agent-lifecycle-test.js
//      node tests/agent-lifecycle-test.js --selftest   (mutants; run by default)
//      APEX_OS_ROOT=/path/to/apex-os node tests/agent-lifecycle-test.js
//
//  ── What this is defending ──────────────────────────────────────────────────
//
//  §19 closes with "Do not treat all of these as one process-state model", and
//  before this change the Agent Center did exactly that for five of the eight
//  kinds. The interesting part is that the runtime was never the problem:
//  apex-agentd has reported `request_origin` on every session record since §7,
//  and `git grep request_origin -- src/` on roadmap/v2.2 @ 690014a returns
//  nothing. The data was arriving and being thrown away.
//
//  Three failures are worth more than the mapping itself, and each has a
//  mutant below.
//
//  1. A REMOTE-HOST AGENT REPORTS `local-terminal`. That is not a bug in the
//     daemon; from that machine's point of view a person IS in front of a
//     terminal. So a classifier that reads only the field labels every remote
//     session a local PTY — the exact confusion §19 exists to end, on the
//     records where it is least visible. The kind is therefore a function of
//     the record AND the listing it came from, and the listing wins.
//
//  2. ABSENT IS NOT LOCAL. A record from a daemon that predates origin
//     tracking has no `request_origin`, and apex-agentd refuses to default
//     that to `local-terminal` because that is the origin §7 reserves root
//     for. Defaulting it here would put a confident "Terminal" pill on a
//     session nobody classified, which is worse than no pill: it is the pill a
//     user would trust.
//
//  3. THE VOCABULARY IS ANOTHER REPOSITORY'S. Section 1 reads the real
//     `RequestOrigin::as_str` arms out of an apex-os checkout when one is
//     present, so the mapping cannot silently drift from the daemon that
//     produces it. Without a checkout it falls back to a transcribed list and
//     SAYS SO, because a soft skip on the machine where most people run tests
//     would leave the check doing nothing.
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

// ── The fleet ───────────────────────────────────────────────────────────────
//
// One session per origin the daemon can report, plus the two records that have
// no origin at all: one where the key is missing (an older daemon) and one
// where it is null (a daemon that wrote the key and could not fill it).
function s(id, origin) {
    const rec = { id: id, agent: "claude", state: "working", cwd: "/home/t/p" };
    if (origin !== undefined) rec.request_origin = origin;
    return rec;
}

const FLEET = [
    s(1, "local-terminal"),
    s(2, "apex-shell"),
    s(3, "claude-remote-control"),
    s(4, "scheduled-job"),
    s(5, "mcp"),
    s(6, "subagent"),
    s(7, "cloud-job"),
    s(8),            // key absent: a daemon that predates §7
    s(9, null),      // key present, unfilled
    s(10, "quantum-entangled")  // a value a NEWER daemon invented
];

function fixture(L) {
    console.log("\n── 0. the fixture is non-trivial ──");
    check("the fleet covers every origin the runtime can report",
          Object.keys(L.ORIGINS).filter(o => o !== "remote-control")
                .every(o => FLEET.some(r => r.request_origin === o)),
          Object.keys(L.ORIGINS).join(" "));
    check("the fleet carries an absent origin and a null one",
          FLEET.some(r => !("request_origin" in r)) &&
          FLEET.some(r => r.request_origin === null));
    check("the fleet carries an origin no build knows",
          FLEET.some(r => r.request_origin === "quantum-entangled"));
}

// ── 1. the vocabulary is the daemon's, read from it where possible ──────────
function vocabulary(L) {
    console.log("\n── 1. the origin vocabulary matches apex-agent-core ──");

    // Transcribed from apex-agent-core/src/policy.rs `RequestOrigin::as_str`.
    // Used only when no checkout is around; the checkout wins whenever it is.
    let want = ["local-terminal", "apex-shell", "claude-remote-control",
                "scheduled-job", "mcp", "subagent", "cloud-job"];
    let note = "transcribed vocabulary (no apex-os checkout found)";

    // POLICY.RS HAS NINE `as_str` FUNCTIONS, one per dimension enum, and the
    // first draft of this reader matched the wrong one. It came back with
    // NativeMode's arms — inherit, ask, bypass — and reported that the runtime
    // writes three origins none of which this file classifies. On a machine
    // with no checkout it said "transcribed vocabulary" and looked fine; the
    // bug was only visible with APEX_OS_ROOT set, which is the one case the
    // check exists for.
    //
    // So the impl block is anchored FIRST and `as_str` is found inside it. And
    // a checkout that is present but unreadable is a HARD FAILURE rather than
    // a fallback to the transcription: "the file moved" and "there is no
    // checkout" are different facts, and quietly turning the first into the
    // second is how this check would go back to asserting nothing.
    let hardFail = "";
    const roots = [];
    if (process.env.APEX_OS_ROOT) roots.push(process.env.APEX_OS_ROOT);
    roots.push(path.join(__dirname, "..", "..", "apex-os"));
    for (const root of roots) {
        const file = path.join(root, "apexd", "apex-agent-core", "src", "policy.rs");
        let text;
        try { text = fs.readFileSync(file, "utf8"); } catch (e) { continue; }
        const impl = text.match(/\nimpl RequestOrigin \{[\s\S]*?\n\}/);
        if (!impl) { hardFail = "no `impl RequestOrigin` block in " + file; break; }
        const m = impl[0].match(/fn as_str\(&self\)[\s\S]*?\n    \}/);
        if (!m) { hardFail = "no `as_str` inside `impl RequestOrigin` in " + file; break; }
        const found = [...m[0].matchAll(/=>\s*"([a-z-]+)"/g)].map(x => x[1]);
        if (found.length === 0) { hardFail = "no origin strings in that `as_str`"; break; }
        want = found;
        note = "read from " + file;
        break;
    }
    console.log("  origin source: " + (hardFail || note));
    check("an apex-os checkout that is present can be read",
          hardFail === "", hardFail);

    const mapped = Object.keys(L.ORIGINS);
    const missing = want.filter(o => mapped.indexOf(o) === -1);
    check("every origin the runtime can write is classified",
          missing.length === 0, "unmapped: " + missing.join(" "));

    // And the other direction, which catches a typo in this file: a key here
    // that the daemon never writes would be dead code that looks like cover.
    // `remote-control` is the one legitimate extra — policy.rs's `parse`
    // accepts it as an alias, so a record hand-written against the short
    // spelling still classifies.
    const extra = mapped.filter(o => want.indexOf(o) === -1 && o !== "remote-control");
    check("no origin is classified that the runtime never writes",
          extra.length === 0, "unknown to the daemon: " + extra.join(" "));

    check("every mapped origin resolves to a kind this build knows",
          mapped.every(o => L.known(L.ORIGINS[o])));
}

// ── 2. the listing outranks the record ──────────────────────────────────────
function precedence(L) {
    console.log("\n── 2. where the record came from outranks what it says ──");

    // The failure this ordering exists for, stated as a test: the same record,
    // classified two ways, because the two callers know two different things.
    const remote = s(11, "local-terminal");
    check("a record from another host is a remote-host agent",
          L.kindOf(remote, L.FROM_HOST) === L.REMOTE_HOST,
          L.kindOf(remote, L.FROM_HOST));
    check("the identical record from the local daemon is a local PTY",
          L.kindOf(remote, L.FROM_DAEMON) === L.LOCAL,
          L.kindOf(remote, L.FROM_DAEMON));

    // And it holds for every origin, not just the one that motivated it: a
    // remote host's scheduled job is still reached over the network, and the
    // row that says "Remote host" is the one the user can act on.
    check("no origin can turn a remote-host record into a local kind",
          FLEET.every(r => L.kindOf(r, L.FROM_HOST) === L.REMOTE_HOST));

    // A source nobody recognises must not fall through to local.
    check("an unrecognised source is unclassified, not local",
          L.kindOf(s(12, "local-terminal"), "remote") === L.UNKNOWN);
    check("a missing source is unclassified, not local",
          L.kindOf(s(13, "local-terminal"), undefined) === L.UNKNOWN);
}

// ── 3. the mapping itself ───────────────────────────────────────────────────
function mapping(L) {
    console.log("\n── 3. each origin lands on the kind §19 names ──");
    const cases = [
        ["local-terminal",        L.LOCAL],
        ["apex-shell",            L.LOCAL],
        ["claude-remote-control", L.REMOTE_CTL],
        ["remote-control",        L.REMOTE_CTL],
        ["scheduled-job",         L.SCHEDULED],
        ["mcp",                   L.SIDECAR],
        ["subagent",              L.SUBAGENT],
        ["cloud-job",             L.CLOUD]
    ];
    for (const [origin, kind] of cases) {
        check(origin + " is " + kind,
              L.kindOf(s(99, origin), L.FROM_DAEMON) === kind,
              L.kindOf(s(99, origin), L.FROM_DAEMON));
    }

    // Five kinds were indistinguishable before this file existed. If any two
    // of them collapse onto one label the page is back where it started, so
    // distinctness is asserted rather than eyeballed.
    const labels = L.KINDS.map(k => L.label(k));
    check("no two kinds share a label",
          new Set(labels).size === L.KINDS.length, labels.join(" | "));
    check("no two kinds share an icon",
          new Set(L.KINDS.map(k => L.icon(k))).size === L.KINDS.length);
    check("every kind has a label, an icon and a meaning",
          L.KINDS.every(k => L.label(k) !== "" && L.icon(k) !== "" && L.meaning(k) !== ""));
}

// ── 4. absent is not local ──────────────────────────────────────────────────
function absence(L) {
    console.log("\n── 4. an unclassified session says nothing ──");
    check("an absent origin is unknown",
          L.kindOf(s(20), L.FROM_DAEMON) === L.UNKNOWN);
    check("a null origin is unknown",
          L.kindOf(s(21, null), L.FROM_DAEMON) === L.UNKNOWN);
    check("an empty origin is unknown",
          L.kindOf(s(22, ""), L.FROM_DAEMON) === L.UNKNOWN);
    check("an origin a newer daemon invented is unknown, not local",
          L.kindOf(s(23, "quantum-entangled"), L.FROM_DAEMON) === L.UNKNOWN);
    check("a missing session is unknown",
          L.kindOf(null, L.FROM_DAEMON) === L.UNKNOWN);

    // `known` is what the row's `visible:` binds to, so it is the thing that
    // decides whether a wrong pill is drawn.
    check("unknown is not a known kind",
          L.known(L.UNKNOWN) === false);
    check("the badge for an unclassified session is empty",
          L.badge(s(24), L.FROM_DAEMON) === "");
    check("the badge for a classified session names it",
          L.badge(s(25, "cloud-job"), L.FROM_DAEMON).indexOf("Cloud job") !== -1);

    // The meaning is the one string UNKNOWN does have, because a tooltip that
    // explains the absence is useful where a pill would mislead.
    check("unknown still explains itself in words",
          L.meaning(L.UNKNOWN).length > 20);
}

// ── 5. the gap the runtime cannot close ─────────────────────────────────────
function gap(L) {
    console.log("\n── 5. what this build cannot distinguish, in words ──");
    const g = L.gap();
    check("the recurring/scheduled merge is stated",
          /recurring/i.test(g) && /scheduled/i.test(g), g);
    check("there is exactly one scheduled kind, not two invented ones",
          L.KINDS.filter(k => /sched|recur/i.test(k)).length === 1);
    check("the seven kinds are the yaml's seven",
          L.KINDS.length === 7, L.KINDS.join(" "));
}

// ── 6. grouping never loses a session ───────────────────────────────────────
function grouping(L) {
    console.log("\n── 6. grouping is total ──");
    const g = L.groupByKind(FLEET, L.FROM_DAEMON);
    const total = Object.keys(g).reduce((n, k) => n + g[k].length, 0);
    check("every session lands in exactly one group",
          total === FLEET.length, total + " of " + FLEET.length);
    check("the three unclassifiable records land under unknown",
          g[L.UNKNOWN].length === 3, String(g[L.UNKNOWN].length));
    check("every kind is a key even when empty",
          L.KINDS.every(k => Array.isArray(g[k])));
    check("an empty listing still answers with every key",
          L.KINDS.every(k => Array.isArray(L.groupByKind([], L.FROM_DAEMON)[k])));
    check("a missing listing does not throw",
          Array.isArray(L.groupByKind(null, L.FROM_DAEMON)[L.LOCAL]));
}

// ── 7. the wiring: a classifier nothing renders is a file ───────────────────
//
// Read out of the real QML with comment lines stripped, so the prose above a
// binding cannot be what makes this pass. Both sources must have a real caller
// or one branch of the classifier is reachable only from this test — which is
// the defect that shipped in PushToTalkService.pinnedTarget, a property with
// no writer.
function wiring() {
    console.log("\n── 7. both sources have a real caller ──");
    const read = f => {
        const p = path.join(SRC, "services", "agents", f);
        return fs.readFileSync(p, "utf8")
                 .split("\n").filter(l => !/^\s*\/\//.test(l)).join("\n");
    };
    const session = read("SessionRow.qml");
    const remote  = read("RemoteSessionRow.qml");

    check("SessionRow imports the classifier",
          /import "\.\.\/agentlifecycle\.js" as Lifecycle/.test(session));
    check("RemoteSessionRow imports the classifier",
          /import "\.\.\/agentlifecycle\.js" as Lifecycle/.test(remote));
    check("SessionRow classifies against the local daemon",
          /Lifecycle\.kindOf\(row\.session, Lifecycle\.FROM_DAEMON\)/.test(session));
    check("RemoteSessionRow classifies against a host listing",
          /Lifecycle\.badge\(srow\.session, Lifecycle\.FROM_HOST\)/.test(remote));

    // The pill's visibility is bound to `known`, which is what keeps a
    // confident wrong label off an unclassified session. A row that drew the
    // badge unconditionally would pass every assertion above and still ship
    // the defect section 4 exists for.
    check("SessionRow draws nothing for an unclassified session",
          /visible:\s*Lifecycle\.known\(/.test(session));

    // No hardcoded kind words in either row: the label belongs to the
    // classifier, or the page grows a second vocabulary to drift from.
    const words = /"(Terminal|Remote Control|Scheduled|Cloud job|Remote host|Subagent|MCP sidecar)"/;
    check("SessionRow does not spell a kind out for itself",
          !words.test(session));
    check("RemoteSessionRow does not spell a kind out for itself",
          !words.test(remote));

    // And the classifier is in ci.yml, or it is a file rather than a gate.
    const ci = fs.readFileSync(
        path.join(__dirname, "..", ".github", "workflows", "ci.yml"), "utf8");
    check("the suite runs in ci.yml",
          ci.indexOf("node tests/agent-lifecycle-test.js") !== -1);
}

// ── the self-test: prove each check can fail ────────────────────────────────
//
// Mutants are applied to a COPY of the module and the whole suite is re-run
// against it in a child process. A mutant that did not change the file is a
// hard failure and never a pass.
function selftest() {
    console.log("\n── self-test: can these checks fail? ──");
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "apex-lifecycle-"));
    const original = fs.readFileSync(MODULE, "utf8");
    let sp = 0, sf = 0;

    function expect(name, mutated, want) {
        if (mutated === original) {
            sf++;
            console.log("  FAIL  " + name + "  [the mutation did not apply]");
            return;
        }
        const alt = path.join(dir, "services");
        fs.mkdirSync(alt, { recursive: true });
        const file = path.join(alt, "agentlifecycle.js");
        fs.writeFileSync(file, mutated);
        let code = 0;
        try {
            execFileSync(process.execPath, [__filename, "--child"], {
                env: Object.assign({}, process.env, { APEX_LIFECYCLE_MODULE: file }),
                stdio: "pipe"
            });
        } catch (e) { code = e.status === undefined ? 1 : e.status; }
        const got = code === 0 ? "green" : "red";
        if (got === want) { sp++; console.log("  PASS  " + name); }
        else { sf++; console.log("  FAIL  " + name + "  [wanted " + want + ", got " + got + "]"); }
    }

    // 1. THE ONE THAT WOULD SHIP. An absent origin reads as local, so every
    //    session on a daemon that predates §7 gets a confident "Terminal".
    expect("defaulting an absent origin to local is caught",
           original.replace('    if (origin === "") return UNKNOWN;',
                            '    if (origin === "") return LOCAL;'),
           "red");

    // 2. The remote-host mistake, restored: classify by the field alone and
    //    every remote session becomes a local PTY.
    expect("dropping the host precedence is caught",
           original.replace("    if (source === FROM_HOST) return REMOTE_HOST;\n", ""),
           "red");

    // 3. An origin a newer daemon invents reads as local instead of unknown.
    expect("treating an unrecognised origin as local is caught",
           original.replace("    return mapped === undefined ? UNKNOWN : mapped;",
                            "    return mapped === undefined ? LOCAL : mapped;"),
           "red");

    // 4. The source is no longer validated, so a caller's typo becomes local.
    expect("accepting any source string is caught",
           original.replace("    if (SOURCES.indexOf(source) === -1) return UNKNOWN;\n", ""),
           "red");

    // 5. Two kinds collapse onto one label — the state the page was in.
    expect("collapsing two kinds onto one label is caught",
           original.replace('"scheduled":         "Scheduled",',
                            '"scheduled":         "Terminal",'),
           "red");

    // 6. An origin the daemon writes stops being classified. Section 1 is the
    //    only thing that can see this, and only because it reads the arms out
    //    of apex-os rather than trusting the list in this file.
    expect("dropping an origin the daemon writes is caught",
           original.replace('    "mcp":                   SIDECAR,\n', ""),
           "red");

    // 7. `known` admits UNKNOWN, so the row's `visible:` turns on and draws an
    //    empty pill over a session nobody classified.
    expect("making unknown a known kind is caught",
           original.replace("    return KINDS.indexOf(kind) !== -1;",
                            "    return true;"),
           "red");

    // 8. Grouping drops what it cannot classify — the failure mode of every
    //    group-by written as a filter chain, and invisible until a session
    //    disappears from a page.
    //
    //    TWO edits, and the reason is worth recording: the first draft of this
    //    mutant changed only the `undefined` guard and SURVIVED, because
    //    `groupByKind` pre-seeds the unknown bucket and the guard therefore
    //    never fires for it. A one-line mutant there is a no-op, not a
    //    weakness in section 6 — so the mutant became the defect a person
    //    would actually write: keep only the buckets §19 names, and let
    //    everything else fall out.
    expect("dropping unclassified sessions from a grouping is caught",
           original.replace("    out[UNKNOWN] = [];\n", "")
                   .replace("        if (out[kind] === undefined) out[kind] = [];\n        out[kind].push(sessions[i]);",
                            "        if (out[kind] === undefined) continue;\n        out[kind].push(sessions[i]);"),
           "red");

    // 9. The gap stops being stated, so the recurring/scheduled merge becomes
    //    an absence a reader has to notice.
    expect("silently dropping the recurring/scheduled gap is caught",
           original.replace('    return "This build cannot tell a recurring task from a one-off scheduled " +',
                            '    return "" + ('),
           "red");

    // 10. The INVERSE mutant. Prose must not be what makes anything pass: a
    //     copy with every comment stripped has to stay green, or an assertion
    //     is reading documentation instead of code.
    expect("a copy with every comment stripped is still green",
           original.split("\n").filter(l => !/^\s*\/\//.test(l)).join("\n"),
           "green");

    fs.rmSync(dir, { recursive: true, force: true });
    console.log("\n  self-test: passed=" + sp + " failed=" + sf);
    return sf;
}

// ─────────────────────────────────────────────────────────────────────────────
const MODULE = process.env.APEX_LIFECYCLE_MODULE
    || path.join(SRC, "services", "agentlifecycle.js");
const L = require(MODULE);

fixture(L);
vocabulary(L);
precedence(L);
mapping(L);
absence(L);
gap(L);
grouping(L);

const child = process.argv.includes("--child");
if (!child) wiring();

const selfFailed = child ? 0 : selftest();

console.log(`\nagent-lifecycle: passed=${passed} failed=${failed}`);
process.exit(failed === 0 && selfFailed === 0 ? 0 : 1);
