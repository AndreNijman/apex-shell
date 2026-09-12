#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
//  The shell's size arithmetic (P1-040).
//
//      node tests/scaling-test.js
//
//  ── Why this suite exists at all ────────────────────────────────────────────
//
//  tests/scaling-test.qml had a function called `bucket()` that re-implemented
//  the breakpoint table from theme/Metrics.qml, and seven assertions of the
//  form `eq("1440p -> 1.20", bucket(1440), 1.20)`. Those assertions compared
//  the test's copy against the test's own literals. Changing the table in
//  Metrics.qml changed nothing about whether they passed — measured: shifting
//  the 1440p breakpoint from 1600 to 1500 left that suite at 25/0, unchanged.
//
//  The table now lives in src/theme/scaling.js, which both Metrics and this
//  file read, and every expectation below is a LITERAL rather than a second
//  computation of the same thing.
//
//  It is node rather than QML because the QML suite needs a compositor and
//  skips without one, which is every CI runner this project has.
// ─────────────────────────────────────────────────────────────────────────────
"use strict";

const path = require("path");
const SRC = process.env.APEX_SHELL_SRC
    || path.join(__dirname, "..", "src");
const S = require(path.join(SRC, "theme", "scaling.js"));

let passed = 0;
let failed = 0;

function check(name, cond, detail) {
    if (cond) { passed++; console.log("  PASS  " + name); }
    else {
        failed++;
        console.log("  FAIL  " + name + (detail !== undefined ? "  [" + detail + "]" : ""));
    }
}
function eq(name, got, want) {
    check(name + " (want " + want + ")", got === want, "got " + got);
}

// ── 1. the breakpoints, at heights no machine here has ──────────────────────
{
    eq("768 rows  -> 0.85", S.scaleForHeight(768), 0.85);
    eq("899 rows  -> 0.85 (the last row below the first breakpoint)",
       S.scaleForHeight(899), 0.85);
    eq("900 rows  -> 1.00", S.scaleForHeight(900), 1.00);
    eq("1080 rows -> 1.00", S.scaleForHeight(1080), 1.00);
    // 1200 is in the baseline bucket deliberately: the shell was calibrated on
    // a 1920x1200 panel, and moving it up a bucket would enlarge the UI on the
    // reference machine.
    eq("1200 rows -> 1.00 (the calibrated panel must not grow)",
       S.scaleForHeight(1200), 1.00);
    eq("1249 rows -> 1.00", S.scaleForHeight(1249), 1.00);
    eq("1250 rows -> 1.20", S.scaleForHeight(1250), 1.20);
    eq("1440 rows -> 1.20", S.scaleForHeight(1440), 1.20);
    // Both sides of every boundary, and that is not thoroughness for its own
    // sake: a first draft of this suite tested 1440 and 1600 and nothing in
    // between, so moving the third breakpoint from 1600 to 1500 left it at
    // 35/0. A breakpoint table is only pinned at its edges.
    eq("1499 rows -> 1.20", S.scaleForHeight(1499), 1.20);
    eq("1599 rows -> 1.20 (the last row below the third breakpoint)",
       S.scaleForHeight(1599), 1.20);
    eq("1600 rows -> 1.35", S.scaleForHeight(1600), 1.35);
    eq("1800 rows -> 1.35", S.scaleForHeight(1800), 1.35);
    eq("1999 rows -> 1.35 (the last row below the top bucket)",
       S.scaleForHeight(1999), 1.35);
    eq("2000 rows -> 1.50", S.scaleForHeight(2000), 1.50);
    eq("2160 rows -> 1.50", S.scaleForHeight(2160), 1.50);
    eq("4320 rows -> 1.50 (nothing above the top bucket)",
       S.scaleForHeight(4320), 1.50);

    let mono = true;
    let prev = 0;
    for (const h of [1, 720, 768, 899, 900, 1080, 1200, 1250, 1440, 1600, 1800, 2160, 4320]) {
        const s = S.scaleForHeight(h);
        if (s < prev) mono = false;
        prev = s;
    }
    check("a taller screen never scales down", mono);
}

// ── 2. the recommended compositor scale ─────────────────────────────────────
//
// Integers only, and that is measured rather than chosen: at compositor scale
// 1.25, 1.5 and 1.6 on a 3840x2160 output, Qt reported devicePixelRatio 2 in
// every case — the client renders a 2x buffer and the compositor downsamples
// it. See src/theme/scaling.js.
{
    check("only whole-number scales are offered",
          S.CANDIDATES.every(c => Number.isInteger(c)),
          S.CANDIDATES.join(","));

    eq("3840x2160 -> 2 (1080 logical rows: the calibrated band)",
       S.recommendedScale(3840, 2160), 2);
    eq("3840x2400 -> 2 (1200 logical rows)", S.recommendedScale(3840, 2400), 2);
    eq("5120x2880 -> 2 (1440 logical rows; 3 would leave 960)",
       S.recommendedScale(5120, 2880), 2);
    // 2 would leave 720 rows, under the floor, so the panel stays at 1 and the
    // shell magnifies instead. That is the right way round: a shell too small
    // to read cannot be fixed by the user noticing.
    eq("2560x1440 -> 1", S.recommendedScale(2560, 1440), 1);
    eq("2560x1600 -> 1", S.recommendedScale(2560, 1600), 1);
    eq("1920x1080 -> 1", S.recommendedScale(1920, 1080), 1);
    eq("1366x768  -> 1", S.recommendedScale(1366, 768), 1);

    // A mode that does not divide evenly must not be offered a scale that
    // leaves a fractional buffer: Hyprland refuses the whole monitor rule
    // rather than falling back.
    eq("1365x2049 (odd both ways) -> 1", S.recommendedScale(1365, 2049), 1);
    check("every recommendation divides its mode evenly",
          [[3840, 2160], [3840, 2400], [5120, 2880], [2560, 1440], [1920, 1080]]
              .every(([w, h]) => {
                  const s = S.recommendedScale(w, h);
                  return w % s === 0 && h % s === 0;
              }));
    check("no recommendation leaves fewer rows than the shell can read",
          [[3840, 2160], [3840, 2400], [5120, 2880], [2560, 1440], [1920, 1080],
           [1366, 768]]
              .every(([w, h]) => h / S.recommendedScale(w, h) >= Math.min(h, S.BASELINE_MIN)));
}

