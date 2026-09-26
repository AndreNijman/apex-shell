import QtQuick
import "../../"
import "../../components/controls"

// The permanent way into the guide, pinned above the Agents list (roadmap §43).
//
// §43 asks for a prominent entry that does not get in the way, which pulls in
// two directions. The accent glyph and the accent-tinted border make it the
// first thing the eye lands on; one row of height and no dismiss control keep
// it out of the way. A banner the user has to close on every visit would fail
// the second half, which is what the separate first-run card is for.
//
// ApexPressable root (UI/UX roadmap v3 Phase 21): the whole row was a
// HoverHandler/TapHandler pair with no keyboard path at all. Now it is one Tab
// stop, Space/Return open the guide, and the ring is keyboard-only.

ApexPressable {
    id: entry

    height: theme.px(32)
    radius: theme.px(8)
    Accessible.name: AgentHelpContent.entryLabel
    onActivated: AgentHelp.open("start")

    // The row exists only once the Agents page has been built, so this line in
    // the log means "a user opening the tab saw the way in". §43's requirement
    // is that the entry survives dismissing the first-run card, and
    // tests/run-agent-center-smoke.sh reads this before and after a dismissal.
    Component.onCompleted: console.info("AgentHelp: entry row shown")

    Rectangle {
        anchors.fill: parent
        radius: entry.radius
        color: entry.hovered
            ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.16)
            : Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.08)
        border.width: 1
        border.color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.28)

        Behavior on color { MotionColor {} }
    }

    Row {
        anchors.left: parent.left
        anchors.leftMargin: theme.px(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: theme.px(9)

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "󰋗"
            font.pixelSize: theme.fs(13)
            color: Theme.active
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: AgentHelpContent.entryLabel
            font.pixelSize: theme.fs(11)
            color: Theme.text
        }
    }

    Text {
        anchors.right: parent.right
        anchors.rightMargin: theme.px(11)
        anchors.verticalCenter: parent.verticalCenter
        text: "󰅂"
        font.pixelSize: theme.fs(12)
        color: entry.hovered ? Theme.text : Theme.subtext
    }

    ApexFocusRing { target: entry }
}
