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

// A read shaped like `hyprctl -j animations` on rime-os appearance.lua
// (0.56.2 wraps the list in an outer array).
const leaf = (name, o) => Object.assign({ name, overridden: true, enabled: true, bezier: "rimeDecel", speed: 2, style: "" }, o);
const LIVE = [[
    leaf("windowsIn",  { speed: 2.4,  style: "popin 87%" }),
    leaf("windowsOut", { speed: 1.75, bezier: "rimeAccel", style: "popin 87%" }),
    leaf("fadeIn",     { speed: 1.3,  bezier: "rimeEffects" }),
    leaf("workspaces", { speed: 2.0,  style: "slide" }),
    leaf("border",     { speed: 1.3,  bezier: "rimeStandard" }),
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
      at1.includes('leaf = "windowsIn", enabled = true, speed = 2.4, bezier = "rimeDecel", style = "popin 87%"')
      && at1.includes('leaf = "fadeIn", enabled = true, speed = 1.3, bezier = "rimeEffects" })'), at1);
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

// ── springs (rime-os appearance.lua, 2026-09-27) ─────────────────────────────
// Measured in a nested 0.56.2: a spring leaf reads back as bezier
// "spring:<name>" with nothing about the spring itself; config globals are
// visible to `hyprctl eval`; a curve eval'd from one works as a leaf's spring;
// `hyprctl reload` restores the config's leaves (and keeps eval'd curves).
const SLIVE = [[
    leaf("windowsIn",   { speed: 4.8, bezier: "spring:rimeArrive", style: "popin 80%" }),
    leaf("windowsMove", { speed: 4.0, bezier: "spring:rimeGlide" }),
    leaf("windowsOut",  { speed: 2.0, bezier: "emphasizedAccel", style: "popin 85%" }),
    leaf("fadeIn",      { speed: 1.8, bezier: "rimeEffects" }),
    leaf("fadeGlow",    { speed: 3.0, bezier: "spring:glowSpring" }),                // an effect on a spring
    leaf("zoomFactor",  { speed: 3.0, bezier: 'spring:x"]) os.execute("y' }),      // not a name: dropped
]];
const sbase = HM.baseFrom(JSON.stringify(SLIVE));
const sb = n => sbase.find(x => x.name === n);
check("a spring leaf is part of the base, by its spring's name",
      sb("windowsIn") && sb("windowsIn").spring === true && sb("windowsIn").bezier === "rimeArrive"
      && sb("windowsOut") && !sb("windowsOut").spring,
      JSON.stringify(sbase));
check("…and a spring that is not a name never reaches the eval",
      !sb("zoomFactor") && !JSON.stringify(sbase).includes("os.execute"));
check("a scaled copy read back is taken for its base, never a base of its own",
      HM.baseFrom(JSON.stringify([[leaf("windowsMove", { speed: 10, bezier: "spring:rimeGlide__rimes250" })]]))[0].bezier === "rimeGlide");
check("…and so is a copy the shell made before the rename",
      HM.baseFrom(JSON.stringify([[leaf("windowsMove", { speed: 10, bezier: "spring:apexGlide__apexs250" })]]))[0].bezier === "apexGlide");  // rime-rename: keep

const s1 = HM.plan(sbase, 1, false);
check("at the default speed a spring leaf is re-declared on its own spring, nothing derived",
      s1.includes('hl.animation({ leaf = "windowsIn", enabled = true, speed = 4.8, spring = "rimeArrive", style = "popin 80%" })')
      && !s1.includes("RIME_SPRINGS"), s1);
const s25 = HM.plan(sbase, 2.5, false);
check("at another speed the push derives a scaled copy from RIME_SPRINGS",
      s25.includes('local S = RIME_SPRINGS or APEX_SPRINGS; local s = S and S["rimeArrive"]') && s25.includes('hl.curve("rimeArrive__rimes250"')  // rime-rename: keep
      && s25.includes("stiffness = s.stiffness / 6.25") && s25.includes("dampening = s.dampening / 2.5")
      && s25.includes('speed = 12, spring = ok and "rimeArrive__rimes250" or "rimeArrive", style = "popin 80%"'), s25);

const srm = HM.expected(sbase, 2.5, true);
const sr = n => srm.find(x => x.name === n);
check("Reduce Motion switches spatial spring leaves off like any other",
      !sr("windowsIn").enabled && !sr("windowsMove").enabled);
check("…and an effect on a spring runs on the default curve, capped (a spring cannot be)",
      sr("fadeGlow").enabled && sr("fadeGlow").bezier === "default" && sr("fadeGlow").speed === 1.5 && !sr("fadeGlow").spring,
      JSON.stringify(sr("fadeGlow")));

// What Hyprland reports after `table`, with or without the RIME_SPRINGS entries.
function sliveAfter(table, withTable) {
    return [table.map(t => !t.enabled ? leaf(t.name, { enabled: false, bezier: "default", speed: 1, style: "" })
        : leaf(t.name, { speed: t.speed, style: t.style,
                         bezier: t.spring ? "spring:" + (withTable ? t.scaled : t.bezier) : t.bezier }))];
}
const spushed = HM.expected(sbase, 2.5, false);
check("our spring push matches, on the scaled copy",
      HM.matches(JSON.stringify(sliveAfter(spushed, true)), spushed));
check("…and on the unscaled fallback (no RIME_SPRINGS entry)",
      HM.matches(JSON.stringify(sliveAfter(spushed, false)), spushed));
check("a reload (the config's own springs and speeds) does not match a scaled push",
      !HM.matches(JSON.stringify(SLIVE), spushed));
const sstate = { signature: "sig-A", base: sbase, pushed: spushed };
check("a restart scales springs from the recorded base, not from its own push",
      HM.chooseBase(JSON.stringify(sliveAfter(spushed, true)), sstate, "sig-A") === sbase);

// The Lua itself, where a Lua is at hand (the L16 has luajit; CI may not):
// a stub `hl` records what the push declares, with and without the table.
const { spawnSync } = require("child_process");
const lua = ["luajit", "lua", "lua5.4"].find(l => spawnSync(l, ["-v"]).status === 0);
if (!lua) {
    console.log("skip the pushed Lua, run: no lua interpreter here");
} else {
    const stub = `
        local out = {}
        hl = { config = function() end,
               curve = function(n, t) out[#out+1] = string.format("curve %s %s %.4f %.4f %.4f", n, t.type, t.mass, t.stiffness, t.dampening) end,
               animation = function(t) out[#out+1] = string.format("leaf %s %s %s", t.leaf, tostring(t.spring or t.bezier), tostring(t.speed)) end }
    `;
    const run = pre => {
        const r = spawnSync(lua, ["-"], { input: stub + pre + "\n" + s25 + "\nprint(table.concat(out, '\\n'))\n", encoding: "utf8" });
        return (r.stdout || "") + (r.stderr || "");
    };
    const withT = run('RIME_SPRINGS = { rimeArrive = { mass = 1, stiffness = 171.3, dampening = 20.94 }, rimeGlide = { mass = 1, stiffness = 246.74, dampening = 27.02 } }');
    check("run: the scaled copy is the same spring 2.5× slower (stiffness / 6.25, dampening / 2.5)",
          withT.includes("curve rimeArrive__rimes250 spring 1.0000 27.4080 8.3760")
          && withT.includes("leaf windowsIn rimeArrive__rimes250 12"), withT);
    check("run: every spring in the table is scaled, and one missing from it stays on its own curve",
          withT.includes("leaf windowsMove rimeGlide__rimes250 10")
          && withT.includes("leaf fadeGlow glowSpring 7.5") && !withT.includes("glowSpring__rimes"), withT);
    const noT = run("");
    check("run: with no RIME_SPRINGS at all every spring leaf falls back to its own spring, and nothing errors",
          noT.includes("leaf windowsIn rimeArrive 12") && noT.includes("leaf windowsMove rimeGlide 10")
          && !noT.includes("curve ") && !/error|attempt to/.test(noT), noT);
    // An appearance.lua from before the rename keeps the same table under its
    // old name, and a session restarted onto the new shell may still have it.
    const oldT = run('APEX_SPRINGS = { rimeArrive = { mass = 1, stiffness = 171.3, dampening = 20.94 } }');  // rime-rename: keep
    check("run: the table under its pre-rename name, APEX_SPRINGS, scales the same way",
          oldT.includes("curve rimeArrive__rimes250 spring 1.0000 27.4080 8.3760")
          && oldT.includes("leaf windowsIn rimeArrive__rimes250 12"), oldT);
    const both = run('RIME_SPRINGS = { rimeArrive = { mass = 1, stiffness = 171.3, dampening = 20.94 } } '
                     + 'APEX_SPRINGS = { rimeArrive = { mass = 1, stiffness = 1, dampening = 1 } }');  // rime-rename: keep
    check("run: with both, RIME_SPRINGS is the one read",
          both.includes("curve rimeArrive__rimes250 spring 1.0000 27.4080 8.3760"), both);
    const partial = run("RIME_SPRINGS = { rimeArrive = { stiffness = 'stiff' } }");
    check("run: an entry that is not numbers is not guessed at", partial.includes("leaf windowsIn rimeArrive 12")
          && !/error|attempt to/.test(partial), partial);
}

console.log(`\nhypr-motion: passed=${passed} failed=${failed}`);
process.exit(failed === 0 ? 0 : 1);
