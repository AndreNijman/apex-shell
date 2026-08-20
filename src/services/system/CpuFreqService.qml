pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// ─────────────────────────────────────────────────────────────────────────────
// CpuFreqService — CPU governor, average clock, and auto-cpufreq daemon state.
//
// Singleton + refcounted. This was the single worst offender in the shell: it
// ran `pgrep -x auto-cpufreq` plus TWO globbed `cat` pipelines every 2 seconds,
// unconditionally, from shell start to shell exit, whether or not the dashboard
// had ever been opened. Three forks per tick, 1.5 forks/second, forever.
//
// Now:
//   • governor  — FileView on cpu0's cpufreq policy. Reading one policy rather
//     than globbing every core is a deliberate trade: FileView cannot glob, and
//     every core in a policy group shares a governor by definition. Machines
//     with heterogeneous policies (big.LITTLE) will report the first policy's
//     governor rather than a "dominant" vote — an acceptable cosmetic loss for
//     removing a per-tick fork.
//   • frequency — /proc/cpuinfo, which carries one "cpu MHz" line per logical
//     CPU, averaged. Falls back to cpu0's scaling_cur_freq (kHz) on kernels and
//     architectures that do not publish "cpu MHz" (notably arm64).
//   • daemon    — still a `pgrep`, because liveness of a foreign daemon is not
//     exposed anywhere in /proc or /sys that FileView can address. It is now
//     refcounted AND slowed to 10s, so it costs nothing at idle and 0.1 forks/s
//     while the stats page is actually on screen.
//
// Exposes:
//   string governor      — e.g. "powersave"
//   string activeProfile — "performance" | "powersave"
//   bool   daemonActive
//   bool   busy
//   string curFreqStr    — e.g. "2.40 GHz"
//   function setActiveProfile(profile)
// ─────────────────────────────────────────────────────────────────────────────

Singleton {
    id: root

    property int refCount: 0

    property int interval: 2000
    property int daemonInterval: 10000

    property string governor: "—"
    property string activeProfile: "powersave"
    property bool daemonActive: false
    property bool busy: false
    property string curFreqStr: "— GHz"

    // ── Governor ────────────────────────────────────────────────────────────
    readonly property FileView govFile: FileView {
        path: "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
        onLoaded: {
            const g = (text() || "").trim()
            if (g === "")
                return
            root.governor = g
            root.activeProfile = g === "performance" ? "performance" : "powersave"
        }
    }

    // ── Frequency: /proc/cpuinfo, averaged over every "cpu MHz" line ────────
    readonly property FileView cpuinfoFile: FileView {
        path: "/proc/cpuinfo"
        onLoaded: {
            const t = text()
            if (!t)
                return

            const lines = t.split("\n")
            let sum = 0;
            let n = 0
            for (let i = 0; i < lines.length; i++) {
                if (!lines[i].startsWith("cpu MHz"))
                    continue
                const v = parseFloat(lines[i].split(":")[1])
                if (!isNaN(v)) {
                    sum += v
                    n++
                }
            }

            if (n > 0)
                root.curFreqStr = (sum / n / 1000).toFixed(2) + " GHz"
            else
                root.freqFile.reload()   // no "cpu MHz" here — try sysfs
        }
    }

    // Fallback for architectures without "cpu MHz" in /proc/cpuinfo (kHz).
    readonly property FileView freqFile: FileView {
        path: "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
        onLoaded: {
            const v = parseFloat((text() || "").trim())
            if (!isNaN(v) && v > 0)
                root.curFreqStr = (v / 1e6).toFixed(2) + " GHz"
        }
    }

    // ── auto-cpufreq daemon liveness ────────────────────────────────────────
    readonly property Process daemonProc: Process {
        command: ["sh", "-c", "pgrep -x auto-cpufreq >/dev/null && echo active || echo inactive"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: root.daemonActive = text.trim() === "active"
        }
    }

    // ── Set governor across every core (pkexec) ─────────────────────────────
    readonly property Process setProc: Process {
        command: []
        running: false
        onRunningChanged: {
            if (!running) {
                root.busy = false
                root._poll()
            }
        }
    }

    function setActiveProfile(profile) {
        if (root.busy)
            return
        root.busy = true

        const gov = profile === "performance" ? "performance" : "powersave"
        root.setProc.command = ["pkexec", "sh", "-c", "echo \"$1\" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null", "--", gov]
        root.setProc.running = false
        root.setProc.running = true
    }

    function _poll() {
        root.govFile.reload()
        root.cpuinfoFile.reload()
    }

    readonly property Timer poll: Timer {
        interval: root.interval
        running: root.refCount > 0
        repeat: true
        triggeredOnStart: true
        onTriggered: root._poll()
    }

    readonly property Timer daemonPoll: Timer {
        interval: root.daemonInterval
        running: root.refCount > 0
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            root.daemonProc.running = false
            root.daemonProc.running = true
        }
    }
}
