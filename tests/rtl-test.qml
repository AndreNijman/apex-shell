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

        // ── 3. the load-bearing one: the row really swaps sides ──────────────
        // Measured on ONE instance, before and after, so the pair isolates
        // mirroring from every other reason two rows could lay out differently.
        // The label box and the control slot are found through the live tree —
        // the row's internal order is not this suite's business and must stay
        // free to change.
        function test_030_a_real_row_swaps_its_label_and_its_control() {
            var slot = ctl.parent
            verify(slot !== null && slot !== row,
                   "the row adopted the control into a slot of its own")
            var box = labelBox()
            verify(box !== null, "the row has a label box to measure")

            var wasBox = box.x, wasSlot = slot.x
            verify(wasBox < wasSlot,
                   "unmirrored, the label is to the LEFT of the control "
                   + "(label x=" + wasBox + ", control x=" + wasSlot + ")")

            row.LayoutMirroring.enabled = true
            var nowBox = box.x, nowSlot = slot.x
            row.LayoutMirroring.enabled = Qt.binding(function () {
                return Qt.application.layoutDirection === Qt.RightToLeft
            })

            verify(nowBox > nowSlot,
                   "mirrored, the label is to the RIGHT of the control "
                   + "(label x=" + nowBox + ", control x=" + nowSlot + ")")
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
