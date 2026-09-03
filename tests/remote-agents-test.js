#!/usr/bin/env node
// Tests §20's remote agent status logic against the file the shell actually
// loads (src/services/remoteagents.js), not a copy of it.
//
//   node tests/remote-agents-test.js
//
// ── Where the fixtures come from ─────────────────────────────────────────────
//
// The `apex host list --json` shapes below are transcribed from the OS side's
// own serialisation, not invented: apexd/apex/src/host.rs builds the object in
// its `HostCmd::List { json: true }` arm, and apexd/apexd-core/src/host.rs
// declares `HostCaps` with the `skip_serializing_if` attributes that decide
// which keys are present. Read on the apex-os branch `p2/base` at 77cbf68.
//
// That matters most for the omissions. A probed host does NOT print
// `apex_version`, `variant`, `os`, `cpus`, `memory_mib`, `free_mib`, `gpus` or
// `accel` when they are absent or empty, so the "sparse" fixtures below are the
// normal case rather than a corner one — which is the whole reason
// normalizeCaps exists.

"use strict";

const path = require("path");
const R = require(path.join(__dirname, "..", "src", "services", "remoteagents.js"));

let failed = 0;
function check(name, got, want) {
    const ok = JSON.stringify(got) === JSON.stringify(want);
    if (!ok) {
        failed++;
        console.error(`FAIL ${name}\n  got:  ${JSON.stringify(got)}\n  want: ${JSON.stringify(want)}`);
    } else {
        console.log(`ok   ${name}`);
    }
}

// ── the registry: an OBJECT keyed by host name, never an array ───────────────
// This is the trap. The house pattern next door is `if (Array.isArray(fresh))`
// and `apex host list --json` does not print an array, so a reflex copy would
// leave the section permanently empty with nothing logged.

const REGISTRY = JSON.stringify({
    katana: {
        ssh: "katana",
        port: null,
        note: "build box",
        caps: {
            probed_at: 1000000,
            apex_version: "0.1.0",
            variant: "daily",
            cpus: 20,
            memory_mib: 63488,
            gpus: ["NVIDIA GeForce RTX 3070 Mobile"],
            accel: ["cuda", "vulkan"],
            agentd: true,
            ai: true,
            podman: true
        }
    },
    // A plain Fedora box the shell probe reached: no apex, so no agent runtime.
    fileserver: {
        ssh: "andre@10.0.0.9",
        port: 2222,
        note: null,
        caps: {
            probed_at: 1000000,
            os: "Fedora Linux 43",
            cpus: 4,
            memory_mib: 8192,
            agentd: false,
            ai: false,
            podman: true
        }
    },
    // Registered with --no-probe. Nothing is known and nothing may be guessed.
    laptop: { ssh: "laptop", port: null, note: null, caps: null }
});

const parsed = R.parseHostList(REGISTRY);

check("a registry object parses", parsed.ok, true);
check("hosts come back sorted by name",
      parsed.hosts.map(h => h.name), ["fileserver", "katana", "laptop"]);
check("a top-level array is refused by name",
      R.parseHostList('[{"name":"katana"}]'),
      { ok: false, reason: "array-not-object", hosts: [] });
check("empty output is not an empty registry",
      R.parseHostList("").reason, "empty");
check("garbage is refused",
      R.parseHostList("no trusted devices.").reason, "unparsable");
check("null input is refused",
      R.parseHostList(null).ok, false);
check("a JSON scalar is refused",
      R.parseHostList("7").reason, "not-an-object");

const katana     = parsed.hosts.find(h => h.name === "katana");
const fileserver = parsed.hosts.find(h => h.name === "fileserver");
const laptop     = parsed.hosts.find(h => h.name === "laptop");

check("a name is its own ssh destination when none is given", katana.ssh, "katana");
check("an explicit destination is kept", fileserver.ssh, "andre@10.0.0.9");
check("a port is kept", fileserver.port, 2222);
check("a missing port is null, not 0", katana.port, null);
check("a missing note is an empty string, not null", fileserver.note, "");

// ── the three shapes of "we do not know" ────────────────────────────────────
check("a probed host with the runtime is probed and agentd",
      [katana.probed, katana.agentd], [true, true]);
check("a probed host without the runtime is probed and not agentd",
      [fileserver.probed, fileserver.agentd], [true, false]);
check("an unprobed host is neither probed nor agentd",
      [laptop.probed, laptop.agentd], [false, false]);
