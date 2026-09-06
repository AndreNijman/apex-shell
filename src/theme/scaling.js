// ─── scaling.js ──────────────────────────────────────────────────────────────
// The shell's size arithmetic, in one place, testable from node.
//
// It lived in theme/Metrics.qml, where nothing could reach it except a running
// quickshell — and tests/scaling-test.qml therefore RE-IMPLEMENTED the
// breakpoint table as its own `bucket()` function and asserted the copy against
// itself. Every breakpoint assertion passed no matter what Metrics said. This
// module exists so that the shell and the test read the same function.
//
// Two questions live here and they are not the same question:
//
//   scaleForHeight(h)     given a LOGICAL height, how much does the shell
//                         magnify its own tokens
//   recommendedScale(w,h) given a PHYSICAL mode, what compositor scale puts
//                         that output into the band the shell was calibrated
//                         for in the first place
// ─────────────────────────────────────────────────────────────────────────────

// ── The shell's own factor ──────────────────────────────────────────────────
//
// Sublinear in resolution: a 4K panel is usually also physically larger, so a
// literal 2x would be enormous. Fixed breakpoints rather than a continuous
// height/1080 ratio, because a continuous factor produces awkward fractional
// pixel values and shifts the whole UI on any mode change.
//
// The input is the LOGICAL height — what Wayland hands the client after the
// compositor's own output scale. That is deliberate: an output at compositor
// scale 2 reports half its pixels, lands in a lower bucket, and the two
// magnifications multiply out to the right physical size. Measured on
// quickshell 0.3.1 / Qt 6.10: a 3840x2160 output at compositor scale 2 arrives
// as 1920x1080 with devicePixelRatio 2.
//
// [maximum logical height (exclusive), factor]
var BREAKPOINTS = [
    [900,  0.85],   // 1366x768 and friends
    [1250, 1.00],   // 1080p and 1200p — the calibrated baseline
    [1600, 1.20],   // 1440p
    [2000, 1.35]    // 1600p / 1800p
]
var TOP_SCALE = 1.50   // 2160p and up

// The band the token set was calibrated against. An output whose logical height
// lands in here needs no shell magnification at all, which is why it is also
// the target recommendedScale() aims for.
var BASELINE_MIN = 1000
var BASELINE_MAX = 1250

function scaleForHeight(h) {
    for (var i = 0; i < BREAKPOINTS.length; i++)
        if (h < BREAKPOINTS[i][0]) return BREAKPOINTS[i][1]
    return TOP_SCALE
}

// ── The compositor's factor ─────────────────────────────────────────────────
//
// INTEGERS ONLY, and that is a measurement rather than a preference.
//
// Qt does not render at a fractional device pixel ratio here. Asked for output
// scale 1.5 on a 3840x2160 panel, the compositor reported a 2560x1440 logical
// size and Qt took devicePixelRatio 2 — so the shell drew a 2x buffer and the
// compositor downsampled it to 1.5x. Text goes through a resample. Measured at
// 1.25, 1.5 and 1.6; all three came back with devicePixelRatio 2. At scale 2
// the logical size was 1920x1080 and devicePixelRatio was 2, which is the same
// number the client drew at: no resample.
//
// A non-integer scale is also the one thing Hyprland refuses outright when it
// cannot resolve to a whole buffer size, and it errors the whole monitor rule
// rather than falling back.
var CANDIDATES = [1, 2, 3]

/// The compositor scale that brings a mode into the calibrated band.
///
/// The largest candidate that divides the mode evenly and still leaves at least
/// BASELINE_MIN logical rows — largest, because that is the one that puts the
/// most physical pixels behind each logical one, and "at least", because an
/// output that lands under the band gets a UI that is too small to read rather
/// than merely too large.
function recommendedScale(w, h) {
    var best = 1
    for (var i = 0; i < CANDIDATES.length; i++) {
        var s = CANDIDATES[i]
        if (w % s !== 0 || h % s !== 0) continue
        if (h / s < BASELINE_MIN) continue
        if (s > best) best = s
    }
    return best
}

/// What `scaleForHeight` would answer for a mode at a given compositor scale.
/// Both halves of the magnification in one call, so a caller does not have to
/// remember which of them takes physical pixels.
function shellScaleFor(w, h, compositorScale) {
    var s = compositorScale > 0 ? compositorScale : 1
    return scaleForHeight(Math.round(h / s))
}

/// True when a set of outputs cannot share one shell factor.
///
/// The shell has ONE process-wide scale — Theme and Metrics are QML singletons
/// read directly by 82 files at 831 call sites — so a desk whose outputs land in
/// different buckets is a desk where the factor is wrong for at least one of
/// them. This is what lets the Display page say so instead of leaving the user
/// to notice that the bar is half the height of the other monitor's.
///
/// `outputs` is [{ width, height, scale }] — physical mode plus compositor scale.
function bucketsDisagree(outputs) {
    var seen = null
    for (var i = 0; i < outputs.length; i++) {
        var o = outputs[i]
        if (!o || o.enabled === false || !o.height) continue
        var f = shellScaleFor(o.width || 0, o.height, o.scale || 1)
        if (seen === null) seen = f
        else if (seen !== f) return true
    }
    return false
}

if (typeof module !== "undefined" && module.exports)
    module.exports = {
        BREAKPOINTS: BREAKPOINTS,
        TOP_SCALE: TOP_SCALE,
        BASELINE_MIN: BASELINE_MIN,
        BASELINE_MAX: BASELINE_MAX,
        CANDIDATES: CANDIDATES,
        scaleForHeight: scaleForHeight,
        recommendedScale: recommendedScale,
        shellScaleFor: shellScaleFor,
        bucketsDisagree: bucketsDisagree
    }
