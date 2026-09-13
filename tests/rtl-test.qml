import QtQuick
import QtTest
import "components/config" as Cfg

// ─────────────────────────────────────────────────────────────────────────────
//  rtl-test.qml — does the shipped settings surface MIRROR (roadmap P2-004)?
//
//  The ledger carried "RTL: the image cannot render it" from round 1 to round
//  19. Round 20 measured it and it is false — Arabic, Hebrew, Thai and
//  Devanagari all fall out of the hardcoded JetBrains Mono into image-owned
//  fonts that cover them. What is actually missing is layout, and layout is
//  what this file measures: a real CfgRow, instantiated, mirrored, and the
//  positions read back off the live objects.
//
//  Nothing here looks at a string or a colour. Mirroring is a geometric claim
//  and it is asserted geometrically — except where it is a declaration, and
//  then it is read off the live attached object rather than out of the file.
// ─────────────────────────────────────────────────────────────────────────────
Item {
    width: 600; height: 400

    // The shipped row, with a control handed to it the way every settings page
    // hands one: as a child. CfgRow adopts it into its right-hand slot.
    Cfg.CfgRow {
        id: row
        objectName: "row"
        width: 400; height: 40
        label: "Ambient"
        Rectangle { id: ctl; objectName: "ctl"; width: 30; height: 10 }
    }

    // The shipped scroll container, because the fix this round made to it is a
    // geometric one and has to be measured as such: its lifecycle banner used to
    // sit at `x: 2` — a number LayoutMirroring cannot touch — inside the very
    // component that declares the mirroring.
    Cfg.CfgScroll {
        id: scroll
        objectName: "scroll"
        width: 400; height: 300
        lifecycle: "live"
    }

    // A bare Item with the same child, as the control for everything below: if
    // this one does not move when mirrored, the runner's Qt does not implement
    // LayoutMirroring and every verdict here is about the toolkit, not the row.
    Item {
        id: plain
        width: 200; height: 20
        Rectangle { id: plainKid; width: 40; height: 10; anchors.left: parent.left }
    }

    TestCase {
        name: "rtl"
        when: windowShown

        // ── 0. the engine can mirror at all ──────────────────────────────────
        function test_000_the_engine_mirrors_a_plain_anchor() {
            compare(plainKid.x, 0,
                    "a left-anchored child starts at x=0 before anything is mirrored")
            plain.LayoutMirroring.enabled = true
            plain.LayoutMirroring.childrenInherit = true
            compare(plainKid.x, plain.width - plainKid.width,
                    "with mirroring on, anchors.left resolves to the RIGHT edge")
            plain.LayoutMirroring.enabled = false
            compare(plainKid.x, 0, "and turning it off puts it back")
        }

        // ── 1. the row's switch is the APPLICATION's direction ───────────────
        // Read off the live attached object, not out of the file. A property
        // that is present in the source and never takes effect — bound to
        // something that does not resolve, or overridden by a parent — reads
        // the same to a grep and different here.
        function test_010_the_row_binds_mirroring_to_the_application_direction() {
            compare(row.LayoutMirroring.enabled,
                    Qt.application.layoutDirection === Qt.RightToLeft,
                    "CfgRow mirrors exactly when the application does — not on a "
                    + "setting of its own, and not never")
        }

        // ── 2. childrenInherit, read off the live object ─────────────────────
        // A declaration rather than a geometry, and named as one. The control a
        // page hands the row is adopted into a slot whose own contents anchor
        // themselves; without childrenInherit the row would mirror and
        // everything inside it would not, which looks more broken than no
        // mirroring at all.
        function test_020_the_row_passes_mirroring_down() {
            compare(row.LayoutMirroring.childrenInherit, true,
                    "CfgRow passes mirroring to the control it holds")
        }

        // ── 3. the row really swaps sides when it is mirrored ───────────────
        // Both states are FORCED here, so this function answers "does the row
        // mirror when told to" the same way whatever direction the application
        // happens to be in. The separate question — does it mirror when nobody
        // tells it to — is test_040, and it is the one that needs the suite to
        // run this fixture under an RTL locale.
        //
        // The label box and the control slot are found through the live tree —
        // the row's internal order is not this suite's business and must stay
        // free to change.
        function test_030_a_real_row_swaps_its_label_and_its_control() {
            var slot = ctl.parent
            verify(slot !== null && slot !== row,
                   "the row adopted the control into a slot of its own")
            var box = labelBox()
            verify(box !== null, "the row has a label box to measure")

            row.LayoutMirroring.enabled = false
            var ltrBox = box.x, ltrSlot = slot.x
            row.LayoutMirroring.enabled = true
            var rtlBox = box.x, rtlSlot = slot.x
            restoreBinding()

            verify(ltrBox < ltrSlot,
                   "unmirrored, the label is to the LEFT of the control "
                   + "(label x=" + ltrBox + ", control x=" + ltrSlot + ")")
            verify(rtlBox > rtlSlot,
                   "mirrored, the label is to the RIGHT of the control "
                   + "(label x=" + rtlBox + ", control x=" + rtlSlot + ")")
        }

        // ── 4. and it mirrors WITHOUT BEING TOLD TO ──────────────────────────
        // The one function in this fixture that exercises the binding the
        // product actually ships. Everything above forces LayoutMirroring on by
        // hand, so all of it passes over a row hardcoded to `enabled: false` —
        // which is exactly the mutant R1, and it survived the first harness run
        // for precisely this reason.
        //
        // Nothing is set here. The row is read as the engine left it, and the
        // side the label sits on must match the application's direction. The
        // suite runs this fixture TWICE, once with the locale scrubbed and once
        // under an RTL locale with the image's platform theme, so this function
        // is load-bearing in the second pass and a control in the first.
        function test_040_the_row_mirrors_without_being_told_to() {
            var rtl = Qt.application.layoutDirection === Qt.RightToLeft
            var slot = ctl.parent, box = labelBox()
            verify(box !== null, "the row has a label box to measure")
            var where = "(direction=" + Qt.application.layoutDirection
                      + ", label x=" + box.x + ", control x=" + slot.x + ")"
            if (rtl)
                verify(box.x > slot.x,
                       "the application is RightToLeft and nothing was set by "
                       + "hand, so the shipped row must already be mirrored " + where)
            else
                verify(box.x < slot.x,
                       "the application is LeftToRight and nothing was set by "
                       + "hand, so the shipped row must NOT be mirrored " + where)
        }

        // ── 5. the scroll container's banner follows the reading direction ──
        // The one site in the mirrored surface that was a BARE LEFT INSET: 2px
        // from the left against 12px from the right, so under mirroring it kept
        // its 2px on the wrong side while everything around it moved. It is an
        // anchor now, and this is the assertion that says so in numbers rather
        // than in a grep for the word `anchors`.
        function test_050_the_banner_inset_follows_the_reading_direction() {
            var b = bannerOf(scroll)
            verify(b !== null, "the scroll container has a lifecycle banner")
            verify(b.width > 0 && b.width < scroll.width,
                   "the banner is narrower than the container, so its two insets "
                   + "are not the same number (width=" + b.width + ")")

            scroll.LayoutMirroring.enabled = false
            var ltrX = b.x
            scroll.LayoutMirroring.enabled = true
            var rtlX = b.x
            scroll.LayoutMirroring.enabled = Qt.binding(function () {
                return Qt.application.layoutDirection === Qt.RightToLeft
            })

            compare(ltrX, 2, "unmirrored the banner keeps its 2px inset on the left")
            compare(rtlX, scroll.width - 2 - b.width,
                    "mirrored, the 2px inset is on the RIGHT — x moves to "
                    + (scroll.width - 2 - b.width) + ", not " + ltrX)
        }

        // The direct child of the scroll container that carries a lifecycle.
        function bannerOf(node) {
            for (var i = 0; i < node.children.length; i++)
                if (node.children[i].lifecycle !== undefined)
                    return node.children[i]
            return null
        }

        function restoreBinding() {
            row.LayoutMirroring.enabled = Qt.binding(function () {
                return Qt.application.layoutDirection === Qt.RightToLeft
            })
        }

        // The direct child of the row that CONTAINS the label text. The Text
        // itself sits at x=0 inside its own column, so measuring it would read
        // zero whatever the row does — which is exactly the false green this
        // function exists to avoid.
        function labelBox() {
            for (var i = 0; i < row.children.length; i++)
                if (containsText(row.children[i], row.label))
                    return row.children[i]
            return null
        }

        function containsText(node, want) {
            if (node.text !== undefined && node.text === want)
                return true
            for (var i = 0; i < node.children.length; i++)
                if (containsText(node.children[i], want))
                    return true
            return false
        }
    }
}
