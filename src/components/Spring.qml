import QtQuick
import "../theme/spring.js" as S

// ─────────────────────────────────────────────────────────────────────────────
// Spring — a damped harmonic oscillator, the physics behind fluid motion.
//
// Andre, 2026-09-26: "everything goes way too quick and doesn't feel like liquid
// and fluid, i want real apple level animation." A fixed-length bezier cannot
// give that: it has one shape whatever happened before it, and reversing it
// half-way starts a new curve from rest — the motion snaps. A spring keeps its
// velocity. Retarget it mid-flight and it bends toward the new target from
// where and how fast it already was, so an open caught by a close flows back
// instead of stopping dead; and it lands on a long, soft tail rather than a
// hard stop.
//
// Parameterised like SwiftUI: `response` is the period of the undamped
// oscillation in seconds (how quick), `dampingFraction` 1 is critical (no
// overshoot), below 1 settles with a whisper of overshoot (0.85 → ~0.6 %).
// The maths is theme/spring.js — closed form, so the motion is independent of
// the frame rate — and tests/spring-test.js holds it to the physics.
//
// Time is the wall clock, clamped to 50 ms a step: a stalled frame costs one
// slower step, not a teleport.
//
//     Spring { id: s; target: open ? 1 : 0; response: 0.5; dampingFraction: 0.86 }
//     … s.value, s.velocity, s.running; settled() fires on arrival
//
// `snap()` puts it on its target at rest (Reduce Motion, or a surface built
// already open).
// ─────────────────────────────────────────────────────────────────────────────
QtObject {
    id: spring

    property real target: 0
    property real value: 0
    property real velocity: 0
    property real response: 0.5
    property real dampingFraction: 0.86
    property real epsilon: 0.0005
    readonly property bool running: _frames.running

    signal settled()

    function snap() {
        _frames.running = false
        velocity = 0
        value = target
    }

    // Retargeting keeps the velocity: a spring already moving just bends
    // toward the new target. One that is already at rest on it stays put — a
    // target changed and changed back in the same tick moves nothing.
    onTargetChanged: {
        if (S.atRest(value, velocity, target, epsilon)) {
            _frames.running = false
        } else if (!_frames.running) {
            _last = Date.now()
            _frames.running = true
        }
    }

    property real _last: 0

    property FrameAnimation _frames: FrameAnimation {
        running: false
        onTriggered: {
            const now = Date.now()
            const dt = Math.min(0.05, Math.max(0, (now - spring._last) / 1000))
            spring._last = now
            if (dt > 0) {
                const r = S.step(spring.value, spring.velocity, spring.target,
                                 spring.response, spring.dampingFraction, dt)
                // Velocity first: writing the value runs its listeners, and one
                // of them may snap this spring to rest (a lifecycle reaching a
                // visual zero) — a velocity written after that would leave it
                // "at rest" and still moving.
                spring.velocity = r[1]
                spring.value = r[0]
                if (!running) return
            }
            if (S.atRest(spring.value, spring.velocity, spring.target, spring.epsilon)) {
                running = false
                spring.velocity = 0
                spring.value = spring.target
                spring.settled()
            }
        }
    }
}