check("an unprobed host rests at not_probed, NOT at no_agentd",
      R.restingStatus(laptop), R.STATUS.NOT_PROBED);
check("a probed host without the runtime rests at no_agentd",
      R.restingStatus(fileserver), R.STATUS.NO_AGENTD);
check("a host with the runtime rests at unknown, NOT at unreachable",
      R.restingStatus(katana), R.STATUS.UNKNOWN);

// ── only demonstrated capability is queried ─────────────────────────────────
check("only the agentd host is worth an ssh",
      R.queryTargets(parsed.hosts), ["katana"]);
check("an empty registry asks nothing", R.queryTargets([]), []);
check("a null registry asks nothing", R.queryTargets(null), []);

// ── caps: every key present, no undefined anywhere ──────────────────────────
const schemaKeys = Object.keys(R.CAPS_SCHEMA).sort();

check("a sparse probe still yields every schema key",
      Object.keys(fileserver.caps).sort(), schemaKeys);
check("an unprobed host still yields every schema key",
      Object.keys(laptop.caps).sort(), schemaKeys);
check("no caps value is ever undefined",
      parsed.hosts.every(h =>
          Object.keys(h.caps).every(k => h.caps[k] !== undefined)), true);
check("a missing boolean is false, not undefined",
      [laptop.caps.agentd, laptop.caps.ai, laptop.caps.podman],
      [false, false, false]);
check("a missing scalar is null, not 0",
      [laptop.caps.cpus, laptop.caps.memory_mib, laptop.caps.variant],
      [null, null, null]);
check("a missing list is [], not undefined",
      [laptop.caps.gpus, laptop.caps.accel], [[], []]);
check("a stringy true is not true",
      R.normalizeCaps({ agentd: "false" }).agentd, false);
check("a stringy 1 is not true",
      R.normalizeCaps({ agentd: 1 }).agentd, false);
check("caps null is null, not an all-false record",
      R.normalizeCaps(null), null);
check("caps as an array is not a record",
      R.normalizeCaps([]), null);
check("a wrong-typed probed_at falls back to 0",
      R.normalizeCaps({ probed_at: "yesterday" }).probed_at, 0);
check("an unknown key from a newer apex is dropped, not merged",
      R.normalizeCaps({ agentd: true, quantum: true }).quantum, undefined);

// ── a real probe, off a real machine ────────────────────────────────────────
// Everything above is transcribed from the serialiser. This one is the actual
// `caps` object `apex host probe` wrote for the developer's katana, pasted
// verbatim — a hand-written fixture only proves the parser accepts what I
// imagined the other end sends, which is the same argument apex-os's own
// host.rs parser test makes about its fixture.
//
// It is also the case that would have been got wrong: `agentd` is FALSE on a
// machine that is unmistakably an APEX box, because it records whether the
// binary is installed and this one does not have it. A reading of `agentd` as
// "is an APEX machine" or "has agents" would query it every sweep for nothing.
const KATANA_REAL = {
    probed_at: 1788439662, apex_version: "0.1.0", variant: "gaming",
    os: "APEX-OS", cpus: 20, memory_mib: 63997,
    gpus: ["i915", "nvidia"], accel: ["cuda", "vulkan"],
    agentd: false, ai: false, podman: true
};
const real = R.parseHostList(JSON.stringify({
    katana: { ssh: "katana", port: null, note: null, caps: KATANA_REAL }
})).hosts[0];

check("a real probe parses with every key present",
      Object.keys(real.caps).sort(), schemaKeys);
check("a real probe keeps its own values",
      [real.caps.variant, real.caps.os, real.caps.cpus, real.caps.accel],
      ["gaming", "APEX-OS", 20, ["cuda", "vulkan"]]);
check("an APEX box without the agent binary is probed but not agentd",
      [real.probed, real.agentd], [true, false]);
check("an APEX box without the agent binary is never queried",
      R.queryTargets([real]), []);
check("a real probe's hardware reads back",
      R.describeHardware(real.caps), "20 cores  ·  62 GiB  ·  cuda+vulkan");

