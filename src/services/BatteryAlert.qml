pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Services.UPower
import "../"

// ─────────────────────────────────────────────────────────────────────────────
// BatteryAlert — low-battery warning, exactly once per threshold per discharge.
//
// This logic used to live in modules/Right/BatteryStatus.qml, which is a BAR
// widget and is therefore instantiated once per screen. Each copy carried its
// own `warnedLevels` dedupe list and its own BatteryWarning window, so on a
// two-monitor machine every threshold produced two warning popups, and the
// "already warned" bookkeeping in one bar knew nothing about the other. The
// dedupe was correct per instance and useless globally.
//
// Owning it in a singleton makes the dedupe mean what it says: one window, one
// list, one warning per threshold, however many outputs are connected.
//
// The list resets when charging starts, so unplugging again re-arms every
// threshold.
// ─────────────────────────────────────────────────────────────────────────────

Singleton {
    id: root

    // Descending, so a battery that falls straight past several thresholds
    // warns at the most severe one it has reached rather than the mildest.
    readonly property var thresholds: [5, 10, 20, 30]

    readonly property var bat: UPower.displayDevice

    readonly property bool valid: bat && bat.ready && bat.isLaptopBattery

    readonly property int pct: root.valid ? Math.round(bat.percentage * 100) : 100

    readonly property bool charging: root.valid
        ? (bat.state === UPowerDeviceState.Charging
           || bat.state === UPowerDeviceState.PendingCharge
           || bat.state === UPowerDeviceState.FullyCharged)
        : true

    property var warnedLevels: []

    function check() {
        if (!root.valid)
            return

        if (root.charging) {
            if (root.warnedLevels.length > 0)
                root.warnedLevels = []
            return
        }

        for (const lvl of root.thresholds) {
            if (root.pct > lvl)
                continue
            if (root.warnedLevels.indexOf(lvl) >= 0)
                continue
            root.warnedLevels = root.warnedLevels.concat([lvl])
            warningWindow.warnLevel = lvl
            warningWindow.visible = true
            return
        }
    }

    onPctChanged: root.check()
    onChargingChanged: root.check()

    readonly property BatteryWarning window: BatteryWarning {
        id: warningWindow

        visible: false
    }
}
