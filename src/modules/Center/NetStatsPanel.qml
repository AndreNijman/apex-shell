import QtQuick
import "../../"
import "../../components"

Item {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    required property var service

    Column {
        anchors.centerIn: parent
        width:            parent.width - 16
        spacing:          10

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text:           "Network"
            font.pixelSize: theme.fs(11)
            font.weight:    Font.Medium
            color:          Qt.rgba(1, 1, 1, 0.4)
        }

        Column {
            width:   parent.width
            spacing: 6

            StatRow {
                width:      parent.width
                label:      "Interface"
                value:      root.service.iface
            }

            StatRow {
                width:      parent.width
                label:      "↑ Upload"
                value:      root.service.upSpeed
                valueColor: Theme.success
            }

            StatRow {
                width:      parent.width
                label:      "↓ Download"
                value:      root.service.downSpeed
                valueColor: Theme.active
            }
        }
    }
}
