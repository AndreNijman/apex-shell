import QtQuick
import QtTest
import "components/config"

// ─────────────────────────────────────────────────────────────────────────────
//  slider-wheel-test.qml — the wheel scrolls the page; it never edits a value.
//
//  Run via tests/run-slider-wheel-test.sh, which stages the real
//  src/components/config next to a Theme stub and hands this file to
//  qmltestrunner on the offscreen platform. Nothing here is a reimplementation:
//  the CfgScroll, CfgRow and CfgSlider under test are the shipped sources.
//
//  The events are synthetic but they travel the real path — QWheelEvent,
//  QMouseEvent and QKeyEvent through QQuickWindow's delivery agent, hit-tested
//  by position, which is where a compositor's input arrives once libinput has
//  decoded it. What this therefore cannot tell you is whether libinput calls a
//  given touchpad gesture a wheel; it tells you what the shell does with one.
//
//  The page is the root item and TestCase is a child of it, not the other way
//  round: TestCase sets `visible: false` on itself, so a fixture parented to it
//  is invisible, fails hit-testing, and receives no mouse event at all. The
//  suite then passes every "nothing moved" assertion for the wrong reason.
//  test_000_fixture exists to catch exactly that.
//
//  Reported as UI-004: "Scrolling over sliders changes values." A page of
//  sliders is read by scrolling, and every scroll past one silently moved it.
// ─────────────────────────────────────────────────────────────────────────────

