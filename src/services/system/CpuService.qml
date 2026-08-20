pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// ─────────────────────────────────────────────────────────────────────────────
// CpuService — aggregate CPU utilisation from /proc/stat.
//
// Singleton + refcounted. Costs nothing at all while no consumer holds a ref.
//
// ── Why FileView and not `cat /proc/stat` ───────────────────────────────────
// This used to spawn `cat` once a second, forever, per instantiation (and it was
// instantiated per screen). FileView reads the file in-process: no fork, no
// exec, no pipe, no shell. The old "FileView can't read virtual fs" comment on
// MemService was simply wrong — verified against Quickshell 0.3.0 on /proc/stat,
// /proc/meminfo, /proc/net/dev and /sys/**, all of which reload correctly and
// re-emit `loaded` on every reload().
//
// Parsing is driven by FileView's `loaded` signal rather than reading text()
// straight after reload(): reload() is asynchronous, so text() immediately after
// it still returns the PREVIOUS contents. Signal-driven parsing has no such
// off-by-one-interval trap.
//
// Exposes:
//   real usagePercent  — 0..100, aggregate across all cores
// ─────────────────────────────────────────────────────────────────────────────

Singleton {
    id: root

    // Consumers: declare `ServiceRef { service: CpuService }`.
    property int refCount: 0

    property int interval: 1000

    property real usagePercent: 0.0

    property real _prevIdle: 0
    property real _prevTotal: 0
    property bool _firstRead: true

    // A ref that comes back after a gap must not report a delta measured across
    // the idle period — that would read as a huge spike on the first tick.
    onRefCountChanged: if (refCount === 0) root._firstRead = true

    function _parse(text) {
        if (!text)
            return

        const line = text.split("\n")[0]
        const parts = line.trim().split(/\s+/)
        if (parts.length < 8 || parts[0] !== "cpu")
            return

        const user = parseFloat(parts[1])
        const nice = parseFloat(parts[2])
        const system = parseFloat(parts[3])
        const idle = parseFloat(parts[4])
        const iowait = parseFloat(parts[5])
        const irq = parseFloat(parts[6])
        const softirq = parseFloat(parts[7])
        const steal = parts.length > 8 ? parseFloat(parts[8]) : 0

        const totalIdle = idle + iowait
        const total = user + nice + system + totalIdle + irq + softirq + steal

        if (!root._firstRead) {
            const dTotal = total - root._prevTotal
            const dIdle = totalIdle - root._prevIdle
            if (dTotal > 0)
                root.usagePercent = Math.round((1 - dIdle / dTotal) * 100)
        }

        root._firstRead = false
        root._prevTotal = total
        root._prevIdle = totalIdle
    }

    readonly property FileView statFile: FileView {
        path: "/proc/stat"
        onLoaded: root._parse(text())
    }

    readonly property Timer poll: Timer {
        interval: root.interval
        running: root.refCount > 0
        repeat: true
        triggeredOnStart: true
        onTriggered: root.statFile.reload()
    }
}
