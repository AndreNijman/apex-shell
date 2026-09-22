pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// ─── InputService ─────────────────────────────────────────────────────────────
// The graphical half of §18's input settings parity.
//
// There is exactly ONE model — ~/.config/apex-shell/input.json — and one
// generator that turns it into whatever each compositor understands:
//
//     input.json  ──►  /usr/libexec/apex-input-apply  ──►  Hyprland apex/input.lua
//                                                     ├─►  niri KDL
//                                                     └─►  labwc <libinput>
//
// This page does not know Hyprland from labwc, and must not learn: that is the
// whole point of the parity work. It writes the model and asks the generator to
// run. The generator validates, corrects out-of-range values, and refuses to
// touch an rc.xml it cannot parse — so a bad value here is reported, not
// obeyed.
//
// EVERY KEY HERE EXISTS IN THE GENERATOR
//
// The key names and default values below mirror apex-input-apply's own
// DEFAULTS exactly, and apex-os's CI asserts that they still do. The first
// draft of this file invented `numlock_on_boot`, which the generator does not
// read — a switch that writes the model, runs the generator, reports success
// and changes nothing. A control that silently does nothing is the worst
// possible outcome for a settings page, and it is invisible in review.
//
// The DEFAULTS also matter in their own right: they reproduce exactly what the
// shipped compositor configs already set, so opening this page for the first
// time and touching one control does not quietly change four other things.
// tests/test-apex-input.sh in apex-os asserts that ("default reproduces
// <tap>yes</tap>" and three more).
//
// ── UI-003: a key existing is not the same as a control working ──────────────
//
// The parity above proves the generator READS every key. It says nothing about
// whether the compositor running right now can act on it, and that is where
// "changing Input configuration has no effect" actually came from — niri has no
// three-finger drag, neither niri nor Hyprland has a click method that produces
// no button at all, and four touchpad settings exist on Hyprland only as a
// named device. Nine controls were writing the model and reaching nothing.
//
// So this service asks the generator three questions rather than assuming:
//
//   --capabilities  what the running compositor can do, and the REASON where it
//                   cannot. A control whose answer is "cannot" is switched off
//                   in the page and shows the reason. It is never written.
//   --devices       what is plugged in, classified, so per-device settings can
//                   name a real touchpad instead of guessing.
//   --read-back     what is in EFFECT, and whether that came from the
//                   compositor or from the file it loads. A control that writes
//                   and never reads cannot tell a working setting from one
//                   whose option was renamed upstream — which is how this page
//                   filled up with switches that did nothing in the first
//                   place, silently, with every test passing.
//
// None of those answers are duplicated here. The generator is the one place
// that knows what each compositor accepts, because it is the thing that has to
// produce it.
// ──────────────────────────────────────────────────────────────────────────────

