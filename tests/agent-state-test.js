#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
//  What an agent state looks like, measured rather than asserted (P0-021).
//
//      node tests/agent-state-test.js
//      APEX_SHELL_SRC=/path/to/other/src node tests/agent-state-test.js
//
//  ── Why this file does arithmetic ───────────────────────────────────────────
//
//  "Contrast meets accessibility targets" is not a thing a test can take on
//  trust, and neither is "the states are visually distinct". Both are numbers.
//  This computes them — WCAG 2.1 relative luminance for contrast, CIE76 ΔE over
//  Viénot-1999 dichromat simulations for distinctness — against the palettes
//  the shell actually ships, and prints the table it checked.
//
//  It reads src/services/agentstate.js (the file the shell loads) and the hex
//  values out of src/theme/Colors.qml, so the numbers describe the tree rather
//  than a copy of it. Point APEX_SHELL_SRC at another checkout to measure that
//  one instead — which is how the pre-fix tree was shown to fail.
//
//  ── Where the palettes come from ────────────────────────────────────────────
//
//  Not invented. Every row of PALETTES below is matugen 4.2.0's own output for
//  a wallpaper that ships in this repository, rendered through the shell's own
//  contract template:
//
//      matugen image src/assets/wallpapers/<file> \
//          -c <cfg> --source-color-index 0 --type scheme-content -m <mode>
//
//  with src/config/apex-shell-colors.json.example as the template — the same
//  file ~/.cache/apex-shell/colors.json is generated from. Six wallpapers, both
//  modes, twelve palettes.
//
//  Both modes, because P0-021 asks for light as well as dark and the shell had
//  only ever been looked at on dark. These figures were measured before the
//  flag was reachable — WallpaperService passes `-m` now, and section 10 holds
//  it there, so the numbers below describe a palette a user can actually get to
//  rather than one nobody can reach.
//
//  The dark surfaces cluster at #111410–#141311 and the light ones at
//  #f9f9f9–#fdf9f3. That tightness is the reason a two-value status token
//  works at all: an M3 surface is near-black or near-white, never the mid grey
//  where a lightness threshold would have nothing useful to say. A hand-edited
//  colors.json with a genuinely mid-grey surface is outside what these values
//  can promise, and this file does not pretend otherwise.
//
//  ── The three surfaces ──────────────────────────────────────────────────────
//
//  A tone is never drawn on the background alone. SessionRow paints a card at
//  3% of the palette's foreground over the background, 7% while hovered, so the
//  ground under a state colour has three values and the hovered one is the
//  worst of them. All three are checked.
// ─────────────────────────────────────────────────────────────────────────────

"use strict";

const fs = require("fs");
const path = require("path");

const SRC = process.env.APEX_SHELL_SRC
    || path.join(__dirname, "..", "src");

let failed = 0;
let passed = 0;
function ok(name)          { passed++; console.log(`ok   ${name}`); }
function bad(name, detail) {
    failed++;
    console.error(`FAIL ${name}`);
    if (detail) console.error(`       ${detail}`);
}
function check(name, cond, detail) { cond ? ok(name) : bad(name, detail); }

// ── colour maths ────────────────────────────────────────────────────────────

function rgb(hex) {
    const h = String(hex).replace("#", "");
    return [0, 2, 4].map(i => parseInt(h.slice(i, i + 2), 16) / 255);
}
function toHex(c) {
    return "#" + c.map(v =>
        Math.max(0, Math.min(255, Math.round(v * 255)))
            .toString(16).padStart(2, "0")).join("");
}
// sRGB → linear, and back. Every formula below needs linear light; doing any of
// this on the gamma-encoded components is the classic way to get numbers that
// look plausible and are wrong by a third.
const toLinear = v => v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
const toSrgb   = v => v <= 0.0031308 ? 12.92 * v : 1.055 * Math.pow(v, 1 / 2.4) - 0.055;

