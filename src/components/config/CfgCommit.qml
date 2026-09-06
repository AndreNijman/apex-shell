import QtQuick
import "../../"
import "settings-semantics.js" as Semantics

// The bar a page shows while it is holding changes the machine has not seen
// (roadmap P0-023, criteria 2, 3 and 4).
//
// ── One bar, because three pages had three ways out ─────────────────────────
//
// Display offered Apply / Save / a button labelled Revert on a row labelled
// Discard. Blueprint offered Save / a button labelled Revert on a row labelled
// Discard, with Apply somewhere further down the page. Keybinds offered a
// button labelled Save that wrote the file AND reloaded the compositor, next to
// one labelled Discard. Three pages, three orders, two words for putting the
// draft back and two meanings for Save.
//
// So the words, the order and the sentence above them come from here, and the
// page supplies only what is true about itself: how many changes it holds, what
// it calls them, which of the three acts it can actually perform, and one
// sentence of its own if the general one is not enough.
//
// ── Why Revert is on the left and Apply on the right ────────────────────────
//
// Reading order, and the cost of a mis-click. The rightmost button is the one
// under the thumb and the one a user reaches for without looking; it should be
// the one that does what they came here to do. Throwing the draft away sits at
// the far end of the row from it.
//
// ── Why a failed act does not clear the bar ─────────────────────────────────
//
// `error` renders in place of the hint and the staged count stays exactly as it
// was. That is criterion 4: a refused write must leave the user's intent where
// they can press the button again, and this bar is where they can see that it
// is still there. A page that clears its draft and then reports a failure has
// told the user about work it already destroyed.
Item {
    id: root

    // How many changes are held, and what this page calls one of them.
    property int    count: 0
    property string noun:  "change"

    // Which acts this page can honestly perform. A page where persisting and
    // taking effect are the same write offers Apply alone — see
    // settings-semantics.js's APPLY_IS_ALSO_SAVE — and says so through
    // `note` rather than by growing a second button for one act.
    property bool canApply:  false
    property bool canSave:   false
    property bool canRevert: true

    // True while an act is in flight. Every button goes inert; the one that is
    // working says so.
    property bool busy: false

    // Non-empty when the last act was refused. Replaces the hint.
    property string error: ""

    // One page-specific sentence, shown under the hint. For what only this page
    // knows: which files a Save writes, how long a countdown runs.
    property string note: ""

    signal applyRequested()
    signal saveRequested()
    signal revertRequested()

    readonly property bool held: root.count > 0

    width: parent ? parent.width : 0
    visible: root.held
    implicitHeight: root.held
                    ? Math.max(Theme.px(46), lines.implicitHeight + Theme.px(16))
                    : 0
    height: implicitHeight
    clip: true
    Behavior on implicitHeight { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

    readonly property color _tone: root.error !== "" ? Theme.danger : Theme.warning

    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: 10
        anchors.rightMargin: 2
        radius: 8
        color: Qt.rgba(root._tone.r, root._tone.g, root._tone.b, 0.07)
        border.color: Qt.rgba(root._tone.r, root._tone.g, root._tone.b, 0.20)
        border.width: 1
        Behavior on color { ColorAnimation { duration: 140 } }
        Behavior on border.color { ColorAnimation { duration: 140 } }

        Column {
            id: lines
            anchors {
                left: parent.left
                right: buttons.left
                verticalCenter: parent.verticalCenter
                leftMargin: 12
                rightMargin: 12
            }
            spacing: 2

            Text {
                width: parent.width
                text: Semantics.stagedLine(root.count, root.noun)
                font.pixelSize: Theme.fs(11)
                font.weight: Font.Medium
                color: root._tone
                elide: Text.ElideRight
            }
            Text {
                width: parent.width
                text: root.error !== ""
                      ? root.error
                      : Semantics.stagedHint(root.canApply, root.canSave)
                font.pixelSize: Theme.fs(10)
                color: root.error !== "" ? Theme.danger : Theme.subtext
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }
            Text {
                width: parent.width
                visible: root.note !== "" && root.error === ""
                text: root.note
                font.pixelSize: Theme.fs(10)
                color: Theme.subtext
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }
        }

        Row {
            id: buttons
            anchors {
                right: parent.right
                verticalCenter: parent.verticalCenter
                rightMargin: 10
            }
            spacing: 6

            CfgButton {
                visible: root.canRevert
                label:   Semantics.verbLabel("revert")
                enabled: !root.busy
                onClicked: root.revertRequested()
            }
            CfgButton {
                visible: root.canSave
                // Only one button says it is working, and it is the one that
                // is: where a page offers both, `busy` belongs to Apply.
                label:   (root.busy && !root.canApply)
                         ? "Saving…" : Semantics.verbLabel("save")
                enabled: !root.busy
                onClicked: root.saveRequested()
            }
            CfgButton {
                visible: root.canApply
                variant: "accent"
                label:   root.busy ? "Applying…" : Semantics.verbLabel("apply")
                enabled: !root.busy
                onClicked: root.applyRequested()
            }
        }
    }
}
