import QtQuick
import Quickshell.Io

// GPU telemetry. Handles three cases from the same code path:
//
//   1. Single AMD (APU / Radeon)          — the historical case, unchanged.
//   2. Hybrid Optimus (Intel iGPU + NVIDIA dGPU, e.g. MSI Katana).
//   3. NVIDIA-only / reverse-PRIME.
//
// At start-up every /sys/class/drm/card*/device node is enumerated (PCI
// `vendor`: 0x1002 AMD, 0x8086 Intel, 0x10de NVIDIA). A "primary" GPU — the one
// the compositor renders on — is chosen (boot_vga first, then the card that
// actually exposes utilisation, then card0) and surfaced under the historical
// `igpu` object so existing bindings keep working. Any second GPU is surfaced
// under `dgpu`.
//
// Utilisation source per vendor:
//   • AMD    — sysfs `gpu_busy_percent` + hwmon `freq1_input` (identical to the
//              old single-card readout).
//   • Intel  — no `gpu_busy_percent` in sysfs; frequency via `gt_cur_freq_mhz`,
//              utilisation left unavailable (tile greys, as before).
//   • NVIDIA — not in sysfs the same way; degrade gracefully — the GPU is always
//              shown present with a name, and utilisation/clock come from
//              `nvidia-smi` only if it is installed.
//
// Exposes:
//   available          — true once the PRIMARY GPU has a live utilisation read
//                        (on an AMD-only box this is exactly the old behaviour)
//   igpu.usagePercent  — 0–100, primary GPU
//   igpu.curMhz        — e.g. "800 MHz", primary GPU
//   primaryVendor      — "AMD" | "Intel" | "NVIDIA" | raw id
//   primaryName        — human name (refined by nvidia-smi when primary is NVIDIA)
//   dgpu.{present,hasUtil,vendor,name,usagePercent,curMhz} — the second GPU
//   gpus               — array snapshot, one entry per physical GPU