function luminance(hex) {
    const [r, g, b] = rgb(hex).map(toLinear);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
function contrast(a, b) {
    const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
    return (hi + 0.05) / (lo + 0.05);
}
// Source-over of `over` at alpha `a` on `base`, in the same space Qt composites
// a Rectangle in.
function blend(base, over, a) {
    const [b, o] = [rgb(base), rgb(over)];
    return toHex(b.map((v, i) => v * (1 - a) + o[i] * a));
}

function toLab(hex) {
    const [r, g, b] = rgb(hex).map(toLinear);
    const X = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047;
    const Y = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 1.0;
    const Z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883;
    const f = t => t > 0.008856 ? Math.cbrt(t) : 7.787 * t + 16 / 116;
    const [fx, fy, fz] = [f(X), f(Y), f(Z)];
    return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
}
function deltaE(a, b) {
    const [la, lb] = [toLab(a), toLab(b)];
    return Math.hypot(la[0] - lb[0], la[1] - lb[1], la[2] - lb[2]);
}

// Viénot, Brettel & Mollon 1999: project onto the dichromat's reduced colour
// plane in LMS. Not a perfect model of what anybody sees, but it is the one the
// accessibility tooling agrees on, and it is far better than eyeballing hues.
function simulate(hex, kind) {
    if (kind === "normal") return hex;
    const [r, g, b] = rgb(hex).map(toLinear);
    let L = 0.31399022 * r + 0.63951294 * g + 0.04649755 * b;
    let M = 0.15537241 * r + 0.75789446 * g + 0.08670142 * b;
    let S = 0.01775239 * r + 0.10944209 * g + 0.87256922 * b;
    if (kind === "protan")      L =  1.05118294 * M - 0.05116099 * S;
    else if (kind === "deutan") M =  0.9513092  * L + 0.04866992 * S;
    else if (kind === "tritan") S = -0.86744736 * L + 1.86727089 * M;
    const out = [
         5.47221206 * L - 4.6419601  * M + 0.16963708 * S,
        -1.1252419  * L + 2.29317094 * M - 0.1678952  * S,
         0.02980165 * L - 0.19318073 * M + 1.16364789 * S
    ];
    return toHex(out.map(v => toSrgb(Math.max(0, Math.min(1, v)))));
}

// ── the tree under test ─────────────────────────────────────────────────────

const agentStatePath = path.join(SRC, "services", "agentstate.js");
if (!fs.existsSync(agentStatePath)) {
    console.error(`FAIL the shell has no single source for a state's colour`);
    console.error(`       expected ${agentStatePath}`);
    console.error(`       without it every row decides a state's colour inline,`);
    console.error(`       which is how seven states collapsed onto Theme.text.`);
    process.exit(1);
}
const A = require(agentStatePath);

// Colours out of Colors.qml. Line comments are dropped first: this file argues
// with itself at length and names plenty of hexes in prose.
function readColorsQml() {
    const raw = fs.readFileSync(path.join(SRC, "theme", "Colors.qml"), "utf8");
    const code = raw.split("\n").map(l => l.replace(/\/\/.*$/, "")).join("\n");
    const pairs = {}, flat = {};
    let m;
    const paired = /property color\s+(\w+)\s*:\s*darkSurface\s*\?\s*"(#[0-9a-fA-F]{6})"\s*:\s*"(#[0-9a-fA-F]{6})"/g;
    while ((m = paired.exec(code)) !== null)
        pairs[m[1]] = { dark: m[2].toLowerCase(), light: m[3].toLowerCase() };
    const single = /property color\s+(\w+)\s*:\s*"(#[0-9a-fA-F]{3,8})"/g;
    while ((m = single.exec(code)) !== null) flat[m[1]] = m[2].toLowerCase();
    return { pairs, flat };
}
const COLORS = readColorsQml();
const THEME_QML = fs.readFileSync(path.join(SRC, "theme", "Theme.qml"), "utf8");

// ── the palettes, from matugen 4.2.0 ────────────────────────────────────────
// wallpaper, mode, and the two fields a status colour is drawn against.
const PALETTES = [
    ["apex-shell-default-0.png", "dark",  "#141311", "#e6e2dd", "#ccc6b9"],
    ["apex-shell-default-0.png", "light", "#fdf9f3", "#1d1b19", "#4a473c"],
    ["apex-shell-default-1.png", "dark",  "#121316", "#e2e2e5", "#c2c7cf"],
    ["apex-shell-default-1.png", "light", "#f9f9fc", "#1a1c1e", "#42474e"],
    ["apex-shell-default-2.jpg", "dark",  "#111410", "#e2e3dc", "#c2c9bc"],
    ["apex-shell-default-2.jpg", "light", "#f9faf3", "#1a1c18", "#42493f"],
    ["apex-shell-default-3.jpg", "dark",  "#111319", "#e1e2ea", "#c2c6d4"],
    ["apex-shell-default-3.jpg", "light", "#f9f9ff", "#191c21", "#424752"],
    ["apex-shell-default-4.jpg", "dark",  "#121414", "#e2e2e2", "#c0c8c9"],
    ["apex-shell-default-4.jpg", "light", "#f9f9f9", "#1a1c1c", "#414849"],
    ["apex-shell-default-5.jpg", "dark",  "#121318", "#e3e1e9", "#c5c5d3"],
    ["apex-shell-default-5.jpg", "light", "#fbf8ff", "#1b1b21", "#454651"]
].map(([wall, mode, background, text, subtext]) => ({
    wall, mode, background, text, subtext,
    card:  blend(background, text, 0.03),
    hover: blend(background, text, 0.07)
}));

// WCAG 2.1: 4.5:1 for text at this size. The state word IS text — it says
// "waiting for you" — so the lower 3:1 non-text bar does not apply, and holding
// the badge and the stripe to the text bar as well costs nothing.
const MIN_CONTRAST = 4.5;
// A ΔE a person can see across a gap, rather than side by side. Two swatches
// touching are separable well below this; two rows apart in a list are not.
const MIN_DELTA_E = 20;

// apex-agent-core/src/protocol.rs, `enum AgentState`. Transcribed rather than
// derived: if the runtime grows an eighth state, this list not knowing about it
// is the failure that should be reported.
const RUNTIME_STATES = [
    "starting", "working", "waiting_for_user", "permission_request",
    "complete", "failed", "exited"
];

// ── 1. every runtime state has a tone, and nothing is guessed ───────────────
{
    const unmapped = RUNTIME_STATES.filter(s => !(s in A.STATE_TONES));
    check("every state apex-agent-core can publish has a tone",
          unmapped.length === 0, `unmapped: ${unmapped.join(", ")}`);
    check("a state this build has not been taught is drawn as idle, not guessed",
          A.tone("some_future_state") === "idle" && A.tone("") === "idle",
          `got ${A.tone("some_future_state")}`);
    const stale = Object.keys(A.STATE_TONES).filter(s => !RUNTIME_STATES.includes(s));
    check("no tone describes a state the runtime does not have",
          stale.length === 0, `stale: ${stale.join(", ")}`);
}

// ── 2. the five the roadmap requires are five ──────────────────────────────
{
    const tokens = A.DISTINCT_TONES.map(t => A.TONES[t].token);
    check("the five distinct states use five distinct tokens",
          new Set(tokens).size === 5, tokens.join(", "));
    const missing = tokens.filter(t =>
        !new RegExp(`property color\\s+${t}\\s*:`).test(THEME_QML));
    check("every token a state names is reachable as Theme.<token>",
          missing.length === 0, `not on Theme: ${missing.join(", ")}`);
}

// ── 3. the status tokens answer to surface lightness ───────────────────────
// The defect this replaces: one value per token, chosen on a dark surface, and
// therefore a 1.3:1 read on a light one.
{
    const need = ["danger", "warning", "success", "info", "attention"];
    const flatOnly = need.filter(t => !COLORS.pairs[t]);
    check("every status token has a value for a light surface and a dark one",
          flatOnly.length === 0,
          flatOnly.length
              ? `single-valued: ${flatOnly.map(t =>
                  `${t}=${COLORS.flat[t] || "?"}`).join(", ")}`
              : "");
    check("the fixed-contrast foregrounds are still literal",
          !!COLORS.flat.fixedLight && !!COLORS.flat.fixedDark);
}

// Resolve a tone's colour the way Colors.qml does, for a given palette.
function toneColor(tone, pal) {
    const token = A.TONES[tone].token;
    if (COLORS.pairs[token])
        return COLORS.pairs[token][pal.mode === "dark" ? "dark" : "light"];
    if (token === "subtext") return pal.subtext;
    if (token === "text")    return pal.text;
    return COLORS.flat[token];
}
// Mirrors Colors.onStatus: the better-measuring of the two fixed foregrounds.
function onStatus(fill) {
    return contrast(COLORS.flat.fixedDark, fill)
           >= contrast(COLORS.flat.fixedLight, fill)
           ? COLORS.flat.fixedDark : COLORS.flat.fixedLight;
}

// ── 4. contrast, on all three surfaces, for all twelve palettes ────────────
if (Object.keys(COLORS.pairs).length) {
    console.log("\n── contrast: state tone against background / card / hovered card ──");
    let worst = { ratio: Infinity };
    const rows = [];
    for (const pal of PALETTES) {
        for (const tone of A.DISTINCT_TONES.concat(["idle"])) {
            const c = toneColor(tone, pal);
            const grounds = { bg: pal.background, card: pal.card, hover: pal.hover };
            for (const [where, ground] of Object.entries(grounds)) {
                const ratio = contrast(c, ground);
                if (ratio < worst.ratio) worst = { ratio, tone, where, pal, c };
            }
            rows.push({
                pal, tone, c,
                bg: contrast(c, pal.background),
                card: contrast(c, pal.card),
                hover: contrast(c, pal.hover)
            });
        }
    }
    // One line per (palette, tone) is 72 lines; print the per-mode summary and
    // the full table only for the wallpaper the installer sets by default.
    for (const mode of ["dark", "light"]) {
        console.log(`  ${mode}:`);
        for (const tone of A.DISTINCT_TONES.concat(["idle"])) {
            const mine = rows.filter(r => r.pal.mode === mode && r.tone === tone);
            const lo = Math.min(...mine.map(r => Math.min(r.bg, r.card, r.hover)));
            const hi = Math.max(...mine.map(r => Math.max(r.bg, r.card, r.hover)));
            const sample = mine[0];
            console.log(`    ${tone.padEnd(8)} ${String(sample.c).padEnd(9)} `
                + `${lo.toFixed(2)}:1 … ${hi.toFixed(2)}:1  `
                + `(weight ${A.TONES[tone].weight})`);
        }
    }
    check(`every state tone clears ${MIN_CONTRAST}:1 on every surface of every shipped palette`,
          worst.ratio >= MIN_CONTRAST,
          worst.ratio === Infinity ? "" :
          `worst: ${worst.tone} ${worst.c} on ${worst.where} `
          + `(${worst.pal.wall} ${worst.pal.mode}) = ${worst.ratio.toFixed(2)}:1`);

    // ── 5. the glyph ON a filled badge ─────────────────────────────────────
    let worstFill = { ratio: Infinity };
    for (const pal of PALETTES) {
        for (const tone of A.DISTINCT_TONES) {
            if (A.TONES[tone].weight !== "solid") continue;
            const fill = toneColor(tone, pal);
            const ratio = contrast(onStatus(fill), fill);
            if (ratio < worstFill.ratio)
                worstFill = { ratio, tone, fill, fg: onStatus(fill), pal };
        }
    }
    check("the glyph on a filled badge is readable on the fill under it",
          worstFill.ratio >= MIN_CONTRAST,
          `worst: ${worstFill.fg} on ${worstFill.tone} ${worstFill.fill} `
          + `= ${(worstFill.ratio || 0).toFixed(2)}:1`);

    // ── 6. the bug itself ──────────────────────────────────────────────────
    // Four of seven states used to resolve to the palette's own foreground.
    // Assert they cannot again: a state tone is never the text colour, and is
    // never within touching distance of it.
    let collision = null;
    for (const pal of PALETTES) {
        for (const tone of A.DISTINCT_TONES) {
            const c = toneColor(tone, pal);
            for (const [name, fg] of [["text", pal.text], ["subtext", pal.subtext]]) {
                if (deltaE(c, fg) < MIN_DELTA_E)
                    collision = `${tone} ${c} is ΔE ${deltaE(c, fg).toFixed(1)} `
                        + `from ${name} ${fg} (${pal.wall} ${pal.mode})`;
            }
        }
    }
    check("no state tone is the palette's own foreground (the defect P0-021 reports)",
          collision === null, collision);

    // ── 7. distinct to a colourblind reader, or distinct by shape ─────────
    console.log("\n── distinctness: ΔE between state tones, simulated ──");
    let worstPair = null;
    for (const mode of ["dark", "light"]) {
        const pal = PALETTES.find(p => p.mode === mode);
        for (const vision of ["normal", "protan", "deutan", "tritan"]) {
            let lowest = { d: Infinity };
            for (let i = 0; i < A.DISTINCT_TONES.length; i++) {
                for (let j = i + 1; j < A.DISTINCT_TONES.length; j++) {
                    const [x, y] = [A.DISTINCT_TONES[i], A.DISTINCT_TONES[j]];
                    const d = deltaE(simulate(toneColor(x, pal), vision),
                                     simulate(toneColor(y, pal), vision));
                    const shaped = A.TONES[x].weight !== A.TONES[y].weight;
                    if (!shaped && d < lowest.d) lowest = { d, x, y };
                    if (!shaped && d < MIN_DELTA_E)
                        worstPair = `${x}/${y} ΔE ${d.toFixed(1)} under ${vision} `
                            + `(${mode}) and they share the ${A.TONES[x].weight} weight`;
                }
            }
            console.log(`  ${mode.padEnd(5)} ${vision.padEnd(7)} `
                + `closest same-weight pair: `
                + (lowest.d === Infinity ? "none"
                   : `${lowest.x}/${lowest.y} ΔE ${lowest.d.toFixed(1)}`));
        }
    }
    check(`every pair of the five differs in badge weight, or by ${MIN_DELTA_E} ΔE under `
          + `normal, protanopic, deuteranopic and tritanopic vision`,
          worstPair === null, worstPair);
} else {
    bad("contrast could not be measured: no two-valued status token was found",
        "Colors.qml gives each status token a single value");
}

// ── 8. the agents render consistently ──────────────────────────────────────
{
    const want = {
        claude: "Claude", opencode: "OpenCode", codex: "Codex",
        gemini: "Gemini", kimi: "Kimi", generic: "Agent"
    };
    const wrong = Object.entries(want)
        .filter(([id, name]) => A.agentName(id) !== name)
        .map(([id, name]) => `${id} → ${A.agentName(id)}, want ${name}`);
    check("every adapter is named the way its vendor spells it",
          wrong.length === 0, wrong.join("; "));
    check("an unknown adapter keeps its id rather than disappearing",
          A.agentName("newthing") === "Newthing");
    check("a session with no adapter recorded is still named",
          A.agentName("") === "Agent" && A.agentName(null) === "Agent");
    // Every adapter gets the same treatment; nothing branches on which one.
    const tones = Object.keys(want).map(() => A.tone("working"));
    check("the adapter does not change how a state is drawn",
          new Set(tones).size === 1);
}

// ── 9. needsYou agrees with the runtime ────────────────────────────────────
{
    const yes = RUNTIME_STATES.filter(A.needsYou);
    check("exactly the two states that are waiting on a human say so",
          yes.length === 2
          && yes.includes("waiting_for_user")
          && yes.includes("permission_request"),
          yes.join(", "));
    check("and they are drawn differently from each other",
          A.token("waiting_for_user") !== A.token("permission_request"));
}

// ── 10. the light half of every palette above is reachable ─────────────────
//
// Sections 3 to 7 measure twelve palettes, six of them light. That measurement
// is worth nothing if no user can get to a light palette: matugen defaults to
// dark, so a generator that never passes `-m` renders the dark half of every
// template and the light values in Colors.qml are dead weight that still passes
// every contrast assertion.
//
// So this is the section that keeps the other six honest. It reads the
// generator rather than the palette.
{
    const wall = fs.readFileSync(
        path.join(SRC, "services", "WallpaperService.qml"), "utf8");

    check("WallpaperService has a palette mode",
          /property\s+string\s+mode\s*:\s*"(dark|light)"/.test(wall));

    // Both invocations. The second renders whatever templates the user keeps in
    // their own matugen config; a shell in light beside a terminal still in dark
    // is a worse outcome than either mode on its own.
    const invocations = wall.split("\n").filter(l => /matugen image/.test(l));
    check("both matugen invocations are still there", invocations.length === 2,
          `found ${invocations.length}`);
    check("every matugen invocation passes -m",
          invocations.length === 2 && invocations.every(l => /-m \\"\$4\\"/.test(l)),
          invocations.join(" | "));

    // The flag has to carry the mode, not a constant. `-m dark` spelled out
    // would satisfy the check above and leave light exactly as unreachable.
    check("the mode reaches the command as an argument, not a literal",
          /root\.scheme,\s*root\.mode/.test(wall));

    check("the choice is persisted with the wallpaper",
          /mode:\s*root\.mode/.test(wall) && /obj\.mode\s*===\s*"light"/.test(wall));

    // A property no page writes is still unreachable, one screen further along.
    const appearance = fs.readFileSync(
        path.join(SRC, "services", "config_tab", "pages", "AppearancePage.qml"),
        "utf8");
    check("a control on the Appearance page sets it",
          /WallpaperService\.setMode\(/.test(appearance)
          && /WallpaperService\.modes/.test(appearance));
}

console.log(`\nagent-state: passed=${passed} failed=${failed}`);
process.exit(failed === 0 ? 0 : 1);
