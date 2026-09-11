import QtQuick
import QtTest
import "components/config"

// ─────────────────────────────────────────────────────────────────────────────
//  a11y-controls-test.qml — what a screen reader and a keyboard-only user get
//  from the shared settings controls (roadmap P2-003).
//
//  Run via tests/run-a11y-controls-test.sh, which stages the real
//  src/components/config next to a Theme stub and hands this file to
//  qmltestrunner on the offscreen platform. Every control under test is the
//  shipped source; only the palette is fake, and no assertion here reads a
//  colour.
//
//  ── The measurement, and why it is not a grep ───────────────────────────────
//
//  Before this suite the shell had ZERO `Accessible.` usages across 209 QML
//  files, no FocusScope, no KeyNavigation, and exactly one real
//  `activeFocusOnTab` (CfgSlider). Eleven Settings pages and the nav pane were
//  mouse-only. The fix is in the shared controls rather than the pages, because
//  294 of the 671 labels in this tree live in `config_tab/pages` and naming
//  them one at a time would rot the first time somebody changed a label and not
//  its twin.
//
//  So the claim under test is not "the property is present". It is:
//
//    * a reader landing on a control is told what the ROW says, which is where
//      the words actually are — read back off the live attached object;
//    * it is told the control's kind and, for the checkable ones, its state;
//    * every control is reachable by a real Qt.Key_Tab and operable by a real
//      Qt.Key_Space, counted through the signals the pages listen to.
//
//  ── The trap this fixture is shaped around ──────────────────────────────────
//
//  CfgRow supplies its label to the control it was given. An assertion that
//  looked the control up BY that name would vanish rather than fail if the
//  propagation broke — the lookup would simply find nothing and the loop would
//  pass over an empty set. So every control here is found by objectName, the
//  count of found controls is asserted first, and only then are their names
//  read.
// ─────────────────────────────────────────────────────────────────────────────