// ── one query's exit status ─────────────────────────────────────────────────
// `apex host run` execs ssh, so the exit code is either ssh's own 255 or the
// remote command's.
const SESSIONS = JSON.stringify([
    { id: 1, agent: "claude", state: "working",  started: 100, last_activity: 400,
      exit_code: null, exit_signal: null, project_name: "apex-os" },
    { id: 2, agent: "codex",  state: "complete", started: 50,  last_activity: 300,
      exit_code: 0, exit_signal: null, project_name: "apex-shell" },
    { id: 3, agent: "claude", state: "working",  started: 200, last_activity: 500,
      exit_code: null, exit_signal: null, project_name: "wavy" }
]);

check("exit 0 with a session array reads as ok",
      R.readSessions(0, SESSIONS).status, R.STATUS.OK);
check("255 is unreachable, not an error",
      R.readSessions(255, "").status, R.STATUS.UNREACHABLE);
check("127 says apex is not installed there",
      R.readSessions(127, "").status, R.STATUS.NO_APEX);
check("any other non-zero is the runtime not running there",
      R.readSessions(1, "").status, R.STATUS.NO_RUNTIME);
// The runtime is opt-in, so "installed and not running" is its NORMAL state.
// This label is read by someone looking at their own LAN, and it must not
// suggest a fault.
check("a daemon that is simply off is not worded as a failure",
      R.statusLabel(R.STATUS.NO_RUNTIME), "agent runtime not running");
check("a SIGTERM exit is not read as reachable-and-empty",
      R.readSessions(15, "").status, R.STATUS.NO_RUNTIME);
check("a negative code means we gave up, which reads as unreachable",
      R.readSessions(-1, "").status, R.STATUS.UNREACHABLE);
check("a missing code means we gave up",
      R.readSessions(undefined, "").status, R.STATUS.UNREACHABLE);
check("exit 0 with no output is unreadable, not zero sessions",
      R.readSessions(0, "").status, R.STATUS.UNREADABLE);
check("exit 0 with an ssh banner is unreadable",
      R.readSessions(0, "Welcome to katana\n").status, R.STATUS.UNREADABLE);
check("exit 0 with a JSON object is unreadable",
      R.readSessions(0, '{"id":1}').status, R.STATUS.UNREADABLE);
check("exit 0 with an empty array is ok with no sessions",
      [R.readSessions(0, "[]").status, R.readSessions(0, "[]").sessions.length],
      [R.STATUS.OK, 0]);
check("a failing query carries no sessions",
      R.readSessions(255, SESSIONS).sessions, []);

// ── ordering and liveness ───────────────────────────────────────────────────
const read = R.readSessions(0, SESSIONS);
check("live sessions sort first, then by last activity",
      read.sessions.map(s => s.id), [3, 1, 2]);
check("liveness is neither exit_code nor exit_signal",
      R.liveCount(read.sessions), 2);
check("a signalled session is not live",
      R.isLive({ exit_code: null, exit_signal: 9 }), false);
check("a zero-exit session is not live",
      R.isLive({ exit_code: 0, exit_signal: null }), false);
check("sorting does not mutate its input",
      (() => { const a = [{ id: 1, exit_code: 0, exit_signal: null },
                          { id: 2, exit_code: null, exit_signal: null }];
               R.sortSessions(a); return a.map(s => s.id) })(), [1, 2]);

// ── display capping ─────────────────────────────────────────────────────────
const many = [];
for (let i = 0; i < 11; i++) many.push({ id: i, exit_code: 0, exit_signal: null });
check("a long list is capped",
      R.visibleSessions(many).shown.length, R.SESSION_DISPLAY_CAP);
check("the remainder is counted",
      R.visibleSessions(many).hidden, 11 - R.SESSION_DISPLAY_CAP);
check("a short list is not capped and hides nothing",
      [R.visibleSessions(read.sessions).shown.length,
       R.visibleSessions(read.sessions).hidden], [3, 0]);
check("no sessions is not an error",
      [R.visibleSessions([]).shown, R.visibleSessions([]).hidden], [[], 0]);

// ── staleness: the OS side's own threshold ──────────────────────────────────
check("the freshness window matches apex host's PROBE_FRESH_SECS",
      R.PROBE_FRESH_SECS, 7 * 24 * 60 * 60);
check("a fresh probe is not stale",
      R.probeIsStale({ probed_at: 1000 }, 1000 + 60), false);
check("a probe older than a week is stale",
      R.probeIsStale({ probed_at: 1000 }, 1000 + R.PROBE_FRESH_SECS + 1), true);
check("an unprobed host is not 'stale' — it is unprobed",
      R.probeIsStale({ probed_at: 0 }, 99999999), false);
