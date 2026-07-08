import QtQuick
import Quickshell.Io

// AMD GPU telemetry via amdgpu sysfs.
//
// Card indices aren't stable (card0 may be a render-only or non-AMD node) and
// NVIDIA-only systems lack gpu_busy_percent entirely, so at start-up we
// discover the first DRM card whose device dir exposes gpu_busy_percent and
// poll that. If none is found, `available` stays false and the UI greys out.
//
// Exposes:
//   available          — true once an amdgpu card is discovered
//   igpu.usagePercent  — 0–100 (amdgpu gpu_busy_percent)
//   igpu.curMhz        — e.g. "800 MHz" (amdgpu sclk, from hwmon freq1_input)

QtObject {
    id: root

    property bool active: true

    // False until discovery finds a card exposing gpu_busy_percent.
    property bool available: false

    // Device dir of the discovered card, e.g. "/sys/class/drm/card0/device".
    property string _deviceDir: ""

    property QtObject igpu: QtObject {
        property real   usagePercent: 0.0
        property string curMhz:       "— MHz"
    }

    // ── Discover the DRM card exposing amdgpu telemetry ────────────────────────
    // Fixed glob over card[0-9]*; emit the device dir of the first match.
    property var _discoverProc: Process {
        command: ["sh", "-c",
            "for f in /sys/class/drm/card[0-9]*/device/gpu_busy_percent; do " +
            "[ -f \"$f\" ] && { printf %s \"${f%/gpu_busy_percent}\"; break; }; done"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                var dir = text.trim()
                if (dir !== "") {
                    root._deviceDir = dir
                    root.available  = true
                    // Prime an immediate first read.
                    _busyProc.running = true
                    _freqProc.running = true
                } else {
                    root.available = false
                }
            }
        }
    }

    // ── GPU busy % — discovered card's device dir ──────────────────────────────
    property var _busyProc: Process {
        command: ["cat", root._deviceDir + "/gpu_busy_percent"]
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
            "cat " + root._deviceDir + "/hwmon/hwmon*/freq1_input 2>/dev/null | head -n1"]
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
        running:  root.active && root.available
        repeat:   true
        onTriggered: {
            _busyProc.running = false
            _busyProc.running = true
            _freqProc.running = false
            _freqProc.running = true
        }
    }

    Component.onCompleted: _discoverProc.running = true
}
