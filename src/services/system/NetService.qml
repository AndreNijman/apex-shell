pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// ─────────────────────────────────────────────────────────────────────────────
// NetService — throughput on the default-route interface, from /proc.
//
// Singleton + refcounted; free while nothing holds a ref.
//
// ── Two forks per second removed ────────────────────────────────────────────
// The old implementation ran BOTH `ip route get 1.1.1.1 | awk …` and
// `cat /proc/net/dev` every single second, unconditionally, to answer "which
// interface, and how fast". Both are now plain FileView reads:
//
//   • interface — /proc/net/route, the same routing table `ip route` prints.
//     The default route is the row with Destination 00000000; when several
//     exist (wifi + ethernet + VPN up together) the lowest Metric wins, which
//     is precisely the kernel's own selection rule. Route changes appear the
//     moment the table changes, so VPN up/down and cable plug/unplug are picked
//     up as fast as before — without the fork.
//
//   • counters — /proc/net/dev, as before but in-process.
//
// Exposes:
//   string iface      — e.g. "wlan0"
//   string upSpeed    — e.g. "1.2 MB/s"
//   string downSpeed
// ─────────────────────────────────────────────────────────────────────────────

Singleton {
    id: root

    property int refCount: 0

    property int interval: 1000

    property string iface: "—"
    property string upSpeed: "0 KB/s"
    property string downSpeed: "0 KB/s"

    property real _prevRx: 0
    property real _prevTx: 0
    property real _prevAt: 0
    property bool _firstRead: true

    // Dropping to zero refs means the next delta would span the whole idle gap.
    onRefCountChanged: if (refCount === 0) root._firstRead = true

    function _resetCounters() {
        root._firstRead = true
        root._prevRx = 0
        root._prevTx = 0
        root.upSpeed = "0 KB/s"
        root.downSpeed = "0 KB/s"
    }

    // /proc/net/route:
    //   Iface  Destination  Gateway  Flags  RefCnt  Use  Metric  Mask ...
    //   wlan0  00000000     0102A8C0 0003   0       0    600     00000000
    function _parseRoute(text) {
        if (!text)
            return

        const lines = text.split("\n")
        let best = "";
        let bestMetric = Number.MAX_VALUE

        for (let i = 1; i < lines.length; i++) {
            const parts = lines[i].trim().split(/\s+/)
            if (parts.length < 7)
                continue
            // Destination 00000000 == default route (0.0.0.0/0).
            if (parts[1] !== "00000000")
                continue
            const metric = parseInt(parts[6]) || 0
            if (metric < bestMetric) {
                bestMetric = metric
                best = parts[0]
            }
        }

        if (best !== "" && best !== root.iface) {
            root.iface = best
            root._resetCounters()
        } else if (best === "" && root.iface !== "—") {
            // Default route went away entirely (all links down).
            root.iface = "—"
            root._resetCounters()
        }
    }

    function _parseDev(text) {
        if (!text || root.iface === "—")
            return

        const lines = text.split("\n")
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i].trim()
            if (!line.startsWith(root.iface + ":"))
                continue

            const parts = line.split(":")[1].trim().split(/\s+/)
            const rx = parseFloat(parts[0])
            const tx = parseFloat(parts[8])
            const now = Date.now()

            if (!root._firstRead) {
                // Wall-clock delta, not the nominal interval: a tick that lands
                // late (busy machine, resumed from sleep) would otherwise report
                // a proportionally inflated rate.
                const dt = (now - root._prevAt) / 1000
                if (dt > 0) {
                    root.downSpeed = root._fmt(Math.max(0, rx - root._prevRx) / dt)
                    root.upSpeed = root._fmt(Math.max(0, tx - root._prevTx) / dt)
                }
            }

            root._firstRead = false
            root._prevRx = rx
            root._prevTx = tx
            root._prevAt = now
            break
        }
    }

    function _fmt(bytesPerSec) {
        if (bytesPerSec >= 1024 * 1024)
            return (Math.round(bytesPerSec / 1024 / 1024 * 10) / 10) + " MB/s"
        if (bytesPerSec >= 1024)
            return Math.round(bytesPerSec / 1024) + " KB/s"
        return Math.round(bytesPerSec) + " B/s"
    }

    readonly property FileView routeFile: FileView {
        path: "/proc/net/route"
        onLoaded: root._parseRoute(text())
    }

    readonly property FileView devFile: FileView {
        path: "/proc/net/dev"
        onLoaded: root._parseDev(text())
    }

    readonly property Timer poll: Timer {
        interval: root.interval
        running: root.refCount > 0
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            root.routeFile.reload()
            root.devFile.reload()
        }
    }
}
