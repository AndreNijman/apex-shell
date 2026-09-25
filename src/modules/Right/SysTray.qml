import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.SystemTray
import "../../components"
import "../../"

RowLayout {
    id: root

    readonly property bool hasItems: SystemTray.items.values.length > 0
    visible: hasItems
    spacing: 2

    RowLayout {
        id: trayRow
        Layout.alignment: Qt.AlignVCenter
        property bool isOpen: false

        visible: opacity > 0
        opacity: isOpen ? 1 : 0
        Layout.preferredWidth: isOpen ? implicitWidth : 0
        clip: true
        spacing: 2

        Behavior on opacity { NumberAnimation { duration: Theme.animDuration; easing.type: Easing.OutCubic } }
        Behavior on Layout.preferredWidth { NumberAnimation { duration: Theme.animDuration; easing.type: Easing.OutCubic } }

        Repeater {
            model: SystemTray.items
            delegate: MouseArea {
                id: trayItem

                required property var modelData

                width: 26
                height: 26
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton

                Rectangle {
                    anchors.fill: parent
                    radius: 6
                    color: trayItem.containsMouse ? Qt.rgba(1, 1, 1, 0.1) : "transparent"
                    Behavior on color { ColorAnimation { duration: 120 } }

                    Image {
                        width: 16
                        height: 16
                        anchors.centerIn: parent
                        source: trayItem.modelData.icon
                        sourceSize.width: 16
                        sourceSize.height: 16
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                    }
                }

                // A press hides the label until the pointer leaves, so it is
                // not left standing next to the menu the press opened.
                property bool tipSuppressed: false
                onPressed: tipSuppressed = true
                onExited: tipSuppressed = false

                BarTooltip {
                    target: trayItem
                    text: trayItem.modelData.tooltipTitle || trayItem.modelData.title || trayItem.modelData.id || ""
                    shown: trayItem.containsMouse && !trayItem.tipSuppressed && !trayMenu.visible
                }

                onClicked: (mouse) => {
                    if (mouse.button === Qt.MiddleButton) {
                        modelData.secondaryActivate()
                    } else if (mouse.button === Qt.RightButton || modelData.onlyMenu) {
                        if (modelData.hasMenu) trayMenu.toggle()
                    } else {
                        modelData.activate()
                    }
                }

                onWheel: (wheel) => {
                    const horizontal = Math.abs(wheel.angleDelta.x) > Math.abs(wheel.angleDelta.y)
                    const delta = horizontal ? wheel.angleDelta.x : wheel.angleDelta.y
                    modelData.scroll(delta, horizontal)
                    wheel.accepted = true
                }

                TrayMenu {
                    id: trayMenu
                    target: trayItem
                    menu: trayItem.modelData.menu
                }
            }
        }
    }

    IconBtn {
        Layout.alignment: Qt.AlignVCenter
        text: trayRow.isOpen ? "󰅀" : "•••"
        onClicked: trayRow.isOpen = !trayRow.isOpen
    }
}
