#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
//  The shell's motion table and its policy (UI/UX roadmap v3, Phase 1).
//
//      node tests/motion-test.js
//
//  src/theme/motion.js is what theme/Motion.qml turns into tokens. Everything
//  here is asserted against LITERALS or against a property of the whole table,
//  never against a second computation of the same number — see the header of
//  tests/scaling-test.js for why that distinction is the whole value of a suite
//  like this.
// ─────────────────────────────────────────────────────────────────────────────
"use strict";

const path = require("path");
const fs = require("fs");
const SRC = process.env.APEX_SHELL_SRC || path.join(__dirname, "..", "src");
const M = require(path.join(SRC, "theme", "motion.js"));

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("  PASS  " + name); }
    else { failed++; console.log("  FAIL  " + name + (detail !== undefined ? "  [" + detail + "]" : "")); }
}

console.log("── the Balanced table is the fluid retune (2026-09-26) ──");
const WANT = { hover: 130, pressIn: 90, pressOut: 280, state: 220, selection: 400, page: 380,
               surfaceEnterSmall: 360, surfaceExitSmall: 240, morphEnter: 520, morphExit: 380,
               notificationShift: 420, hero: 640 };
for (const k of Object.keys(WANT))
    check(k + " = " + WANT[k] + " ms", M.BASE[k] === WANT[k], M.BASE[k]);

console.log("── the shape of the table ──");
check("exits are shorter than entrances (small surface)", M.BASE.surfaceExitSmall < M.BASE.surfaceEnterSmall);
check("exits are shorter than entrances (morph)", M.BASE.morphExit < M.BASE.morphEnter);
check("content leaves faster than it arrives", M.BASE.fadeOut < M.BASE.fadeIn);
check("a press is quicker than its release", M.BASE.pressIn < M.BASE.pressOut);
check("a press is quicker than a hover", M.BASE.pressIn < M.BASE.hover);
const longest = Math.max.apply(null, Object.keys(M.BASE).map(k => M.BASE[k]));
check("nothing is longer than hero", longest === M.BASE.hero, longest);

console.log("── what people do often stays brief (Apple HIG: feedback is brief and precise) ──");
check("a hover is under 150 ms", M.BASE.hover < 150, M.BASE.hover);
check("a press lands in under 100 ms", M.BASE.pressIn < 100, M.BASE.pressIn);
check("a surface takes longer than a page change", M.BASE.morphEnter > M.BASE.page);

console.log("── springs ──");
for (const k of Object.keys(M.SPRINGS)) {
    const sp = M.SPRINGS[k];
    check(k + ": response is a period in seconds (0.1..1)", sp.response >= 0.1 && sp.response <= 1, sp.response);
    check(k + ": damping 0.8..1 (a whisper of overshoot at most)", sp.damping >= 0.8 && sp.damping <= 1, sp.damping);
}
check("a surface folds away quicker than it grows", M.SPRINGS.surfaceClose.response < M.SPRINGS.surfaceOpen.response);
check("surface springs land without overshoot (the geometry clamps progress)",
      M.SPRINGS.surfaceOpen.damping === 1 && M.SPRINGS.surfaceClose.damping === 1);
check("spring(): the speed scales the response", Math.abs(M.spring("page", 1.25, false).response - 1.25 * M.SPRINGS.page.response) < 1e-9);
check("spring(): Reduce Motion snaps", M.spring("page", 1, true).response === 0);
check("spring(): motion off snaps", M.spring("page", 0, false).response === 0);
check("spring(): an unknown role is the surface spring", M.spring("warp", 1, false).response === M.SPRINGS.surfaceOpen.response);
// No curve may leave at full speed: the first 5 % of the time covers under 20 %
// of the travel. The old (0, 0, 0.2, 1) family covered ~30 % there — the snap.
for (const name of Object.keys(M.CURVES))
    check(name + " eases out of rest (under 20 % at 5 % of its time)", M.ease(M.CURVES[name], 0.05) < 0.2,
          M.ease(M.CURVES[name], 0.05).toFixed(3));

