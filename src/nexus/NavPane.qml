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
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    required property string currentPage

    signal pageSelected(string id)

    implicitWidth: 240

    // Scrolls, and is clipped to the window. The list is sixteen pages and
    // growing; as a bare Column it simply ran past the bottom of the Settings
    // window on a short screen, drawing "Pair a device" … "Misc" over whatever
    // was underneath and leaving them half off the card.
    Flickable {
        id: flick
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: col.height + root.theme.px(20)
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        // Keep the selected page in view when something other than a click
        // selects it — a keybind or a deep link to a page near the bottom.
        function reveal() {
            const list = PageRegistry.pages
            for (let i = 0; i < list.length; i++) {
                if (list[i].id !== root.currentPage) continue
                const item = pages.itemAt(i)
                if (!item) return
                const pad = root.theme.px(10)
                const top = col.y + item.y
                const bottom = top + item.height
                if (top < flick.contentY)
                    flick.contentY = Math.max(0, top - pad)
                else if (bottom > flick.contentY + flick.height)
                    flick.contentY = Math.min(flick.contentHeight - flick.height, bottom - flick.height + pad)
                return
            }
        }

    Column {
        id: col

        x: root.theme.px(10)
        y: root.theme.px(10)
        width: flick.width - root.theme.px(20)
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
            id: pages
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

    onCurrentPageChanged: Qt.callLater(flick.reveal)
}
