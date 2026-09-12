import QtQuick
import "../../"

// A heading between groups in the Agent Center.
//
// `height: visible ? … : 0` because a Column reserves space for an invisible
// child. Without it, hiding a section leaves its gap behind and the list looks
// like it has lost something.

Item {
    id: heading
    readonly property ThemeSet theme: Theme.setForHeight(Screen.height)   // P1-040: this output's sizes


    property string text: ""
    property bool accent: false

    // Which accent, when accented. Defaults to the palette's own, and is
    // overridden where the group under the heading has ONE state — a heading in
    // the wallpaper's primary above a stack of cards in the `attention` tone
    // reads as two unrelated things stacked on top of each other.
    property color tone: Theme.active

    width: parent ? parent.width : 0
    height: visible ? label.implicitHeight + theme.fs(14) : 0

    Text {
        id: label
        anchors.left: parent.left
        anchors.leftMargin: theme.px(4)
        anchors.bottom: parent.bottom
        anchors.bottomMargin: theme.px(4)
        text: heading.text.toUpperCase()
        color: heading.accent ? heading.tone : Theme.subtext
        font.pixelSize: theme.fs(9)
        font.bold: true
        font.letterSpacing: theme.fs(1)
    }
}