// ── 3. the two magnifications multiply ──────────────────────────────────────
{
    eq("a 4K at compositor scale 2 needs no shell magnification",
       S.shellScaleFor(3840, 2160, 2), 1.00);
    eq("the same 4K at compositor scale 1 needs 1.5",
       S.shellScaleFor(3840, 2160, 1), 1.50);
    eq("a 1080p needs none either way", S.shellScaleFor(1920, 1080, 1), 1.00);
    eq("compositor scale 0 is treated as 1 rather than dividing by it",
       S.shellScaleFor(1920, 1080, 0), 1.00);
}

// ── 4. the mixed desk, which is the whole task ──────────────────────────────
//
// The shell has ONE factor. Two outputs that land in different buckets are two
// outputs the factor cannot both be right for, and the Display page says so.
{
    const fourK1  = { width: 3840, height: 2160, scale: 1 };
    const fourK2  = { width: 3840, height: 2160, scale: 2 };
    const hd      = { width: 1920, height: 1080, scale: 1 };
    const qhd     = { width: 2560, height: 1440, scale: 1 };

    check("a 4K and a 1080p, both unscaled, cannot share one shell size",
          S.bucketsDisagree([fourK1, hd]) === true);
    check("the same pair agrees once the 4K is on its recommended scale",
          S.bucketsDisagree([fourK2, hd]) === false);
    check("a 4K at 2 and a 1440p still disagree — the recommendation is not "
          + "a promise that every desk can be made consistent",
          S.bucketsDisagree([fourK2, qhd]) === true);
    check("one output never disagrees with itself",
          S.bucketsDisagree([fourK1]) === false);
    check("no output at all is not a disagreement",
          S.bucketsDisagree([]) === false);
    check("a disabled output is not counted",
          S.bucketsDisagree([fourK2, hd,
                             { width: 2560, height: 1440, scale: 1, enabled: false }]) === false);
    check("an output with no mode yet is not counted",
          S.bucketsDisagree([fourK2, hd, { width: 0, height: 0, scale: 1 }]) === false);
}

// ── factors(): the registry's model ──────────────────────────────────────────
//
// theme/OutputScale builds one shared ThemeSet per entry in this list. If it
// ever stops agreeing with the table, a whole density class of output silently
// gets the wrong token set — or none — so the agreement is asserted here rather
// than left to the QML suite, which needs a compositor CI does not have.
{
    const f = S.factors();

    eq("factors() reports one factor per distinct entry in the table",
       f.length, 5);
    check("factors() is ascending",
          f.every((v, i) => i === 0 || f[i - 1] < v), f.join(","));
    check("factors() has no duplicates",
          new Set(f).size === f.length, f.join(","));
    check("factors() ends at the top-of-table factor",
          f[f.length - 1] === S.TOP_SCALE, f.join(","));
    check("the calibrated baseline 1.0 is one of them", f.indexOf(1.0) >= 0);

    // The property the registry's indexOf lookup depends on, and the reason it
    // is a lookup rather than a float comparison with a tolerance: every answer
    // scaleForHeight() can give must be findable in this list by identity.
    const heights = [1, 200, 720, 768, 899, 900, 1080, 1200, 1249, 1250, 1440,
                     1599, 1600, 1800, 1999, 2000, 2160, 4320, 10000];
    let missing = [];
    for (const h of heights)
        if (f.indexOf(S.scaleForHeight(h)) < 0) missing.push(h + "->" + S.scaleForHeight(h));
    check("every factor scaleForHeight() can return is findable in factors() by identity",
          missing.length === 0, missing.join(" "));

    // And the other direction: a factor in the list that no height produces
    // would be a token set nothing ever reads.
    let unreachable = f.filter(v => !heights.some(h => S.scaleForHeight(h) === v));
    check("every factor in the list is one some output can actually ask for",
          unreachable.length === 0, unreachable.join(","));

    // Derived, not copied. A breakpoint added to the table must appear here
    // without anyone editing a second list — the defect this module exists to
    // end, one level up.
    const fromTable = S.BREAKPOINTS.map(b => b[1]).concat([S.TOP_SCALE]);
    check("factors() is exactly the table's own factors, deduplicated",
          f.length === new Set(fromTable).size
          && f.every(v => fromTable.indexOf(v) >= 0),
          f.join(",") + " vs " + fromTable.join(","));
}

console.log("");
console.log("passed=" + passed + " failed=" + failed);
process.exit(failed === 0 ? 0 : 1);
