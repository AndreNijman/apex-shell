pragma Singleton
import QtQuick
import "../services"
import "motion.js" as M

// ─────────────────────────────────────────────────────────────────────────────
// Motion — the shell's one motion system.
//
// Every animation in APEX takes its duration and its curve from here, by what it
// MEANS rather than by a number: a hover tint is `Motion.hover`, a tab's moving
// selection is `Motion.selection`, the Dashboard growing out of the notch is
// `Motion.morphEnter`. The numbers live in motion.js, where node can read them
// (tests/motion-test.js) as well as the shell; this singleton is the policy that
// applies the user's settings to them.
//
// ── Why not one global duration ─────────────────────────────────────────────
// The shell used to run on a single `animDuration` (320 ms) for every large
// surface and on 403 private literals for everything else. That made the two
// opposite mistakes at once: a press, a hover and a Dashboard all weighed the
// same 320 ms where they shared it, and where they did not, every file had its
// own idea of how long a hover lasts (80, 90, 100, 110, 120, 130, 150, 200 ms).
// A duration here is a role, and the roles have different weights on purpose.
//
// ── Spatial and effect tokens ───────────────────────────────────────────────
// SPATIAL tokens move or reshape something: travel, size, scale, a morph. EFFECT
// tokens change how something looks where it already is: opacity, colour.
// Reduce Motion is the difference between them — it removes spatial motion
// entirely (0 ms, so the thing is simply in its new place) and keeps effects,
// shortened, because a selection that changes colour instantly is fine but one
// that also teleports its highlight across the bar with no fade at all is harder
// to follow than the animation was. See `reduced` below.
//
// ── Speed ───────────────────────────────────────────────────────────────────
// `SettingsService.motionSpeed` picks a preset (snappy 0.8x, balanced 1x,
// relaxed 1.25x) and `SettingsService.motionScale` is the advanced multiplier on
// top of it. 0 is legal and means "no motion at all", which is what the old
// slider at 0 ms meant; Reduce Motion is the accessibility mode and is not that.
//
// ── Curves ──────────────────────────────────────────────────────────────────
// Bind a curve as
//     easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.standardDecel
// None of them overshoot. APEX's springs are continuity, not bounce.
// ─────────────────────────────────────────────────────────────────────────────
QtObject {
    id: motion

    // ── Policy ───────────────────────────────────────────────────────────────
    /// Reduce Motion, the accessibility mode. Spatial tokens are 0 while it is on.
    readonly property bool reduced: SettingsService.reduceMotion

    /// The combined speed multiplier every token is scaled by.
    readonly property real scale: M.speedScale(SettingsService.motionSpeed,
                                               SettingsService.motionScale)

    /// A spatial duration: scaled, and 0 under Reduce Motion.
    function spatial(ms) { return M.spatial(ms, motion.scale, motion.reduced) }
    /// An effect duration: scaled, and shortened (not removed) under Reduce Motion.
    function effect(ms)  { return M.effect(ms, motion.scale, motion.reduced) }
    /// A travel distance in px for content that moves while it fades. 0 under
    /// Reduce Motion, so the fade is all that is left.
    function travel(px)  { return motion.reduced ? 0 : px }

    // ── Effect tokens (colour, opacity) ─────────────────────────────────────
    readonly property int micro:  effect(M.BASE.micro)   // icon swap, tiny feedback
    readonly property int hover:  effect(M.BASE.hover)   // hover tint in / out
    readonly property int state:  effect(M.BASE.state)   // on/off, enabled, focus, status colour
    readonly property int fadeIn:  effect(M.BASE.fadeIn)  // content arriving inside a surface
    readonly property int fadeOut: effect(M.BASE.fadeOut) // content leaving ahead of its surface
    readonly property int settle:  effect(M.BASE.settle)  // a feedback highlight returning to rest
    /// How long after a surface's body starts moving its content begins to
    /// arrive. Choreography, so 0 under Reduce Motion — there is no body motion
    /// to wait for.
    readonly property int contentDelay: spatial(M.BASE.contentDelay)

    // ── Spatial tokens (travel, size, scale, morph) ─────────────────────────
    readonly property int pressIn:  spatial(M.BASE.pressIn)   // pointer-down compression
    readonly property int pressOut: spatial(M.BASE.pressOut)  // release back to rest
    readonly property int selection: spatial(M.BASE.selection) // a selection pill travelling
    readonly property int page:     spatial(M.BASE.page)      // directional page change
    readonly property int surfaceEnterSmall: spatial(M.BASE.surfaceEnterSmall)
    readonly property int surfaceExitSmall:  spatial(M.BASE.surfaceExitSmall)
    readonly property int morphEnter: spatial(M.BASE.morphEnter)  // connected surface growing out of the bar
    readonly property int morphExit:  spatial(M.BASE.morphExit)
    readonly property int notificationShift: spatial(M.BASE.notificationShift)
    readonly property int hero:     spatial(M.BASE.hero)      // the one signature transition; also the ceiling
    readonly property int valueFollow: spatial(M.BASE.valueFollow) // an indicator catching up with its value
    readonly property int errorShake:  spatial(M.BASE.errorShake)  // one swing of a rejected-input shake

    // ── Loops ───────────────────────────────────────────────────────────────
    // A looping animation is gated, never zeroed: an infinite animation with a
    // 0 ms body runs every frame.
    //
    // `loops` — any looping animation may run at all. False only when the
    //   user turned motion off entirely (scale 0).
    // `ambient` — a DECORATIVE loop may run: a breathing badge, a scan ring, a
    //   title marquee. Off under Reduce Motion as well; the state it decorates
    //   must be readable without it (a static colour, an icon, a label).
    // A busy spinner is not ambient: it is the only sign work is happening, so
    //   it gates on `loops` and keeps turning under Reduce Motion.
    readonly property bool loops:   motion.scale > 0
    readonly property bool ambient: motion.loops && !motion.reduced
    readonly property int spinPeriod: M.LOOPS.spinPeriod
    readonly property int pulseHalf:  M.LOOPS.pulseHalf
    readonly property int scanPeriod: M.LOOPS.scanPeriod
    readonly property int scanStagger: M.LOOPS.scanStagger

    /// Pointer-down scale for a pressable surface. 1 under Reduce Motion: the
    /// press still reads, through the fill.
    readonly property real pressScale: motion.reduced ? 1.0 : M.PRESS_SCALE

    /// How far page content travels on a directional page change, before
    /// scaling for the output (callers multiply by their theme's px()).
    readonly property int pageTravel: motion.reduced ? 0 : M.PAGE_TRAVEL

    // ── Curves ──────────────────────────────────────────────────────────────
    readonly property var standard:        M.CURVES.standard
    readonly property var standardDecel:   M.CURVES.standardDecel
    readonly property var standardAccel:   M.CURVES.standardAccel
    readonly property var emphasized:      M.CURVES.emphasized
    readonly property var emphasizedDecel: M.CURVES.emphasizedDecel
    readonly property var emphasizedAccel: M.CURVES.emphasizedAccel
    readonly property var fastDecel:       M.CURVES.fastDecel
    readonly property var fastSpatial:     M.CURVES.fastSpatial
    readonly property var linear:          M.CURVES.linear
    readonly property var defaultSpatial:  M.CURVES.defaultSpatial
    readonly property var slowSpatial:     M.CURVES.slowSpatial
    readonly property var effects:         M.CURVES.effects

    /// A curve evaluated at t (0..1) — for geometry that derives several
    /// parameters from one progress value and wants each on its own curve.
    function ease(curve, t) { return M.ease(curve, t) }
}
