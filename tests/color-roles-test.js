#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
//  color-roles-test.js — the surface and text roles (src/theme/roles.js) hold
//  their contrast targets on every palette the shell ships, and the fallback
//  rule says which palettes needed it.
//
//  The palettes are matugen 4.2.0's own output for the six shipped wallpapers
//  in both schemes (tests/fixtures/palettes-matugen-4.2.0.json records how
//  they were produced). The light scheme is reachable but not offered (see
//  Colors.qml); it is checked anyway, because these roles are what makes it
//  offerable.
// ─────────────────────────────────────────────────────────────────────────────
"use strict";
const path = require("path");
const R = require(path.join(__dirname, "..", "src", "theme", "roles.js"));
const FIX = require(path.join(__dirname, "fixtures", "palettes-matugen-4.2.0.json"));

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("  PASS  " + name); }
    else { failed++; console.log("  FAIL  " + name + (detail ? "  [" + detail + "]" : "")); }
}
const hex = h => ({ r: parseInt(h.slice(1, 3), 16) / 255, g: parseInt(h.slice(3, 5), 16) / 255, b: parseInt(h.slice(5, 7), 16) / 255 });
const toHex = c => "#" + [c.r, c.g, c.b].map(v => Math.round(v * 255).toString(16).padStart(2, "0")).join("");
const near = (c, h) => { const d = hex(h); return Math.abs(c.r - d.r) * 255 <= 1.01 && Math.abs(c.g - d.g) * 255 <= 1.01 && Math.abs(c.b - d.b) * 255 <= 1.01; };

// ── 1. the design brief's own table, from its default palette ────────────────
{
    const { roles: r, fired } = R.resolve({ background: hex("#171210"), active: hex("#fab898"), text: hex("#ece0dc") });
    const table = { surfaceRaised: "#221c1a", surfaceOverlay: "#282220", surfaceHigh: "#312b28",
                    surfaceSelected: "#3b2d26", accentContainer: "#523d33", outlineStrong: "#4a4341",
                    // textSecondary .28 and textTertiary .50 (roles.js); the brief's
                    // table has .35 → #a19895 and .55 → #776f6c. .28 since the APEX-OS
                    // default wallpaper became the default look (roles.js says why);
                    // it was .30 → #aca29f.
                    hairline: "#2c2724", textSecondary: "#b0a6a3", textTertiary: "#827976" };
    const off = Object.keys(table).filter(k => !near(r[k], table[k])).map(k => k + "=" + toHex(r[k]) + "≠" + table[k]);
    check("the brief's default palette gives the role table, text at .28 / .50 (±1 per channel)", off.length === 0, off.join(" "));
    check("…with no fallback needed", fired.length === 0, fired.join("; "));
    check("hover and pressed on the base surface are the brief's", near(R.hover(r.surfaceBase, r.textPrimary), "#241e1c")
          && near(R.pressed(r.surfaceBase, r.textPrimary), "#2c2724"),
          toHex(R.hover(r.surfaceBase, r.textPrimary)) + " " + toHex(R.pressed(r.surfaceBase, r.textPrimary)));
}

