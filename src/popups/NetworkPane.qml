import QtQuick
import "../components"
import "../"

// ─────────────────────────────────────────────────────────────────────────────
// NetworkPane — the network panel's content: Wi-Fi, Bluetooth, VPN, Hotspot.
//
// A pane of RightPanel, which draws the body it sits in (RIGHT_POUR) and
// reveals it at this, its finished layout; nothing in here moves with the
// morph. It used to be its own window with its own sizer tweening width and
// height, and the tab bar rode up with the sizer's bottom edge (brief §F.4);
// now it is laid once where it ends.
//
// Tabs are Loaders, deliberately: each tab starts its scan or query when it is
// built and stops when it is destroyed, so only the tab on screen ever runs.
// Changing tab therefore has no old page to animate out; the new one arrives
// from the side of the tab it came from, over the page beat, while the shared
// selection pill travels (UI/UX roadmap v3 Phase 7 / Phase 9 navigation).
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: root
    required property ThemeSet theme

    readonly property string page: (Popups.networkPage && Popups.networkPage !== "")
                                   ? Popups.networkPage : "wifi"
    readonly property var tabs: [
        { key: "wifi",      icon: "󰤨", label: "Wi-Fi"     },
        { key: "bluetooth", icon: "󰂯", label: "Bluetooth" },
        { key: "vpn",       icon: "󰦝", label: "VPN"       },
        { key: "hotspot",   icon: "󰀃", label: "Hotspot"   },
    ]
    function _indexOf(key) {
        for (var i = 0; i < root.tabs.length; i++) if (root.tabs[i].key === key) return i
        return 0
    }

    Keys.onEscapePressed: Popups.networkOpen = false

    // The height the active tab asks for, with the tab bar; -1 when it does not
    // say (the panel then keeps its full depth). The tab bar hangs 16 px into
    // the panel's padding (its bottomMargin).
    readonly property real preferredHeight: {
        const tabs = [wifiTab, btTab, vpnTab, hotspotTab]
        for (const l of tabs)
            if (l.active && l.item && l.item.preferredHeight !== undefined)
                return l.item.preferredHeight + tabBar.height - 16
        return -1
    }

    // ── Tab page area ─────────────────────────────────────────────────────────
    Item {
        id: tabContent
        anchors {
            top:    parent.top
            left:   parent.left
            right:  parent.right
            bottom: tabBar.top
        }

        property int _idx: root._indexOf(root.page)
        property real _offset: 0
        transform: Translate { x: tabContent._offset }

        Connections {
            target: root
            function onPageChanged() {
                var i = root._indexOf(root.page)
                var dir = i >= tabContent._idx ? 1 : -1
                tabContent._idx = i
                arrive.stop()
                arriveMove.from = dir * Motion.pageTravel
                arriveFade.from = 0
                arrive.start()
            }
        }
        ParallelAnimation {
            id: arrive
            NumberAnimation {
                id: arriveMove
                target: tabContent; property: "_offset"; to: 0
                duration: Motion.page
                easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.standardDecel
            }
            NumberAnimation {
                id: arriveFade
                target: tabContent; property: "opacity"; to: 1
                duration: Motion.fadeIn
                easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.effects
            }
        }

        Loader {
            id: wifiTab
            anchors.fill: parent
            active:       root.page === "wifi"
            source:       "WifiTab.qml"
        }

        Loader {
            id: btTab
            anchors.fill: parent
            active:       root.page === "bluetooth"
            source:       "BluetoothTab.qml"
        }

        // VPN — WireGuard connections
        Loader {
            id: vpnTab
            anchors.fill: parent
            active:       root.page === "vpn"
            source:       "VPNTab.qml"
        }

        // Hotspot — virtual AP interface
        Loader {
            id: hotspotTab
            anchors.fill: parent
            active:       root.page === "hotspot"
            source:       "HotspotTab.qml"
        }
    }

    // ── Tab bar — at its final place from the first frame ────────────────────
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
        model:        root.tabs
        onPageChanged: function(key) { Popups.networkPage = key }
    }
}
