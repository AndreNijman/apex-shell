// hypr-motion-test.js — the compositor follows the shell's motion settings
// (src/services/compositor/hyprMotion.js, UI/UX roadmap v3 Phase 21).
//
//     node tests/hypr-motion-test.js
//
// The live half (a push landing in a real Hyprland) was measured in a nested
// Hyprland 0.56.2: an eval'd hl.animation retargets a leaf at once, a leaf
// switched off loses its curve and style, and `hyprctl reload` restores the
// config's values. This suite pins the planning those facts require.
"use strict";
const path = require("path");
const HM = require(path.join(__dirname, "..", "src", "services", "compositor", "hyprMotion.js"));

let passed = 0, failed = 0;
function check(name, ok, detail) {
    if (ok) { passed++; console.log("ok   " + name); }
    else    { failed++; console.log("FAIL " + name + (detail ? "  — " + detail : "")); }
}

// A read shaped like `hyprctl -j animations` on apex-os appearance.lua
// (0.56.2 wraps the list in an outer array).
const leaf = (name, o) => Object.assign({ name, overridden: true, enabled: true, bezier: "apexDecel", speed: 2, style: "" }, o);
const LIVE = [[
    leaf("windowsIn",  { speed: 2.4,  style: "popin 87%" }),
    leaf("windowsOut", { speed: 1.75, bezier: "apexAccel", style: "popin 87%" }),
    leaf("fadeIn",     { speed: 1.3,  bezier: "apexEffects" }),
    leaf("workspaces", { speed: 2.0,  style: "slide" }),
    leaf("border",     { speed: 1.3,  bezier: "apexStandard" }),
    leaf("windows",    { overridden: false, bezier: "", speed: 0 }),          // inherits: not re-declared
    leaf("borderangle", { enabled: false, bezier: "default", speed: 1 }),     // off in the config: left alone
    leaf("fadeDpms",   { style: 'fade" }) os.execute("x' }),                  // not a style: dropped
    leaf('bad"name',   {}),                                                   // not a name: dropped
]];

// ── the base ─────────────────────────────────────────────────────────────────
const base = HM.baseFrom(JSON.stringify(LIVE));
check("the base is the leaves the config set, enabled, with a speed",
      base && base.map(b => b.name).join(",") === "border,fadeIn,windowsIn,windowsOut,workspaces",
      base && base.map(b => b.name).join(","));
check("…and nothing that is not a leaf name, curve name or style reaches it",
      !JSON.stringify(base).includes("os.execute") && !JSON.stringify(base).includes('bad"'));
check("an unreadable read gives no base rather than an empty one",
      HM.baseFrom("not json") === null && HM.baseFrom("{}") === null);

// ── the push ─────────────────────────────────────────────────────────────────
const at1 = HM.plan(base, 1, false);
check("at the default speed the push is the config's own values",
      at1.includes('leaf = "windowsIn", enabled = true, speed = 2.4, bezier = "apexDecel", style = "popin 87%"')
      && at1.includes('leaf = "fadeIn", enabled = true, speed = 1.3, bezier = "apexEffects" })'), at1);
check("…and animations are switched on", at1.startsWith("hl.config({ animations = { enabled = true } })"));

const relaxed = HM.plan(base, 1.25 * 2, false);
check("a slower shell is a slower compositor, every class by the same factor",
      relaxed.includes("windowsIn\", enabled = true, speed = 6,") && relaxed.includes("workspaces\", enabled = true, speed = 5,"),
      relaxed);
check("closing stays shorter than opening at any speed",
      HM.expected(base, 0.8, false).find(x => x.name === "windowsOut").speed
      < HM.expected(base, 0.8, false).find(x => x.name === "windowsIn").speed);

const rm = HM.expected(base, 2.5, true);
const by = n => rm.find(x => x.name === n);
check("Reduce Motion switches the spatial classes off",
      !by("windowsIn").enabled && !by("windowsOut").enabled && !by("workspaces").enabled);
check("…and keeps the fades and the border, capped at the shell's reduced ceiling (150 ms)",
      by("fadeIn").enabled && by("fadeIn").speed === 1.5 && by("border").enabled && by("border").speed === 1.5,
      JSON.stringify([by("fadeIn"), by("border")]));
check("…a fade already under the cap is not lengthened",
      HM.expected(base, 0.5, true).find(x => x.name === "fadeIn").speed === 0.65);
check("a switched-off leaf is declared off with nothing else (Hyprland resets the rest)",
      HM.plan(base, 1, true).includes('hl.animation({ leaf = "windowsIn", enabled = false })'));

check("scale 0 is no motion at all: animations off, nothing re-declared",
      HM.plan(base, 0, false) === "hl.config({ animations = { enabled = false } })");
check("…and what it records is the leaves as they were, so a restart still recognises them",
      HM.matches(JSON.stringify(LIVE), HM.expected(base, 0, true)));

// ── telling our own push from a reload ───────────────────────────────────────
function liveAfter(table) {   // what Hyprland reports once `table` has been pushed
    return [table.map(t => t.enabled
        ? leaf(t.name, { speed: t.speed, bezier: t.bezier, style: t.style })
        : leaf(t.name, { enabled: false, bezier: "default", speed: 1, style: "" }))];
}
const pushed = HM.expected(base, 2, true);
const state = { signature: "sig-A", base: base, pushed: pushed };
check("a live table that is exactly our push matches it", HM.matches(JSON.stringify(liveAfter(pushed)), pushed));
check("the config's own values do not match a scaled push", !HM.matches(JSON.stringify(LIVE), pushed));
check("a shell restart scales from the recorded base, not from its own push",
      HM.chooseBase(JSON.stringify(liveAfter(pushed)), state, "sig-A") === base);
check("after a reload (live ≠ pushed) the live table is the new base",
      HM.chooseBase(JSON.stringify(LIVE), state, "sig-A").length === base.length
      && HM.chooseBase(JSON.stringify(LIVE), state, "sig-A") !== base);
check("another Hyprland instance's state is ignored",
      HM.chooseBase(JSON.stringify(liveAfter(pushed)), state, "sig-B") !== base);

// ── the inverse: a compounding push is what the state exists to prevent ─────
const naive = HM.baseFrom(JSON.stringify(liveAfter(HM.expected(base, 2, false))));
check("self-test: re-reading our own push as a base WOULD compound (the case chooseBase avoids)",
      naive.find(x => x.name === "windowsIn").speed === 4.8);

console.log(`\nhypr-motion: passed=${passed} failed=${failed}`);
process.exit(failed === 0 ? 0 : 1);
