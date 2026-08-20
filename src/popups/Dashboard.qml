import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../shapes"
import "../components"
import "../modules/Center/"
import '../services/'
import "../"

// Dashboard — PanelWindow required for TextInput keyboard focus on Wayland.
// Uses WlrKeyboardFocus.Exclusive so TextInputs inside pages receive key events.
//
// Positioning mirrors the original PopupWindow behaviour: the sizer's top sits
// exactly at the notch-bar bottom (topMargin: Theme.notchHeight), so there is
// no vertical offset compared to the PopupWindow version.

PanelWindow {
    id: root

    // Kept so existing instantiation sites that pass anchorWindow: … still compile.
    required property var anchorWindow
    readonly property string screenName: anchorWindow.screen ? anchorWindow.screen.name : ""
    readonly property bool open: Popups.dashboardOpen && Popups.dashboardScreen === screenName
    screen: anchorWindow.screen

    readonly property int fw: Theme.notchRadius
    readonly property int fh: Theme.notchRadius
    readonly property int animDuration: Theme.animDuration

    property string page: Popups.dashboardPage

    // "A user can actually see this window right now." Pages hand this down to
    // their ServiceRefs; it is the difference between a poller that stops when
    // the dashboard closes and one that runs until logout. Item-level `visible`
    // is NOT a substitute: an Item inside an unmapped window still reports
    // visible === true.
    readonly property bool pageLive: root.windowVisible && !LockState.locked

    // ── Per-page content widths ───────────────────────────────────────────────
    readonly property var _pageWidths: ({
        "home":     900,
        "stats":    900,
        "kanban":   900,
        "launcher": 560,
        "config":   900
    })

    function _applyPageWidth(p) {
        var w = _pageWidths[p]
        Popups.dashboardPageWidth = (w !== undefined) ? w : 900
    }

    onPageChanged: _applyPageWidth(page)

    color:   "transparent"
    visible: windowVisible

    anchors.top:   true
    anchors.left:  true
    anchors.right: true
    anchors.bottom: true

    exclusionMode: ExclusionMode.Ignore

    WlrLayershell.layer:         WlrLayer.Overlay

    property bool wantsFocus: false
    WlrLayershell.keyboardFocus: wantsFocus ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    Timer {
        id: focusGrabTimer
        interval: 15
        onTriggered: if (windowVisible && root.open) root.wantsFocus = true
    }

    property bool windowVisible: false

    onOpenChanged: {
        if (root.open) {
            closeTimer.stop()
            root.windowVisible = true
            root._applyPageWidth(root.page)
            focusGrabTimer.restart() // Delay the grab slightly
        } else {
            root.wantsFocus = false // Release instantly
            focusGrabTimer.stop()
            closeTimer.restart()
        }
    }
    
    Timer {
        id: closeTimer
        interval: root.animDuration + 20
        onTriggered: {
            root.windowVisible = false
            tabBar.reset()
        }
    }

    // ── Backdrop — closes popup when clicking outside the sizer ──────────────
    MouseArea {
        anchors.fill: parent
        onClicked:    Popups.dashboardOpen = false
    }

    // ── Sizer ─────────────────────────────────────────────────────────────────
    // topMargin: Theme.notchHeight places the sizer top exactly at the notch
    // bottom — identical to where PopupWindow put it. No fh subtraction, which
    // was the source of the vertical offset in the text-working variant.
    Item {
        id: sizer
        anchors.top:              parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        clip: true

        width:  root.open ? Popups.dashboardPageWidth + 2 * root.fw : Theme.cNotchMinWidth + 2 * root.fw
        height: root.open ? Theme.dashboardHeight : Theme.notchHeight / 2

        Behavior on width  { NumberAnimation { duration: root.animDuration; easing.type: Easing.InOutCubic } }
        Behavior on height { NumberAnimation { duration: root.animDuration; easing.type: Easing.InOutCubic } }
        
        MouseArea {
            anchors.fill: parent
            onClicked:    {}
        }

        // ── Background ────────────────────────────────────────────────────────
        PopupShape {
            anchors.fill: parent
            attachedEdge: "top"
            color:        Theme.background
            radius:       Theme.cornerRadius
            flareWidth:   root.fw
            flareHeight:  root.fh
            // Start the melt at the top strip's bottom edge (tangent blend —
            // no kink where the flare leaves the thin bar line).
            edgeOffset:   Theme.borderWidth
        }

        // ── Content ───────────────────────────────────────────────────────────
        Item {
            id: content
            anchors {
                fill:         parent
                topMargin:    root.fh + 8
                leftMargin:   root.fw + 8
                rightMargin:  root.fw + 8
                bottomMargin: 8
            }

            opacity: root.open ? 1 : 0
            Behavior on opacity {
                NumberAnimation {
                    duration: root.open
                        ? root.animDuration * 0.5
                        : root.animDuration * 0.15
                }
            }

            Column {
                anchors.fill: parent
                spacing: 0

                // ── Tab bar ───────────────────────────────────────────────────
                TabSwitcher {
                    id: tabBar
                    orientation: "horizontal"
                    width:       parent.width
                    currentPage: root.page
                    model: [
                        { key: "home",     icon: "󰋜", label: "Home"   },
                        { key: "stats",    icon: "󰻠", label: "System" },
                        { key: "kanban",   icon: "󰄬", label: "Tasks"  },
                        { key: "launcher", icon: "󱓞", label: "Apps"   },
                        { key: "config",   icon: "󰒓", label: "Config" },
                    ]
                    onPageChanged: function(key) { Popups.dashboardPage = key }
                }

                // ── Page area ─────────────────────────────────────────────────
                Item {
                    id: pageArea
                    focus: true
                    
                    width:  parent.width
                    height: parent.height - tabBar.height

                    // Each page is built on first visit rather than at shell
                    // startup, and told whether it is genuinely in front of a
                    // user so its services can stop when it is not. See
                    // components/LazyPage.qml and components/ServiceRef.qml.
                    LazyPage {
                        anchors.fill: parent
                        shown: root.page === "home"
                        sourceComponent: Component {
                            DashHome {
                                anchors.fill: parent
                                onScreen: root.pageLive && root.page === "home"
                            }
                        }
                    }

                    LazyPage {
                        anchors.fill: parent
                        shown: root.page === "stats"
                        sourceComponent: Component {
                            DashStats {
                                anchors.fill: parent
                                onScreen: root.pageLive && root.page === "stats"
                            }
                        }
                    }

                    LazyPage {
                        anchors.fill: parent
                        shown: root.page === "kanban"
                        sourceComponent: Component {
                            KanbanBoard { anchors.fill: parent }
                        }
                    }

                    LazyPage {
                        anchors.fill: parent
                        shown: root.page === "launcher"
                        sourceComponent: Component {
                            AppLauncher { anchors.fill: parent }
                        }
                    }

                    LazyPage {
                        anchors.fill: parent
                        shown: root.page === "config"
                        sourceComponent: Component {
                            ShellConfig {
                                anchors.fill: parent
                                onScreen: root.pageLive && root.page === "config"
                            }
                        }
                    }
                    
                    Keys.onEscapePressed: Popups.dashboardOpen = false
                }
            }
        }
    }
}
