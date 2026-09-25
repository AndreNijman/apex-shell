import QtQuick
import "../"
import "controls"

// A power-profile pill. Built on ApexPressable (UI/UX roadmap v3 Phase 3): it
// dips when pressed, by pointer or keyboard, and its hover is a state layer.
ApexPressable {
    id: root

    property string label:   ""
    property string icon:    ""
    property bool   active:  false

    signal clicked()

    implicitWidth:  row.implicitWidth + 24
    implicitHeight: theme.controlCompact
    radius: height / 2
    interactive: root.enabled
    Accessible.name: root.label
    Accessible.checkable: true
    Accessible.checked: root.active
    onActivated: root.clicked()

    Rectangle {
        anchors.fill: parent
        radius:       root.radius

        color: root.active ? Theme.active : root.stateLayer()
        border.color: root.active ? Theme.active : Theme.outlineStrong
        border.width: 1

        Behavior on color        { MotionColor { role: "state" } }
        Behavior on border.color { MotionColor { role: "state" } }
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 5

        Text {
            visible:        root.icon !== ""
            text:           root.icon
            font.pixelSize: theme.fs(12)
            color:          root.active ? Theme.onAccent : Theme.textPrimary
            anchors.verticalCenter: parent.verticalCenter
            Behavior on color { MotionColor { role: "state" } }
        }

        Text {
            text:           root.label
            font.pixelSize: theme.fs(11)
            font.weight:    root.active ? Font.Medium : Font.Normal
            color:          root.active ? Theme.onAccent : Theme.textPrimary
            anchors.verticalCenter: parent.verticalCenter
            Behavior on color { MotionColor { role: "state" } }
        }
    }
    ApexFocusRing { target: root }
}
