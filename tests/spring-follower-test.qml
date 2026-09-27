import QtQuick
import QtTest

// ─────────────────────────────────────────────────────────────────────────────
// SpringFollower — a value that follows its target on the closed-form spring,
// stepped per frame on the wall clock (the replacement for Behavior +
// SpringAnimation, which Qt steps at a fixed 16 ms: ~62 Hz on a 144 Hz panel).
//
// Driven by tests/run-spring-follower-test.sh under qmltestrunner on the
// offscreen platform, against the REAL src/theme/anim/SpringFollower.qml and
// the real motion table (tests/lib/theme-stub.sh's stage_motion).
// ─────────────────────────────────────────────────────────────────────────────
TestCase {
    id: tc
    name: "SpringFollower"
    when: windowShown
    width: 100; height: 100

    Component { id: fc; SpringFollower {} }
    function make(props) {
        var o = createTemporaryObject(fc, tc, props || {})
        verify(o !== null, "created")
        return o
    }

    function test_born_at_its_target() {
        // Nothing slides in from 0 when it is created.
        var f = make({ target: 240 })
        compare(f.value, 240)
        compare(f.running, false)
    }

    function test_follows_and_lands_exactly() {
        var f = make({ target: 0 })
        f.target = 300
        compare(f.value, 0, "it does not jump")
        verify(f.running, "it moves")
        tryVerify(function () { return f.value > 150 }, 1000, "half-way")
        tryVerify(function () { return !f.running }, 3000, "comes to rest")
        compare(f.value, 300, "exactly on the target")
        compare(f.velocity, 0)
    }

    function test_selection_spring_overshoots_by_a_hair() {
        // The selection role is damped 0.86: past the mark by ~0.5 %, then back.
        var f = make({ target: 0, role: "selection" })
        var peak = 0
        f.valueChanged.connect(function () { peak = Math.max(peak, f.value) })
        f.target = 1000
        tryVerify(function () { return !f.running }, 3000)
        verify(peak > 1000 && peak < 1015, "peak " + peak)
    }

    function test_a_retarget_keeps_its_velocity() {
        // Chased back mid-travel, it keeps moving the way it was going for a
        // moment and bends back — it does not stop dead the way a restarted
        // animation does.
        var f = make({ target: 0 })
        f.target = 400
        tryVerify(function () { return f.value > 120 }, 1000)
        var at = f.value
        verify(f.velocity > 0, "moving forward: " + f.velocity)
        f.target = 0
        wait(20)
        verify(f.value >= at - 1, "still carried forward at first: " + at + " → " + f.value)
        tryVerify(function () { return !f.running }, 3000)
        compare(f.value, 0)
    }

    function test_not_live_jumps() {
        // `live: false` is a Behavior's `enabled: false`: straight to the target.
        var f = make({ target: 10, live: false })
        f.target = 200
        compare(f.value, 200)
        compare(f.running, false)
        f.live = true
        f.target = 0
        verify(f.running, "and once live it moves again")
        tryVerify(function () { return !f.running }, 3000)
    }

    function test_going_not_live_mid_travel_snaps() {
        var f = make({ target: 0 })
        f.target = 500
        wait(40)
        f.live = false
        compare(f.value, 500)
        compare(f.running, false)
    }

    // Frame-rate independence is the closed form's, and is proven where the
    // closed form lives (tests/spring-test.js: sixty 1/60 s steps land where
    // one 1 s step does); qmltestrunner cannot vary the frame rate.
}
