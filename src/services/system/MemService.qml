pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// ─────────────────────────────────────────────────────────────────────────────
// MemService — memory usage from /proc/meminfo.
//
// Singleton + refcounted; free while nothing holds a ref.
//
// The previous implementation carried the comment "FileView can't read virtual
// fs" and forked `cat /proc/meminfo` every 2s with `active: true` hardcoded at
// two call sites, so it ran for the entire session whether or not anything was
// on screen. The comment was wrong: FileView reads /proc fine (verified on
// Quickshell 0.3.0). See CpuService for the signal-driven reload rationale.
//
// Exposes:
//   real   usagePercent  — 0..100
//   real   usedGb / totalGb
//   string usedStr / totalStr  — e.g. "11.2 GB"
// ─────────────────────────────────────────────────────────────────────────────

Singleton {
    id: root

    property int refCount: 0

    property int interval: 2000

    property real usagePercent: 0.0
    property real usedGb: 0.0
    property real totalGb: 0.0
    property string usedStr: "—"
    property string totalStr: "—"

    function _parse(text) {
        if (!text)
            return

        let total = 0;
        let avail = 0;
        const lines = text.split("\n")
        for (let i = 0; i < lines.length; i++) {
            const parts = lines[i].trim().split(/\s+/)
            if (parts[0] === "MemTotal:")
                total = parseFloat(parts[1])
            else if (parts[0] === "MemAvailable:")
                avail = parseFloat(parts[1])
            if (total > 0 && avail > 0)
                break
        }
        if (total <= 0)
            return

        const used = total - avail
        root.totalGb = Math.round(total / 1024 / 1024 * 10) / 10
        root.usedGb = Math.round(used / 1024 / 1024 * 10) / 10
        root.usagePercent = Math.round(used / total * 100)
        root.usedStr = root.usedGb + " GB"
        root.totalStr = root.totalGb + " GB"
    }

    readonly property FileView memFile: FileView {
        path: "/proc/meminfo"
        onLoaded: root._parse(text())
    }

    readonly property Timer poll: Timer {
        interval: root.interval
        running: root.refCount > 0
        repeat: true
        triggeredOnStart: true
        onTriggered: root.memFile.reload()
    }
}
