import QtQuick
import "../"
import "../../"
import "../../components"

Item {
    id: root

    // Handed down from the owning window; forwarded to whichever sub-page needs
    // live telemetry so its services stop when the dashboard is not on screen.
    property bool onScreen: false

    property string _page: "appearance"

    readonly property var _tabs: [
        { key: "appearance", icon: "󰏘", label: "Appearance"        },
        { key: "layout",     icon: "󰕰", label: "Layout & Behavior" },
        { key: "data",       icon: "󰋊", label: "Data & Storage"    },
        { key: "keybinds",   icon: "󰌌", label: "Keybinds"          },
        { key: "misc",       icon: "󰒓", label: "Misc"               },
    ]

    Row {
        anchors {
            fill:    parent
            margins: 8
        }
        spacing: 12

        // ── Left: tab column (30%) ────────────────────────────────────────────
        Rectangle {
            width:  Math.floor((parent.width - parent.spacing) * 0.30)
            height: parent.height
            radius: Theme.cornerRadius
            color:  Qt.rgba(1, 1, 1, 0.04)
            border.color: Qt.rgba(1, 1, 1, 0.07)
            border.width: 1

            TabSwitcher {
                orientation: "vertical"
                anchors {
                    top:              parent.top
                    bottom:           parent.bottom
                    left:             parent.left
                    right:            parent.right
                    topMargin:        8
                    bottomMargin:     8
                    leftMargin:       6
                    rightMargin:      6
                }
                currentPage: root._page
                model:       root._tabs
                onPageChanged: function(key) { root._page = key }
            }
        }

        // ── Right: content area (70%) ─────────────────────────────────────────
        Item {
            width:  parent.width - Math.floor((parent.width - parent.spacing) * 0.30) - parent.spacing
            height: parent.height

            LazyPage {
                anchors.fill: parent
                shown: root._page === "appearance"
                sourceComponent: Component {
                    AppearancePage { anchors.fill: parent }
                }
            }
            LazyPage {
                anchors.fill: parent
                shown: root._page === "layout"
                sourceComponent: Component {
                    LayoutPage { anchors.fill: parent }
                }
            }
            LazyPage {
                anchors.fill: parent
                shown: root._page === "data"
                sourceComponent: Component {
                    DataPage {
                        anchors.fill: parent
                        onScreen: root.onScreen && root._page === "data"
                    }
                }
            }
            LazyPage {
                anchors.fill: parent
                shown: root._page === "keybinds"
                sourceComponent: Component {
                    KeybindsPage { anchors.fill: parent }
                }
            }
            LazyPage {
                anchors.fill: parent
                shown: root._page === "misc"
                sourceComponent: Component {
                    MiscPage { anchors.fill: parent }
                }
            }
        }
    }
}