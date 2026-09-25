// ─── motion.js ───────────────────────────────────────────────────────────────
// The numbers behind theme/Motion.qml, where node can reach them.
//
// Motion.qml is policy (which setting scales what, what Reduce Motion removes);
// this file is the table and the arithmetic. It is split out for the same reason
// theme/scaling.js was: a value only a running quickshell can compute can only be
// tested by re-implementing it, and a re-implementation asserts against itself.
// tests/motion-test.js reads THIS file.
//
// No `.pragma library` line: node cannot parse it, and nothing here keeps state.
// ─────────────────────────────────────────────────────────────────────────────

// ── Durations, Balanced speed, in ms ─────────────────────────────────────────
// Roadmap v3 Phase 1's starting table. The shape is the point, not any one
// number: exits are shorter than entrances, a press is shorter than a hover
// release, and nothing but the one signature transition reaches `hero`.
var BASE = {
    micro:             100,
    hover:              80,
    pressIn:            65,
    pressOut:          115,
    state:             130,
    selection:         160,
    page:              200,
    surfaceEnterSmall: 190,
    surfaceExitSmall:  135,
    morphEnter:        240,
    morphExit:         175,
    notificationShift: 200,
    hero:              320,
    // Content inside a surface: it arrives after its container has begun to
    // move, and leaves before it, so its fades are short and asymmetric.
    // `contentDelay` is an offset, not a length: how long after a body starts
    // moving its content begins to arrive.
    fadeIn:            130,
    fadeOut:            70,
    contentDelay:       40,
    // A feedback highlight fading back to rest (a card that flashed "connected").
    // An EFFECT, so under Reduce Motion it is short rather than gone.
    settle:            320,
    // An indicator catching up with a value that changed under it (a volume
    // bar after a key press, a slider fill after a click, a meter). Short,
    // because the value is already true and the bar is merely late.
    valueFollow:        90,
    // Several items leaving or arriving together (a cleared field, a paste, a
    // cleared notification stack) stagger by one step each, never more than
    // the cap in total, so the group reads as one gesture rather than a queue.
    staggerStep:        20,
    staggerCap:        100,
    // One swing of the "wrong password" shake. Spatial, so under Reduce Motion
    // the field does not move and its danger outline carries the message alone.
    errorShake:         45
};

// ── Loops ───────────────────────────────────────────────────────────────────
// Not transitions, so not scaled by speed: a spinner that turns faster because
// the user asked for snappier menus would be a bug. They are GATED instead —
// see Motion.qml's `loops` and `ambient`. A loop whose duration fell to 0 would
// spin every frame, which is why these never pass through spatial().
var LOOPS = {
    spinPeriod:  900,   // one turn of a busy spinner
    pulseHalf:   600,   // one half (in or out) of a breathing indicator
    scanPeriod: 2200,   // one ring of a radar-style "scanning" indicator
    scanStagger: 650    // the offset between successive rings
};

// ── Speed presets ───────────────────────────────────────────────────────────
var SPEEDS = { snappy: 0.8, balanced: 1.0, relaxed: 1.25 };
var SCALE_MIN = 0;      // "no motion at all" — what the old 0 ms slider meant
var SCALE_MAX = 2.5;

// Under Reduce Motion an effect keeps happening, but never takes longer than
// this: long enough for the eye to register a change, short enough that nothing
// on screen is still moving when the user looks at it.
var REDUCED_EFFECT_CAP = 150;

// Pointer-down compression, and how far page content travels as it fades.
var PRESS_SCALE = 0.975;
var PAGE_TRAVEL = 12;

