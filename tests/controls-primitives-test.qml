import QtQuick
import QtTest
import "components/controls"

// ─────────────────────────────────────────────────────────────────────────────
// ApexPressable & co. — the press, hover and focus language every control
// shares (UI/UX roadmap v3 Phase 3). Run by tests/run-controls-primitives-test.sh
// under qmltestrunner on the offscreen platform, against the REAL primitives
// and the real motion system (shipped defaults: Balanced, 1x).
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: fixture
    width: 400; height: 300

    property int clicks: 0
    property int offClicks: 0
    property int iconClicks: 0

    ApexPressable {
        id: btn
        objectName: "btn"
        x: 20; y: 20; width: 100; height: 32
        onActivated: fixture.clicks++
        Rectangle { anchors.fill: parent; color: btn.tint(Theme.surfaceRaised) }
        ApexFocusRing { id: ring; target: btn }
    }
    ApexPressable {
        id: other
        x: 20; y: 80; width: 100; height: 32
    }
    ApexPressable {
        id: off
        x: 20; y: 140; width: 100; height: 32
        interactive: false
        onActivated: fixture.offClicks++
    }
    ApexIconButton {
        id: icon
        x: 200; y: 20
        bar: true
        glyph: "x"
        onActivated: fixture.iconClicks++
    }

    TestCase {
        name: "ControlsPrimitives"
        when: windowShown

        function test_010_a_press_dips_and_a_release_comes_back() {
            mousePress(btn, 50, 16)
            tryVerify(function () { return btn.scale < 0.99 }, 500, "no dip on press: " + btn.scale)
            verify(btn.scale >= Motion.pressScale - 0.001, "dipped past pressScale: " + btn.scale)
            mouseRelease(btn, 50, 16)
            tryCompare(btn, "scale", 1, 1000)
        }

        function test_020_a_click_activates_once() {
            const before = fixture.clicks
            mouseClick(btn, 50, 16)
            compare(fixture.clicks, before + 1)
        }

        function test_030_pointer_focus_lights_no_ring() {
            mouseClick(btn, 50, 16)
            verify(btn.activeFocus, "a click did not focus the control")
            verify(!btn.focusVisible, "a pointer click lit the focus ring")
            verify(!ring.visible, "the ring is drawn for pointer focus")
        }

        function test_040_keyboard_focus_lights_it() {
            other.forceActiveFocus()
            keyClick(Qt.Key_Tab)        // ends up somewhere; then come back with the keyboard
            btn.forceActiveFocus()
            keyClick(Qt.Key_Tab); keyClick(Qt.Key_Backtab)
            verify(btn.activeFocus, "Backtab did not come back to the control")
            verify(btn.focusVisible, "keyboard focus did not light the ring")
            verify(ring.visible, "the ring is not drawn for keyboard focus")
        }

        function test_050_space_and_return_activate_and_replay_the_dip() {
            btn.forceActiveFocus()
            const before = fixture.clicks
            keyClick(Qt.Key_Space)
            compare(fixture.clicks, before + 1, "Space did not activate")
            tryVerify(function () { return btn.scale < 0.999 }, 300, "Space did not replay the dip")
            tryCompare(btn, "scale", 1, 1000)
            keyClick(Qt.Key_Return)
            compare(fixture.clicks, before + 2, "Return did not activate")
            // The keyboard dip lets go by itself, one pressIn later.
            tryCompare(btn, "pressed", false, 500)
            tryCompare(btn, "scale", 1, 1000)
        }

        function test_060_a_disabled_control_does_nothing() {
            verify(!off.activeFocusOnTab, "a disabled control is a tab stop")
            tryCompare(off, "opacity", 0.38, 1000)
            mouseClick(off, 50, 16)
            off.forceActiveFocus()
            keyClick(Qt.Key_Space)
            compare(fixture.offClicks, 0, "a disabled control activated")
            compare(off.scale, 1, "a disabled control dipped")
        }

        function test_070_the_state_layer_is_nothing_at_rest() {
            // The pointer is still resting on the button from the clicks above.
            mouseMove(fixture, 390, 290)
            tryVerify(function () { return !btn.hovered }, 500, "the button still reads as hovered")
            const c = Theme.surfaceRaised
            const t = btn.tint(c)
            verify(Math.abs(t.r - c.r) < 1e-6 && Math.abs(t.g - c.g) < 1e-6, "tint moved the surface at rest")
            compare(other.stateLayer().a, 0, "stateLayer() is not transparent at rest")
            mouseMove(btn, 50, 16)
            tryVerify(function () { return btn.hovered }, 500, "hovering did not register")
            const h = btn.tint(c)
            verify(Math.abs(h.r - c.r) + Math.abs(h.g - c.g) + Math.abs(h.b - c.b) > 0.005,
                   "hovering did not move the surface toward the text colour")
        }

        function test_080_the_bar_icon_has_a_24_px_target() {
            verify(icon.width < 24, "the test icon is not smaller than its target: " + icon.width)
            const before = fixture.iconClicks
            mouseClick(icon, -1, icon.height / 2)          // just outside the drawn glyph box
            compare(fixture.iconClicks, before + 1, "a click inside the 24 px target but outside the glyph missed")
        }
    }
}