Item {
    id: fixture
    width:  640
    height: 720

    // What the pages listen to. Counted, so "the key press did something" is
    // measured at the same boundary a real page observes.
    property int  switchToggles:  0
    property bool lastSwitchValue: false
    property int  buttonClicks:   0
    property int  tileToggles:    0
    property int  segmentPicks:   0
    property var  lastSegment:    null
    property int  sliderMoves:    0
    property int  blockedToggles: 0
    property real lastSliderValue: -1

    Column {
        id: rows
        width: parent.width
        spacing: 4

        CfgRow {
            id: switchRow
            objectName: "switchRow"
            label:       "Reduce motion"
            description: "Turn off animations across the shell"
            status:      "on"
            CfgSwitch {
                id: theSwitch
                objectName: "theSwitch"
                checked: fixture.lastSwitchValue
                onToggled: function (v) {
                    fixture.switchToggles++
                    fixture.lastSwitchValue = v
                }
            }
        }

        CfgRow {
            id: buttonRow
            objectName: "buttonRow"
            label:       "Reset every appearance setting"
            description: "Puts the theme back to what the image ships"
            CfgButton {
                id: theButton
                objectName: "theButton"
                label: "Reset"
                onClicked: fixture.buttonClicks++
            }
        }

        CfgRow {
            id: sliderRow
            objectName: "sliderRow"
            label:  "Animation speed"
            effect: "apply"
            CfgSlider {
                id: theSlider
                objectName: "theSlider"
                from: 0; to: 1200; step: 20; value: 320; suffix: "ms"
                onMoved: function (v) {
                    fixture.sliderMoves++
                    fixture.lastSliderValue = v
                }
            }
        }

        CfgRow {
            id: fieldRow
            objectName: "fieldRow"
            label: "Hostname"
            CfgTextField {
                id: theField
                objectName: "theField"
                placeholder: "apex-laptop"
            }
        }

        CfgRow {
            id: segRow
            objectName: "segRow"
            label: "Scaling mode"
            CfgSegmented {
                id: theSegmented
                objectName: "theSegmented"
                options: ["Automatic", "Manual"]
                value:   "Automatic"
                onSelected: function (v) {
                    fixture.segmentPicks++
                    fixture.lastSegment = v
                }
            }
        }

        // A row whose control is switched off, to prove the REASON reaches a
        // reader. A dimmed control whose explanation is only a sibling Text is
        // a control that, to a reader, refuses for no reason at all.
        CfgRow {
            id: blockedRow
            objectName: "blockedRow"
            label: "Tap to click"
            disabledReason: "This machine has no touchpad"
            // The handler is not decoration. Without it this control's toggle
            // reaches no counter, and test_045 below passes whether the row is
            // switched off or not — which is exactly what happened: mutant N8
            // removed CfgRow's `enabled` guard and the suite stayed green.
            CfgSwitch {
                id: blockedSwitch
                objectName: "blockedSwitch"
                onToggled: fixture.blockedToggles++
            }
        }
    }

    CfgTile {
        id: theTile
        objectName: "theTile"
        y: 640
        width: 120; height: 64
        label: "Wi-Fi"
        sublabel: "MyNetwork"
        on: true
        onToggled: fixture.tileToggles++
    }

    // ── Tree helpers ─────────────────────────────────────────────────────────
    function walk(item, out) {
        if (!item || !item.children) return out
        for (var i = 0; i < item.children.length; i++) {
            var c = item.children[i]
            out.push(c)
            walk(c, out)
        }
        return out
    }
    function all() { return walk(fixture, []) }

    function named(n) {
        var a = all()
        for (var i = 0; i < a.length; i++) if (a[i].objectName === n) return a[i]
        return null
    }
    function allNamed(n) {
        var a = all(), out = []
        for (var i = 0; i < a.length; i++) if (a[i].objectName === n) out.push(a[i])
        return out
    }

    function focusedItem() {
        var a = all(), deepest = null
        for (var i = 0; i < a.length; i++) {
            var c = a[i]
            if (!c.activeFocus) continue
            var kid = false
            for (var j = 0; j < c.children.length; j++)
                if (c.children[j].activeFocus) { kid = true; break }
            if (!kid) deepest = c
        }
        return deepest
    }
    function focusedName() {
        var f = focusedItem()
        return f ? (f.objectName || "<unnamed>") : "<none>"
    }

    TestCase {
        id: tc
        name: "a11y-controls"
        when: windowShown

        // ── The fixture is real ──────────────────────────────────────────────
        // TestCase sets visible:false on itself, so a fixture parented to it is
        // invisible, fails hit-testing and receives no input — every "the key
        // did something" assertion would then pass for the wrong reason.
        function test_000_fixture_is_live() {
            verify(fixture.visible, "the fixture is not visible")
            verify(fixture.all().length > 30,
                   "only " + fixture.all().length + " items in the tree")
        }

        // Asserted before anything reads a name off them. CfgRow supplies the
        // name, so a lookup BY name would find nothing and pass vacuously if
        // the propagation broke.
        function test_001_every_control_was_found() {
            var want = ["theSwitch", "theButton", "theSlider", "theField",
                        "theSegmented", "theTile", "blockedSwitch"]
            for (var i = 0; i < want.length; i++)
                verify(fixture.named(want[i]) !== null, "no item named " + want[i])
            compare(fixture.allNamed("cfgSegmentedPill").length, 2,
                    "the segmented control did not build two pills")
        }

        // ── The row hands its words to the control ───────────────────────────
        function test_010_row_names_its_control() {
            compare(theSwitch.Accessible.name, "Reduce motion",
                    "the switch is unnamed; a reader announces an anonymous checkbox")
            compare(theSlider.Accessible.name, "Animation speed", "slider name")
            compare(theSegmented.Accessible.name, "Scaling mode", "segmented group name")
        }

        // Bound, not copied once: a page that changes a label at runtime — and
        // several do, from a live readback — must not leave the reader on the
        // old one.
        function test_011_a_renamed_row_renames_its_control() {
            switchRow.label = "Reduce motion and transparency"
            compare(theSwitch.Accessible.name, "Reduce motion and transparency",
                    "the control kept the old label after the row was renamed")
            switchRow.label = "Reduce motion"
        }

        // CfgButton's words are its own. The row must not overwrite them, or
        // every button in Settings gets announced as its row's sentence.
        function test_012_a_control_that_names_itself_is_left_alone() {
            compare(theButton.Accessible.name, "Reset",
                    "the row overwrote the button's own label")
        }

        // The description carries what a sighted user reads around the control:
        // the explanation, and the status the machine reported back.
        function test_013_description_carries_the_rows_prose_and_readback() {
            var d = theSwitch.Accessible.description
            verify(d.indexOf("Turn off animations") >= 0,
                   "the row's description did not reach the control; got '" + d + "'")
            verify(d.indexOf("Currently on") >= 0,
                   "the effective value the machine reported is not announced; got '" + d + "'")
        }

        // A control switched off for a reason must give the reason, not silence.
        function test_014_a_refusal_says_why() {
            var d = blockedSwitch.Accessible.description
            verify(d.indexOf("no touchpad") >= 0,
                   "a disabled control announces '" + d + "' instead of why it is off")
        }

        // ── Roles and state ──────────────────────────────────────────────────
        function test_020_every_control_declares_a_role() {
            compare(theSwitch.Accessible.role,   Accessible.CheckBox,   "switch role")
            compare(theButton.Accessible.role,   Accessible.Button,     "button role")
            compare(theSlider.Accessible.role,   Accessible.Slider,     "slider role")
            compare(theTile.Accessible.role,     Accessible.Button,     "tile role")
            var pills = fixture.allNamed("cfgSegmentedPill")
            compare(pills[0].Accessible.role, Accessible.RadioButton,   "pill role")
        }

        // checkable without checked announces every toggle in the shell as off.
        function test_021_checkable_controls_report_their_state() {
            verify(theSwitch.Accessible.checkable, "the switch is not checkable")
            fixture.lastSwitchValue = true
            compare(theSwitch.Accessible.checked, true,  "switch checked=true")
            fixture.lastSwitchValue = false
            compare(theSwitch.Accessible.checked, false, "switch checked=false")

            var pills = fixture.allNamed("cfgSegmentedPill")
            compare(pills[0].Accessible.checked, true,
                    "the selected pill does not report itself selected")
            compare(pills[1].Accessible.checked, false,
                    "an unselected pill reports itself selected")
        }

        // Each pill says which option it is, not just that it is a radio button.
        function test_022_each_pill_names_its_option() {
            var pills = fixture.allNamed("cfgSegmentedPill")
            compare(pills[0].Accessible.name, "Automatic", "first pill name")
            compare(pills[1].Accessible.name, "Manual",    "second pill name")
        }

        // The field a reader lands on is the TextInput, not the wrapper. A name
        // on a wrapper the focus never reaches helps nobody.
        function test_023_the_text_field_carries_its_name_where_focus_lands() {
            var input = fixture.named("cfgTextFieldInput")
            verify(input !== null, "no item named cfgTextFieldInput")
            compare(input.Accessible.role, Accessible.EditableText, "input role")
            compare(input.Accessible.name, "Hostname",
                    "the row's label did not reach the TextInput that takes focus")
        }

        // ── Keyboard: reach ──────────────────────────────────────────────────
        function test_030_every_control_is_a_tab_stop() {
            var items = [theSwitch, theButton, theSlider, theTile]
            for (var i = 0; i < items.length; i++)
                verify(items[i].activeFocusOnTab,
                       items[i].objectName + " cannot be reached with Tab")
            var input = fixture.named("cfgTextFieldInput")
            verify(input.activeFocusOnTab, "the text field cannot be reached with Tab")
            var pills = fixture.allNamed("cfgSegmentedPill")
            for (var j = 0; j < pills.length; j++)
                verify(pills[j].activeFocusOnTab, "segmented pill " + j + " is not a tab stop")
        }

        // Pressed, not inspected: Tab walks the real chain in visual order.
        function test_031_tab_walks_the_rows_in_order() {
            theSwitch.forceActiveFocus()
            compare(fixture.focusedName(), "theSwitch", "focus did not start on the switch")
            var seen = []
            for (var i = 0; i < 4; i++) {
                keyClick(Qt.Key_Tab)
                seen.push(fixture.focusedName())
            }
            compare(seen[0], "theButton", "Tab 1")
            compare(seen[1], "theSlider", "Tab 2")
            compare(seen[2], "cfgTextFieldInput", "Tab 3")
            compare(seen[3], "cfgSegmentedPill", "Tab 4")
        }

        // ── Keyboard: operate ────────────────────────────────────────────────
        // Counted through the signals the pages listen to, so this measures the
        // same boundary a real page observes rather than an internal flag.
        function test_040_space_toggles_the_switch() {
            var before = fixture.switchToggles
            theSwitch.forceActiveFocus()
            keyClick(Qt.Key_Space)
            compare(fixture.switchToggles, before + 1,
                    "Space on the focused switch emitted no toggle")
        }

        function test_041_space_and_enter_press_the_button() {
            var before = fixture.buttonClicks
            theButton.forceActiveFocus()
            keyClick(Qt.Key_Space)
            keyClick(Qt.Key_Return)
            compare(fixture.buttonClicks, before + 2,
                    "Space and Return on the focused button did not press it")
        }

        function test_042_space_chooses_a_segment() {
            var pills = fixture.allNamed("cfgSegmentedPill")
            var before = fixture.segmentPicks
            pills[1].forceActiveFocus()
            keyClick(Qt.Key_Space)
            compare(fixture.segmentPicks, before + 1, "Space did not choose the pill")
            compare(fixture.lastSegment, "Manual", "the wrong option was chosen")
        }

        function test_043_space_toggles_the_tile() {
            var before = fixture.tileToggles
            theTile.forceActiveFocus()
            keyClick(Qt.Key_Space)
            compare(fixture.tileToggles, before + 1, "Space on the focused tile did nothing")
        }

        // The slider was already keyboard-operable; this guards that against
        // the focus changes the rest of this work made.
        function test_044_arrows_still_move_the_slider() {
            var before = fixture.sliderMoves
            theSlider.forceActiveFocus()
            keyClick(Qt.Key_Right)
            compare(fixture.sliderMoves, before + 1, "Right did not move the slider")
            compare(fixture.lastSliderValue, 340, "the slider moved by the wrong amount")
        }

        // A disabled row must not be operable from the keyboard either. CfgRow
        // switches the slot off, and `enabled` propagates — but a control that
        // answers a keypress anyway would be a refusal only a mouse respects.
        function test_045_a_disabled_control_ignores_the_keyboard() {
            // The control is wired to its OWN counter, and the counter is proved
            // to move before it is used to prove something did not move. An
            // assertion that a number stayed the same is worthless until the
            // number has been shown capable of changing — mutant N8 survived on
            // exactly that, because the fixture had wired no handler at all.
            var live = fixture.named("theSwitch")
            verify(live !== null, "no item named theSwitch")

            var before = fixture.blockedToggles
            blockedSwitch.forceActiveFocus()
            keyClick(Qt.Key_Space)
            compare(fixture.blockedToggles, before,
                    "Space operated a control the row had switched off")

            // …and the same counter DOES move when the row is not switched off.
            blockedRow.disabledReason = ""
            blockedSwitch.forceActiveFocus()
            keyClick(Qt.Key_Space)
            compare(fixture.blockedToggles, before + 1,
                    "the control never responds to Space at all, so the refusal " +
                    "above proved nothing")
            blockedRow.disabledReason = "This machine has no touchpad"
        }
    }
}
