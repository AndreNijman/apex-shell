#!/usr/bin/env node
// Tests P1-049's Gaming settings logic against the file the shell actually loads
// (src/services/config_tab/gaming.js), not a copy of it.
//
//   node tests/gaming-settings-test.js
//
// ── WHY THIS SUITE CANNOT SKIP ───────────────────────────────────────────────
// No CI runner has a compositor, so a behavioural QML suite always skips there,
// and a suite that skips proves nothing. So the deciding logic lives in a plain
// module with no process spawning and no filesystem access, and every fixture
// below is inline. It either runs and passes, or runs and fails.
//
// The gaming fixture is the real output of `apex gaming --json` on a machine
// with an RTX 3070 and none of the three packages installed — the state a fresh
// APEX image is actually in, and the one the page has to be good at.

"use strict";

const path = require("path");
const G = require(path.join(__dirname, "..", "src", "services", "config_tab", "gaming.js"));

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

// ── the vocabulary the page renders ──────────────────────────────────────────
check("three on-demand packages are named", G.TOOLS.map(t => t.key),
      ["steam", "gamescope", "mangoapp"]);
check("every named package says what it is for",
      G.TOOLS.every(t => t.label !== "" && t.why !== ""), true);
check("the setup checks are named", G.SETUP.map(s => s.key),
      ["session_desktop", "session_launcher", "switch_helper",
       "switch_sudoers", "rtprio_limits"]);

// ── readGaming(): the fresh-image state, verbatim from the machine ───────────
const FRESH = JSON.stringify({
    ready: false, probes_programs: true, boots_to_game: false,
    preselected_session: "hyprland",
    checks: {
        session_desktop:  { value: true,  source: "/usr/share/wayland-sessions/apex-gaming.desktop" },
        session_launcher: { value: true,  source: "/usr/libexec/apex-gaming-session" },
        switch_helper:    { value: true,  source: "/usr/libexec/apex-session-select" },
        switch_sudoers:   { value: false, source: "/etc/sudoers.d/040-apex-session-select" },
        rtprio_limits:    { value: true,  source: "/etc/security/limits.d/30-apex-gaming-rtprio.conf" },
        gamescope:        { value: false, source: "PATH:gamescope" },
        steam:            { value: false, source: "PATH:steam" },
        mangoapp:         { value: false, source: "PATH:mangoapp" }
    },
    gamepads: [],
    blockers: ["gamescope is not installed; the session exits FATAL without it",
               "steam is not installed; the session exits FATAL without it"],
    warnings: ["mangoapp is not installed, so the in-game overlay is unavailable"],
    install_hint: "sudo apex install gamescope steam"
});

let g = G.readGaming(FRESH);
check("the report is read",              g.ok, true);
check("a fresh image is not ready",      g.ready, false);
check("it does not boot to game",        g.bootsToGame, false);
check("the preselected session is read", g.preselected, "hyprland");
check("both blockers survive",           g.blockers.length, 2);
check("blockers are the CLI's own sentences",
      /exits FATAL/.test(g.blockers[0]), true);
check("the install hint is the CLI's",   g.installHint, "sudo apex install gamescope steam");

check("steam is missing",     G.checkPassed(g, "steam"), false);
check("the launcher is there", G.checkPassed(g, "session_launcher"), true);
// A renamed probe must not read as a pass. This is the difference between "your
// machine is set up" and "this build stopped looking".
check("an unknown check does not count as passing",
      G.checkPassed(g, "no_such_probe"), false);
check("a check carries where it looked",
      G.checkSource(g, "steam"), "PATH:steam");

check("all three packages are missing on a fresh image",
      G.missingTools(g).map(t => t.key), ["steam", "gamescope", "mangoapp"]);
check("the install line is the CLI's hint, not a guess",
      G.installLine(g), "sudo apex install gamescope steam");

// ── nothing the CLI reports may vanish ───────────────────────────────────────
// A probe added on the OS side and not named in TOOLS or SETUP still has to
// appear, or the page silently under-reports what is wrong.
const EXTRA = JSON.parse(FRESH);
EXTRA.checks.hdr_metadata = { value: false, source: "PATH:hdr-thing" };
let ge = G.readGaming(JSON.stringify(EXTRA));
check("an unnamed check is surfaced, not dropped",
      G.otherChecks(ge).map(c => c.key), ["hdr_metadata"]);
