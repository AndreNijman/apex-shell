import QtQuick
import "../.."
import "../spring.js" as S

// A value that follows `target` on a spring — for anything retargeted while it
// moves: a tab pill chased across the bar, a nav highlight, a switch knob
// flipped twice, a surface's width changing page mid-open, a notch following
// its title.
//
//     SpringFollower { id: pillX; target: <where the pill should be>; live: placed }
//     x: pillX.value
//
// It replaced `Behavior { MotionSpring {} }` (Qt's SpringAnimation). That one
// kept velocity through a retarget, but Qt steps it at a fixed 16 ms, so its
// values moved at ~62 Hz whatever the display did: invisible on a 60 Hz panel,
// a judder on katana's 144 Hz one (review, 2026-09-26). This steps the same
// closed-form spring the surfaces run on (theme/spring.js) once per frame on
// the wall clock, so it is exact at any refresh rate — and a pill and the bloom
// it sits in move on literally the same physics.
//
//   role     a Motion spring role (motion.js SPRINGS): the response and damping
//   live     false: jump straight to the target (a Behavior's `enabled: false`
//            — before a pill has been placed, say). Reduce Motion or motion off
//            (response 0) jump too.
//   epsilon  at rest within this of the target, in the value's own units: the
//            default suits pixels; a scale wants far less.
//
// It is born AT its target: the first value is the target, not 0, so nothing
// slides in from the origin when it is created.
QtObject {
    id: f

    property real target: 0
    property string role: "selection"
    property bool live: true
    property real epsilon: 0.25

    property real value: 0
    property real velocity: 0
    readonly property bool running: f._frames.running

    readonly property var _p: Motion.spring(f.role)
    property bool _born: false

    function snap() {
        f._frames.running = false
        f.velocity = 0
        f.value = f.target
    }

    function _go() {
        if (!f._born || !f.live || !(f._p.response > 0)) { f.snap(); return }
        if (S.atRest(f.value, f.velocity, f.target, f.epsilon)) {
            f._frames.running = false
            f.value = f.target
            f.velocity = 0
            return
        }
        if (!f._frames.running) {
            f._last = Date.now()
            f._frames.running = true
        }
    }
    onTargetChanged: f._go()
    onLiveChanged: if (!f.live) f.snap()
    Component.onCompleted: { f.snap(); f._born = true }

    property real _last: 0
    property FrameAnimation _frames: FrameAnimation {
        running: false
        onTriggered: {
            const now = Date.now()
            // Wall clock, clamped: a stalled frame costs one slower step, not a
            // teleport.
            const dt = Math.min(0.05, Math.max(0, (now - f._last) / 1000))
            f._last = now
            if (dt > 0) {
                const r = S.step(f.value, f.velocity, f.target, f._p.response, f._p.damping, dt)
                f.velocity = r[1]
                f.value = r[0]
                if (!running) return
            }
            if (S.atRest(f.value, f.velocity, f.target, f.epsilon)) {
                running = false
                f.velocity = 0
                f.value = f.target
            }
        }
    }
}
