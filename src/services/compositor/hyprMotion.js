// ─── hyprMotion.js ───────────────────────────────────────────────────────────
// The compositor on the shell's motion settings (UI/UX roadmap v3 Phase 21).
//
// APEX Shell's Motion has a speed (Snappy / Balanced / Relaxed × a duration
// scale) and Reduce Motion. Hyprland's motion lives in its own config
// (apex-os appearance.lua), so without this a user who asked for slower or
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

/// The leaves worth re-declaring, from `hyprctl -j animations` output.
/// [{ name, speed, bezier, style }], sorted by name.
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
        if (!NAME_RE.test(String(a.name)) || !NAME_RE.test(String(a.bezier || ""))) continue;
        var style = String(a.style || "");
        if (style !== "" && !STYLE_RE.test(style)) continue;
        out.push({ name: String(a.name), speed: speed, bezier: String(a.bezier), style: style });
    }
    out.sort(function (x, y) { return x.name < y.name ? -1 : x.name > y.name ? 1 : 0; });
    return out;
}

function _round(v) { return Math.round(v * 100) / 100; }

/// The table Hyprland should report after a push: [{ name, enabled, speed?,
/// bezier?, style? }]. Also what a later read is compared against, to tell
/// "this is our own push" from "the config was reloaded".
function expected(base, scale, reduced) {
    // Scale 0 switches animations off globally and leaves every leaf as it is.
    if (!(scale > 0)) return expected(base, 1, false);
    var out = [];
    for (var i = 0; i < base.length; i++) {
        var b = base[i];
        if (reduced && SPATIAL.test(b.name)) { out.push({ name: b.name, enabled: false }); continue; }
        var s = _round(b.speed * scale);
        if (reduced) s = Math.min(s, REDUCED_CAP_DS);
        out.push({ name: b.name, enabled: true, speed: s, bezier: b.bezier, style: b.style });
    }
    return out;
}

/// The Lua a push evaluates: one string, one hyprctl call.
function plan(base, scale, reduced) {
    if (!(scale > 0)) return "hl.config({ animations = { enabled = false } })";
    var lines = ["hl.config({ animations = { enabled = true } })"];
    var want = expected(base, scale, reduced);
    for (var i = 0; i < want.length; i++) {
        var w = want[i];
        if (!w.enabled) { lines.push('hl.animation({ leaf = "' + w.name + '", enabled = false })'); continue; }
        lines.push('hl.animation({ leaf = "' + w.name + '", enabled = true, speed = ' + w.speed
                   + ', bezier = "' + w.bezier + '"' + (w.style ? ', style = "' + w.style + '"' : "") + " })");
    }
    return lines.join("\n");
}

/// The same leaves as `table` in a live read? A disabled leaf compares on its
/// flag alone: Hyprland resets the rest when it is switched off.
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
        if (!l.enabled || Math.abs(Number(l.speed) - t.speed) > 0.005
            || String(l.bezier) !== t.bezier || String(l.style || "") !== t.style) return false;
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
                       expected: expected, plan: plan, matches: matches, chooseBase: chooseBase };
