import QtQuick
import Quickshell.Io

// AMD Radeon 780M iGPU telemetry (this machine has no dGPU).
//
// Exposes:
//   igpu.usagePercent — 0–100 (amdgpu gpu_busy_percent)
//   igpu.curMhz       — e.g. "800 MHz" (amdgpu sclk, from hwmon freq1_input)

QtObject {
    id: root

    property bool active: true

    property QtObject igpu: QtObject {
        property real   usagePercent: 0.0
        property string curMhz:       "— MHz"
    }

    // ── GPU busy % — stable sysfs path for the sole DRM card ───────────────────
    property var _busyProc: Process {
        command: ["cat", "/sys/class/drm/card0/device/gpu_busy_percent"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                var v = parseFloat(text.trim())
                if (!isNaN(v))
                    root.igpu.usagePercent = Math.max(0, Math.min(100, Math.round(v)))
            }
        }
    }

    // ── sclk — amdgpu hwmon index is non-deterministic, so glob it ─────────────
    property var _freqProc: Process {
        command: ["sh", "-c",
            "cat /sys/class/drm/card0/device/hwmon/hwmon*/freq1_input 2>/dev/null | head -n1"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                var hz = parseFloat(text.trim())
                if (!isNaN(hz) && hz > 0)
                    root.igpu.curMhz = Math.round(hz / 1000000) + " MHz"
            }
        }
    }

    // ── Poll timer ────────────────────────────────────────────────────────────
    property var _timer: Timer {
        interval: 1000
        running:  root.active
        repeat:   true
        onTriggered: {
            _busyProc.running = false
            _busyProc.running = true
            _freqProc.running = false
            _freqProc.running = true
        }
    }

    Component.onCompleted: {
        _busyProc.running = true
        _freqProc.running = true
    }
}