QtObject {
    id: root

    readonly property string modelPath:
        Quickshell.env("HOME") + "/.config/apex-shell/input.json"
    // Overridable for development, same reasoning as DisplayService's engine.
    readonly property string generator: {
        const override = Quickshell.env("APEX_INPUT_GENERATOR") || ""
        return override !== "" ? override : "/usr/libexec/apex-input-apply"
    }

    // ── Touchpad ──────────────────────────────────────────────────────────────
    property bool   tap:                true
    property bool   tapAndDrag:         true
    property bool   dragLock:           false
    property bool   naturalScroll:      true
    property bool   disableWhileTyping: true
    property bool   middleEmulation:    false
    property bool   threeFingerDrag:    false
    property bool   leftHandedPad:      false
    property real   padSpeed:           0.0     // -1.0 … 1.0
    property real   scrollFactor:       1.0     //  0.1 … 10.0
    property string clickMethod:        "buttonAreas"  // none|buttonAreas|clickfinger
    property string scrollMethod:       "twofinger"    // none|twofinger|edge
    property string tapButtonMap:       "lrm"          // lrm|lmr
    property string padAccelProfile:    "adaptive"     // adaptive|flat

    // ── Pointer ───────────────────────────────────────────────────────────────
    // A mouse deliberately does not inherit the touchpad's natural scroll:
    // inverting a wheel is not the same gesture as inverting a two-finger
    // swipe. The generator's comment says the same; both defaults are false
    // here and true there for exactly that reason.
    property bool   leftHanded:             false
    property bool   pointerNaturalScroll:   false
    property bool   pointerMiddleEmulation: false
    property real   pointerSpeed:           0.0
    property real   pointerScrollFactor:    1.0
    property string pointerAccelProfile:    "adaptive"

    // ── Keyboard ──────────────────────────────────────────────────────────────
    property int    repeatRate:  25    //   1 … 100
    property int    repeatDelay: 600   // 100 … 2000

    // Property name -> (section, generator key, default). One table, used for
    // loading, saving, resetting and the CI parity check, so a key cannot be
    // added to the UI without appearing in the model.
    readonly property var schema: ({
        "tap":                    { s: "touchpad", k: "tap",                  d: true },
        "tapAndDrag":             { s: "touchpad", k: "tap_and_drag",         d: true },
        "dragLock":               { s: "touchpad", k: "drag_lock",            d: false },
        "naturalScroll":          { s: "touchpad", k: "natural_scroll",       d: true },
        "disableWhileTyping":     { s: "touchpad", k: "disable_while_typing", d: true },
        "middleEmulation":        { s: "touchpad", k: "middle_emulation",     d: false },
        "threeFingerDrag":        { s: "touchpad", k: "three_finger_drag",    d: false },
        "leftHandedPad":          { s: "touchpad", k: "left_handed",          d: false },
        "padSpeed":               { s: "touchpad", k: "speed",                d: 0.0 },
        "scrollFactor":           { s: "touchpad", k: "scroll_factor",        d: 1.0 },
        "clickMethod":            { s: "touchpad", k: "click_method",         d: "buttonAreas" },
        "scrollMethod":           { s: "touchpad", k: "scroll_method",        d: "twofinger" },
        "tapButtonMap":           { s: "touchpad", k: "tap_button_map",       d: "lrm" },
        "padAccelProfile":        { s: "touchpad", k: "accel_profile",        d: "adaptive" },

        "leftHanded":             { s: "pointer",  k: "left_handed",      d: false },
        "pointerNaturalScroll":   { s: "pointer",  k: "natural_scroll",   d: false },
        "pointerMiddleEmulation": { s: "pointer",  k: "middle_emulation", d: false },
        "pointerSpeed":           { s: "pointer",  k: "speed",            d: 0.0 },
        "pointerScrollFactor":    { s: "pointer",  k: "scroll_factor",    d: 1.0 },
        "pointerAccelProfile":    { s: "pointer",  k: "accel_profile",    d: "adaptive" },

        "repeatRate":             { s: "keyboard", k: "repeat_rate",  d: 25 },
        "repeatDelay":            { s: "keyboard", k: "repeat_delay", d: 600 }
    })

    property bool loaded: false
    // Set when the generator reported a correction, so the page can say so
    // rather than showing a value that was not applied.
    property string lastNotes: ""
    property bool   applying: false

    // ── What the running compositor can actually do ───────────────────────────
    // `{ running: "hyprland", controls: { "touchpad.tap": { hyprland: {...} } } }`
    // straight from the generator. Empty until it answers, and an empty table
    // means "not asked yet", which is why nothing here treats a missing entry as
    // unsupported: a control that greys itself out because a Process has not
    // returned is a worse lie than the one this replaces.
    property var capabilities: ({})
    readonly property string compositor: root.capabilities.running || ""
    // The generator was asked and could not answer — it is older than these
    // flags, or it is not installed. Different from "no compositor is running",
    // and worth telling apart: on an image that predates this page every
    // control still works exactly as it did, and saying "nothing below is known
    // to work" would be alarming and wrong.
    property bool capabilitiesFailed: false

    function _cap(prop) {
        const e = root.schema[prop]
        if (e === undefined || !root.capabilities.controls || root.compositor === "")
            return null
        const entry = root.capabilities.controls[e.s + "." + e.k]
        return entry ? entry[root.compositor] || null : null
    }

    // "" when the control works here, otherwise the sentence to show instead.
    function reasonFor(prop) {
        const c = root._cap(prop)
        return (c && c.supported === false) ? (c.reason || "") : ""
    }

    function supported(prop) { return root.reasonFor(prop) === "" }

    // A control can be supported and still have a value that is not: neither
    // Hyprland nor niri has a touchpad click method that produces no button.
    // Those options are dropped from the choice rather than offered and ignored.
    function valueSupported(prop, value) {
        const c = root._cap(prop)
        if (!c || !c.unsupported_values) return true
        return c.unsupported_values[value] === undefined
    }

    function valueReason(prop, value) {
        const c = root._cap(prop)
        if (!c || !c.unsupported_values) return ""
        return c.unsupported_values[value] || ""
    }

    // Options minus the ones this compositor cannot express. Given the whole
    // list so the page states its choices once.
    function optionsFor(prop, options) {
        return options.filter(o => root.valueSupported(prop, o.value))
    }

    // ── What is in effect, as opposed to what we asked for ────────────────────
    property var effective: ({})
    // Controls whose effective value is not the one in the model.
    readonly property var diverged: root.effective.diverged || []
    readonly property bool readBackReady: root.effective.values !== undefined

    function _effectiveEntry(prop) {
        const e = root.schema[prop]
        if (e === undefined || !root.effective.values) return null
        return root.effective.values[e.s + "." + e.k] || null
    }

    // A short readout for the page: what the compositor reports, and — when it
    // came from a file rather than a query — that it came from a file. Empty
    // when there is nothing to say, so a row shows a readout only where one
    // exists.
    function effectiveText(prop) {
        const v = root._effectiveEntry(prop)
        if (v === null) return ""
        if (v.value === null || v.value === undefined) return "not set"
        const shown = (typeof v.value === "boolean") ? (v.value ? "on" : "off")
                                                     : String(v.value)
        return v.source === "compositor" ? shown : shown + " (file)"
    }

    function divergedFrom(prop) {
        const e = root.schema[prop]
        if (e === undefined) return false
        return root.diverged.some(d => d.control === e.s + "." + e.k)
    }

    // ── Input devices ─────────────────────────────────────────────────────────
    // [{ name, type, hypr_name, hypr_name_source }], kernel names, classified by
    // udev. `other` is dropped: a power button is an input device to the kernel
    // and not one a settings page has anything to say about.
    property var devices: []
    readonly property var configurableDevices:
        root.devices.filter(d => ["touchpad", "trackpoint", "mouse", "tablet",
                                  "touchscreen"].indexOf(d.type) >= 0)
    // Per-device overrides, `{ "<kernel name>": { type, key: value } }`. NOT in
    // the schema table: that table is the flat section/key contract apex-os's
    // check-input-parity reads, and a device map has no place in it.
    property var deviceOverrides: ({})
    // Which keys each kind of device accepts, from the generator, so the page
    // does not decide that a touchscreen has a tap setting.
    readonly property var deviceKeys: root.capabilities.device_keys || ({})
    readonly property var perDeviceCapability: {
        const p = root.capabilities.per_device
        if (!p || root.compositor === "") return null
        return p[root.compositor] || null
    }
    readonly property string perDeviceReason: {
        const p = root.perDeviceCapability
        return (p && p.supported === false) ? (p.reason || "") : ""
    }

    function deviceValue(name, key) {
        const d = root.deviceOverrides[name]
        return (d && d[key] !== undefined) ? d[key] : undefined
    }

    function setDevice(name, type, key, value) {
        const next = JSON.parse(JSON.stringify(root.deviceOverrides))
        if (next[name] === undefined) next[name] = { "type": type }
        next[name][key] = value
        root.deviceOverrides = next
        root._scheduleWrite()
    }

    function clearDevice(name) {
        const next = JSON.parse(JSON.stringify(root.deviceOverrides))
        delete next[name]
        root.deviceOverrides = next
        root._scheduleWrite()
    }

    function set(prop, value) {
        if (root.schema[prop] === undefined) {
            console.warn("InputService: no such setting:", prop)
            return
        }
        // The last line of defence for criterion 8. A control the compositor
        // cannot honour is already switched off in the page; refusing the write
        // here as well means a future page that forgets to ask still cannot
        // report success for a value that goes nowhere.
        const reason = root.reasonFor(prop)
        if (reason !== "") {
            root.lastNotes = reason
            return
        }
        if (!root.valueSupported(prop, value)) {
            root.lastNotes = root.valueReason(prop, value)
            return
        }
        root[prop] = value
        root._scheduleWrite()
    }

    function resetAll() {
        for (const p of Object.keys(root.schema))
            root[p] = root.schema[p].d
        root.deviceOverrides = ({})
        root._scheduleWrite()
    }

    function isDefault(prop) {
        const e = root.schema[prop]
        return e !== undefined && root[prop] === e.d
    }

    readonly property bool anyChanged: {
        for (const p of Object.keys(root.schema))
            if (root[p] !== root.schema[p].d) return true
        return Object.keys(root.deviceOverrides).length > 0
    }

    // ── The model, in the generator's own shape ───────────────────────────────
    function buildModel() {
        const out = { "touchpad": {}, "pointer": {}, "keyboard": {} }
        for (const p of Object.keys(root.schema)) {
            const e = root.schema[p]
            out[e.s][e.k] = root[p]
        }
        if (Object.keys(root.deviceOverrides).length > 0)
            out["devices"] = JSON.parse(JSON.stringify(root.deviceOverrides))
        return out
    }

    function _adopt(o) {
        for (const p of Object.keys(root.schema)) {
            const e = root.schema[p]
            const section = o[e.s]
            if (!section || section[e.k] === undefined) continue
            const v = section[e.k]
            if (typeof e.d === "boolean")      root[p] = !!v
            else if (typeof e.d === "number")  root[p] = Number(v)
            else                               root[p] = String(v)
        }
        root.deviceOverrides = (o.devices && typeof o.devices === "object")
            ? JSON.parse(JSON.stringify(o.devices)) : ({})
    }

    // ── Load ──────────────────────────────────────────────────────────────────
    // A missing file is the normal first-run state and means "the defaults",
    // which are already a no-op against the shipped configs. It is NOT created
    // here: writing a model on mere page-open would make opening Settings a
    // change to the user's input behaviour.
    property var _loadProc: Process {
        command: ["cat", root.modelPath]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                const raw = text.trim()
                if (raw !== "") {
                    try {
                        root._adopt(JSON.parse(raw))
                    } catch (e) {
                        console.warn("InputService: cannot parse", root.modelPath, e)
                    }
                }
                root.loaded = true
            }
        }
    }

    // ── Write, then generate ──────────────────────────────────────────────────
    function _scheduleWrite() { if (root.loaded) root._writeTimer.restart() }

    property var _writeTimer: Timer {
        // Long enough that dragging a slider is one write and one generator run
        // rather than forty. The generator rewrites three compositor configs and
        // reloads the live one; doing that per frame is visible as stutter.
        interval: 400
        repeat: false
        onTriggered: root.apply()
    }

    function apply() {
        root.applying = true
        root.lastNotes = ""
        // The JSON is passed as an ARGUMENT, not interpolated into the script.
        // Every value here ultimately came off disk or out of a text field, and
        // a model spliced into a shell string is a shell injection.
        root._applyProc.command = ["bash", "-c",
            'mkdir -p "$(dirname "$1")" && printf %s "$2" > "$1" && exec "$3"',
            "--", root.modelPath,
            JSON.stringify(root.buildModel(), null, 2), root.generator]
        root._applyProc.running = true
    }

    property var _applyProc: Process {
        command: []
        running: false
        // The generator reports corrections on stderr — an out-of-range speed
        // clamped, an unknown profile replaced. Surfaced rather than swallowed:
        // the whole design is that a bad value is corrected AND reported.
        stderr: StdioCollector {
            onStreamFinished: {
                const t = text.trim()
                if (t !== "") root.lastNotes = t
            }
        }
        onExited: function(code) {
            root.applying = false
            if (code !== 0 && root.lastNotes === "")
                root.lastNotes = "apex-input-apply exited " + code
            // Read back AFTER every apply, because the point of reading back is
            // to find out whether the apply took. A page that refreshes its
            // effective state only on open would show the last successful write
            // forever.
            root.refreshEffective()
        }
    }

    // ── Asking the generator the three questions ──────────────────────────────
    function refreshCapabilities() { root._capsProc.running = true }
    function refreshDevices()      { root._devicesProc.running = true }
    function refreshEffective()    { root._readBackProc.running = true }

    property var _capsProc: Process {
        command: [root.generator, "--capabilities"]
        running: true
        onExited: function (code) {
            if (code !== 0) root.capabilitiesFailed = true
        }
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.capabilities = JSON.parse(text.trim() || "{}")
                    root.capabilitiesFailed = root.capabilities.controls === undefined
                } catch (e) {
                    root.capabilitiesFailed = true
                    // Left empty on purpose. An unparseable answer means the
                    // page does not know what this compositor can do, and
                    // guessing "everything" is how the fake toggles got here.
                    console.warn("InputService: cannot parse --capabilities", e)
                }
            }
        }
    }

    property var _devicesProc: Process {
        command: [root.generator, "--devices"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const parsed = JSON.parse(text.trim() || "{}")
                    root.devices = parsed.devices || []
                    if (parsed.notes && parsed.notes.length > 0)
                        root.lastNotes = parsed.notes.join("; ")
                } catch (e) {
                    console.warn("InputService: cannot parse --devices", e)
                }
            }
        }
    }

    // NOT started on construction, unlike the two above. This service is in the
    // eager singleton chain — it is constructed at every shell start whether or
    // not anybody opens Settings — and on Hyprland a read-back is seventeen
    // serial `hyprctl getoption` calls. Twenty processes on every login, for a
    // page most logins never open. The Input page asks for it when it opens,
    // and every apply asks for it again.
    property var _readBackProc: Process {
        command: [root.generator, "--read-back"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.effective = JSON.parse(text.trim() || "{}")
                } catch (e) {
                    console.warn("InputService: cannot parse --read-back", e)
                }
            }
        }
    }
}
