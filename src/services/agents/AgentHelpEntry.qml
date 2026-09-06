import QtQuick
import "../../"

// The permanent way into the guide, pinned above the Agents list (roadmap §43).
//
// §43 asks for a prominent entry that does not get in the way, which pulls in
// two directions. The accent glyph and the accent-tinted border make it the
// first thing the eye lands on; one row of height and no dismiss control keep
// it out of the way. A banner the user has to close on every visit would fail
// the second half, which is what the separate first-run card is for.

Rectangle {
    id: entry

    height: Theme.px(32)
    radius: Theme.px(8)
    color: hover.hovered
        ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.16)
        : Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.08)
    border.width: 1
    border.color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.28)

    Behavior on color { ColorAnimation { duration: 90 } }

    // The row exists only once the Agents page has been built, so this line in
    // the log means "a user opening the tab saw the way in". §43's requirement
    // is that the entry survives dismissing the first-run card, and
    // tests/run-agent-center-smoke.sh reads this before and after a dismissal.
    Component.onCompleted: console.info("AgentHelp: entry row shown")

    Row {
        anchors.left: parent.left
        anchors.leftMargin: Theme.px(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.px(9)

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "󰋗"
            font.pixelSize: Theme.fs(13)
            color: Theme.active
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: AgentHelpContent.entryLabel
            font.pixelSize: Theme.fs(11)
            color: Theme.text
        }
    }

    Text {
        anchors.right: parent.right
        anchors.rightMargin: Theme.px(11)
        anchors.verticalCenter: parent.verticalCenter
        text: "󰅂"
        font.pixelSize: Theme.fs(12)
        color: hover.hovered ? Theme.text : Theme.subtext
    }

    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: AgentHelp.open("start") }
}
