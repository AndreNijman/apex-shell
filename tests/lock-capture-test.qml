import QtQuick
import QtTest

// ─────────────────────────────────────────────────────────────────────────────
// LockState.lock() with the arrival's picture (windows/LockCapture.qml),
// behaviourally. Driven by tests/run-lock-capture-test.sh against the REAL
// src/state/LockState.qml, staged as a plain component (its singleton pragma
// stripped) so every case gets a fresh one.
//
// A lock that waits is a lock that can be lost, so what is pinned here is
// the waiting: it is short, it always ends in a lock, it ends at once for a
// repeated request, and nothing that arrives late can change the lock.
// ─────────────────────────────────────────────────────────────────────────────
TestCase {
    id: tc
    name: "LockCapture"
    when: windowShown

    Component { id: stateC; LockStateUnderTest {} }
    function make(props) {
        var o = createTemporaryObject(stateC, tc, props || {})
        verify(o !== null)
        return o
    }
    // Records the capture requests a state emits.
    function requests(s) {
        var got = []
        s.captureRequested.connect(function (seq) { got.push(seq) })
        return got
    }

    function test_without_a_capture_a_lock_is_immediate() {
        var s = make()
        var got = requests(s)
        s.lock()
        compare(s.locked, true, "engaged in the same call")
        compare(got.length, 0, "and nobody was asked for a picture")
    }

    function test_a_fresh_lock_waits_for_its_picture_then_engages() {
        var s = make({ captureEnabled: true })
        var got = requests(s)
        s.lock()
        compare(s.locked, false, "not yet: the picture has to be taken before the lock engages")
        compare(s.capturing, true)
        compare(got.length, 1)
        s.captured(got[0], { "eDP-1": "file:///run/x.ppm" })
        compare(s.locked, true, "engaged the moment the picture is ready")
        compare(s.capturing, false)
        compare(s.captures["eDP-1"], "file:///run/x.ppm", "and the surfaces can find it")
    }

    function test_no_picture_in_time_locks_anyway() {
        var s = make({ captureEnabled: true })
        var got = requests(s)
        var t0 = Date.now()
        s.lock()
        tryCompare(s, "locked", true, 1000)
        var took = Date.now() - t0
        verify(took >= 100 && took <= 250, "the cap engaged it on its own, ~120 ms (" + took + " ms)")
        compare(Object.keys(s.captures).length, 0, "with no picture: the old arrival")
    }

    function test_a_late_picture_is_thrown_away() {
        var s = make({ captureEnabled: true })
        var got = requests(s)
        s.lock()
        tryCompare(s, "locked", true, 1000)
        s.captured(got[0], { "eDP-1": "file:///run/late.ppm" })
        compare(Object.keys(s.captures).length, 0, "a picture that missed the lock never appears on it")
        compare(s.locked, true)
    }

    function test_a_picture_for_an_older_request_is_ignored() {
        var s = make({ captureEnabled: true })
        var got = requests(s)
        s.lock()
        s.captured(got[0] - 1, { "eDP-1": "file:///run/old.ppm" })
        compare(s.locked, false, "still waiting for its own")
        compare(Object.keys(s.captures).length, 0)
        s.captured(got[0], {})
        compare(s.locked, true)
    }

    function test_a_second_request_is_never_made_to_wait() {
        // Idle locks, and a lid closes a moment later: before_sleep's lock
        // must not queue behind the first one's picture.
        var s = make({ captureEnabled: true })
        s.lock()
        compare(s.locked, false)
        s.lock()
        compare(s.locked, true, "the second request engaged at once")
        compare(s.capturing, false)
    }

    function test_a_lock_during_the_unlock_release_holds_at_once() {
        // The 2026-09-26 fix: a correct password releases the lock a beat
        // later; a lock asked for in that beat must cancel the release, not
        // wait for a picture (the screen is the lock, there is nothing to take).
        var s = make()
        s.lock()
        s.captureEnabled = true
        s.unlocking = true
        var got = requests(s)
        s.lock()
        compare(s.unlocking, false, "the release is cancelled")
        compare(s.locked, true)
        compare(s.capturing, false, "no picture taken of a locked screen")
        compare(got.length, 0)
    }

    function test_every_lock_asks_afresh() {
        var s = make({ captureEnabled: true })
        var got = requests(s)
        s.lock()
        s.captured(got[0], { "eDP-1": "file:///run/a.ppm" })
        s.locked = false            // (the release, as Lockscreen does it)
        s.lock()
        compare(got.length, 2)
        verify(got[1] > got[0], "a new request number")
        compare(Object.keys(s.captures).length, 0, "the last lock's picture is gone")
    }
}
