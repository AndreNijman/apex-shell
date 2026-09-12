import QtQuick
import "../"
import "../components"

// NavPane — the page list down the left of the Nexus window.
//
// Built from PageRegistry, so it never drifts from the pages that actually
// exist. Selection is by page id, not index, so reordering the registry cannot
// silently change which page a keybind opens.
Item {
    id: root
    readonly property ThemeSet theme: Theme.setForHeight(Screen.height)   // P1-040: this output's sizes


    required property string currentPage

    signal pageSelected(string id)

    implicitWidth: 240

    Column {
        id: col

        anchors {
            left: parent.left
            right: parent.right
            top: parent.top
            margins: theme.px(10)
        }
        spacing: theme.px(2)

        // Header
        Item {
            width: parent.width
            height: theme.px(46)

            Text {
                anchors {
                    left: parent.left
                    leftMargin: theme.px(10)
                    verticalCenter: parent.verticalCenter
                }
                text: "Settings"
                color: Theme.text
                font.pixelSize: theme.fs(17)
                font.bold: true
            }
        }

        Repeater {
            model: PageRegistry.pages

            delegate: Rectangle {
                id: row

                required property var modelData

                readonly property bool active: root.currentPage === row.modelData.id

                width: parent.width
                height: theme.px(44)
                radius: theme.cornerRadius
                color: row.active
                           ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.16)
                           : hov.hovered ? Qt.rgba(1, 1, 1, 0.05) : "transparent"

                Behavior on color { ColorAnimation { duration: 120 } }

                // Active marker: a bar rather than only a tint, so the selected
                // page is still obvious at low contrast or with a pale accent.
                Rectangle {
                    anchors {
                        left: parent.left
                        verticalCenter: parent.verticalCenter
                    }
                    width: theme.px(3)
                    height: row.active ? parent.height * 0.55 : 0
                    radius: width
                    color: Theme.active
                    Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }

                Text {
                    id: icon
                    anchors {
                        left: parent.left
                        leftMargin: theme.px(14)
                        verticalCenter: parent.verticalCenter
                    }
                    text: row.modelData.icon
                    color: row.active ? Theme.active : Theme.icon
                    font.pixelSize: theme.fs(15)
                    Behavior on color { ColorAnimation { duration: 120 } }
                }

                Text {
                    anchors {
                        left: icon.right
                        leftMargin: theme.px(11)
                        right: parent.right
                        rightMargin: theme.px(8)
                        verticalCenter: parent.verticalCenter
                    }
                    text: row.modelData.title
                    color: row.active ? Theme.text : Theme.subtext
                    font.pixelSize: theme.fs(12)
                    font.bold: row.active
                    elide: Text.ElideRight
                    Behavior on color { ColorAnimation { duration: 120 } }
                }

                HoverHandler { id: hov; cursorShape: Qt.PointingHandCursor }

                MouseArea {
                    anchors.fill: parent
                    onClicked: root.pageSelected(row.modelData.id)
                }
            }
        }
    }
}
