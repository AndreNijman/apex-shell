import QtQuick
import "../../"

// A heading between groups in the Agent Center.
//
// `height: visible ? … : 0` because a Column reserves space for an invisible
// child. Without it, hiding a section leaves its gap behind and the list looks
// like it has lost something.

Item {
    id: heading

    property string text: ""
    property bool accent: false

    width: parent ? parent.width : 0
    height: visible ? label.implicitHeight + Theme.fs(14) : 0

    Text {
        id: label
        anchors.left: parent.left
        anchors.leftMargin: Theme.px(4)
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.px(4)
        text: heading.text.toUpperCase()
        color: heading.accent ? Theme.active : Theme.subtext
        font.pixelSize: Theme.fs(9)
        font.bold: true
        font.letterSpacing: Theme.fs(1)
    }
}
