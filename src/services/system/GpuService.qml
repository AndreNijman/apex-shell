pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// ─────────────────────────────────────────────────────────────────────────────
// GpuService — GPU telemetry. Handles three cases from one code path:
//
//   1. Single AMD (APU / Radeon)   — the historical case.
//   2. Hybrid Optimus (Intel iGPU + NVIDIA dGPU, e.g. MSI Katana).
//   3. NVIDIA-only / reverse-PRIME.
//
// Singleton + refcounted, and lazily constructed: a QML singleton is not created
// until first referenced, so on a machine where the stats page is never opened
// this file never runs at all — not even the enumeration.
//
// ── Forks ───────────────────────────────────────────────────────────────────
// Enumeration is ONE shell invocation, once, on first use. It resolves the
// concrete sysfs paths (including the globbed hwmon directory, which FileView
// cannot expand) and hands them to FileViews, so every recurring read afterwards
// is fork-free. The old version ran up to five `cat`/`sh` pipelines per second.
//
// nvidia-smi is the one exception: NVIDIA publishes nothing equivalent in sysfs,
// so it stays a subprocess — refcounted, and never spawned at all unless an
// NVIDIA card is actually present.
//
// Utilisation source per vendor:
//   • AMD    — sysfs `gpu_busy_percent` + hwmon `freq1_input`.
//   • Intel  — no `gpu_busy_percent`; frequency via `gt_cur_freq_mhz`,
//              utilisation left unavailable (tile greys).
//   • NVIDIA — `nvidia-smi` if installed, with its exit status checked.
//
// Exposes:
//   available          — primary GPU has a live utilisation read
//   igpu.usagePercent / igpu.curMhz   — primary GPU
//   primaryVendor / primaryName
//   dgpu.{present,hasUtil,vendor,name,usagePercent,curMhz}
//   gpus               — array snapshot, one entry per physical GPU
//   vendorOverride     — "", "amd", "intel", "nvidia": force the primary vendor
// ─────────────────────────────────────────────────────────────────────────────

