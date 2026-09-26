import QtQuick
import QtTest
import "components"
import "components/controls"

// ─────────────────────────────────────────────────────────────────────────────
// TabSwitcher on the keyboard (UI/UX roadmap v3 Phase 21). Run by
// tests/run-keyboard-nav-test.sh under qmltestrunner on the offscreen platform,
// against the REAL TabSwitcher and controls.
//
// A switcher hands its choice up with pageChanged and is told the page back
// through currentPage, exactly as the Dashboard, the network panel and the
// settings column drive it — so each one here is wired the same way.
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: fixture
    width: 600; height: 520

    readonly property var fourPages: [
        { key: "a", label: "Alpha", icon: "" }, { key: "b", label: "Bravo", icon: "" },
        { key: "c", label: "Charlie", icon: "" }, { key: "d", label: "Delta", icon: "" }
    ]

    ApexPressable { id: before; x: 10; y: 10; width: 60; height: 32 }

    TabSwitcher {
        id: h
        x: 10; y: 60; width: 400; height: 40
        model: fixture.fourPages
        currentPage: "a"
        onPageChanged: function (key) { h.currentPage = key }
    }

    TabSwitcher {
        id: v
        x: 440; y: 60; width: 140; height: 300
        orientation: "vertical"
        model: fixture.fourPages
        currentPage: "a"
        onPageChanged: function (key) { v.currentPage = key }
    }

    Item {
        x: 10; y: 120; width: 400; height: 40
        LayoutMirroring.enabled: true
        LayoutMirroring.childrenInherit: true
        TabSwitcher {
            id: rtl
            anchors.fill: parent
            model: fixture.fourPages
            currentPage: "b"
            onPageChanged: function (key) { rtl.currentPage = key }
        }
    }

    // Short enough to scroll: eight rows in 120 px.
    TabSwitcher {
        id: shortV
        x: 440; y: 370; width: 140; height: 120
        orientation: "vertical"
        model: fixture.fourPages.concat([
            { key: "e", label: "Echo", icon: "" }, { key: "f", label: "Foxtrot", icon: "" },
            { key: "g", label: "Golf", icon: "" }, { key: "h", label: "Hotel", icon: "" }])
        currentPage: "a"
        onPageChanged: function (key) { shortV.currentPage = key }
    }

    TabSwitcher {
        id: single
        x: 10; y: 180; width: 200; height: 40
        model: [{ key: "only", label: "Only", icon: "" }]
        currentPage: "only"
    }

    TestCase {
        name: "KeyboardNav"
        when: windowShown

        function init() {
            h.currentPage = "a"; v.currentPage = "a"; rtl.currentPage = "b"
            before.forceActiveFocus()
        }

        function test_010_tab_reaches_the_switcher_as_one_stop() {
            keyClick(Qt.Key_Tab)
            verify(h.activeFocus, "Tab from the button did not land on the tab list")
            keyClick(Qt.Key_Tab)
            verify(!h.activeFocus, "the tab list kept focus through a second Tab: its tabs are separate stops")
        }

        function test_020_the_arrows_move_the_selection_and_wrap() {
            h.forceActiveFocus()
            keyClick(Qt.Key_Right); compare(h.currentPage, "b")
            keyClick(Qt.Key_Right); compare(h.currentPage, "c")
            keyClick(Qt.Key_Left);  compare(h.currentPage, "b")
            keyClick(Qt.Key_Left);  keyClick(Qt.Key_Left)
            compare(h.currentPage, "d", "Left from the first page did not wrap to the last")
        }

        function test_030_home_and_end_jump() {
            h.forceActiveFocus()
            keyClick(Qt.Key_End);  compare(h.currentPage, "d")
            keyClick(Qt.Key_Home); compare(h.currentPage, "a")
        }

        function test_040_a_vertical_list_takes_up_and_down_only() {
            v.forceActiveFocus()
            keyClick(Qt.Key_Down); compare(v.currentPage, "b")
            keyClick(Qt.Key_Right); compare(v.currentPage, "b", "a vertical list moved on Right")
            keyClick(Qt.Key_Up); compare(v.currentPage, "a")
        }

        function test_050_a_mirrored_row_runs_the_other_way() {
            rtl.forceActiveFocus()
            keyClick(Qt.Key_Right); compare(rtl.currentPage, "a", "Right in a right-to-left row should go back")
            keyClick(Qt.Key_Left);  compare(rtl.currentPage, "b")
        }

        function test_060_the_ring_is_shown_only_while_it_has_focus() {
            verify(!h.focusVisible)
            h.forceActiveFocus()
            verify(h.focusVisible, "focused by the keyboard, no ring")
            before.forceActiveFocus()
            verify(!h.focusVisible, "the ring stayed after focus left")
        }

        function test_070_one_page_is_no_tab_stop() {
            verify(!single.activeFocusOnTab, "a switcher with one page is a Tab stop that does nothing")
        }

        function flickOf(item) {   // the switcher's own scroller
            for (let i = 0; i < item.children.length; i++) {
                const c = item.children[i]
                if (c.contentY !== undefined && c.interactive !== undefined) return c
            }
            return null
        }

        function test_090_a_selection_moved_by_the_keyboard_stays_in_view() {
            const f = flickOf(shortV)
            verify(f !== null, "no scroller inside the vertical switcher")
            verify(f.interactive, "eight rows in 120 px did not scroll — the fixture proves nothing")
            compare(f.contentY, 0, "the column opened scrolled")
            shortV.forceActiveFocus()
            keyClick(Qt.Key_End)
            compare(shortV.currentPage, "h")
            tryVerify(function () { return f.contentY > 0 }, 1000, "End chose the last row but left it out of view")
            keyClick(Qt.Key_Home)
            tryCompare(f, "contentY", 0, 1000, "Home chose the first row but left it out of view")
        }

        function test_080_a_click_chooses_without_taking_focus() {
            mouseClick(h, h.width * 3 / 8, h.height / 2)        // the second of four slots
            compare(h.currentPage, "b")
            verify(!h.activeFocus, "a pointer click gave the tab list focus (and so a ring)")
        }
    }
}
