// ─── hyprMotion.js ───────────────────────────────────────────────────────────
// The compositor on the shell's motion settings (UI/UX roadmap v3 Phase 21).
//
// Rime Shell's Motion has a speed (Snappy / Balanced / Relaxed × a duration
// scale) and Reduce Motion. Hyprland's motion lives in its own config
// (rime-os appearance.lua), so without this a user who asked for slower or
// less motion got it in the shell and not in the windows around it.
//
// Nothing here knows Hyprland's numbers. The base is read back from Hyprland
// itself (`hyprctl -j animations`): every leaf its config set explicitly
// ("overridden"), enabled, with a speed. The push re-declares each of those at
// base × scale — a leaf its config did not set inherits from its parent, which
// is re-declared, so it follows. Under Reduce Motion the spatial classes are
// off and the fades are capped at the shell's own reduced-effect ceiling
// (150 ms, motion.js REDUCED_EFFECT_CAP), the same split the shell makes: a
// change is still visible, nothing travels. At scale 0 — "no motion at all" —
// animations are off entirely.
//
// Disabling a leaf resets its curve and style (measured: `enabled = false`
// alone leaves bezier "default", speed 1, style ""), which is why the base is
// kept and every push is a full declaration of every leaf.
//
// A leaf on a spring reads back as bezier "spring:<name>" and nothing more —
// Hyprland reports neither its stiffness nor its damping, and ignores `speed`
// for it (a spring is stepped in real time until it is at rest). So a spring
// is scaled inside Hyprland's own Lua: rime-os appearance.lua keeps every
// spring it declares in the global RIME_SPRINGS, and the push derives a copy
// from that entry — stiffness / s², dampening / s, the same motion s times
// slower — named <name>__rimes<percent>. A spring with no entry (someone's own
// config) is re-declared unscaled rather than guessed at: it still follows
// Reduce Motion and "no motion". The copy's suffix is stripped on read, so a
// copy is never mistaken for a base. Copies outlive `hyprctl reload` (it keeps
// eval'd curves), one per speed ever used; they are a few floats each.
//
// Pure, no `.pragma library`: node reads this file too
// (tests/hypr-motion-test.js).
// ─────────────────────────────────────────────────────────────────────────────

// The classes that move something. Everything else (fades, the border's
// colour) is an effect, and survives Reduce Motion shortened.
var SPATIAL = /^(windows|workspaces|specialWorkspace|layers|zoomFactor|monitorAdded)/;

// motion.js REDUCED_EFFECT_CAP, in Hyprland's unit (tenths of a second).
var REDUCED_CAP_DS = 1.5;

// What may be spliced into the eval. The values come from Hyprland's own
// output, but they end up inside a Lua string, so anything outside these
// shapes is dropped rather than escaped.
var NAME_RE  = /^[A-Za-z][A-Za-z0-9_]*$/;
var STYLE_RE = /^[a-z]+( [a-z]+| -?[0-9.]+%?)*$/;

var SPRING_PREFIX = "spring:";
// A scaled copy made by this shell is <name>__rimes<pct>. Copies outlive a
// `hyprctl reload`, so a session the shell was restarted into can still hold
// the ones the shell made before the rename, __apexs<pct>; either suffix is a
// copy, never a base of its own.
var SCALED_RE     = /__(rime|apex)s[0-9]+$/;  // rime-rename: keep (the suffix the APEX shell gave its copies)

/// The name of `spring` at `scale`: itself at 100 %, else its scaled copy.
function scaledSpring(spring, scale) {
    var pct = Math.round(scale * 100);
    return pct === 100 ? spring : spring + "__rimes" + pct;
}

/// The leaves worth re-declaring, from `hyprctl -j animations` output.
/// [{ name, speed, bezier, spring?, style }], sorted by name. `bezier` is the
/// curve's name; `spring` marks it as a spring (`spring:` and any scaled
/// copy's suffix stripped).
function baseFrom(json) {
    var data;
    try { data = typeof json === "string" ? JSON.parse(json) : json; } catch (e) { return null; }
    if (!Array.isArray(data)) return null;
    var list = (data.length && Array.isArray(data[0])) ? data[0] : data;
    var out = [];
    for (var i = 0; i < list.length; i++) {
        var a = list[i];
        if (!a || typeof a !== "object" || !a.overridden || !a.enabled) continue;
        var speed = Number(a.speed);
        if (!isFinite(speed) || speed <= 0) continue;
        var curve = String(a.bezier || ""), spring = curve.indexOf(SPRING_PREFIX) === 0;
        if (spring) curve = curve.slice(SPRING_PREFIX.length).replace(SCALED_RE, "");
        if (!NAME_RE.test(String(a.name)) || !NAME_RE.test(curve)) continue;
        var style = String(a.style || "");
        if (style !== "" && !STYLE_RE.test(style)) continue;
        var b = { name: String(a.name), speed: speed, bezier: curve, style: style };
        if (spring) b.spring = true;
        out.push(b);
    }
    out.sort(function (x, y) { return x.name < y.name ? -1 : x.name > y.name ? 1 : 0; });
    return out;
}

function _round(v) { return Math.round(v * 100) / 100; }