Singleton {
    id: root

    property int refCount: 0

    property int interval: 1000

    // User override for broken/odd topologies where boot_vga and utilisation
    // heuristics pick the wrong card. Empty means "detect". Settable from the
    // config page; persisted by SettingsService.
    property string vendorOverride: ""

    property bool available: false

    // Primary (the GPU the compositor renders on). Kept under the historical
    // `igpu` name so existing consumers need no change.
    readonly property QtObject igpu: QtObject {
        id: igpuObj

        property real usagePercent: 0.0
        property string curMhz: "— MHz"
    }

    property string primaryVendor: ""
    property string primaryName: ""

    readonly property QtObject dgpu: QtObject {
        id: dgpuObj

        property bool present: false
        property bool hasUtil: false
        property string vendor: ""
        property string name: ""
        property real usagePercent: 0.0
        property string curMhz: "— MHz"
    }

    property var gpus: []

    // ── internals ───────────────────────────────────────────────────────────
    property bool _primaryFreqIsHz: false   // AMD hwmon reports Hz; Intel MHz
    property bool _pollBusy: false
    property bool _pollFreq: false
    property bool _pollNv: false
    property bool _pollDBusy: false
    property bool _pollDFreq: false
    property bool _nvPrimary: false
    property bool _enumerated: false

    function _vendorName(id) {
        if (id === "0x1002")
            return "AMD"
        if (id === "0x8086")
            return "Intel"
        if (id === "0x10de")
            return "NVIDIA"
        return id
    }

    function _vendorId(name) {
        const n = (name || "").toLowerCase()
        if (n === "amd")
            return "0x1002"
        if (n === "intel")
            return "0x8086"
        if (n === "nvidia")
            return "0x10de"
        return ""
    }

    // ── Enumerate every DRM GPU, once ───────────────────────────────────────
    // Emits "card|vendorId|boot_vga|has_gpu_busy|freqPath" per real card. The
    // `*-*` case skips connector nodes (card0-eDP-1, …); the vendor read filters
    // out anything that is not a PCI GPU device. freqPath is resolved HERE
    // because it is a glob on AMD (hwmon/hwmon*/freq1_input) and FileView cannot
    // expand globs.
    readonly property Process enumProc: Process {
        command: ["sh", "-c", "for c in /sys/class/drm/card[0-9]*; do " + "  case \"${c##*/}\" in *-*) continue ;; esac; " + "  d=\"$c/device\"; [ -d \"$d\" ] || continue; " + "  v=$(cat \"$d/vendor\" 2>/dev/null) || continue; " + "  [ -n \"$v\" ] || continue; " + "  bv=$(cat \"$d/boot_vga\" 2>/dev/null || echo 0); " + "  hb=0; [ -f \"$d/gpu_busy_percent\" ] && hb=1; " + "  fp=''; " + "  for f in \"$d\"/hwmon/hwmon*/freq1_input; do [ -f \"$f\" ] && fp=\"$f\" && break; done; " + "  [ -n \"$fp\" ] || { [ -f \"$c/gt_cur_freq_mhz\" ] && fp=\"$c/gt_cur_freq_mhz\"; }; " + "  printf '%s|%s|%s|%s|%s\\n' \"${c##*/}\" \"$v\" \"$bv\" \"$hb\" \"$fp\"; " + "done"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: root._onEnum(text)
        }
    }

    function _onEnum(out) {
        const lines = (out || "").split("\n")
        const cards = []
        for (let i = 0; i < lines.length; i++) {
            const ln = lines[i].trim()
            if (ln === "")
                continue
            const p = ln.split("|")
            if (p.length < 4)
                continue
            cards.push({
                "card": p[0],
                "vendorId": p[1],
                "bootVga": p[2] === "1",
                "hasBusy": p[3] === "1",
                "freqPath": p.length > 4 ? p[4] : ""
            })
        }

        root.available = false
        root._pollBusy = false
        root._pollFreq = false
        root._pollNv = false
        root._pollDBusy = false
        root._pollDFreq = false
        root._nvPrimary = false
        dgpuObj.present = false
        dgpuObj.hasUtil = false

        if (cards.length === 0) {
            root.gpus = []
            return
        }

        // ── choose primary (the display / compositor GPU) ──
        let pi = -1

        // An explicit user override wins over every heuristic.
        const wantId = root._vendorId(root.vendorOverride)
        if (wantId !== "")
            for (let w = 0; w < cards.length; w++)
                if (cards[w].vendorId === wantId) {
                    pi = w
                    break
                }

        if (pi < 0 && cards.length === 1)
            pi = 0
        if (pi < 0)
            for (let j = 0; j < cards.length; j++)
                if (cards[j].bootVga) {
                    pi = j
                    break
                }
        if (pi < 0)
            for (let k = 0; k < cards.length; k++)
                if (cards[k].hasBusy) {
                    pi = k
                    break
                }
        if (pi < 0)
            pi = 0

        const prim = cards[pi]

        root.primaryVendor = root._vendorName(prim.vendorId)
        root.primaryName = root.primaryVendor + " GPU"

        // ── choose secondary (prefer an NVIDIA dGPU, else any other card) ──
        let di = -1
        for (let a = 0; a < cards.length; a++)
            if (a !== pi && cards[a].vendorId === "0x10de") {
                di = a
                break
            }
        if (di < 0)
            for (let b = 0; b < cards.length; b++)
                if (b !== pi) {
                    di = b
                    break
                }

        // ── configure the primary's utilisation/frequency source ──
        if (prim.vendorId === "0x10de") {
            root._pollNv = true
            root._nvPrimary = true
        } else if (prim.hasBusy) {
            busyFile.path = "/sys/class/drm/" + prim.card + "/device/gpu_busy_percent"
            root._primaryFreqIsHz = true
            root._pollBusy = true
            if (prim.freqPath !== "") {
                freqFile.path = prim.freqPath
                root._pollFreq = true
            }
            root.available = true
        } else if (prim.vendorId === "0x8086") {
            // Intel iGPU — no gpu_busy_percent; show frequency, leave util greyed
            if (prim.freqPath !== "") {
                freqFile.path = prim.freqPath
                root._primaryFreqIsHz = false
                root._pollFreq = true
            }
        }

        // ── configure the secondary ──
        if (di >= 0) {
            const sec = cards[di]
            dgpuObj.present = true
            dgpuObj.vendor = root._vendorName(sec.vendorId)
            dgpuObj.name = dgpuObj.vendor + " GPU"
            if (sec.vendorId === "0x10de") {
                root._pollNv = true
            } else if (sec.hasBusy) {
                dbusyFile.path = "/sys/class/drm/" + sec.card + "/device/gpu_busy_percent"
                root._pollDBusy = true
                if (sec.freqPath !== "") {
                    dfreqFile.path = sec.freqPath
                    root._pollDFreq = true
                }
                dgpuObj.hasUtil = true
            }
        }

        // ── build the public snapshot ──
        const snap = []
        for (let m = 0; m < cards.length; m++) {
            const isPrim = m === pi
            const isSec = di >= 0 && m === di
            snap.push({
                "card": cards[m].card,
                "vendorId": cards[m].vendorId,
                "vendor": root._vendorName(cards[m].vendorId),
                "name": root._vendorName(cards[m].vendorId) + " GPU",
                "primary": isPrim,
                "hasUtil": isPrim ? root.available || root._nvPrimary : isSec ? dgpuObj.hasUtil || cards[m].vendorId === "0x10de" : false
            })
        }
        root.gpus = snap

        root._enumerated = true
        root._tick()
    }

    // ── Recurring reads: all FileView, no forks ─────────────────────────────
    readonly property FileView busyFileV: FileView {
        id: busyFile

        onLoaded: {
            const v = parseFloat((text() || "").trim())
            if (!isNaN(v))
                igpuObj.usagePercent = Math.max(0, Math.min(100, Math.round(v)))
        }
    }

    readonly property FileView freqFileV: FileView {
        id: freqFile

        onLoaded: {
            const raw = parseFloat((text() || "").trim())
            if (!isNaN(raw) && raw > 0)
                igpuObj.curMhz = (root._primaryFreqIsHz ? Math.round(raw / 1000000) : Math.round(raw)) + " MHz"
        }
    }

    readonly property FileView dbusyFileV: FileView {
        id: dbusyFile

        onLoaded: {
            const v = parseFloat((text() || "").trim())
            if (!isNaN(v))
                dgpuObj.usagePercent = Math.max(0, Math.min(100, Math.round(v)))
        }
    }

    readonly property FileView dfreqFileV: FileView {
        id: dfreqFile

        onLoaded: {
            const hz = parseFloat((text() || "").trim())
            if (!isNaN(hz) && hz > 0)
                dgpuObj.curMhz = Math.round(hz / 1000000) + " MHz"
        }
    }

    // ── nvidia-smi: the one unavoidable subprocess ──────────────────────────
    // The exit status is now checked. Previously a failing nvidia-smi (driver
    // mismatch after an update, GPU powered down by PRIME, container without
    // /dev/nvidiactl) printed nothing to stdout and the service silently kept
    // reporting the LAST value it ever saw, indefinitely, as if it were live.
    readonly property Process nvProc: Process {
        command: ["sh", "-c", "command -v nvidia-smi >/dev/null 2>&1 || exit 90; " + "nvidia-smi --query-gpu=name,utilization.gpu,clocks.gr " + "--format=csv,noheader,nounits 2>/dev/null | head -n1"]
        running: false

        onExited: function (exitCode) {
            if (exitCode === 0)
                return
            // 90 = not installed; anything else = present but failed.
            if (root._nvPrimary) {
                root.available = false
                igpuObj.curMhz = "— MHz"
            } else if (dgpuObj.present) {
                dgpuObj.hasUtil = false
                dgpuObj.curMhz = "— MHz"
            }
        }

        stdout: StdioCollector {
            onStreamFinished: {
                const line = text.trim()
                if (line === "")
                    return
                const parts = line.split(",")
                const nm = (parts[0] || "").trim()
                const ut = parseFloat((parts[1] || "").trim())
                const clk = parseFloat((parts[2] || "").trim())
                if (root._nvPrimary) {
                    if (nm !== "")
                        root.primaryName = nm
                    if (!isNaN(ut)) {
                        igpuObj.usagePercent = Math.max(0, Math.min(100, Math.round(ut)))
                        root.available = true
                    }
                    if (!isNaN(clk) && clk > 0)
                        igpuObj.curMhz = Math.round(clk) + " MHz"
                } else if (dgpuObj.present) {
                    if (nm !== "")
                        dgpuObj.name = nm
                    if (!isNaN(ut)) {
                        dgpuObj.usagePercent = Math.max(0, Math.min(100, Math.round(ut)))
                        dgpuObj.hasUtil = true
                    }
                    if (!isNaN(clk) && clk > 0)
                        dgpuObj.curMhz = Math.round(clk) + " MHz"
                }
            }
        }
    }

    function _tick() {
        if (root._pollBusy)
            busyFile.reload()
        if (root._pollFreq)
            freqFile.reload()
        if (root._pollDBusy)
            dbusyFile.reload()
        if (root._pollDFreq)
            dfreqFile.reload()
        if (root._pollNv) {
            root.nvProc.running = false
            root.nvProc.running = true
        }
    }

    // Enumerate on the first ref rather than at construction, and re-enumerate
    // if the user changes the override.
    onRefCountChanged: {
        if (refCount > 0 && !root._enumerated && !root.enumProc.running)
            root.enumProc.running = true
    }

    onVendorOverrideChanged: {
        root._enumerated = false
        if (root.refCount > 0) {
            root.enumProc.running = false
            root.enumProc.running = true
        }
    }

    readonly property Timer poll: Timer {
        interval: root.interval
        running: root.refCount > 0 && root._enumerated
        repeat: true
        triggeredOnStart: true
        onTriggered: root._tick()
    }
}
