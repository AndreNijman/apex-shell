import QtQuick
import "../../"

// First-run guidance, shown until the user says otherwise (roadmap §43).
//
// It sits below the permanent entry row and above the session list, so a user
// who already knows the runtime scrolls past one card once and then has their
// list back for good. Dismissal is a file, not a session flag: see AgentHelp.
//
// The card announces itself to the log on construction, and AgentHelp logs the
// dismissal. tests/run-agent-center-smoke.sh reads both, which is how it can
// tell "the card was drawn" from "the page rendered without errors".

Rectangle {
    id: card
    readonly property ThemeSet theme: Theme.setForHeight(Screen.height)   // P1-040: this output's sizes


    // A Column reserves space for an invisible child, so the collapse has to be
    // a height of zero. Same trap as the notes in AgentCenter.
    visible: AgentHelp.showOnboarding
    height: visible ? column.implicitHeight + theme.px(24) : 0
    radius: theme.px(8)
    color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.05)
    border.width: 1
    border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.09)

    // Announced when it becomes visible, not when it is constructed. The card
    // exists as soon as the page is built and is invisible until AgentHelp has
    // read its state file, so a Component.onCompleted log would claim the card
    // was shown to somebody who dismissed it months ago.
    function _announce() {
        if (card.visible) console.info("AgentHelp: first-run card shown")
    }
    onVisibleChanged: card._announce()
    Component.onCompleted: card._announce()

    Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: theme.px(12)
        spacing: theme.px(7)

        Text {
            text: AgentHelpContent.cardTitle
            color: Theme.text
            font.pixelSize: theme.fs(12)
            font.bold: true
        }

        Text {
            width: parent.width
            text: AgentHelpContent.cardBody
            color: Theme.subtext
            font.pixelSize: theme.fs(10)
            lineHeight: 1.35
            wrapMode: Text.WordWrap
        }

        Item { width: 1; height: theme.px(2) }

        Row {
            spacing: theme.px(8)

            Rectangle {
                id: readBtn
                width: readLabel.implicitWidth + theme.px(20)
                height: theme.px(26)
                radius: theme.px(6)
                color: readHover.hovered
                    ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.35)
                    : Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.20)

                Behavior on color { ColorAnimation { duration: 90 } }

                Text {
                    id: readLabel
                    anchors.centerIn: parent
                    text: AgentHelpContent.cardRead
                    color: Theme.text
                    font.pixelSize: theme.fs(10)
                }

                HoverHandler { id: readHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: AgentHelp.open("start") }
            }

            // Dismissal is permanent and takes no confirmation. Getting the
            // card back is one IPC call, documented in the guide's own
            // "Keys and commands" section, so the worst case is recoverable.
            Rectangle {
                id: gotItBtn
                width: gotItLabel.implicitWidth + theme.px(20)
                height: theme.px(26)
                radius: theme.px(6)
                color: gotItHover.hovered
                    ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.14)
                    : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.06)

                Behavior on color { ColorAnimation { duration: 90 } }

                Text {
                    id: gotItLabel
                    anchors.centerIn: parent
                    text: AgentHelpContent.cardDismiss
                    color: Theme.subtext
                    font.pixelSize: theme.fs(10)
                }

                HoverHandler { id: gotItHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: AgentHelp.dismissOnboarding() }
            }
        }
    }
}
