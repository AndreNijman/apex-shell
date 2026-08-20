pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io

// ─────────────────────────────────────────────────────────────────────────────
// BrightnessService — backlight level per monitor, with no polling whatsoever.
//
// Three separate implementations of this used to coexist, two of them forking
// `brightnessctl -m` once a second forever, to watch a number that only changes
// when a human touches a key or a slider. All three are gone.
//
// ── How it knows without polling ────────────────────────────────────────────
// An internal panel publishes its level in /sys/class/backlight/<dev>/brightness
// and inotify fires on every write to it, including writes made by
// `brightnessctl` from a Hyprland XF86MonBrightness bind. So a FileView with
// `watchChanges` gets external changes immediately and for free, and the watched
// file *is* the current raw value, so there is no reason to spawn anything to
// find out what it now says.
//
// ── Per-monitor ─────────────────────────────────────────────────────────────
// External displays have no sysfs backlight; they are driven over DDC/CI with
// `ddcutil`. That is a different cost model entirely — a DDC read is an I2C
// round trip taking ~100ms and some monitors mishandle rapid writes — so:
//
//   • DDC monitors are detected ONCE (`ddcutil detect`), never polled.
//   • Their level is read once at detection and then tracked locally, because
//     this shell is the only thing writing it. There is no inotify equivalent.
//   • Writes are rate-limited per monitor, with the newest value queued rather
//     than every intermediate slider position sent. Without that, dragging a
//     slider queues dozens of I2C writes and the monitor visibly lags behind.
//
// `ddcutil detect` is slow (seconds, and it probes every I2C bus), so it runs
// lazily on first use rather than at startup, and only when there is more than
// one screen or no internal backlight at all — a single-laptop-panel machine,
// which is the common case, never pays for it.
//
// Exposes:
//   real   value      — 0..1 for the primary/active monitor (back-compatible)
//   bool   available
//   list   monitors   — per-output entries, each with its own value/setter
//   function set(v)          — 0..1 on the active monitor, debounced
//   function adjust(d)       — relative, on the active monitor
//   function setFor(name, v) — a specific output by name
//   function forScreen(s)    — the entry driving a given ShellScreen
//   signal changedExternally(real value)
// ─────────────────────────────────────────────────────────────────────────────

