import QtQuick
import Quickshell.Services.UPower
import "../"

// Config:
//showPercentage: bool — always show % beside icon (default: false = hover only)

Item {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


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
    // Two levels, because the four this replaced were not a ramp. They ran
    // #ff4444 / #ff6b00 / #ffcc00 / #ff9900 at 5 / 10 / 20 / 30, which is not
    // monotonic: 20% showed a calm yellow while 30% showed a more urgent orange,
    // so the icon got *less* alarming as the battery drained past 30. That is
    // accretion, not a designed scale, and there is no four-step severity token
    // to express it with. Critical and low now use the same two tokens as
    // BatteryWarning, which is the other surface reporting the same fact.
    // Charging and full are good news, so the success colour (brief §D.3) — it
    // used to be the accent, which in the bar is reserved for "you opened this".
    readonly property color iconColor: {
        if (full)      return Theme.success
        if (charging)  return Theme.success
        if (pct <= 10) return Theme.danger
        if (pct <= 30) return Theme.warning
        return hov.hovered ? Theme.textPrimary : Theme.iconDefault
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
            font.pixelSize:         theme.typeIcon
            font.family:            Theme.fontIcon
            anchors.verticalCenter: parent.verticalCenter

            // Pulse when critically low and discharging
            SequentialAnimation on opacity {
                id: pulseAnim
                running:  root.pct <= 10 && !root.charging && Motion.ambient
                // Finish the current beat when gated off, so it rests at its
                // end value instead of freezing mid-fade (Reduce Motion mid-pulse).
                alwaysRunToEnd: true
                loops:    Animation.Infinite
                NumberAnimation { to: 0.2; duration: Motion.pulseHalf; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1.0; duration: Motion.pulseHalf; easing.type: Easing.InOutSine }
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
            Behavior on implicitWidth { MotionSpring { role: "page" } }

            Text {
                id: pctText
                text:           root.pct + "%"
                color:          hov.hovered ? Theme.textPrimary : Theme.textSecondary
                font.pixelSize: theme.typeBodySmall
                font.features:  { "tnum": 1 }
                anchors.verticalCenter: parent.verticalCenter
                Behavior on color { MotionColor {} }
            }
        }
    }

    HoverHandler { id: hov }
}
