import QtQuick
import "../../"
import "../../components/controls"

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
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes

    // Fired after a dismissal from the keyboard. The card's own two buttons go
    // with it — `visible` collapses the instant AgentHelp.showOnboarding does —
    // so the page puts the keys somewhere sensible instead of nowhere (UI/UX
    // roadmap v3 Phase 21). A click dismisses and moves nothing.
    signal dismissedByKey()

    // A Column reserves space for an invisible child, so the collapse has to be
    // a height of zero. Same trap as the notes in AgentCenter.
    visible: AgentHelp.showOnboarding
    height: visible ? column.implicitHeight + theme.px(24) : 0
    // A card is a surface, not a box (UI/UX Phase 17, StatCard's rule): the
    // raised surface, no border. It was a .05 fill inside a .09 border, 10 px
    // body text, and a primary button flooded with the accent.
    radius: theme.radiusL
    color: Theme.surfaceRaised

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
            color: Theme.textPrimary
            font.family: Theme.fontUi
            font.pixelSize: theme.typeBodyStrong
            font.weight: Font.DemiBold
        }

        Text {
            width: parent.width
            text: AgentHelpContent.cardBody
            color: Theme.textSecondary
            font.family: Theme.fontUi
            font.pixelSize: theme.typeBodySmall
            lineHeight: 1.3
            wrapMode: Text.WordWrap
        }

        Item { width: 1; height: theme.px(2) }

        Row {
            spacing: theme.px(8)

            // ApexPressable (UI/UX roadmap v3 Phase 21): was a bare
            // Rectangle/HoverHandler/TapHandler pair with no keyboard path.
            ApexPressable {
                id: readBtn
                // The one action style (UI/UX Phase 17), on the card's raised
                // surface one step up.
                width: readLabel.implicitWidth + theme.px(24)
                height: theme.controlStandard
                radius: theme.radiusS
                Accessible.name: AgentHelpContent.cardRead
                onActivated: AgentHelp.open("start")

                Rectangle {
                    anchors.fill: parent; radius: parent.radius
                    color: readBtn.tint(Theme.surfaceHigh)
                    Behavior on color { MotionColor {} }
                }

                Text {
                    id: readLabel
                    anchors.centerIn: parent
                    text: AgentHelpContent.cardRead
                    color: Theme.textPrimary
                    font.pixelSize: theme.typeCaption
                    font.weight: Font.Medium
                }

                ApexFocusRing { target: readBtn }
            }

            // Dismissal is permanent and takes no confirmation. Getting the
            // card back is one IPC call, documented in the guide's own
            // "Keys and commands" section, so the worst case is recoverable.
            ApexPressable {
                id: gotItBtn
                // The quieter of the two: a text button, the state layer only.
                width: gotItLabel.implicitWidth + theme.px(24)
                height: theme.controlStandard
                radius: theme.radiusS
                Accessible.name: AgentHelpContent.cardDismiss
                // The card (and this button with it) disappears the instant
                // this runs, so the keys go to wherever the caller decides —
                // AgentCenter sends them back to the permanent entry row.
                onActivated: {
                    const byKey = gotItBtn.focusVisible   // read before the card hides
                    AgentHelp.dismissOnboarding()
                    if (byKey) card.dismissedByKey()
                }

                Rectangle {
                    anchors.fill: parent; radius: parent.radius
                    color: gotItBtn.stateLayer()
                    Behavior on color { MotionColor {} }
                }

                Text {
                    id: gotItLabel
                    anchors.centerIn: parent
                    text: AgentHelpContent.cardDismiss
                    color: gotItBtn.hovered ? Theme.textPrimary : Theme.textSecondary
                    font.pixelSize: theme.typeCaption
                    font.weight: Font.Medium
                }

                ApexFocusRing { target: gotItBtn }
            }
        }
    }
}
