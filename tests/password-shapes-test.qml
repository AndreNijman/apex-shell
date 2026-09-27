import QtQuick
import QtTest
import "components/auth"

// ─────────────────────────────────────────────────────────────────────────────
// PasswordShapes — the password field's shape feedback, behaviourally.
// Driven by tests/run-password-shapes-test.sh under qmltestrunner against the
// REAL src/components/auth/PasswordShapes.qml and the real motion table.
// ─────────────────────────────────────────────────────────────────────────────
TestCase {
    id: tc
    name: "PasswordShapes"
    when: windowShown
    width: 400; height: 60

    Component { id: shapesC; PasswordShapes { width: 300; height: 20 } }

    function make(props) {
        var o = createTemporaryObject(shapesC, tc, props || {})
        verify(o !== null)
        return o
    }
    // The slots are the Repeater's delegates inside the Row.
    function slotsOf(o) {
        var row = o.children[0]
        var out = []
        for (var i = 0; i < row.children.length; i++)
            if (row.children[i].hasOwnProperty("kind")) out.push(row.children[i])
        return out
    }
    function aliveCount(o) {
        return slotsOf(o).filter(function (s) { return s.alive }).length
    }

    function test_takes_a_length_and_no_text() {
        var o = make()
        // The whole point: nothing here can hold the secret.
        verify(!("text" in o) || typeof o.text !== "string" || o.text.length === 0 || /^#/.test(String(o.text)),
               "`text` is only ever the palette's text colour")
        compare(typeof o.length, "number")
        verify(!("password" in o), "no password property")
        verify(!("displayText" in o), "no displayText property")
    }

    function test_one_shape_per_character() {
        var o = make()
        o.length = 5
        tryCompare(o, "_alive", 5, 1000)
        compare(aliveCount(o), 5)
        o.length = 3
        tryVerify(function () { return aliveCount(o) === 3 }, 1000, "deleting two leaves three")
    }

    function test_clearing_ends_empty_only_when_every_shape_has_left() {
        var o = make()
        o.length = 6
        tryCompare(o, "_alive", 6, 1000)
        o.length = 0
        compare(o.empty, false, "not empty the instant the field clears — the row is still leaving")
        tryCompare(o, "empty", true, 2000)
    }

    function test_kind_depends_on_position_only() {
        var o = make()
        o.length = 8
        tryCompare(o, "_alive", 8, 1000)
        var first = slotsOf(o).slice(0, 8).map(function (s) { return s.kind })
        o.length = 0
        tryCompare(o, "empty", true, 2000)
        o.length = 8
        tryCompare(o, "_alive", 8, 1000)
        var again = slotsOf(o).slice(0, 8).map(function (s) { return s.kind })
        compare(again.join(","), first.join(","), "the same position shows the same shape")
        for (var i = 1; i < first.length; i++)
            verify(first[i] !== first[i - 1], "no two identical shapes side by side: " + first.join(","))
    }

    function test_reduced_motion_is_a_fade_at_full_size() {
        var o = make({ reduced: true })
        o.length = 2
        var s = slotsOf(o)[0]
        compare(s.p, 1, "no spatial motion: the shape is simply at its end state")
        verify(s.f < 1, "but it fades in rather than popping: f=" + s.f)
        tryCompare(s, "f", 1, 500)
    }

    function test_several_at_once_stagger_but_finish_together_enough() {
        var o = make()
        o.length = 10
        tryCompare(o, "_alive", 10, 1500)
        var t0 = Date.now()
        o.length = 0
        tryCompare(o, "empty", true, 2000)
        var took = Date.now() - t0
        // exit 135 ms + at most the 100 ms stagger cap, plus test slack.
        verify(took < 700, "a cleared field is gone as one gesture (" + took + " ms)")
    }

    function test_a_busy_check_steps_the_row_back() {
        var o = make()
        o.busy = true
        tryVerify(function () { return o.opacity < 0.7 }, 1000)
        o.busy = false
        tryCompare(o, "opacity", 1, 1000)
    }

    function test_a_long_passphrase_never_goes_silent() {
        // At 32 slots the 33rd key and every one after it added nothing.
        var o = make()
        o.length = 40
        tryCompare(o, "_alive", 40, 2000)
        o.length = 41
        tryCompare(o, "_alive", 41, 1000)
    }

    function test_reduced_motion_leaves_the_way_it_arrived() {
        // Under Reduce Motion a deleted shape keeps its form and its slot while
        // it fades; it used to snap to a tilted dot in a zero-width slot first.
        var o = make({ reduced: true })
        o.length = 3
        var s = slotsOf(o)[2]
        tryCompare(s, "f", 1, 500)
        o.length = 2
        compare(s.p, 1, "still full-size the instant it starts leaving")
        verify(s.width > 0, "still holding its slot")
        tryCompare(s, "f", 0, 500)
        tryCompare(s, "p", 0, 500)
    }

    // End-4's and Google's PIN entry (2026-09-27): a new shape is born in the
    // accent and settles to the text colour; one leaving after a refused
    // attempt turns danger. Colour by AGE, never by what was typed.
    function test_born_in_the_accent_settling_to_the_text_colour() {
        var o = make({ accent: "#fab898", text: "#ece0dc", background: "#171210", danger: "#ffb4ab" })
        o.length = 1
        var s = slotsOf(o)[0]
        compare(String(s.tint), "#fab898", "born in the accent")
        tryCompare(s, "tint", o.text, 2000, "settles to the text colour")
        o.length = 4
        var fresh = slotsOf(o)[3]
        tryVerify(function () { return fresh.alive }, 1000)
        verify(String(fresh.tint) !== String(o.text), "the newest is still glowing while the first has settled")
        tryCompare(fresh, "tint", o.text, 2000)
        // Settled, it follows the palette.
        o.text = "#d0c4c0"
        compare(String(s.tint), "#d0c4c0", "a settled shape follows a palette change")
    }

    function test_every_kind_is_a_real_material_shape() {
        var o = make()
        var seen = {}
        for (var i = 0; i < 7; i++) seen[o.kindAt(i)] = true
        compare(Object.keys(seen).length, 7, "seven different shapes in turn")
        o.length = 7
        tryCompare(o, "_alive", 7, 1500)
        var shapes = slotsOf(o).slice(0, 7)
        for (var j = 0; j < shapes.length; j++) {
            var shape = shapes[j].children[0].item      // Loader → Shape
            verify(shape !== null, shapes[j].kind + ": its shape was built")
            var path = shape.data[0].pathElements[0].path
            verify(/^M [\d.]+ [\d.]+ C /.test(path), shapes[j].kind + ": a real path, not a fallback: " + path.slice(0, 40))
            var nums = path.match(/-?[\d.]+/g).map(Number)
            verify(Math.min.apply(null, nums) >= -0.5 && Math.max.apply(null, nums) <= o.size + 0.5,
                   shapes[j].kind + ": drawn inside its " + o.size + " px box")
        }
    }

    function test_it_pops_on_the_expressive_spring() {
        var o = make()
        o.length = 1
        var s = slotsOf(o)[0]
        var peak = 0
        tryVerify(function () { peak = Math.max(peak, s.pop); return s.p >= 1 }, 2000)
        verify(peak > 1.03, "overshoots its size on the way in (peak " + peak.toFixed(3) + ")")
        compare(s.pop, 1, "and lands exactly on it")
        verify(o.tEnter >= 250 && o.tEnter <= 600, "the spring's run at Balanced: " + o.tEnter + " ms")
        verify(o._popAt(0.5) > 1.0, "past its size half-way through the run")
    }

    function test_leaving_shrinks_without_an_overshoot() {
        var o = make()
        o.length = 2
        tryCompare(o, "_alive", 2, 1500)
        tryVerify(function () { return slotsOf(o)[1].p >= 1 }, 1500)
        var s = slotsOf(o)[1]
        o.length = 1
        var low = 1
        tryVerify(function () { low = Math.min(low, s.pop); return !s.alive }, 2000)
        verify(low >= 0, "never shrinks below nothing (" + low + ")")
    }

    function test_the_caret_rides_after_the_last_shape() {
        var o = make({ accent: "#fab898", text: "#ece0dc", background: "#171210", danger: "#ffb4ab" })
        var caret = o.children[1]
        compare(caret.opacity, 0, "no caret over an empty field (the placeholder is there)")
        o.length = 3
        tryCompare(caret, "opacity", 1, 1000)
        tryVerify(function () { return slotsOf(o)[2].p >= 1 }, 1500)
        var last = slotsOf(o)[2]
        verify(Math.abs(caret.x - (o.children[0].x + last.x + last.width + o.gap)) < 1.5,
               "just after the last shape")
        o.busy = true
        tryCompare(caret, "opacity", 0, 1000, "it steps back while a check runs")
    }

    function test_under_reduce_motion_nothing_pops() {
        var o = make({ reduced: true })
        compare(o.tEnter, 0, "no spring run under Reduce Motion")
        o.length = 1
        var s = slotsOf(o)[0]
        compare(s.pop, 1, "at its size from the first frame")
    }
}