check("no caps is not stale", R.probeIsStale(null, 99999999), false);

// ── display strings ─────────────────────────────────────────────────────────
check("hardware reads from what was actually reported",
      R.describeHardware(katana.caps), "20 cores  ·  62 GiB  ·  cuda+vulkan");
check("a single core is not pluralised",
      R.describeHardware(R.normalizeCaps({ cpus: 1 })), "1 core");
check("absent hardware produces nothing, not zeroes",
      R.describeHardware(laptop.caps), "");
check("no caps produces nothing", R.describeHardware(null), "");

const nowSecs = 1000000 + 60;
check("a reachable host with two live agents says so",
      R.hostSummary(katana, { status: R.STATUS.OK, sessions: read.sessions }, nowSecs),
      "2 running  ·  1 finished  ·  20 cores  ·  62 GiB  ·  cuda+vulkan");
check("a reachable host with nothing running says nothing is running",
      R.hostSummary(katana, { status: R.STATUS.OK, sessions: [] }, nowSecs),
      "no agent sessions  ·  20 cores  ·  62 GiB  ·  cuda+vulkan");
check("an unreachable host says only that",
      R.hostSummary(katana, { status: R.STATUS.UNREACHABLE, sessions: [] }, nowSecs),
      "unreachable");
check("an unprobed host names the command that fixes it",
      R.hostSummary(laptop, null, nowSecs), "not probed  ·  apex host probe laptop");
check("a probed host with no runtime says so and keeps its hardware",
      R.hostSummary(fileserver, null, nowSecs),
      "no agent runtime  ·  4 cores  ·  8 GiB");
check("a host being checked says checking, not unreachable",
      R.hostSummary(katana, { status: R.STATUS.QUERYING, sessions: [] }, nowSecs)
          .indexOf("checking") === 0, true);
check("a week-old probe is mentioned",
      /probe over a week old/.test(
          R.hostSummary(katana, { status: R.STATUS.OK, sessions: [] },
                        1000000 + R.PROBE_FRESH_SECS + 1)), true);
check("no status label says the word error",
      Object.keys(R.STATUS_LABELS).every(k => !/error|fail/i.test(R.STATUS_LABELS[k])),
      true);
check("every status has a label",
      Object.keys(R.STATUS).every(k => R.STATUS_LABELS[R.STATUS[k]] !== undefined),
      true);
check("an unknown status is surfaced verbatim rather than blanked",
      R.statusLabel("something_new"), "something_new");

check("the attach command names the host and the remote id",
      R.attachCommand("katana", 7),
      "apex host run -t katana -- apex agent attach 7");

// ── the whole picture ───────────────────────────────────────────────────────
const results = {
    katana:     { status: R.STATUS.OK, sessions: read.sessions },
    fileserver: { status: R.STATUS.NO_AGENTD, sessions: [] }
};
const o = R.overview(parsed.hosts, results);
check("the overview counts devices, runtimes and sessions",
      [o.hosts, o.withRuntime, o.reachable, o.notProbed, o.live, o.sessions],
      [3, 1, 1, 1, 2, 3]);
check("an unreachable device is counted as unreachable, not as reachable",
      R.overview(parsed.hosts,
                 { katana: { status: R.STATUS.UNREACHABLE, sessions: [] } }).unreachable,
      1);
check("a device nobody asked yet is neither reachable nor unreachable",
      (() => { const x = R.overview(parsed.hosts, {});
               return [x.reachable, x.unreachable] })(), [0, 0]);
check("the heading counts what is running",
      R.overviewLabel(o), "2 agents running on 1 device");
check("one agent is not pluralised",
      R.overviewLabel({ hosts: 1, reachable: 1, live: 1 }),
      "1 agent running on 1 device");
check("a reachable device with nothing running says so",
      R.overviewLabel({ hosts: 1, reachable: 1, live: 0 }), "nothing running");
check("the heading says nothing about devices that are down",
      R.overviewLabel({ hosts: 2, reachable: 0, unreachable: 2, live: 0 }), "");
check("no devices means no heading suffix",
      R.overviewLabel({ hosts: 0 }), "");
check("a null overview is not a crash", R.overviewLabel(null), "");

if (failed > 0) {
    console.error(`\n${failed} assertion(s) failed`);
    process.exit(1);
}
console.log("\nall assertions passed");
