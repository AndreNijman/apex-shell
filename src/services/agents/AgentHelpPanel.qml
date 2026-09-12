import QtQuick
import QtQuick.Controls
import "../"
import "../../"

// ─── AgentHelpPanel ───────────────────────────────────────────────────────────
// "How Agents & Workspaces work", in full (roadmap §43).
//
// An overlay inside the Agents page rather than a window of its own. A window
// would be a second thing to position, a second thing to close and a second
// keyboard-focus owner on the Wayland overlay layer; the page it explains is
// two pixels behind it, and the dashboard already dismisses on a click outside.
// KanbanBoard's date picker is the same shape.
//
// Contents live in AgentHelpContent. Nothing here decides what the guide says,
// so a wording change is one file and a layout change is the other.

Item {
    id: panel
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    anchors.fill: parent
    z: 50
    visible: AgentHelp.panelOpen

    readonly property var _section: {
        const all = AgentHelpContent.sections
        for (var i = 0; i < all.length; i++)
            if (all[i].id === AgentHelp.section) return all[i]
        return all[0]
    }

    // ── Escape closes the guide, and only the guide ───────────────────────────
    // Dashboard.qml:262 closes the whole dashboard on Escape. Without this
    // handler taking the key first, one press would throw away the page as well
    // as the panel. Same shape as KanbanBoard's delete-confirm handler: an Item
    // that grabs focus while the overlay is up and hands it back after.
    Item {
        id: keys
        Keys.onEscapePressed: function (ev) {
            if (!AgentHelp.panelOpen) return
            AgentHelp.close()
            ev.accepted = true
        }
    }

    onVisibleChanged: {
        if (panel.visible) keys.forceActiveFocus()
        else if (panel.parent) panel.parent.forceActiveFocus()
    }

    // ── Dim the page behind ───────────────────────────────────────────────────
    // Plain decimals, not a palette token: this has to darken whatever the page
    // is showing, so it must not follow the theme. Same call as KanbanBoard's
    // picker scrim.
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.45)
        MouseArea {
            anchors.fill: parent
            onClicked: AgentHelp.close()
        }
    }

    Rectangle {
        id: card
        anchors.fill: parent
        anchors.margins: theme.px(4)
        radius: theme.cornerRadius
        color: Theme.background
        border.width: 1
        border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.12)

        // Swallow clicks, or they reach the scrim and close the guide.
        MouseArea { anchors.fill: parent; onClicked: {} }

        // ── Title bar ─────────────────────────────────────────────────────────
        Item {
            id: titleBar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: theme.px(14)
            anchors.rightMargin: theme.px(8)
            height: theme.px(38)

            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: AgentHelpContent.entryLabel
                color: Theme.text
                font.pixelSize: theme.fs(13)
                font.bold: true
            }

            SmallIconButton {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                icon: "󰅖"
                tip: "Close  ·  Escape"
                onActivated: AgentHelp.close()
            }
        }

        Rectangle {
            id: rule
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: titleBar.bottom
            height: 1
            color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10)
        }

        // ── Left: the sections ────────────────────────────────────────────────
        Column {
            id: nav
            anchors.left: parent.left
            anchors.top: rule.bottom
            anchors.bottom: parent.bottom
            anchors.margins: theme.px(8)
            width: Math.min(theme.px(184), Math.floor(card.width * 0.32))
            spacing: theme.px(2)

            Repeater {
                model: AgentHelpContent.sections

                delegate: Rectangle {
                    id: navItem
                    required property var modelData

                    readonly property bool current: modelData.id === AgentHelp.section

                    width: nav.width
                    height: theme.px(30)
                    radius: theme.px(7)
                    color: navItem.current
                        ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.22)
                        : navHover.hovered
                          ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07)
                          : "transparent"

                    Behavior on color { ColorAnimation { duration: 90 } }

                    Row {
                        anchors.fill: parent
                        anchors.leftMargin: theme.px(9)
                        anchors.rightMargin: theme.px(6)
                        spacing: theme.px(8)

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: theme.px(16)
                            horizontalAlignment: Text.AlignHCenter
                            text: navItem.modelData.icon
                            font.pixelSize: theme.fs(12)
                            color: navItem.current ? Theme.active : Theme.subtext
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - theme.px(24) - parent.spacing
                            text: navItem.modelData.title
                            elide: Text.ElideRight
                            font.pixelSize: theme.fs(11)
                            color: navItem.current ? Theme.text : Theme.subtext
                        }
                    }

                    HoverHandler { id: navHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: AgentHelp.section = navItem.modelData.id }
                }
            }
        }

        // ── Right: the section itself ─────────────────────────────────────────
        ScrollView {
            id: body
            anchors.left: nav.right
            anchors.right: parent.right
            anchors.top: rule.bottom
            anchors.bottom: parent.bottom
            anchors.leftMargin: theme.px(6)
            anchors.rightMargin: theme.px(10)
            anchors.topMargin: theme.px(4)
            anchors.bottomMargin: theme.px(8)
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            // Scroll back to the top when the section changes. Landing halfway
            // down a page you have never read is disorienting, and the
            // ScrollView keeps its offset across a model swap otherwise.
            Connections {
                target: AgentHelp
                function onSectionChanged() {
                    if (body.contentItem) body.contentItem.contentY = 0
                }
            }

            Column {
                width: body.availableWidth - theme.px(6)
                spacing: 0

                Item { width: 1; height: theme.px(2) }

                Repeater {
                    model: panel._section ? panel._section.blocks : []

                    delegate: AgentHelpBlock {
                        required property var modelData
                        width: parent.width
                        block: modelData
                    }
                }

                Item { width: 1; height: theme.px(14) }
            }
        }
    }
}