Item {
    id: fixture
    width:  340
    height: 200

    // Every slider on the page reports here, so an assertion can speak for the
    // whole page rather than for the one control the cursor happened to be on.
    property int  anyMove:   0
    property int  moves:     0
    property real targetVal: 40

    CfgScroll {
        id: page
        anchors.fill: parent

        CfgRow {
            label: "Target"
            CfgSlider {
                id: target
                from:  0
                to:    100
                step:  1
                value: fixture.targetVal
                onMoved: function (v) {
                    fixture.moves++
                    fixture.anyMove++
                    fixture.targetVal = v
                }
            }
        }

        // Enough rows below it that the page genuinely overflows. Without this
        // the Flickable has nowhere to go and the scroll assertions are vacuous.
        Repeater {
            model: 14
            CfgRow {
                required property int index
                label: "Filler " + index
                CfgSlider {
                    value: 50
                    onMoved: fixture.anyMove++
                }
            }
        }
    }

    TestCase {
        id: tc
        name:  "SliderWheel"
        when:  windowShown

        function reset() {
            fixture.anyMove   = 0
            fixture.moves     = 0
            fixture.targetVal = 40
            flick().cancelFlick()
            flick().contentY = 0
        }

        // CfgScroll keeps its Flickable private, which is right — but the page
        // is the thing the wheel is supposed to move, so the test has to find it.
        function flick() {
            return findFlickable(page)
        }

        function findFlickable(item) {
            for (var i = 0; i < item.children.length; i++) {
                var c = item.children[i]
                if (c.contentY !== undefined && c.contentHeight !== undefined)
                    return c
                var deep = findFlickable(c)
                if (deep !== null)
                    return deep
            }
            return null
        }

        function sliderValues() {
            var out = []
            collectSliders(page, out)
            return out.map(function (s) { return s.value }).join(",")
        }

        function collectSliders(item, out) {
            for (var i = 0; i < item.children.length; i++) {
                var c = item.children[i]
                // A CfgSlider is the only thing on this page with all three.
                if (c.from !== undefined && c.to !== undefined && c.step !== undefined)
                    out.push(c)
                collectSliders(c, out)
            }
        }

        // ── Preconditions ────────────────────────────────────────────────────
        // Every assertion below is also satisfied by a page that receives no
        // input: a slider that never moves is also a slider that is not there.
        // Prove the fixture is live first, and prove it AS a test so a failure
        // is reported rather than swallowed.
        function test_000_fixture() {
            verify(flick() !== null, "CfgScroll must contain a Flickable")
            verify(flick().contentHeight > flick().height,
                   "the page must overflow, or 'it scrolled' cannot be tested")
            verify(target.width > 0 && target.height > 0,
                   "the target slider must be laid out")
            compare(target.value, 40, "the target starts where the tests assume")

            // The mouse reaches it. Asserted with a press rather than a wheel,
            // because a wheel that does nothing is what this suite is for.
            fixture.moves = 0
            mousePress(target, 8, target.height / 2)
            mouseRelease(target, 8, target.height / 2)
            compare(fixture.moves, 1,
                    "mouse events must reach the slider, or every result here is vacuous")
        }

        // ── The regression ───────────────────────────────────────────────────
        function test_010_wheel_over_a_slider_does_not_move_it() {
            reset()
            var before = target.value

            mouseWheel(target, target.width / 4, target.height / 2, 0, -120)
            wait(100)

            compare(fixture.moves, 0, "moved() must not fire for a wheel event")
            compare(target.value, before, "the value must be untouched")
        }

        function test_011_wheel_over_a_slider_scrolls_the_page() {
            reset()

            mouseWheel(target, target.width / 4, target.height / 2, 0, -120)

            // Flickable answers a wheel with a velocity animation, so the
            // position lands over the next few frames, not inside the call.
            tryVerify(function () { return flick().contentY > 0 }, 2000,
                      "the page under the slider must scroll instead")
        }

        function test_012_wheel_up_is_no_different() {
            reset()

            // Aimed at the middle of the page, not at `target`. Once the page
            // has scrolled, target's own coordinates map above the top of the
            // window and the event lands nowhere — which reads as a pass.
            for (var i = 0; i < 3; i++) {
                mouseWheel(page, page.width / 2, page.height / 2, 0, -120)
                wait(80)
            }
            // Let the flick settle, or an animation still in flight decides the
            // assertion below on its own.
            tryVerify(function () { return !flick().moving }, 3000)
            var down = flick().contentY
            verify(down > 0, "the page went down first")

            var before = sliderValues()
            fixture.anyMove = 0

            mouseWheel(page, page.width / 2, page.height / 2, 0, 120)

            compare(fixture.anyMove, 0, "scrolling back up must not move a value either")
            compare(sliderValues(), before, "every slider still reads what it did")
            tryVerify(function () { return flick().contentY < down }, 2000,
                      "the page must scroll back up")
        }

        // Reading a settings page means running the wheel down it, over whatever
        // happens to be under the pointer. Not one value may change.
        function test_013_reading_the_whole_page_changes_nothing() {
            reset()
            var before = sliderValues()

            for (var i = 0; i < 12; i++) {
                mouseWheel(page, page.width / 2, page.height / 2, 0, -120)
                wait(50)
            }

            compare(fixture.anyMove, 0, "no value bar on the page may move while it scrolls")
            verify(flick().contentY > 0, "and the page must have scrolled")
            compare(sliderValues(), before, "every slider still reads what it did")
        }

        // ── The other half: the ways a value IS meant to change ──────────────
        function test_020_click_and_drag_still_move_the_value() {
            reset()
            var y = target.height / 2

            mousePress(target, 8, y)
            compare(fixture.moves, 1, "a click on the track sets the value")
            verify(target.value < 20, "a click near the left end sets a low value")

            mouseMove(target, 130, y, -1, Qt.LeftButton)
            mouseRelease(target, 130, y)
            verify(fixture.moves > 1, "dragging keeps reporting")
            verify(target.value > 60, "dragging right raises the value")
        }

        function test_021_keys_still_move_the_value() {
            reset()
            target.forceActiveFocus()
            verify(target.activeFocus, "the slider takes keyboard focus")

            keyClick(Qt.Key_Right)
            compare(target.value, 41, "Right steps up by one step")
            keyClick(Qt.Key_Left)
            compare(target.value, 40, "Left steps back down")
            keyClick(Qt.Key_Up)
            compare(target.value, 41, "Up is Right")
            keyClick(Qt.Key_Down)
            compare(target.value, 40, "Down is Left")
            keyClick(Qt.Key_PageUp)
            compare(target.value, 50, "PageUp is ten steps")
            keyClick(Qt.Key_PageDown)
            compare(target.value, 40, "PageDown is ten the other way")
            keyClick(Qt.Key_End)
            compare(target.value, 100, "End is the top of the range")
            keyClick(Qt.Key_Home)
            compare(target.value, 0, "Home is the bottom")
        }

        function test_022_keys_stop_at_the_ends() {
            reset()
            target.forceActiveFocus()
            keyClick(Qt.Key_Home)
            compare(target.value, 0)
            var n = fixture.moves
            keyClick(Qt.Key_Left)
            compare(target.value, 0, "the bottom of the range holds")
            compare(fixture.moves, n, "and a no-op emits nothing")
        }

        function test_023_the_slider_is_in_the_tab_chain() {
            reset()
            verify(target.activeFocusOnTab, "Tab must be able to reach it at all")
            target.forceActiveFocus()
            keyClick(Qt.Key_Tab)
            verify(!target.activeFocus, "Tab moves focus on to the next control")
        }
    }
}