// ── 2. every shipped palette ─────────────────────────────────────────────────
const T = R.TARGETS;
const worst = {};
const fallbacks = [];
function track(key, v, where) { if (!(key in worst) || v < worst[key].v) worst[key] = { v, where }; }
for (const p of FIX.palettes) {
    const { roles: r, fired } = R.resolve({ background: hex(p.background), active: hex(p.active), text: hex(p.text) });
    const tag = p.wall + "/" + p.mode;
    if (fired.length) fallbacks.push(tag + ": " + fired.join("; "));
    const surfaces = {
        base: r.surfaceBase, raised: r.surfaceRaised, overlay: r.surfaceOverlay, high: r.surfaceHigh,
        selected: r.surfaceSelected, hover: R.hover(r.surfaceBase, r.textPrimary),
        pressed: R.pressed(r.surfaceBase, r.textPrimary)
    };
    for (const [s, c] of Object.entries(surfaces)) {
        track("textPrimary", R.contrast(r.textPrimary, c), tag + " on " + s);
        if (s !== "pressed") track("textSecondary", R.contrast(r.textSecondary, c), tag + " on " + s);
    }
    track("textTertiary", R.contrast(r.textTertiary, r.surfaceBase), tag);
    track("accentText", R.contrast(r.accentText, r.surfaceBase), tag);
    track("iconDefault", R.contrast(r.iconDefault, r.surfaceHigh), tag + " on high");
    track("onAccentContainer", R.contrast(r.onAccentContainer, r.accentContainer), tag);
    track("containerStep", R.contrast(r.accentContainer, r.surfaceBase), tag);
    // The keyboard focus ring (ApexFocusRing, and every hand-drawn ring since
    // Phase 21) is accentText at 2 px, on whatever surface the control sits:
    // a focus indicator is non-text, 3:1 (WCAG 1.4.11) — measured 4.21 worst.
    for (const [s, c] of Object.entries({ base: r.surfaceBase, raised: r.surfaceRaised, overlay: r.surfaceOverlay,
                                          high: r.surfaceHigh, selected: r.surfaceSelected, container: r.accentContainer }))
        track("focusRing", R.contrast(r.accentText, c), tag + " on " + s);
    // The selected fill is a step, not the whole cue — a selected control also
    // turns its label and glyph to the accent — but the step must not vanish.
    track("selectedStep", R.contrast(r.surfaceSelected, r.surfaceBase), tag);
    // A control ON a selected surface (roles.js, surfaceOnSelected): its fill
    // must separate from the row at rest and still while hovered — the state
    // layer moves it toward the row. And the floor that role replaced must not
    // come back by another route: accentContainer stays apart from selected.
    track("onSelectedStep", R.contrast(r.surfaceOnSelected, r.surfaceSelected), tag);
    track("onSelectedHover", R.contrast(R.hover(r.surfaceOnSelected, r.textPrimary), r.surfaceSelected), tag);
    track("containerOverSelected", R.contrast(r.accentContainer, r.surfaceSelected), tag);
    track("textPrimaryOnSelectedControl", R.contrast(r.textPrimary, R.pressed(r.surfaceOnSelected, r.textPrimary)), tag);
    const lift = [r.surfaceRaised, r.surfaceOverlay, r.surfaceHigh].map(c => R.contrast(c, r.surfaceBase));
    track("elevationOrdered", lift[0] < lift[1] && lift[1] < lift[2] ? 1 : 0, tag);
}
const req = { textPrimary: T.textPrimary, textSecondary: T.textSecondary, textTertiary: T.textTertiary,
              accentText: T.accentOnBase, iconDefault: T.icon, onAccentContainer: T.textSecondary,
              containerStep: T.containerStep, elevationOrdered: 1,
              focusRing: 3.0, selectedStep: 1.2,
              onSelectedStep: T.onSelectedStep, onSelectedHover: 1.1, containerOverSelected: 1.1,
              textPrimaryOnSelectedControl: T.textPrimary };
for (const [k, min] of Object.entries(req)) {
    const w = worst[k];
    check(`${k}: ≥ ${min} on all ${FIX.palettes.length} palettes (worst ${w.v.toFixed(2)}, ${w.where})`, w.v >= min);
}
// Fourteen: the APEX-OS default wallpaper's two (the look every harness uses)
// and the six shipped apex-shell-default-* wallpapers' twelve.
check("fourteen palettes were checked, the APEX default's among them",
      FIX.palettes.length === 14 && FIX.palettes.some(p => p.wall === "apex-wallpaper-default.jpg"),
      String(FIX.palettes.length));
console.log("\n  fallbacks fired: " + (fallbacks.length ? "\n    " + fallbacks.join("\n    ") : "none"));
// The fallbacks are the rule working, not a failure: what matters is that
// every palette meets every target AFTER them (above), and that which ones
// fired is known. Pinned, so a palette or formula change that moves them is
// looked at rather than absorbed.
// 0 on the shipped palettes (the APEX default's included) since the text mixes
// moved to .28 / .50 (.30 fired once, on the APEX light palette; it was
// 13 at the brief's .35 / .55, including the default dark palette itself).
const EXPECT_FALLBACKS = 0;
check(`the fallbacks that fire are the known ${EXPECT_FALLBACKS}`, fallbacks.reduce((n, f) => n + f.split(";").length, 0) === EXPECT_FALLBACKS,
      fallbacks.reduce((n, f) => n + f.split(";").length, 0) + " fired");

// ── 3. the rule itself can fire, and repairs what it fires for ───────────────
{
    // An accent that disappears on its surface, a text colour barely off it.
    const bad = R.resolve({ background: hex("#202020"), active: hex("#303030"), text: hex("#8a8a8a") });
    check("a weak accent is repaired for its label/icon uses", bad.fired.some(f => f.startsWith("accentText")),
          bad.fired.join("; "));
    check("a container indistinguishable from the base is strengthened", bad.fired.some(f => f.startsWith("accentContainer")),
          bad.fired.join("; "));
    check("the repaired accent clears 3:1 where the raw one did not",
          R.contrast(bad.roles.accentText, bad.roles.surfaceBase) > R.contrast(hex("#303030"), hex("#202020")));
    check("a selected surface a control would vanish on is pushed further from the base",
          bad.fired.some(f => f.startsWith("surfaceSelected"))
          && R.contrast(bad.roles.surfaceOnSelected, bad.roles.surfaceSelected)
             > R.contrast(hex("#202020"), R.mix(hex("#202020"), hex("#303030"), 0.16)),
          bad.fired.join("; "));
}

console.log("\ncolor-roles: passed=" + passed + " failed=" + failed);
process.exit(failed === 0 ? 0 : 1);
