import QtQuick
import "../"
import "controls"

// A power-profile choice. Built on ApexPressable (UI/UX roadmap v3 Phase 3): it
// dips when pressed, by pointer or keyboard, and its hover is a state layer.
//
// One of three choices shown side by side, so "chosen" has to read against the
// other two (UI/UX Phase 17 review): the accent container with its own text,
// the Home tiles' "on", and the one action style for the rest; no border,
// radiusS. Not surfaceSelected: beside surfaceHigh buttons it differs by hue
// alone (roles.js, surfaceOnSelected) and on the light palette the chosen one
// read paler than the others — like a disabled button. It was a pill in an
// outlineStrong border, flooded with the accent when chosen.
ApexPressable {
    id: root

    property string label:   ""
    property string icon:    ""
    property bool   active:  false

    signal clicked()

    implicitWidth:  row.implicitWidth + 24
    implicitHeight: theme.controlStandard
    radius: theme.radiusS
    interactive: root.enabled
    Accessible.name: root.label
    Accessible.checkable: true
    Accessible.checked: root.active
    onActivated: root.clicked()

    Rectangle {
        anchors.fill: parent
        radius:       root.radius

        color: root.tint(root.active ? Theme.accentContainer : Theme.surfaceHigh)
        Behavior on color { MotionColor { role: "state" } }
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 5

        Text {
            visible:        root.icon !== ""
            text:           root.icon
            font.pixelSize: theme.fs(12)
            color:          root.active ? Theme.textOnAccentContainer : Theme.iconDefault
            anchors.verticalCenter: parent.verticalCenter
            Behavior on color { MotionColor { role: "state" } }
        }

        Text {
            text:           root.label
            font.pixelSize: theme.typeCaption
            font.weight:    Font.Medium
            color:          root.active ? Theme.textOnAccentContainer : Theme.textPrimary
            anchors.verticalCenter: parent.verticalCenter
            Behavior on color { MotionColor { role: "state" } }
        }
    }
    ApexFocusRing { target: root }
}