// Mapped rather than indexed. `otherChecks(...)[0].passed` throws when a mutant
// empties the list, and a suite that dies partway reports fewer failures than it
// found — every assertion after it never runs.
check("the unnamed check keeps its verdict",
      G.otherChecks(ge).map(c => c.passed), [false]);
check("a fully-named report has no leftovers", G.otherChecks(g), []);

// ── the ready machine ────────────────────────────────────────────────────────
const READY = JSON.parse(FRESH);
READY.ready = true;
READY.boots_to_game = true;
READY.checks.steam.value = true;
READY.checks.gamescope.value = true;
READY.checks.mangoapp.value = true;
READY.checks.switch_sudoers.value = true;
READY.blockers = [];
READY.install_hint = "";
let gr = G.readGaming(JSON.stringify(READY));
check("a ready machine has nothing missing", G.missingTools(gr), []);
check("and offers no install line",          G.installLine(gr), "");
check("and says so",
      G.readiness(gr), "This machine can start straight into Gaming Mode.");

// The count, and its singular. "1 more things" is how a page tells the reader
// nobody proof-read it.
const ONE_SHORT = JSON.parse(JSON.stringify(READY));
ONE_SHORT.ready = false;
ONE_SHORT.checks.steam.value = false;
check("one missing package reads as one",
      G.readiness(G.readGaming(JSON.stringify(ONE_SHORT))),
      "Gaming Mode needs one more thing installed.");
check("three missing packages read as three",
      G.readiness(g), "Gaming Mode needs 3 more things installed.");

// ── readGaming(): the failure modes ──────────────────────────────────────────
check("nothing printed is an error",
      G.readGaming("").error, "apex gaming printed nothing");
check("a failed read is not ready",   G.readGaming("").ready, false);
check("garbage is an error",          /Could not read/.test(G.readGaming("{oops").error), true);
check("a JSON array is not a report",
      G.readGaming("[1,2]").error, "apex gaming did not return a report");
// A failed read must not offer an install line: there is nothing to install
// because nothing was read.
check("a failed read offers no install line", G.installLine(G.readGaming("")), "");
check("a failed read reports nothing missing", G.missingTools(G.readGaming("")), []);

// ── readModeStatus(): the text report ────────────────────────────────────────
const MODE = [
    "tier          : performance",
    "auto-switch   : on",
    "game mode     : off",
    "",
    "mode          : daily"
].join("\n");

let s = G.readModeStatus(MODE);
check("the mode status is read",  s.ok, true);
check("the tier is read",         s.tier, "performance");
check("the auto-switch is read",  s.autoSwitch, "on");
check("game mode is read",        s.gameMode, "off");
check("the mode is read",         s.mode, "daily");
check("daily is not gaming mode", G.inGamingMode(s), false);

let sg = G.readModeStatus(MODE.replace("mode          : daily",
                                       "mode          : gaming"));
check("gaming is gaming mode",    G.inGamingMode(sg), true);
check("the policy line leads with the mode",
      G.policyLine(sg),
      "Mode: gaming   ·   power tier: performance   ·   game mode: off");

// The mode is the one field the page exists to show. A report that parsed
// everything else and not that one is a failed read, not a page with a blank.
check("no mode line is a failed read",
      G.readModeStatus("tier          : performance").ok, false);
check("and says why",
      G.readModeStatus("tier          : performance").error,
      "apex mode status did not report a mode");
check("nothing printed is a failed read", G.readModeStatus("").ok, false);
check("a failed mode read is not gaming mode",
      G.inGamingMode(G.readModeStatus("")), false);
check("the policy line of a failed read is the reason",
      G.policyLine(G.readModeStatus("")), "apex mode status printed nothing");

// Whitespace drift in the report must not lose a field: the columns are
// cosmetic and this parser must not depend on them.
check("column widths do not matter",
      G.readModeStatus("tier : performance\nmode : gaming").mode, "gaming");
check("and neither does trailing space",
      G.readModeStatus("mode          : gaming   ").mode, "gaming");

if (failed > 0) {
    console.error(`\n${failed} assertion(s) failed`);
    process.exit(1);
}
console.log("\nall assertions passed");
