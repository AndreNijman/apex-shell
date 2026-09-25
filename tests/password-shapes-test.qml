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

    function test_tone_is_not_a_colour_per_kind() {
        // A real palette: the component has no defaults on purpose.
        var o = make({ accent: "#fab898", text: "#ece0dc", background: "#171210" })
        o.length = 24
        tryCompare(o, "_alive", 24, 1500)
        var seen = {}
        var slots = slotsOf(o).slice(0, 24)
        for (var i = 0; i < slots.length; i++) {
            var k = slots[i].kind
            seen[k] = seen[k] || {}
            seen[k][String(slots[i].tone)] = true
        }
        for (var kind in seen)
            verify(Object.keys(seen[kind]).length >= 2, kind + " appears in more than one tone")
    }
}
