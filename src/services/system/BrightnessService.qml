pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// ─────────────────────────────────────────────────────────────────────────────
// BrightnessService — backlight level, shared, and with no polling whatsoever.
//
// Three separate implementations of this used to coexist:
//   • services/home/QuickSettings.qml  — `brightnessctl -m` every 1000ms
//   • popups/QuickControl.qml          — `brightnessctl -m` every 1000ms
//   • popups/Osd.qml                   — inotify on sysfs, then a
//                                        `brightnessctl -m` fork to read the
//                                        value the inotify was already about
//
// The two sliders polled once a second each, forever, from the moment their
// popup was first constructed — two forks per second to watch a number that
// only changes when a human touches a key or a slider.
//
// ── How it knows without polling ────────────────────────────────────────────
// Osd already had the right mechanism and it is generalised here: a FileView
// with `watchChanges` on /sys/class/backlight/<device>/brightness. inotify does
// fire on that file for every write, including writes made by `brightnessctl`
// from a Hyprland XF86MonBrightness bind, so external changes are picked up
// immediately and for free.
//
// The improvement over Osd's version: the watched file *is* the current raw
// brightness, so there is no reason to spawn `brightnessctl -m` to find out what
// it now says. The value is parsed straight out of the FileView.
//
// Costs: one `brightnessctl -m` at first use (device name + maximum, which is
// the only thing needing a glob-free lookup), and one `brightnessctl set` per
// user-initiated change, debounced. Steady state is zero processes and zero
// timers.
//
// Exposes:
//   real   value      — 0..1
//   int    raw / max
//   bool   available
//   string device
//   function set(v)      — 0..1, debounced
//   function adjust(d)   — relative, debounced
//   signal changedExternally(real value)  — someone else moved it
// ─────────────────────────────────────────────────────────────────────────────

Singleton {
    id: root

    readonly property real value: root._max > 0 ? root._raw / root._max : 0
    readonly property int raw: root._raw
    readonly property int max: root._max
    readonly property bool available: root._max > 0
    readonly property string device: root._device

    // Emitted when the level changed from outside this service (hardware keys,
    // another process). Not emitted for our own writes.
    signal changedExternally(real value)

    property int _raw: 0
    property int _max: 0
    property string _device: ""
    property bool _primed: false

    // A write we issued is in flight, or about to be. inotify readback is
    // ignored while this is set, so dragging a slider is never fought by the
    // value the kernel reports for the previous step.
    property bool _writing: false
    property int _pendingRaw: -1

    readonly property string _path: root._device !== "" ? "/sys/class/backlight/" + root._device + "/brightness" : ""

    // ── Discovery: one fork, once ───────────────────────────────────────────
    // brightnessctl -m prints "name,class,current,percent,max". The device name
    // is what the FileView path needs and there is no way to glob
    // /sys/class/backlight from QML.
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

    // ── Change notification: inotify, no polling ────────────────────────────
    readonly property FileView watcher: FileView {
        path: root._path
        watchChanges: true

        onFileChanged: reload()

        onLoaded: {
            const v = parseInt((text() || "").trim())
            if (isNaN(v))
                return

            // Our own write landing back. Clear the latch and keep the value we
            // already committed optimistically.
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

    // ── Public API ──────────────────────────────────────────────────────────
    function set(v) {
        if (root._max <= 0)
            return

        // Never allow a hard zero: on most panels that is indistinguishable
        // from the machine being off, and there is no way to see the UI to undo
        // it. Two raw steps is the historical floor.
        const target = Math.max(2, Math.min(root._max, Math.round(Math.max(0, Math.min(1, v)) * root._max)))

        if (target === root._raw && !root._writing)
            return

        root._raw = target          // optimistic; the UI follows the finger
        root._writing = true
        root._pendingRaw = target
        root.writeDebounce.restart()
    }

    function adjust(delta) {
        root.set(root.value + delta)
    }

    // Re-read on demand, for surfaces that want to be certain they are current
    // the moment they appear. Cheap and rare; not a poll.
    function refresh() {
        if (root._device === "")
            root.discoverProc.running = true
        else
            root.watcher.reload()
    }

    Component.onCompleted: root.discoverProc.running = true
}
