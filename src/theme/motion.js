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
// Retuned 2026-09-26 for Andre: "everything goes way too quick and doesn't feel
// liquid and fluid — real Apple-level animation." The first table (Roadmap v3
// Phase 1) was built to react hard and finish early: 65–240 ms on curves that
// leave at full speed. It read as mechanical — every surface snapped into place
// and stopped dead. These are PERCEIVED durations, the time until a change looks
// finished, and they are about 1.7x the old ones for anything that moves a
// surface, with long soft landings. What people do often (a hover, a press) stays
// brief — Apple's HIG: "aim for brevity and precision in feedback animations …
// avoid making people spend extra time on motion every time they interact."
//
// The shape is still the point: exits shorter than entrances, a press quicker
// than its release, and nothing but the signature transition reaches `hero`.
var BASE = {
    micro:             140,
    hover:             130,
    pressIn:            90,
    pressOut:          280,
    state:             220,
    selection:         400,
    page:              380,
    surfaceEnterSmall: 360,
    surfaceExitSmall:  240,
    morphEnter:        520,
    morphExit:         380,
    notificationShift: 420,
    hero:              640,
    // Content inside a surface: it arrives after its container has begun to
    // move, and leaves before it, so its fades are short and asymmetric.
    // `contentDelay` is an offset, not a length: how long after a body starts
    // moving its content begins to arrive.
    fadeIn:            280,
    fadeOut:           140,
    contentDelay:       90,
    // A feedback highlight fading back to rest (a card that flashed "connected").
    // An EFFECT, so under Reduce Motion it is short rather than gone.
    settle:            520,
    // An indicator catching up with a value that changed under it (a volume
    // bar after a key press, a slider fill after a click, a meter). Short,
    // because the value is already true and the bar is merely late.
    valueFollow:       200,
    // Several items leaving or arriving together (a cleared field, a paste, a
    // cleared notification stack) stagger by one step each, never more than
    // the cap in total, so the group reads as one gesture rather than a queue.
    staggerStep:        32,
    staggerCap:        200,
    // One swing of the "wrong password" shake. Spatial, so under Reduce Motion
    // the field does not move and its danger outline carries the message alone.
    errorShake:         62
};

// ── Springs ─────────────────────────────────────────────────────────────────
// What moves a SURFACE is a spring, not a curve (components/Spring.qml, the
// maths in spring.js). A curve has one shape whatever came before it: reversed
// half-way, it restarts from rest and the motion kinks. A spring carries its
// velocity into the new target, so an open caught by a close flows back.
//
// Parameterised like SwiftUI. `response` is the undamped period in seconds —
// with critical damping a change looks finished at about that time, so it is
// set from the matching duration above. `damping` is the damping fraction:
// 1 lands without overshoot, below 1 lands with a whisper of it (0.86 → 0.5 %).
// The speed setting scales `response`; Reduce Motion snaps (response 0).
var SPRINGS = {
    // A connected surface growing out of the bar, and folding back into it.
    surfaceOpen:  { response: BASE.morphEnter / 1000, damping: 1.0 },
    surfaceClose: { response: BASE.morphExit / 1000,  damping: 1.0 },
    // A selection travelling (a tab pill, a nav highlight), a page retarget.
    selection:    { response: BASE.selection / 1000,  damping: 0.86 },
    page:         { response: BASE.page / 1000,       damping: 1.0 },
    // An indicator catching up with its value.
    valueFollow:  { response: BASE.valueFollow / 1000, damping: 1.0 },
    // A control's knob or thumb travelling (a switch flipping): quick, with a
    // whisper of settle so it reads as a physical part.
    toggle:       { response: 0.30, damping: 0.82 }
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
var REDUCED_EFFECT_CAP = 160;

// Pointer-down compression, and how far page content travels as it fades.
var PRESS_SCALE = 0.975;
var PAGE_TRAVEL = 12;

// ── Curves ──────────────────────────────────────────────────────────────────
// In Qt's Easing.BezierSpline form: control1, control2, end, repeated per
// segment, starting from (0,0) and ending at (1,1). Every y stays inside 0..1,
// so no curve overshoots — tests/motion-test.js asserts that for all of them.
//
// Retuned with the durations (2026-09-26). The old spatial curves were
// Material 3's and APEX's "leave at full speed" family — (0, 0, 0.2, 1) and
// (0.05, 0.7, 0.1, 1) have a near-vertical first frame, which is exactly the
// snap Andre called robotic. Nothing physical starts at full speed. The new
// family eases out of rest over the first frames and lands on a long tail:
//
//   spring          a critically damped spring from rest, fitted (1.2 % max
//                   error) — for timed moves that should read like the springs
//                   that drive surfaces. The default for MotionMove.
//   standard        Core Animation's default ease (0.25, 0.1, 0.25, 1).
//   *Decel          arrivals: a softer start than before, the same long landing.
//   standardAccel   departures: eases in and, unlike the old curve, eases out
//                   too — a surface that leaves at full speed stops dead.
//   effects         fades: the same gentle ease as `standard`, so an opacity
//                   change has no hard edge at either end.
var CURVES = {
    spring:          [0.25, 0.2, 0.15, 1, 1, 1],
    standard:        [0.25, 0.1, 0.25, 1, 1, 1],
    standardDecel:   [0.15, 0.55, 0.25, 1, 1, 1],
    standardAccel:   [0.4, 0, 0.65, 1, 1, 1],
    emphasized:      [0.3, 0, 0.1, 1, 1, 1],
    emphasizedDecel: [0.2, 0.6, 0.15, 1, 1, 1],
    emphasizedAccel: [0.4, 0, 0.75, 0.9, 1, 1],
    // fastDecel: quick out of rest, a long soft landing — width of a bloom.
    fastDecel:       [0.18, 0.55, 0.2, 1, 1, 1],
    fastSpatial:     [0.18, 0.55, 0.2, 1, 1, 1],
    defaultSpatial:  [0.25, 0.2, 0.15, 1, 1, 1],
    slowSpatial:     [0.35, 0.1, 0.1, 1, 1, 1],
    effects:         [0.25, 0.1, 0.25, 1, 1, 1],
    // A progress that some other function already shapes runs linearly: an
    // eased progress under it would ease everything twice.
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

/// A spring role at the user's speed: {response (s), damping}. Response 0 —
/// snap to the target — under Reduce Motion or with motion off (scale 0).
function spring(role, scale, reduced) {
    var sp = SPRINGS.hasOwnProperty(role) ? SPRINGS[role] : SPRINGS.surfaceOpen;
    if (reduced || !(scale > 0)) return { response: 0, damping: sp.damping };
    return { response: sp.response * scale, damping: sp.damping };
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
        SPRINGS: SPRINGS,
        spring: spring,
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
