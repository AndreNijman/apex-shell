import QtQuick
import Quickshell.Io
import Quickshell.Networking
import "../../components"
import "../../"

// Bar network indicator.
//
// ── Zero forks ──────────────────────────────────────────────────────────────
// This ran three `nmcli` pipelines every five seconds, forever, because the bar
// is always mapped — 0.6 forks/second just to keep one glyph correct. All three
// answers are available natively from Quickshell.Networking, which is a live
// NetworkManager D-Bus binding: signal strength, wired link state and the
// connectivity verdict are plain properties that push updates when they change.
// No polling, no subprocesses, and it reacts immediately instead of up to five
// seconds late.
Item {
    id: root

    implicitWidth:  row.implicitWidth + 6
    implicitHeight: row.implicitHeight

    // Strongest signal among connected wifi networks, as a percentage; 0 when
    // nothing is associated. Note Quickshell reports signalStrength as a 0..1
    // real, whereas the nmcli this replaced emitted 0..100 — the icon
    // thresholds below are still in percent, so scale here.
    readonly property int _signal: {
        let best = 0
        for (const dev of Networking.devices.values) {
            if (dev.type !== DeviceType.Wifi || !dev.connected)
                continue
            for (const net of dev.networks.values) {
                if (!net.connected)
                    continue
                const s = Math.round((net.signalStrength ?? 0) * 100)
                if (s > best)
                    best = s
            }
        }
        return best
    }

    readonly property bool _ethernet: {
        for (const dev of Networking.devices.values)
            if (dev.type === DeviceType.Wired && dev.connected)
                return true
        return false
    }

    readonly property bool _limited: {
        const c = Networking.connectivity
        return c === NetworkConnectivity.Limited
            || c === NetworkConnectivity.Portal
            || c === NetworkConnectivity.None
    }

    readonly property bool _offline: Networking.connectivity === NetworkConnectivity.None

    readonly property string _netIcon: {
        if (_ethernet) return _limited ? "󰅢" : ""
        if (_signal <= 0) return "󰤭"
        if (_limited) return ""

        if (_signal > 75) return "󰤨"
        if (_signal > 50) return "󰤥"
        if (_signal > 25) return "󰤢"
        return "󰤟"
    }

    readonly property color _netColor: {
        if (!_ethernet && _signal <= 0) return Qt.rgba(1,1,1,0.28)
        if (_offline)                   return "#f87171"
        if (_limited)                   return "#f5c47a"
        return hov.hovered ? Theme.active : Theme.text
    }

    // VPN blink
    property real _vpnOpacity: 1.0
    SequentialAnimation on _vpnOpacity {
        running: ShellState.vpnConnecting; loops: Animation.Infinite
        NumberAnimation { to: 0.20; duration: 500; easing.type: Easing.InOutSine }
        NumberAnimation { to: 1.0;  duration: 500; easing.type: Easing.InOutSine }
    }
    Connections {
        target: ShellState
        function onVpnConnectingChanged() {
            if (!ShellState.vpnConnecting) root._vpnOpacity = 1.0
        }
    }

    // NetworkManager can answer "is this connection actually usable" rather than
    // merely "is it associated", but only while connectivity checking is on.
    Component.onCompleted: {
        if (Networking.canCheckConnectivity)
            Networking.connectivityCheckEnabled = true
    }

    HoverHandler { id: hov; onHoveredChanged: Popups.networkTriggerHovered = hovered }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 4

        // WiFi/ethernet icon — opens to wifi tab
        Text {
            id: netIcon
            text:           root._netIcon
            color:          root._netColor
            font.pixelSize: 16
            anchors.verticalCenter: parent.verticalCenter
            Behavior on color { ColorAnimation { duration: 200 } }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    Popups.closeAll()
                    Popups.networkPage = "wifi"
                    Popups.networkOpen = true
                }
            }
        }

        // VPN shield — opens to vpn tab
        Text {
            visible:        ShellState.vpnActive || ShellState.vpnConnecting
            text:           ShellState.vpnConnecting ? "󱦚" : "󰦝"
            font.pixelSize: 14
            anchors.verticalCenter: parent.verticalCenter
            opacity:        root._vpnOpacity
            color: ShellState.vpnActive ? Theme.active : Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.70)
            Behavior on color   { ColorAnimation  { duration: 200 } }
            Behavior on opacity { NumberAnimation { duration: 80  } }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    Popups.closeAll()
                    Popups.networkPage = "vpn"
                    Popups.networkOpen = true
                }
            }
        }

        // Bluetooth — opens to bluetooth tab
        Text {
            visible:        ShellState.btPowered
            text:           ShellState.btConnected ? "󰂱" : "󰂯"
            font.pixelSize: 14
            anchors.verticalCenter: parent.verticalCenter
            color: ShellState.btConnected ? (hov.hovered ? Theme.active : Theme.text) : Qt.rgba(1,1,1,0.32)
            Behavior on color { ColorAnimation { duration: 200 } }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    Popups.closeAll()
                    Popups.networkPage = "bluetooth"
                    Popups.networkOpen = true
                }
            }
        }

        // Hotspot — opens to hotspot tab
        Text {
            visible:        ShellState.hotspot
            text:           "󰀂"
            font.pixelSize: 14
            anchors.verticalCenter: parent.verticalCenter
            color:          Theme.active
            Behavior on color { ColorAnimation { duration: 200 } }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    Popups.closeAll()
                    Popups.networkPage = "hotspot"
                    Popups.networkOpen = true
                }
            }
        }
    }
}
