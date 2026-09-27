import QtQuick
import QtQuick.Window
import QtTest
import "popups"

// ─────────────────────────────────────────────────────────────────────────────
// A level slider opened after its value changed behind it (Andre, 2026-09-27:
// "when i open the brightness slider at first it like jitters a bit on the
// slider"). The fill follows its value on a SpringFollower, which is stepped
// by rendered frames; behind a closed popup there are none, so a brightness
// or volume key left the fill at the old level and the next open slid it
// across while the thumb already stood at the new one.
//
// Driven by tests/run-slider-open-test.sh against the REAL ChannelColumn.
// ─────────────────────────────────────────────────────────────────────────────
TestCase {
    id: tc
    name: "SliderOpen"
    when: windowShown

    Window {
        id: pop
        width: 160; height: 320
        visible: false
        ChannelColumn {
            id: ch
            icon: "x"
            accessibleName: "Brightness"
            muteable: false
            active: true
            value: 0.2
        }
    }

    function fill() { return findChild(ch, "levelFill") }
    function want(v) { return Math.max(fill().radius * 2, ch.trackHeight * v) }

    function test_a_change_behind_a_closed_popup_is_already_there_when_it_opens() {
        verify(fill() !== null, "the fill is found")
        pop.visible = true
        tryVerify(function () { return Math.abs(fill().height - want(0.2)) < 0.5 }, 2000, "open, at its level")
        pop.visible = false
        ch.value = 0.8                      // a brightness key while it is closed
        pop.visible = true
        verify(Math.abs(fill().height - want(0.8)) < 0.5,
               "the first frame shown is the new level, not a slide from the old one: fill "
               + fill().height.toFixed(1) + " want " + want(0.8).toFixed(1))
        pop.visible = false
    }

    // Under the pointer the thumb IS the finger, and the fill must be with it:
    // it used to chase the thumb on its spring — measured, 120 px behind at the
    // press and 16-36 px behind through a drag (the rest of the "jitter").
    function test_under_the_pointer_the_fill_is_with_the_finger() {
        pop.visible = true
        ch.value = 0.2
        tryVerify(function () { return Math.abs(fill().height - want(0.2)) < 0.5 }, 2000)
        const owner = function (v) { ch.value = v }      // the popup writes it back
        ch.volumeChanged.connect(owner)
        const track = fill().parent
        mousePress(track, track.width / 2, track.height * 0.2)
        verify(ch.value > 0.7, "the press set the value: " + ch.value.toFixed(2))
        verify(Math.abs(fill().height - want(ch.value)) < 0.5,
               "at the press the fill is already at the finger: " + fill().height.toFixed(1)
               + " want " + want(ch.value).toFixed(1))
        mouseMove(track, track.width / 2, track.height * 0.5)
        verify(Math.abs(fill().height - want(ch.value)) < 0.5, "and stays with it while dragged")
        mouseRelease(track, track.width / 2, track.height * 0.5)
        ch.volumeChanged.disconnect(owner)
        pop.visible = false
    }

    function test_while_open_the_level_still_follows_rather_than_jumping() {
        pop.visible = true
        ch.value = 0.3
        tryVerify(function () { return Math.abs(fill().height - want(0.3)) < 0.5 }, 2000)
        ch.value = 0.9
        verify(fill().height < want(0.9) - 1, "on screen it moves to a new value rather than cutting")
        tryVerify(function () { return Math.abs(fill().height - want(0.9)) < 0.5 }, 2000, "and gets there")
        pop.visible = false
    }
}