/// The table Hyprland should report after a push: [{ name, enabled, speed?,
/// bezier?, spring?, scaled?, style? }]. Also what a later read is compared
/// against, to tell "this is our own push" from "the config was reloaded".
/// A spring entry names its base (`bezier`) and the copy the push asks for
/// (`scaled`); which of the two Hyprland ends up on depends on RIME_SPRINGS.
function expected(base, scale, reduced) {
    // Scale 0 switches animations off globally and leaves every leaf as it is.
    if (!(scale > 0)) return expected(base, 1, false);
    var out = [];
    for (var i = 0; i < base.length; i++) {
        var b = base[i];
        if (reduced && SPATIAL.test(b.name)) { out.push({ name: b.name, enabled: false }); continue; }
        var s = _round(b.speed * scale);
        if (reduced) s = Math.min(s, REDUCED_CAP_DS);
        if (b.spring && reduced) {
            // An effect on a spring cannot be capped (a spring has no length):
            // under Reduce Motion it runs on Hyprland's default curve instead,
            // capped like every other effect. rime-os puts no effect on one.
            out.push({ name: b.name, enabled: true, speed: s, bezier: "default", style: b.style });
        } else if (b.spring) {
            out.push({ name: b.name, enabled: true, speed: s, bezier: b.bezier, spring: true,
                       scaled: scaledSpring(b.bezier, scale), style: b.style });
        } else {
            out.push({ name: b.name, enabled: true, speed: s, bezier: b.bezier, style: b.style });
        }
    }
    return out;
}

function _springLine(w, scale) {
    var tail = (w.style ? ', style = "' + w.style + '"' : "") + " })";
    var head = 'hl.animation({ leaf = "' + w.name + '", enabled = true, speed = ' + w.speed + ", spring = ";
    if (w.scaled === w.bezier) return head + '"' + w.bezier + '"' + tail;
    var f = Math.round(scale * 100) / 100;
    // RIME_SPRINGS is the table rime-os appearance.lua keeps; an appearance.lua
    // written before the rename kept the same table as APEX_SPRINGS.
    return "do local S = RIME_SPRINGS or APEX_SPRINGS; local s = S and S[\"" + w.bezier + "\"]; "  // rime-rename: keep (the table an APEX appearance.lua declares)
        + 'local ok = type(s) == "table" and type(s.stiffness) == "number" and type(s.dampening) == "number"; '
        + 'if ok then hl.curve("' + w.scaled + '", { type = "spring", mass = type(s.mass) == "number" and s.mass or 1, '
        + "stiffness = s.stiffness / " + Math.round(f * f * 1e6) / 1e6 + ", dampening = s.dampening / " + f + " }) end; "
        + head + 'ok and "' + w.scaled + '" or "' + w.bezier + '"' + tail + " end";
}

/// The Lua a push evaluates: one string, one hyprctl call.
function plan(base, scale, reduced) {
    if (!(scale > 0)) return "hl.config({ animations = { enabled = false } })";
    var lines = ["hl.config({ animations = { enabled = true } })"];
    var want = expected(base, scale, reduced);
    for (var i = 0; i < want.length; i++) {
        var w = want[i];
        if (!w.enabled) { lines.push('hl.animation({ leaf = "' + w.name + '", enabled = false })'); continue; }
        if (w.spring) { lines.push(_springLine(w, scale)); continue; }
        lines.push('hl.animation({ leaf = "' + w.name + '", enabled = true, speed = ' + w.speed
                   + ', bezier = "' + w.bezier + '"' + (w.style ? ', style = "' + w.style + '"' : "") + " })");
    }
    return lines.join("\n");
}

/// The same leaves as `table` in a live read? A disabled leaf compares on its
/// flag alone: Hyprland resets the rest when it is switched off. A spring leaf
/// may be on its scaled copy or, with no RIME_SPRINGS entry, on its base; the
/// speed still tells a push from a reload, since the push scales it too (at
/// 100 % the two are the same values, and re-pushing them changes nothing).
function matches(json, table) {
    var data;
    try { data = typeof json === "string" ? JSON.parse(json) : json; } catch (e) { return false; }
    if (!Array.isArray(data) || !Array.isArray(table)) return false;
    var list = (data.length && Array.isArray(data[0])) ? data[0] : data;
    var live = {};
    for (var i = 0; i < list.length; i++) if (list[i] && list[i].name) live[list[i].name] = list[i];
    for (var j = 0; j < table.length; j++) {
        var t = table[j], l = live[t.name];
        if (!l) return false;
        if (!t.enabled) { if (l.enabled) return false; continue; }
        var curveOk = t.spring
            ? (String(l.bezier) === SPRING_PREFIX + t.scaled || String(l.bezier) === SPRING_PREFIX + t.bezier)
            : String(l.bezier) === t.bezier;
        if (!l.enabled || Math.abs(Number(l.speed) - t.speed) > 0.005
            || !curveOk || String(l.style || "") !== t.style) return false;
    }
    return true;
}

/// Which base to scale from, given a live read and the state this shell last
/// wrote for this Hyprland instance: the recorded base while the live table is
/// still exactly what was pushed (a shell restart must not scale its own push
/// again), otherwise the live table (the config was reloaded or edited).
function chooseBase(json, state, signature) {
    if (state && state.signature === signature && Array.isArray(state.base)
        && Array.isArray(state.pushed) && matches(json, state.pushed))
        return state.base;
    return baseFrom(json);
}

if (typeof module !== "undefined" && module.exports)
    module.exports = { SPATIAL: SPATIAL, REDUCED_CAP_DS: REDUCED_CAP_DS, baseFrom: baseFrom,
                       scaledSpring: scaledSpring,
                       expected: expected, plan: plan, matches: matches, chooseBase: chooseBase };
