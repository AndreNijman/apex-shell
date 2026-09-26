import QtQuick
import "../../"
import "../../components/controls"

// A heading between groups in the Agent Center.
//
// `height: visible ? … : 0` because a Column reserves space for an invisible
// child. Without it, hiding a section leaves its gap behind and the list looks
// like it has lost something.

Item {
    id: heading
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    property string text: ""
    property bool accent: false

    // Which accent, when accented. Defaults to the palette's own, and is
    // overridden where the group under the heading has ONE state — a heading in
    // the wallpaper's primary above a stack of cards in the `attention` tone
    // reads as two unrelated things stacked on top of each other.
    property color tone: Theme.active

    // An optional action at the right-hand end, e.g. "Clear finished". Empty
    // means none, so every existing heading is unchanged.
    property string actionText: ""
    signal action()

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

    // ApexPressable (UI/UX roadmap v3 Phase 21): was a Text with a
    // HoverHandler/TapHandler pair and no keyboard path. Only a Tab stop when
    // there is an action at all — every heading with no `actionText` is
    // unchanged. No background of its own, so the row still reads as a plain
    // underlined label at rest and on hover; the ring is the only new mark.
    ApexPressable {
        id: actionBtn
        visible: heading.actionText !== ""
        anchors.right: parent.right
        anchors.rightMargin: heading.theme.px(6)
        anchors.bottom: parent.bottom
        anchors.bottomMargin: heading.theme.px(4)
        width: actionLabel.implicitWidth
        height: actionLabel.implicitHeight
        hitMargin: heading.theme.px(4)
        Accessible.name: heading.actionText
        onActivated: heading.action()

        Text {
            id: actionLabel
            anchors.fill: parent
            text: heading.actionText
            color: actionBtn.hovered ? Theme.text : Theme.subtext
            font.pixelSize: heading.theme.fs(10)
            font.underline: actionBtn.hovered
        }

        ApexFocusRing { target: actionBtn }
    }
}