QtObject {
    id: root

    property bool active: true

    // True once the primary GPU exposes a utilisation readout. On an AMD-only
    // box this is identical to the previous implementation.
    property bool available: false

    // Primary (the GPU the compositor renders on). Kept under the historical
    // `igpu` name so consumers (DashStats) need no change.
    property QtObject igpu: QtObject {
        id: igpuObj
        property real   usagePercent: 0.0
        property string curMhz:       "— MHz"
    }
    property string primaryVendor: ""
    property string primaryName:   ""

    // Discrete / secondary GPU (e.g. the NVIDIA dGPU on an Optimus laptop).
    property QtObject dgpu: QtObject {
        id: dgpuObj
        property bool   present:      false
        property bool   hasUtil:      false
        property string vendor:       ""
        property string name:         ""
        property real   usagePercent: 0.0
        property string curMhz:       "— MHz"
    }

    // Enumeration snapshot: [{ card, vendorId, vendor, name, primary, hasUtil }].
    property var gpus: []

    // ── internals ──────────────────────────────────────────────────────────────
    property string _primaryDir:      ""
    property bool   _primaryFreqIsHz: false   // AMD hwmon reports Hz; Intel MHz
    property bool   _pollBusy:        false
    property bool   _pollFreq:        false
    property bool   _pollNv:          false
    property bool   _nvPrimary:       false   // primary GPU is the NVIDIA one
    property string _dgpuDir:         ""
    property bool   _pollDBusy:       false
    property bool   _pollDFreq:       false
    property bool   _polling:         false

    function _vendorName(id) {
        if (id === "0x1002") return "AMD"
        if (id === "0x8086") return "Intel"
        if (id === "0x10de") return "NVIDIA"
        return id
    }

    // ── Enumerate every DRM GPU ─────────────────────────────────────────────────
    // Emits one "card|vendorId|boot_vga|has_gpu_busy" line per real card. The
    // `*-*` case skips connector nodes (card0-eDP-1, …); the vendor read filters
    // out anything that is not a PCI GPU device.
    property var _enumProc: Process {
        command: ["sh", "-c",
            "for c in /sys/class/drm/card[0-9]*; do " +
            "  case \"${c##*/}\" in *-*) continue ;; esac; " +
            "  d=\"$c/device\"; [ -d \"$d\" ] || continue; " +
            "  v=$(cat \"$d/vendor\" 2>/dev/null) || continue; " +
            "  [ -n \"$v\" ] || continue; " +
            "  bv=$(cat \"$d/boot_vga\" 2>/dev/null || echo 0); " +
            "  hb=0; [ -f \"$d/gpu_busy_percent\" ] && hb=1; " +
            "  printf '%s|%s|%s|%s\\n' \"${c##*/}\" \"$v\" \"$bv\" \"$hb\"; " +
            "done"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: root._onEnum(text)
        }
    }

    function _onEnum(out) {
        var lines = out.split("\n")
        var cards = []
        for (var i = 0; i < lines.length; i++) {
            var ln = lines[i].trim()
            if (ln === "") continue
            var p = ln.split("|")
            if (p.length < 4) continue
            cards.push({
                card:     p[0],
                vendorId: p[1],
                bootVga:  p[2] === "1",
                hasBusy:  p[3] === "1"
            })
        }

        // reset
        root.available   = false
        root._pollBusy   = false
        root._pollFreq   = false
        root._pollNv     = false
        root._pollDBusy  = false
        root._pollDFreq  = false
        root._nvPrimary  = false
        dgpuObj.present = false
        dgpuObj.hasUtil = false

        if (cards.length === 0) {
            root.gpus     = []
            root._polling = false
            return
        }

        // ── choose primary (the display / compositor GPU) ──
        var pi = -1
        if (cards.length === 1) pi = 0
        if (pi < 0) for (var j = 0; j < cards.length; j++) if (cards[j].bootVga) { pi = j; break }
        if (pi < 0) for (var k = 0; k < cards.length; k++) if (cards[k].hasBusy) { pi = k; break }
        if (pi < 0) pi = 0
        var prim = cards[pi]

        root._primaryDir   = "/sys/class/drm/" + prim.card + "/device"
        root.primaryVendor = root._vendorName(prim.vendorId)
        root.primaryName   = root.primaryVendor + " GPU"

        // ── choose secondary (prefer an NVIDIA dGPU, else any other card) ──
        var di = -1
        for (var a = 0; a < cards.length; a++) if (a !== pi && cards[a].vendorId === "0x10de") { di = a; break }
        if (di < 0) for (var b = 0; b < cards.length; b++) if (b !== pi) { di = b; break }

        // ── configure the primary's utilisation/frequency source ──
        if (prim.vendorId === "0x10de") {
            // NVIDIA is the primary — utilisation via nvidia-smi (if installed)
            root._pollNv    = true
            root._nvPrimary = true
        } else if (prim.hasBusy) {
            // AMD (or any vendor exposing gpu_busy_percent) — the historical path
            root._configureAmdPrimary()
            root.available = true
        } else if (prim.vendorId === "0x8086") {
            // Intel iGPU — no gpu_busy_percent; show frequency, leave util greyed
            root._freqProc.command = ["sh", "-c",
                "cat /sys/class/drm/" + prim.card + "/gt_cur_freq_mhz 2>/dev/null | head -n1"]
            root._primaryFreqIsHz = false
            root._pollFreq = true
        }

        // ── configure the secondary ──
        if (di >= 0) {
            var sec = cards[di]
            root._dgpuDir     = "/sys/class/drm/" + sec.card + "/device"
            dgpuObj.present = true
            dgpuObj.vendor  = root._vendorName(sec.vendorId)
            dgpuObj.name    = dgpuObj.vendor + " GPU"
            if (sec.vendorId === "0x10de") {
                root._pollNv = true            // nvidia-smi covers the dGPU
            } else if (sec.hasBusy) {
                root._dbusyProc.command = ["cat", root._dgpuDir + "/gpu_busy_percent"]
                root._dfreqProc.command = ["sh", "-c",
                    "cat " + root._dgpuDir + "/hwmon/hwmon*/freq1_input 2>/dev/null | head -n1"]
                root._pollDBusy   = true
                root._pollDFreq   = true
                dgpuObj.hasUtil = true
            }
        }

        // ── nvidia-smi command (drives whichever slot is NVIDIA) ──
        if (root._pollNv) {
            root._nvProc.command = ["sh", "-c",
                "command -v nvidia-smi >/dev/null 2>&1 && " +
                "nvidia-smi --query-gpu=name,utilization.gpu,clocks.gr " +
                "--format=csv,noheader,nounits 2>/dev/null | head -n1"]
        }

        // ── build the public snapshot ──
        var snap = []
        for (var m = 0; m < cards.length; m++) {
            var isPrim = (m === pi)
            var isSec  = (di >= 0 && m === di)
            var util   = isPrim ? (root.available || root._nvPrimary)
                                : (isSec ? (dgpuObj.hasUtil || cards[m].vendorId === "0x10de") : false)
            snap.push({
                card:     cards[m].card,
                vendorId: cards[m].vendorId,
                vendor:   root._vendorName(cards[m].vendorId),
                name:     root._vendorName(cards[m].vendorId) + " GPU",
                primary:  isPrim,
                hasUtil:  util
            })
        }
        root.gpus = snap

        root._polling = root._pollBusy || root._pollFreq || root._pollNv
                     || root._pollDBusy || root._pollDFreq

        // prime immediate reads
        if (root._pollBusy)  root._busyProc.running  = true
        if (root._pollFreq)  root._freqProc.running  = true
        if (root._pollDBusy) root._dbusyProc.running = true
        if (root._pollDFreq) root._dfreqProc.running = true
        if (root._pollNv)    root._nvProc.running    = true
    }

    // AMD primary: byte-for-byte the old single-card commands (gpu_busy_percent +
    // hwmon freq1_input), so an AMD-only box reads exactly as it did before.
    function _configureAmdPrimary() {
        root._busyProc.command = ["cat", root._primaryDir + "/gpu_busy_percent"]
        root._freqProc.command = ["sh", "-c",
            "cat " + root._primaryDir + "/hwmon/hwmon*/freq1_input 2>/dev/null | head -n1"]
        root._primaryFreqIsHz = true
        root._pollBusy = true
        root._pollFreq = true
    }

    // ── primary GPU busy % ──────────────────────────────────────────────────────
    property var _busyProc: Process {
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                var v = parseFloat(text.trim())
                if (!isNaN(v))
                    igpuObj.usagePercent = Math.max(0, Math.min(100, Math.round(v)))
            }
        }
    }

    // ── primary GPU frequency (AMD hwmon = Hz, Intel gt_cur_freq_mhz = MHz) ──────
    property var _freqProc: Process {
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                var raw = parseFloat(text.trim())
                if (!isNaN(raw) && raw > 0) {
                    var mhz = root._primaryFreqIsHz ? Math.round(raw / 1000000) : Math.round(raw)
                    igpuObj.curMhz = mhz + " MHz"
                }
            }
        }
    }

    // ── nvidia-smi: name + utilisation + clock for the NVIDIA GPU ────────────────
    property var _nvProc: Process {
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                var line = text.trim()
                if (line === "") return   // nvidia-smi absent → GPU stays present, no util
                var parts = line.split(",")
                var nm  = (parts[0] || "").trim()
                var ut  = parseFloat((parts[1] || "").trim())
                var clk = parseFloat((parts[2] || "").trim())
                if (root._nvPrimary) {
                    if (nm !== "") root.primaryName = nm
                    if (!isNaN(ut)) {
                        igpuObj.usagePercent = Math.max(0, Math.min(100, Math.round(ut)))
                        root.available = true
                    }
                    if (!isNaN(clk) && clk > 0) igpuObj.curMhz = Math.round(clk) + " MHz"
                } else if (dgpuObj.present) {
                    if (nm !== "") dgpuObj.name = nm
                    if (!isNaN(ut)) {
                        dgpuObj.usagePercent = Math.max(0, Math.min(100, Math.round(ut)))
                        dgpuObj.hasUtil = true
                    }
                    if (!isNaN(clk) && clk > 0) dgpuObj.curMhz = Math.round(clk) + " MHz"
                }
            }
        }
    }

    // ── secondary AMD dGPU busy % ───────────────────────────────────────────────
    property var _dbusyProc: Process {
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                var v = parseFloat(text.trim())
                if (!isNaN(v))
                    dgpuObj.usagePercent = Math.max(0, Math.min(100, Math.round(v)))
            }
        }
    }

    // ── secondary AMD dGPU frequency ────────────────────────────────────────────
    property var _dfreqProc: Process {
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                var hz = parseFloat(text.trim())
                if (!isNaN(hz) && hz > 0)
                    dgpuObj.curMhz = Math.round(hz / 1000000) + " MHz"
            }
        }
    }

    // ── Poll timer ──────────────────────────────────────────────────────────────
    property var _timer: Timer {
        interval: 1000
        running:  root.active && root._polling
        repeat:   true
        onTriggered: {
            if (root._pollBusy)  { root._busyProc.running  = false; root._busyProc.running  = true }
            if (root._pollFreq)  { root._freqProc.running  = false; root._freqProc.running  = true }
            if (root._pollDBusy) { root._dbusyProc.running = false; root._dbusyProc.running = true }
            if (root._pollDFreq) { root._dfreqProc.running = false; root._dfreqProc.running = true }
            if (root._pollNv)    { root._nvProc.running    = false; root._nvProc.running    = true }
        }
    }

    Component.onCompleted: root._enumProc.running = true
}
