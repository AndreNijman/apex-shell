import QtQuick
import "../"
import "../../"
import "../../nexus"
import "../../components"

// Dashboard → Config tab.
//
// The page set is NOT defined here. It comes from PageRegistry, which the
// standalone Nexus window reads too, so the two presentations cannot drift.
// This file used to carry its own tab list AND its own five hand-written
// Loaders, which meant adding a settings page required editing two lists that
// had to agree, and nothing enforced that they did.
//
// There is a "Open in window" affordance because this tab lives inside the
// dashboard and therefore inherits its dismissal rules: a click outside closes
// it. That is right for a popup and wrong for editing configuration, so Nexus
// exists and this points at it.
Item {
    id: root

    // Handed down from the owning window; forwarded to whichever sub-page needs
    // live telemetry so its services stop when the dashboard is not on screen.
    property bool onScreen: false

    property string _page: PageRegistry.firstId

    // TabSwitcher wants {key, icon, label}; the registry speaks {id, icon,
    // title}. Mapped here rather than bending the registry to one consumer's
    // shape.
    readonly property var _tabs: {
        const out = []
        for (const p of PageRegistry.pages)
            out.push({ "key": p.id, "icon": p.icon, "label": p.title })
        return out
    }

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
                id: tabs
                orientation: "vertical"
                anchors {
                    top:              parent.top
                    bottom:           popOut.top
                    left:             parent.left
                    right:            parent.right
                    topMargin:        8
                    bottomMargin:     6
                    leftMargin:       6
                    rightMargin:      6
                }
                currentPage: root._page
                model:       root._tabs
                onPageChanged: function(key) { root._page = key }
            }

            // Hand the current page off to the real window, on the page the user
            // is already looking at.
            Rectangle {
                id: popOut
                anchors {
                    left:         parent.left
                    right:        parent.right
                    bottom:       parent.bottom
                    leftMargin:   6
                    rightMargin:  6
                    bottomMargin: 8
                }
                height: Theme.px(30)
                radius: Theme.cornerRadius
                color:  popHov.hovered ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(1, 1, 1, 0.03)
                Behavior on color { ColorAnimation { duration: 120 } }

                Text {
                    anchors.centerIn: parent
                    text:  "󰏋  Open in window"
                    color: popHov.hovered ? Theme.active : Theme.subtext
                    font.pixelSize: Theme.fs(11)
                    Behavior on color { ColorAnimation { duration: 120 } }
                }

                HoverHandler { id: popHov; cursorShape: Qt.PointingHandCursor }

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        Popups.dashboardOpen = false
                        NexusState.openAt(root._page, Popups.dashboardScreen)
                    }
                }
            }
        }

        // ── Right: content area (70%) ─────────────────────────────────────────
        Item {
            width:  parent.width - Math.floor((parent.width - parent.spacing) * 0.30) - parent.spacing
            height: parent.height

            Repeater {
                model: PageRegistry.pages

                delegate: LazyPage {
                    required property var modelData

                    anchors.fill: parent
                    shown: root._page === modelData.id
                    sourceComponent: modelData.component

                    // Pages declaring needsScreen consume refcounted telemetry
                    // and must be told whether a user can actually see them, or
                    // a poller started here runs until logout.
                    onLoaded: if (modelData.needsScreen && item)
                        item.onScreen = Qt.binding(() => root.onScreen
                                                         && root._page === modelData.id)
                }
            }
        }
    }
}
