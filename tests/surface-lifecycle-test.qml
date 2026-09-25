import QtQuick
import QtTest
import "components"

// ─────────────────────────────────────────────────────────────────────────────
// SurfaceLifecycle — the one clock a transient surface runs on.
//
// Driven by tests/run-surface-lifecycle-test.sh under qmltestrunner, against the
// REAL src/components/SurfaceLifecycle.qml and the real motion table (staged by
// tests/lib/theme-stub.sh's stage_motion at the shipped defaults: Balanced, 1x).
//
// What it must prove, from the UI/UX roadmap's Phase 6:
//   * the surface stays mapped until the close has actually completed;
//   * reopening half-way through a close reverses from the current state, and
//     closing half-way through an open does the same — no jump;
//   * spam cannot leave it stuck mapped or stuck invisible;
//   * a lifecycle BORN open (a LazyPopup built by its flag) opens by itself;
//   * with spatial motion off (Reduce Motion) the same machine still runs: the
//     shape is simply there and a short fade carries the change.
// ─────────────────────────────────────────────────────────────────────────────
TestCase {
    id: tc
    name: "SurfaceLifecycle"
    when: windowShown
    width: 100; height: 100

    Component { id: lifeC; SurfaceLifecycle {} }

    function make(props) {
        var o = createTemporaryObject(lifeC, tc, props || {})
        verify(o !== null, "created")
        return o
    }

    function test_starts_closed() {
        var l = make()
        compare(l.phase, "Closed")
        compare(l.mapped, false)
        compare(l.progress, 0)
    }

    function test_open_maps_at_once_and_reaches_open() {
        var l = make()
        l.open = true
        compare(l.mapped, true, "mapped in the same tick the flag flips — input is never waiting on a frame")
        compare(l.phase, "Opening")
        tryCompare(l, "progress", 1, 2000)
        tryCompare(l, "phase", "Open", 2000)
        tryCompare(l, "content", 1, 2000)
        compare(l.alpha, 1)
    }

    function test_stays_mapped_until_close_completes() {
        var l = make()
        l.open = true
        tryCompare(l, "phase", "Open", 2000)
        var closedSeen = 0
        l.closed.connect(function () { closedSeen++ })
        l.open = false
        compare(l.phase, "Closing")
        compare(l.mapped, true, "a close does not unmap on the flag")
        wait(40)
        verify(l.progress > 0 && l.progress < 1, "mid-close, progress is between: " + l.progress)
        compare(l.mapped, true, "still mapped mid-close")
        tryCompare(l, "mapped", false, 2000)
        compare(l.progress, 0)
        compare(l.content, 0)
        compare(l.alpha, 0)
        compare(closedSeen, 1, "closed() once, on completion")
    }

    function test_reopen_mid_close_reverses_without_jump() {
        var l = make()
        l.open = true
        tryCompare(l, "phase", "Open", 2000)
        l.open = false
        wait(60)
        var at = l.progress
        verify(at > 0.05 && at < 0.98, "caught mid-close at " + at)
        l.open = true
        // The very next reading must be continuous with the last one: the
        // animation restarts FROM the current value, never from 0 or 1.
        verify(Math.abs(l.progress - at) < 0.02, "no jump on reversal: " + at + " → " + l.progress)
        compare(l.mapped, true)
        tryCompare(l, "progress", 1, 2000)
        compare(l.phase, "Open")
    }

    function test_close_mid_open_reverses_without_jump() {
        var l = make()
        l.open = true
        wait(60)
        var at = l.progress
        verify(at > 0.02 && at < 0.98, "caught mid-open at " + at)
        l.open = false
        verify(Math.abs(l.progress - at) < 0.02, "no jump on reversal: " + at + " → " + l.progress)
        tryCompare(l, "mapped", false, 2000)
    }

    function test_reversal_is_shorter_than_a_full_run() {
        var full = make()
        var t0 = Date.now()
        full.open = true
        tryCompare(full, "progress", 1, 2000)
        var fullOpen = Date.now() - t0

        var l = make()
        l.open = true
        tryCompare(l, "phase", "Open", 2000)
        l.open = false
        wait(30)            // barely started closing
        t0 = Date.now()
        l.open = true
        tryCompare(l, "progress", 1, 2000)
        var partial = Date.now() - t0
        verify(partial < fullOpen, "reopening from near-open (" + partial
               + " ms) is quicker than a whole open (" + fullOpen + " ms)")
    }

    function test_spam_settles_in_the_last_state() {
        var l = make()
        for (var i = 0; i < 25; i++) {
            l.open = !l.open
            wait(3)
        }
        // 25 toggles from false ends true.
        compare(l.open, true)
        tryCompare(l, "phase", "Open", 2000)
        for (var j = 0; j < 21; j++) {   // odd: ends closed
            l.open = !l.open
            wait(2)
        }
        compare(l.open, false)
        tryCompare(l, "mapped", false, 2000)
        compare(l.progress, 0)
    }

    function test_born_open_opens_itself() {
        // A LazyPopup builds its popup BY the flag flipping true, so the popup's
        // lifecycle exists only after the transition. It must not wait for the
        // next one — that was the invisible-popup defect applyOpenState fixed.
        var l = make({ open: true })
        compare(l.mapped, true)
        tryCompare(l, "progress", 1, 2000)
        compare(l.phase, "Open")
    }

    function test_content_arrives_after_the_body_and_leaves_before_it() {
        var l = make()
        l.open = true
        wait(30)
        verify(l.progress > l.content, "on the way in the body leads: body " + l.progress
               + ", content " + l.content)
        tryCompare(l, "phase", "Open", 2000)
        tryCompare(l, "content", 1, 2000)
        l.open = false
        wait(40)
        verify(l.content < l.progress, "on the way out the content leaves first: content "
               + l.content + ", body " + l.progress)
        tryCompare(l, "mapped", false, 2000)
    }

    function test_no_spatial_motion_is_a_fade() {
        // Reduce Motion makes the spatial durations 0. The machine is the same;
        // the shape is simply at its end state and alpha carries the change.
        var l = make({ enterDuration: 0, exitDuration: 0 })
        l.open = true
        compare(l.progress, 1, "the shape does not animate")
        compare(l.mapped, true)
        verify(l.alpha < 1, "but it does not pop in either: alpha " + l.alpha)
        tryCompare(l, "alpha", 1, 1000)
        l.open = false
        compare(l.progress, 1, "nor out: it leaves as its finished shape")
        compare(l.mapped, true, "and the window stays until the fade is done")
        tryCompare(l, "alpha", 0, 1000)
        tryCompare(l, "mapped", false, 1000)
        compare(l.progress, 0, "and only then drops its shape")
    }

    function test_reduced_reopen_during_the_fade_keeps_the_shape() {
        var l = make({ enterDuration: 0, exitDuration: 0 })
        l.open = true
        tryCompare(l, "alpha", 1, 1000)
        l.open = false
        wait(20)
        verify(l.alpha > 0 && l.alpha < 1, "caught mid-fade: " + l.alpha)
        l.open = true
        compare(l.progress, 1)
        tryCompare(l, "alpha", 1, 1000)
        compare(l.phase, "Open")
    }

    function test_close_and_reopen_in_one_tick_is_a_no_op() {
        // One lifecycle serving several panes (the right notch): switching pane
        // runs closeAll() and then the next flag, synchronously. The surface
        // must not notice.
        var l = make()
        l.open = true
        tryCompare(l, "phase", "Open", 2000)
        tryCompare(l, "content", 1, 2000)
        l.open = false
        l.open = true
        compare(l.progress, 1, "the body did not move")
        compare(l.content, 1, "the content did not dip")
        compare(l.phase, "Open")
        wait(120)
        compare(l.progress, 1); compare(l.content, 1); compare(l.alpha, 1)
        compare(l.phase, "Open", "and nothing is left settling underneath")
        l.open = false
        tryCompare(l, "mapped", false, 2000)
    }

    function test_no_motion_at_all_still_maps_and_unmaps() {
        // Motion off entirely (scale 0): every duration is 0. Nothing animates
        // and nothing hangs.
        var l = make({ enterDuration: 0, exitDuration: 0, contentIn: 0, contentOut: 0, contentDelay: 0 })
        l.open = true
        compare(l.progress, 1); compare(l.content, 1); compare(l.alpha, 1)
        compare(l.phase, "Open")
        l.open = false
        compare(l.mapped, false, "an instant close unmaps at once")
        compare(l.phase, "Closed")
    }
}