console.log("── curves never overshoot and are valid BezierSplines ──");
for (const name of Object.keys(M.CURVES)) {
    const c = M.CURVES[name];
    check(name + ": whole segments", c.length > 0 && c.length % 6 === 0, c.length);
    check(name + ": ends at (1,1)", c[c.length - 2] === 1 && c[c.length - 1] === 1);
    const ys = c.filter((_, i) => i % 2 === 1);
    check(name + ": every control y inside 0..1 (no overshoot possible)",
          ys.every(y => y >= 0 && y <= 1), ys.join(","));
    let mono = true, prev = -1, lo = 1, hi = 0;
    for (let i = 0; i <= 200; i++) {
        const y = M.ease(c, i / 200);
        if (y < prev - 1e-9) mono = false;
        prev = y; lo = Math.min(lo, y); hi = Math.max(hi, y);
    }
    check(name + ": monotone, sampled", mono);
    check(name + ": stays inside 0..1, sampled", lo >= -1e-9 && hi <= 1 + 1e-9, lo + ".." + hi);
}
check("ease() is 0 at 0 and 1 at 1", M.ease(M.CURVES.standard, 0) === 0 && M.ease(M.CURVES.standard, 1) === 1);
// Decelerating curves must lead a straight line early — that early lead is the
// "reacts hard at the start" the roadmap asks for, and InOutCubic's lack of it
// is what the baseline shows as dead frames.
for (const name of ["standardDecel", "emphasizedDecel", "fastSpatial", "defaultSpatial"])
    check(name + " is past 35% at 20% of its time", M.ease(M.CURVES[name], 0.2) > 0.35,
          M.ease(M.CURVES[name], 0.2).toFixed(3));
check("fastSpatial starts harder than slowSpatial",
      M.ease(M.CURVES.fastSpatial, 0.15) > M.ease(M.CURVES.slowSpatial, 0.15));
check("standardAccel lags a straight line early (it is an exit curve)",
      M.ease(M.CURVES.standardAccel, 0.3) < 0.3);

console.log("── speed ──");
check("balanced is 1x", M.speedScale("balanced", 1) === 1);
check("snappy is 0.8x", Math.abs(M.speedScale("snappy", 1) - 0.8) < 1e-9);
check("relaxed is 1.25x", Math.abs(M.speedScale("relaxed", 1) - 1.25) < 1e-9);
check("an unknown preset is balanced", M.speedScale("warp", 1) === 1);
check("scale multiplies the preset", Math.abs(M.speedScale("relaxed", 2) - 2.5) < 1e-9);
check("scale is clamped at the top", M.speedScale("balanced", 9) === M.SCALE_MAX);
check("scale 0 is legal and means no motion", M.speedScale("balanced", 0) === 0);
check("a non-number scale is 1x", M.speedScale("balanced", "abc") === 1);
check("a null scale is 1x", M.speedScale("balanced", null) === 1);

console.log("── Reduce Motion ──");
check("spatial motion is removed", M.spatial(240, 1, true) === 0);
check("spatial motion scales otherwise", M.spatial(240, 1.25, false) === 300);
check("an effect survives", M.effect(80, 1, true) === 80);
check("a hover survives Reduce Motion whole", M.effect(M.BASE.hover, 1, true) === M.BASE.hover);
check("an effect is capped", M.effect(M.BASE.hero, 1, true) === M.REDUCED_EFFECT_CAP);
check("a relaxed effect is still capped", M.effect(130, 2.5, true) === M.REDUCED_EFFECT_CAP);
check("scale 0 turns effects off too", M.effect(80, 0, false) === 0);

console.log("── the legacy single duration ──");
check("is 320 at 1x", M.legacyDuration(1, false) === 320);
check("is 0 under Reduce Motion", M.legacyDuration(1, true) === 0);
check("follows the speed", M.legacyDuration(1.5, false) === 480);

console.log("── the settings migration reads the same arithmetic ──");
// SettingsService migrates a file that still has animDuration by the ratio to
// 320. Read the service to prove the mapping is the one this table inverts.
const ss = fs.readFileSync(path.join(SRC, "services", "SettingsService.qml"), "utf8");
check("SettingsService migrates animDuration / 320", /legacy\s*\/\s*320/.test(ss));
check("SettingsService no longer persists animDuration",
      !/"animDuration"/.test(ss.split("_keys:")[1].split("]")[0]));
check("motionScale is parsed as a real", /_realKeys:\s*\[[^\]]*"motionScale"/.test(ss));
check("motionScale bounds match the table", /motionScale:\s*\[0,\s*2\.5\]/.test(ss)
      && M.SCALE_MIN === 0 && M.SCALE_MAX === 2.5);

console.log("\nmotion: passed=" + passed + " failed=" + failed);
process.exit(failed === 0 ? 0 : 1);
