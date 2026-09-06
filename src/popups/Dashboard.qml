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
    // Every page but one wants the configured dashboard width. The launcher
    // wants to be narrow: a search field and a single column of results read
    // badly stretched across a whole page.
    //
    // These are preferences, not sizes, and the difference is the bug. They used
    // to be raw 1080p literals written straight into the window's width, so they
    // neither grew with the shell's scale factor nor shrank to fit the output.
    // Theme.dashboardWidthFor() decides what this screen can actually show; see
    // theme/Metrics.qml for what it is protecting against.
    function _preferredWidth(p) {
        return p === "launcher" ? Theme.px(560) : Theme.dashboardWidth
    }

    // The output the dashboard is opening on, which is not necessarily the one
    // that set the shell's scale factor.
    readonly property int availableWidth:  root.screen ? root.screen.width  : 0
    readonly property int availableHeight: root.screen ? root.screen.height : 0

    readonly property int pageWidth:
        Theme.dashboardWidthFor(root.availableWidth, root._preferredWidth(root.page))

    readonly property int pageHeight:
        Theme.dashboardHeightFor(root.availableHeight, Theme.dashboardHeight)

    // The top bar reads this to size the centre notch the dashboard hangs from,
    // so the two cannot disagree about how wide the dashboard is. Bound rather
    // than assigned: it has to follow a scale change or a mode change, not just
    // a tab click.
    Binding {
        target:   Popups
        property: "dashboardPageWidth"
        value:    root.pageWidth
        when:     root.open
    }

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
        objectName: "dashboard-sizer"
        anchors.top:              parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        clip: true

        width:  root.open ? root.pageWidth + 2 * root.fw : Theme.cNotchMinWidth + 2 * root.fw
        height: root.open ? root.pageHeight : Theme.notchHeight / 2

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
            objectName: "dashboard-content"
            anchors {
                fill:         parent
                topMargin:    root.fh + Theme.px(8)
                leftMargin:   root.fw + Theme.px(8)
                rightMargin:  root.fw + Theme.px(8)
                bottomMargin: Theme.px(8)
            }

            // Escape lives here rather than on the page area so it still closes
            // the dashboard when keyboard focus is on a tab rather than a page.
            Keys.onEscapePressed: Popups.dashboardOpen = false

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
                    objectName:  "dashboard-tabbar"
                    orientation: "horizontal"
                    width:       parent.width
                    currentPage: root.page
                    model: [
                        { key: "home",     icon: "󰋜", label: "Home"   },
                        { key: "stats",    icon: "󰻠", label: "System" },
                        { key: "agents",   icon: "󰚩", label: "Agents" },
                        { key: "kanban",   icon: "󰄬", label: "Tasks"  },
                        { key: "launcher", icon: "󱓞", label: "Apps"   },
                        { key: "config",   icon: "󰒓", label: "Config" },
                    ]
                    onPageChanged: function(key) { Popups.dashboardPage = key }
                }

                // ── Page area ─────────────────────────────────────────────────
                Item {
                    id: pageArea
                    objectName: "dashboard-pagearea"
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
                        shown: root.page === "agents"
                        sourceComponent: Component {
                            AgentCenter {
                                anchors.fill: parent
                                onScreen: root.pageLive && root.page === "agents"
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
                            // The launcher is the one page that took no
                            // `onScreen` before §15, because it consumed no
                            // refcounted service. It does now — the search
                            // stack and the compositor's window list are both
                            // held only while somebody is looking at it.
                            AppLauncher {
                                anchors.fill: parent
                                onScreen: root.pageLive && root.page === "launcher"
                            }
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
                }
            }
        }
    }
}