// ── Curves ──────────────────────────────────────────────────────────────────
// In Qt's Easing.BezierSpline form: control1, control2, end, repeated per
// segment, starting from (0,0) and ending at (1,1). Every y stays inside 0..1,
// so no curve overshoots — tests/motion-test.js asserts that for all of them.
//
// standard* and emphasized* are Material 3's. The three spatial curves are
// APEX's own: M3's expressive spatial springs overshoot, and APEX does not.
// fast/default/slow differ in how hard they start — a selection pill should
// leave at once, a hero surface can take a beat to gather — not in their end.
var CURVES = {
    standard:        [0.2, 0, 0, 1, 1, 1],
    standardDecel:   [0, 0, 0, 1, 1, 1],
    standardAccel:   [0.3, 0, 1, 1, 1, 1],
    emphasized:      [0.05, 0, 0.133333, 0.06, 0.166666, 0.4,
                      0.208333, 0.82, 0.25, 1, 1, 1],
    emphasizedDecel: [0.05, 0.7, 0.1, 1, 1, 1],
    emphasizedAccel: [0.3, 0, 0.8, 0.15, 1, 1],
    // fastDecel: leaves at full speed and lands softly. The width of a bloom
    // or a pour, the collapse of every connected surface's progress on close.
    fastDecel:       [0, 0, 0.2, 1, 1, 1],
    fastSpatial:     [0, 0, 0.2, 1, 1, 1],
    defaultSpatial:  [0.25, 0.8, 0.2, 1, 1, 1],
    slowSpatial:     [0.3, 0, 0, 1, 1, 1],
    effects:         [0.3, 0.7, 0.3, 1, 1, 1],
    // A connected surface's progress on OPEN runs linearly: the curves live in
    // the shape's own parameters (geometry.js), each on its own ramp, and an
    // eased progress under them would ease everything twice.
    linear:          [0, 0, 1, 1, 1, 1]
};

function _finite(v, fallback) {
    var n = Number(v);
    return (typeof v === "number" || typeof v === "string") && isFinite(n) ? n : fallback;
}

/// The combined multiplier for a speed preset and the advanced scale.
function speedScale(speed, scale) {
    var preset = SPEEDS.hasOwnProperty(speed) ? SPEEDS[speed] : SPEEDS.balanced;
    var s = Math.max(SCALE_MIN, Math.min(SCALE_MAX, _finite(scale, 1.0)));
    return preset * s;
}

/// A spatial duration: 0 under Reduce Motion.
function spatial(ms, scale, reduced) {
    if (reduced) return 0;
    return Math.round(ms * scale);
}

/// An effect duration: kept under Reduce Motion, but capped.
function effect(ms, scale, reduced) {
    var d = Math.round(ms * scale);
    return reduced ? Math.min(d, REDUCED_EFFECT_CAP) : d;
}

/// The legacy single duration, for callers not yet migrated: what 320 ms used
/// to be, at the user's speed. 0 under Reduce Motion, as it always was.
function legacyDuration(scale, reduced) {
    return reduced ? 0 : Math.round(320 * scale);
}

// ── Curve evaluation ────────────────────────────────────────────────────────
// y at x for a BezierSpline list, the way Qt evaluates one. Geometry that
// drives several parameters from a single progress value (a shape whose width
// leads and whose depth follows) puts each on its own curve with this.
function _bez(a, b, c, d, s) {
    var u = 1 - s;
    return u * u * u * a + 3 * u * u * s * b + 3 * u * s * s * c + s * s * s * d;
}

function ease(curve, t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    var x0 = 0, y0 = 0;
    for (var i = 0; i + 5 < curve.length; i += 6) {
        var x1 = curve[i], y1 = curve[i + 1], x2 = curve[i + 2], y2 = curve[i + 3];
        var x3 = curve[i + 4], y3 = curve[i + 5];
        if (t <= x3 || i + 6 >= curve.length) {
            // Bisection on x(s) — monotone for every curve in the table, and
            // 30 halvings is below a millionth of the segment.
            var lo = 0, hi = 1, s = t;
            for (var k = 0; k < 30; k++) {
                s = (lo + hi) / 2;
                if (_bez(x0, x1, x2, x3, s) < t) lo = s; else hi = s;
            }
            return _bez(y0, y1, y2, y3, (lo + hi) / 2);
        }
        x0 = x3; y0 = y3;
    }
    return t;
}

if (typeof module !== "undefined" && module.exports)
    module.exports = {
        BASE: BASE,
        LOOPS: LOOPS,
        SPEEDS: SPEEDS,
        SCALE_MIN: SCALE_MIN,
        SCALE_MAX: SCALE_MAX,
        REDUCED_EFFECT_CAP: REDUCED_EFFECT_CAP,
        PRESS_SCALE: PRESS_SCALE,
        PAGE_TRAVEL: PAGE_TRAVEL,
        CURVES: CURVES,
        speedScale: speedScale,
        spatial: spatial,
        effect: effect,
        legacyDuration: legacyDuration,
        ease: ease
    };
