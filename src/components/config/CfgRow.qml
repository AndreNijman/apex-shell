import QtQuick
import "../../"
import "settings-semantics.js" as Semantics

// A settings row: label (+ optional description) on the left, a control on the
// right. Put the control as a child — it is placed in the right-hand slot.
Item {
    id: root
    property string label:       ""
    property string description: ""
    property bool   hoverable:   true

    // When this particular control reaches the machine, if it is not now. One
    // of settings-semantics.js's EFFECTS: "relogin", "reboot", "apply",
    // "reload". The default "now" renders nothing on purpose — a page that
    // stamps "takes effect immediately" on every row has taught the reader to
    // skip the one line that matters (roadmap P0-023, criterion 1).
    property string effect: ""

    readonly property string _effectNote: Semantics.effectNote(root.effect)

    default property alias control: slot.data

    width: parent ? parent.width : 0

    // As tall as what it holds, with a floor.
    //
    // This used to be two constants — 56 with a description, 44 without —
    // chosen for how tall two lines are at scale 1.0. The text inside is sized
    // with Theme.fs(), which scales; the row was not, so from 1.5x upward every
    // row with a description drew its second line outside itself. Nothing
    // noticed, because a clipped line is not an error: the row's own rectangle
    // is right, its neighbours are right, and the sentence is simply gone.
    // tests/nav-geometry-test.qml's page block found 34 of them on the first
    // run that graded a page.
    //
    // The control is in the maximum too: a taller one than the text beside it
    // would have hung out of the bottom the same way.
    implicitHeight: Math.max(44, texts.implicitHeight + 14, slot.height + 12)
    height:         implicitHeight

    Rectangle {
        anchors.fill: parent
        radius:       8
        color:        (root.hoverable && hov.hovered) ? Qt.rgba(1,1,1,0.03) : "transparent"
        Behavior on color { ColorAnimation { duration: 120 } }
    }
    HoverHandler { id: hov; enabled: root.hoverable }

    Column {
        id: texts
        anchors.left:           parent.left
        anchors.leftMargin:     10
        anchors.right:          slot.left
        anchors.rightMargin:    12
        anchors.verticalCenter: parent.verticalCenter
        spacing: 3

        Text {
            width:          parent.width
            text:           root.label
            font.pixelSize: Theme.fs(12)
            color:          Qt.rgba(1,1,1,0.75)
            elide:          Text.ElideRight
        }
        Text {
            width:          parent.width
            visible:        root.description !== ""
            text:           root.description
            font.pixelSize: Theme.fs(10)
            color:          Qt.rgba(1,1,1,0.38)
            wrapMode:       Text.WordWrap
            maximumLineCount: 2
            elide:          Text.ElideRight
        }
        Text {
            width:          parent.width
            visible:        root._effectNote !== ""
            text:           root._effectNote
            font.pixelSize: Theme.fs(10)
            color:          Theme.info
            wrapMode:       Text.WordWrap
            maximumLineCount: 2
            elide:          Text.ElideRight
        }
    }

    Item {
        id: slot
        anchors.right:          parent.right
        anchors.rightMargin:    8
        anchors.verticalCenter: parent.verticalCenter
        width:  childrenRect.width
        height: childrenRect.height
    }
}
