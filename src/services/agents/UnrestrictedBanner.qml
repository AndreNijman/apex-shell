import QtQuick
import "../"
import "../../"

// The indicator §42.1 criterion 9 asks for: something visible, wherever agents
// are, for as long as Always Unrestricted is on.
//
// ── ONE COMPONENT, TWO SURFACES ─────────────────────────────────────────────
//
// It is drawn in the Agent Center, above the session list, and on the settings
// page that owns the switch. Two copies of the sentence would have been two
// sentences within a week, and this one has to stay exact: it names what the
// setting removed, and it must not imply anything it did not.
//
// Both surfaces bind `visible` to the same AgentPolicyService property the
// toggle does, so the banner cannot outlive the setting or lag behind it.
//
// ── WHY NOT THE BAR ─────────────────────────────────────────────────────────
//
// The top bar is shared chrome, and a persistent red mark there is a decision
// about the whole shell rather than about agents. The Agent Center is where a
// user looks to find out what agents are doing, and the settings page is where
// they are standing when they change it — the two places the fact is load-
// bearing. If §42.1 later wants it in the bar, the copy is already in one file.

Rectangle {
    id: banner
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    // Drops the second line, for a surface that has already said the rest.
    property bool compact: false

    radius:       theme.px(8)
    color:        Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.08)
    border.width: Math.max(1, theme.px(1))
    border.color: Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.35)

    implicitHeight: content.implicitHeight + theme.px(16)
    height: implicitHeight

    Row {
        id: content
        anchors.left:           parent.left
        anchors.right:          parent.right
        anchors.leftMargin:     theme.px(10)
        anchors.rightMargin:    theme.px(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: theme.px(9)

        Text {
            id: mark
            text:           "󰀦"
            font.pixelSize: theme.fs(15)
            color:          Theme.danger
        }

        Column {
            width: parent.width - mark.width - content.spacing
            spacing: theme.px(2)

            Text {
                width:          parent.width
                text:           "Always Unrestricted is on"
                font.pixelSize: theme.fs(11)
                font.bold:      true
                color:          Theme.danger
                wrapMode:       Text.WordWrap
            }
            Text {
                width:   parent.width
                visible: !banner.compact
                // What it did and what it did not do, one line each. The second
                // half is the part that has to survive editing: the sandbox is
                // gone and nothing else moved, which is what apex-agent-core's
                // invariants assert and the most this may claim.
                text: "Agents started from now on run with no APEX sandbox. They are "
                    + "still not root, and secrets stay behind the broker."
                font.pixelSize: theme.fs(10)
                color:          Theme.subtext
                wrapMode:       Text.WordWrap
            }
        }
    }
}
