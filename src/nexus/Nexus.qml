import QtQuick
import Quickshell
import Quickshell.Wayland
import "../"
import "../components"

// ─────────────────────────────────────────────────────────────────────────────
// Nexus — the standalone settings window.
//
// Settings previously existed only as a tab inside the dashboard, which meant
// they shared the dashboard's lifetime and its dismissal rules: click anywhere
// outside and the settings vanished, and any compositor focus change closed
// them. That is correct behaviour for a popup and wrong for a window you edit
// configuration in.
//
// So this is a real window. It has keyboard focus, it survives clicks elsewhere,
// it closes on Escape or its own close button, and it is opened over IPC:
//
//     apex shell nexus            (or: nexus <page>)
//
// It shares its page set with the dashboard tab through PageRegistry — one
// declaration, two presentations — so neither can drift from the other.
//
// One instance per screen, following the dashboard's pattern; NexusState.
// screenName decides which one is live, so the window opens on the output the
// user is actually looking at instead of always the primary.
// ─────────────────────────────────────────────────────────────────────────────

PanelWindow {
    id: root

    required property string screenName

    readonly property bool live: NexusState.open && NexusState.screenName === root.screenName

    // The window stays mapped for the duration of the close animation, so
    // visibility is latched rather than bound straight to `live`.
    property bool windowVisible: false

    readonly property int animDuration: Theme.animDuration

    color: "transparent"
    visible: root.windowVisible

    anchors.top: true
    anchors.left: true
    anchors.right: true
    anchors.bottom: true

    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay

    // Exclusive focus, unlike the popups: there are text fields in here (the
    // lock-background path, the keybind capture) and they must receive keys.
    WlrLayershell.keyboardFocus: root.windowVisible && root.live
                                     ? WlrKeyboardFocus.Exclusive
                                     : WlrKeyboardFocus.None

    onLiveChanged: {
        if (root.live) {
            closeTimer.stop()
            root.windowVisible = true
        } else {
            closeTimer.restart()
        }
    }

    Timer {
        id: closeTimer
        interval: root.animDuration + 20
        onTriggered: root.windowVisible = false
    }

    // Dim the desktop behind. Deliberately NOT a click-to-dismiss surface:
    // mis-clicking beside a slider should not throw away the settings window.
    // Escape and the close button are the ways out, and both are discoverable.
    Rectangle {
        anchors.fill: parent
        color: "black"
        opacity: root.live ? 0.35 : 0
        Behavior on opacity { NumberAnimation { duration: root.animDuration } }
    }

    Item {
        id: content
        anchors.fill: parent
        focus: true

        Keys.onEscapePressed: NexusState.close()

        Rectangle {
            id: card

            anchors.centerIn: parent

            width: Math.min(parent.width - Theme.px(80), Theme.px(920))
            height: Math.min(parent.height - Theme.px(80), Theme.px(620))

            radius: Theme.cornerRadius + Theme.px(4)
            color: Theme.background
            border.color: Qt.rgba(1, 1, 1, 0.08)
            border.width: 1

            opacity: root.live ? 1 : 0
            scale: root.live ? 1 : 0.97
            Behavior on opacity { NumberAnimation { duration: root.animDuration; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: root.animDuration; easing.type: Easing.OutCubic } }

            // Swallow clicks so they do not reach the backdrop.
            MouseArea {
                anchors.fill: parent
            }

            // ── Left: navigation ────────────────────────────────────────────
            NavPane {
                id: nav
                anchors {
                    left: parent.left
                    top: parent.top
                    bottom: parent.bottom
                }
                currentPage: NexusState.page
                onPageSelected: function (id) { NexusState.page = id }
            }

            Rectangle {
                anchors {
                    left: nav.right
                    top: parent.top
                    bottom: parent.bottom
                    topMargin: Theme.px(10)
                    bottomMargin: Theme.px(10)
                }
                width: 1
                color: Qt.rgba(1, 1, 1, 0.07)
            }

            // ── Right: header + page ────────────────────────────────────────
            Item {
                id: pane

                anchors {
                    left: nav.right
                    right: parent.right
                    top: parent.top
                    bottom: parent.bottom
                    leftMargin: Theme.px(1)
                }

                readonly property var current: PageRegistry.pageFor(NexusState.page)

                Item {
                    id: header
                    anchors {
                        left: parent.left
                        right: parent.right
                        top: parent.top
                    }
                    height: Theme.px(58)

                    Text {
                        id: title
                        anchors {
                            left: parent.left
                            leftMargin: Theme.px(18)
                            top: parent.top
                            topMargin: Theme.px(12)
                        }
                        text: pane.current ? pane.current.title : ""
                        color: Theme.text
                        font.pixelSize: Theme.fs(15)
                        font.bold: true
                    }

                    Text {
                        anchors {
                            left: parent.left
                            leftMargin: Theme.px(18)
                            top: title.bottom
                            topMargin: Theme.px(2)
                            right: closeBtn.left
                            rightMargin: Theme.px(8)
                        }
                        text: pane.current ? pane.current.subtitle : ""
                        color: Theme.subtext
                        font.pixelSize: Theme.fs(11)
                        elide: Text.ElideRight
                    }

                    Rectangle {
                        id: closeBtn
                        anchors {
                            right: parent.right
                            rightMargin: Theme.px(12)
                            top: parent.top
                            topMargin: Theme.px(12)
                        }
                        width: Theme.px(28)
                        height: Theme.px(28)
                        radius: width / 2
                        color: closeHov.hovered ? Qt.rgba(1, 1, 1, 0.10) : "transparent"
                        Behavior on color { ColorAnimation { duration: 120 } }

                        Text {
                            anchors.centerIn: parent
                            text: "󰅖"
                            color: closeHov.hovered ? Theme.text : Theme.subtext
                            font.pixelSize: Theme.fs(13)
                        }

                        HoverHandler { id: closeHov; cursorShape: Qt.PointingHandCursor }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: NexusState.close()
                        }
                    }
                }

                // One LazyPage per registered page: built on first visit, kept
                // afterwards so scroll position and sub-page state survive
                // switching away and back.
                Repeater {
                    model: PageRegistry.pages

                    delegate: LazyPage {
                        required property var modelData

                        anchors {
                            left: parent.left
                            right: parent.right
                            top: header.bottom
                            bottom: parent.bottom
                            leftMargin: Theme.px(8)
                            rightMargin: Theme.px(8)
                            bottomMargin: Theme.px(8)
                        }

                        shown: NexusState.page === modelData.id
                        sourceComponent: modelData.component

                        // Pages that consume refcounted telemetry need to know
                        // whether a user can actually see them; without this a
                        // poller started here would run until logout.
                        onLoaded: if (modelData.needsScreen && item)
                            item.onScreen = Qt.binding(() => root.windowVisible
                                                             && root.live
                                                             && NexusState.page === modelData.id
                                                             && !LockState.locked)
                    }
                }
            }
        }
    }
}
