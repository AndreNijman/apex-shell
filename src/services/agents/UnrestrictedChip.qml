import QtQuick
import QtQuick.Controls
import "../"
import "../../"
import "../../nexus"
import "../../components/controls"

// Always Unrestricted, in the Agents panel's header (§42.1 criterion 9).
//
// It was UnrestrictedBanner there too — a two-line danger card pinned above the
// list. Andre: it should be obvious, but not a gigantic card taking up real
// estate. So it is a chip: the danger colour and the warning glyph make it the
// first thing that reads as wrong on the page, and it takes one line of the
// header instead of a card. What the card said is its tooltip and its
// accessible description, and a click (or Space) opens the Config page that
// carries the toggle. The settings page itself keeps the full banner, beside
// the switch it explains.
ApexPressable {
    id: chip

    readonly property string _explain:
        "Agents started from now on run with no APEX sandbox. They are still not "
        + "root, and secrets stay behind the broker."

    height: theme.px(24)
    width: row.implicitWidth + theme.px(20)
    radius: height / 2
    hitMargin: theme.px(4)
    Accessible.name: "Always Unrestricted is on"
    Accessible.description: chip._explain + " Opens the Agents settings."
    onActivated: {
        Popups.dashboardOpen = false
        NexusState.openAt("agents", Popups.dashboardScreen)
    }

    ToolTip.visible: chip.hovered
    ToolTip.text: chip._explain
    ToolTip.delay: 300

    Rectangle {
        anchors.fill: parent
        radius: chip.radius
        color: Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, chip.hovered ? 0.22 : 0.14)
        Behavior on color { MotionColor { role: "state" } }
    }
    Row {
        id: row
        anchors.centerIn: parent
        spacing: theme.px(6)
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "󰀦"
            font.pixelSize: theme.fs(13)
            color: Theme.danger
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Always Unrestricted"
            font.pixelSize: theme.typeCaption
            font.weight: Font.DemiBold
            color: Theme.danger
        }
    }
    ApexFocusRing { target: chip }
}
