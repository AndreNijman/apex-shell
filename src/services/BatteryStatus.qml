import QtQuick
import Quickshell.Services.UPower
import "../"

// Config:
//showPercentage: bool — always show % beside icon (default: false = hover only)

Item {
    id: root

    property bool showPercentage: false

    // ── UPower data ──────────────────────────────────────────────────────────
    readonly property var  bat:      UPower.displayDevice
    visible: bat.ready && bat.isLaptopBattery
    readonly property real pct:      bat.ready ? Math.round(bat.percentage * 100) : 0
    readonly property bool charging: bat.ready
                                     ? (bat.state === UPowerDeviceState.Charging ||
                                        bat.state === UPowerDeviceState.PendingCharge ||
                                        bat.state === UPowerDeviceState.FullyCharged)
                                     : false
    readonly property bool full:     bat.ready
                                     ? bat.state === UPowerDeviceState.FullyCharged
                                     : false

    implicitWidth:  statusRow.implicitWidth + 6
    implicitHeight: statusRow.implicitHeight

    // Low-battery warnings are NOT handled here. This is a bar widget and is
    // instantiated once per screen, so a dedupe list living here produced one
    // warning popup per monitor with each copy unaware of the others. It now
    // belongs to the BatteryAlert singleton.

    // ── Nerd Font icons ──────────────────────────────────────────────────────
    function staticIcon(p) {
        if (p > 90) return "󰁹"
        if (p > 80) return "󰂂"
        if (p > 70) return "󰂁"
        if (p > 60) return "󰂀"
        if (p > 50) return "󰁿"
        if (p > 40) return "󰁾"
        if (p > 30) return "󰁽"
        if (p > 20) return "󰁼"
        if (p > 10) return "󰁻"
        return "󰁺"
    }

    // Charging glyphs ordered from empty to full.
    readonly property var chargeFrames: ["󰢜","󰂆","󰂇","󰂈","󰂉","󰂊","󰂋","󰂅"]

    readonly property string icon: {
        if (full)     return "󰂄"
        if (charging) {
            const frame = Math.min(chargeFrames.length - 1,
                                   Math.floor(pct * chargeFrames.length / 101))
            return chargeFrames[frame]
        }
        return staticIcon(pct)
    }

    // ── Color ─────────────────────────────────────────────────────────────────
    readonly property color iconColor: {
        if (full)      return Theme.active
        if (charging)  return Theme.active
        if (pct <= 5)  return "#ff4444"
        if (pct <= 10) return "#ff6b00"
        if (pct <= 20) return "#ffcc00"
        if (pct <= 30) return "#ff9900"
        return Theme.text
    }

    // ── Display ───────────────────────────────────────────────────────────────
    Row {
        id: statusRow
        spacing: 4
        anchors.centerIn: parent

        Text {
            id: iconText
            text:                   root.icon
            color:                  root.iconColor
            font.pixelSize:         16
            anchors.verticalCenter: parent.verticalCenter

            // Pulse when critically low and discharging
            SequentialAnimation on opacity {
                id: pulseAnim
                running:  root.pct <= 10 && !root.charging
                loops:    Animation.Infinite
                NumberAnimation { to: 0.2; duration: 600; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutSine }
            }

            // Snap back when animation stops
            Connections {
                target: pulseAnim
                function onRunningChanged() {
                    if (!pulseAnim.running) iconText.opacity = 1.0
                }
            }
        }
        
        Item {
            id: pctWrapper
            property bool show: root.showPercentage || hov.hovered
            implicitWidth: show ? pctText.implicitWidth + 2 : 0
            implicitHeight: pctText.implicitHeight
            clip: true
            anchors.verticalCenter: parent.verticalCenter
            Behavior on implicitWidth { NumberAnimation { duration: Theme.animDuration; easing.type: Easing.InOutCubic } }

            Text {
                id: pctText
                text:           root.pct + "%"
                color:          hov.hovered ? Theme.active : Theme.text
                font.pixelSize: 12
                anchors.verticalCenter: parent.verticalCenter
                Behavior on color { ColorAnimation { duration: 120 } }
            }
        }
    }

    HoverHandler { id: hov }
}
