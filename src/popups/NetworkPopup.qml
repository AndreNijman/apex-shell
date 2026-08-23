import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../shapes"
import "../components"
import "../"

PanelWindow {
    id: root

    readonly property int popupWidth:  Theme.networkPopupWidth   // 480
    readonly property int popupHeight: 648
    readonly property int fw:          Theme.notchRadius
    readonly property int fh:          Theme.notchRadius

    property string page: Popups.networkPage

    anchors.right: true
    anchors.top:   true

    // Standardised pill-popup geometry (same as NotificationsPopup): the window
    // top sits at the pill's bottom edge; the card hangs flush under the pill.
    margins.top: Theme.notchHeight

    // Window height = popup content only — sizer starts at y:0
    implicitWidth:  popupWidth + fw
    implicitHeight: popupHeight

    exclusionMode: ExclusionMode.Ignore
    color:         "transparent"

    WlrLayershell.layer:         WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    // Input region limited to the visible card
    mask: Region { item: sizer }

    // ── Visibility gate ───────────────────────────────────────────────────────
    property bool windowVisible: false
    visible: windowVisible

    // Shared by the open signal and by LazyPopup, which calls this right after
    // building the window — the popup does not exist for the signal that opens
    // it the first time.
    function applyOpenState() {
        closeTimer.stop()
        root.windowVisible = true
        // Use requested page if set, otherwise default to wifi
        root.page = (Popups.networkPage && Popups.networkPage !== "")
            ? Popups.networkPage : "wifi"
    }

    Connections {
        target: Popups
        function onNetworkOpenChanged() {
            if (Popups.networkOpen) {
                root.applyOpenState()
            } else {
                closeTimer.restart()
            }
        }

        function onNetworkPageChanged() {
            root.page = Popups.networkPage
        }
    }

    Timer {
        id: closeTimer
        interval: Theme.animDuration + 20
        onTriggered: { if (!Popups.networkOpen) root.windowVisible = false }
    }

    // ── Sizer — clip container, grows downward from y:0 ──────────────────────
    // Width matches the expanded pill (networkPopupWidth + notchRadius), flush
    // to the screen's right edge — the pill-right shape joins the pill above.
    Item {
        id: sizer
        anchors.right: parent.right
        y: 0
        clip: true

        width: Popups.networkOpen
               ? root.popupWidth + root.fw
               : Theme.rNotchMinWidth + root.fw

        height: Popups.networkOpen ? root.popupHeight : 0

        Behavior on width  { NumberAnimation { duration: Theme.animDuration; easing.type: Easing.InOutCubic } }
        Behavior on height { NumberAnimation { duration: Theme.animDuration; easing.type: Easing.InOutCubic } }

        PopupShape {
            anchors.fill: parent
            attachedEdge: "pill-right"
            color:        Theme.background
            radius:       Theme.cornerRadius
        }

        Keys.onEscapePressed: Popups.networkOpen = false

        Item {
            id: contentArea
            anchors {
                fill:         parent
                topMargin:    Theme.popupPadding
                leftMargin:   Theme.popupPadding
                rightMargin:  Theme.popupPadding
                bottomMargin: Theme.popupPadding
            }

            opacity: Popups.networkOpen ? 1 : 0
            Behavior on opacity {
                NumberAnimation {
                    duration: Popups.networkOpen
                        ? Theme.animDuration * 0.5
                        : Theme.animDuration * 0.15
                }
            }

            // ── Tab page area ─────────────────────────────────────────────────
            Item {
                id: tabContent
                anchors {
                    top:    parent.top
                    left:   parent.left
                    right:  parent.right
                    bottom: tabBar.top
                }

                Loader {
                    anchors.fill: parent
                    active:       root.page === "wifi"
                    source:       "WifiTab.qml"
                }

                Loader {
                    anchors.fill: parent
                    active:       root.page === "bluetooth"
                    source:       "BluetoothTab.qml"
                }

                // VPN — WireGuard connections
                Loader {
                    anchors.fill: parent
                    active:       root.page === "vpn"
                    source:       "VPNTab.qml"
                }

                // Hotspot — virtual AP interface
                Loader {
                    anchors.fill: parent
                    active:       root.page === "hotspot"
                    source:       "HotspotTab.qml"
                }
            }

            // ── Tab bar — lifted by cornerRadius from the popup bottom ────────
            TabSwitcher {
                id: tabBar
                anchors {
                    left:         parent.left
                    right:        parent.right
                    bottom:       parent.bottom
                    bottomMargin: -16
                }
                orientation: "horizontal"
                width:        parent.width
                currentPage:  root.page
                model: [
                    { key: "wifi",      icon: "󰤨", label: "Wi-Fi"     },
                    { key: "bluetooth", icon: "󰂯", label: "Bluetooth" },
                    { key: "vpn",       icon: "󰦝", label: "VPN"       },
                    { key: "hotspot",   icon: "󰀃", label: "Hotspot"   },
                ]
                onPageChanged: function(key) { Popups.networkPage = key }
            }
        }
    }
}