Singleton {
    id: root

    // ── Internal (sysfs) backlight ───────────────────────────────────────────
    readonly property real value: root._max > 0 ? root._raw / root._max : 0
    readonly property int raw: root._raw
    readonly property int max: root._max
    readonly property bool available: root._max > 0 || root.ddcMonitors.length > 0
    readonly property string device: root._device

    signal changedExternally(real value)

    property int _raw: 0
    property int _max: 0
    property string _device: ""
    property bool _primed: false

    // A write we issued is in flight. inotify readback is ignored while this is
    // set, so dragging a slider is never fought by the value the kernel reports
    // for the previous step.
    property bool _writing: false
    property int _pendingRaw: -1

    readonly property string _path: root._device !== "" ? "/sys/class/backlight/" + root._device + "/brightness" : ""

    // ── DDC/CI monitors ──────────────────────────────────────────────────────
    // [{ bus, connector, value }] — populated once, on demand.
    property var ddcMonitors: []
    property bool _ddcProbed: false
    property bool _ddcProbing: false

    // Probing costs seconds and walks every I2C bus, so only do it when an
    // external display could plausibly be present.
    readonly property bool _ddcWorthProbing: Quickshell.screens.length > 1 || root._max <= 0

    function probeDdc() {
        if (root._ddcProbed || root._ddcProbing || !root._ddcWorthProbing)
            return
        root._ddcProbing = true
        ddcDetectProc.running = true
    }

    // Parse `ddcutil detect --brief`. Split out from the Process so it can be
    // unit-tested against captured output — this cannot be exercised on a
    // machine with only an internal panel.
    function parseDdcDetect(text) {
        const found = []
        for (const block of (text || "").split("\n\n")) {
            if (!block.trim().startsWith("Display "))
                continue
            const bus = block.match(/I2C bus:\s*\/dev\/i2c-([0-9]+)/)
            const conn = block.match(/DRM connector:\s*(\S+)/)
            if (!bus)
                continue
            found.push({
                "bus": bus[1],
                // Strip the "card1-" prefix so the name matches
                // ShellScreen.name (e.g. "DP-1").
                "connector": conn ? conn[1].replace(/^card\d+-/, "") : "",
                "value": -1
            })
        }
        return found
    }

    // Parse `ddcutil getvcp 10 --brief`, which prints: VCP 10 C <current> <max>
    // Returns a 0..1 fraction, or -1 when the line is not usable.
    function parseDdcGetvcp(text) {
        const parts = (text || "").trim().split(/\s+/)
        if (parts.length < 5)
            return -1
        if (parts[0] !== "VCP")
            return -1
        const cur = parseInt(parts[3])
        const mx = parseInt(parts[4])
        if (isNaN(cur) || isNaN(mx) || mx <= 0)
            return -1
        return Math.max(0, Math.min(1, cur / mx))
    }

    readonly property Process ddcDetectProc: Process {
        id: ddcDetectProc

        // `--brief` keeps the output parseable; ddcutil is absent on most
        // installs, so a missing binary must be silent rather than an error.
        command: ["sh", "-c", "command -v ddcutil >/dev/null 2>&1 && ddcutil detect --brief 2>/dev/null || true"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                const found = root.parseDdcDetect(text)
                root.ddcMonitors = found
                root._ddcProbed = true
                root._ddcProbing = false
                // Read each one's current level once. After this they are
                // tracked locally; nothing else writes them.
                for (const m of found)
                    root._readDdc(m.bus)
            }
        }
    }

    property var _ddcReadQueue: []

    function _readDdc(bus) {
        root._ddcReadQueue = root._ddcReadQueue.concat([bus])
        if (!ddcReadProc.running)
            root._nextDdcRead()
    }

    function _nextDdcRead() {
        if (root._ddcReadQueue.length === 0)
            return
        const bus = root._ddcReadQueue[0]
        root._ddcReadQueue = root._ddcReadQueue.slice(1)
        ddcReadProc.command = ["sh", "-c", "ddcutil -b " + bus + " getvcp 10 --brief 2>/dev/null || true"]
        ddcReadProc._bus = bus
        ddcReadProc.running = true
    }

    readonly property Process ddcReadProc: Process {
        id: ddcReadProc

        property string _bus: ""

        command: []
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                const v = root.parseDdcGetvcp(text)
                if (v >= 0)
                    root._setDdcValue(ddcReadProc._bus, v)
            }
        }
        onRunningChanged: if (!running)
            root._nextDdcRead()
    }

    function _setDdcValue(bus, v) {
        const next = []
        for (const m of root.ddcMonitors)
            next.push(m.bus === bus ? {
                "bus": m.bus,
                "connector": m.connector,
                "value": v
            } : m)
        root.ddcMonitors = next
    }

    function ddcFor(name) {
        for (const m of root.ddcMonitors)
            if (m.connector === name)
                return m
        return null
    }

    // ── Internal-backlight discovery: one fork, once ─────────────────────────
    readonly property Process discoverProc: Process {
        command: ["brightnessctl", "-m"]
        running: false
        stdout: SplitParser {
            onRead: function (line) {
                const p = line.split(",")
                if (p.length < 5)
                    return
                const cur = parseInt(p[2])
                const mx = parseInt(p[4])
                if (isNaN(mx) || mx <= 0)
                    return
                if (root._device === "")
                    root._device = p[0].trim()
                root._max = mx
                if (!isNaN(cur))
                    root._raw = cur
                root._primed = true
            }
        }
    }

    // ── Change notification for the internal panel: inotify, no polling ──────
    readonly property FileView watcher: FileView {
        path: root._path
        watchChanges: true

        onFileChanged: reload()

        onLoaded: {
            const v = parseInt((text() || "").trim())
            if (isNaN(v))
                return

            if (root._writing && v === root._pendingRaw) {
                root._writing = false
                root._pendingRaw = -1
                root._raw = v
                return
            }

            if (root._writing)
                return   // a newer write is still on its way

            if (v === root._raw)
                return

            root._raw = v
            if (root._primed)
                root.changedExternally(root.value)
        }
    }

    readonly property Process writeProc: Process {
        command: []
        running: false
    }

    readonly property Timer writeDebounce: Timer {
        interval: 50
        repeat: false
        onTriggered: {
            if (root._pendingRaw < 0)
                return
            root.writeProc.command = ["brightnessctl", "set", String(root._pendingRaw)]
            root.writeProc.running = false
            root.writeProc.running = true
        }
    }

    // ── DDC writes: rate-limited, newest-wins ────────────────────────────────
    // A DDC write is an I2C round trip and some monitors mishandle a rapid
    // burst, so slider drags coalesce to the latest value rather than sending
    // every intermediate position.
    property var _ddcPending: ({})

    readonly property Process ddcWriteProc: Process {
        command: []
        running: false
        onRunningChanged: if (!running)
            root._flushDdc()
    }

    readonly property Timer ddcGate: Timer {
        interval: 200
        repeat: false
        onTriggered: root._flushDdc()
    }

    function _flushDdc() {
        if (root.ddcWriteProc.running || root.ddcGate.running)
            return
        for (const bus in root._ddcPending) {
            const pct = root._ddcPending[bus]
            const rest = ({})
            for (const b in root._ddcPending)
                if (b !== bus)
                    rest[b] = root._ddcPending[b]
            root._ddcPending = rest

            root.ddcWriteProc.command = ["ddcutil", "-b", bus, "setvcp", "10", String(pct)]
            root.ddcWriteProc.running = true
            root.ddcGate.restart()
            return
        }
    }

    function setDdc(bus, v) {
        const clamped = Math.max(0, Math.min(1, v))
        root._setDdcValue(bus, clamped)          // optimistic; UI follows the finger
        const next = ({})
        for (const b in root._ddcPending)
            next[b] = root._ddcPending[b]
        next[bus] = Math.round(clamped * 100)
        root._ddcPending = next
        root._flushDdc()
    }

    // ── Public API ───────────────────────────────────────────────────────────
    function set(v) {
        if (root._max <= 0) {
            // No internal panel — drive the first DDC display instead, so the
            // brightness keys still do something on a desktop.
            if (root.ddcMonitors.length > 0)
                root.setDdc(root.ddcMonitors[0].bus, v)
            return
        }

        // Never allow a hard zero: on most panels that is indistinguishable
        // from the machine being off, and there is no way to see the UI to undo
        // it. Two raw steps is the historical floor.
        const target = Math.max(2, Math.min(root._max, Math.round(Math.max(0, Math.min(1, v)) * root._max)))

        if (target === root._raw && !root._writing)
            return

        root._raw = target
        root._writing = true
        root._pendingRaw = target
        root.writeDebounce.restart()
    }

    function adjust(delta) {
        root.set(root.value + delta)
    }

    // Set brightness on a specific output by name, DDC or internal.
    function setFor(name, v) {
        const m = root.ddcFor(name)
        if (m) {
            root.setDdc(m.bus, v)
            return
        }
        root.set(v)
    }

    // The value that applies to a given ShellScreen: its DDC entry if it has
    // one, else the internal panel.
    function forScreen(screen) {
        if (!screen)
            return root.value
        const m = root.ddcFor(screen.name)
        if (m && m.value >= 0)
            return m.value
        return root.value
    }

    function refresh() {
        if (root._device === "")
            root.discoverProc.running = true
        else
            root.watcher.reload()
        root.probeDdc()
    }

    Component.onCompleted: root.discoverProc.running = true
}
