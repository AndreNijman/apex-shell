import QtQuick
import "../../"
import "../../components"

// Power Profile panel — 5 named tiers (Ultra Max … Power Saver), backed by
// PowerProfileService. The GPU Mode (envycontrol Integrated/Hybrid) selector was
// removed: this machine has only the Radeon 780M iGPU, no NVIDIA dGPU.
Item {
    id: root

    required property var powerProfileService

    Column {
        anchors.centerIn: parent
        spacing:          12

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text:           "Power Profile"
            font.pixelSize: 11
            font.weight:    Font.Medium
            color:          Qt.rgba(1, 1, 1, 0.4)
        }

        Column {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 6

            Repeater {
                model: root.powerProfileService.profiles

                ProfileButton {
                    required property var modelData
                    label:     modelData.label
                    active:    root.powerProfileService.current === modelData.id
                    enabled:   true
                    onClicked: root.powerProfileService.setProfile(modelData.id)
                }
            }
        }
    }
}
