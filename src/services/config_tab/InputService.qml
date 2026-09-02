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
//     input.json  ──►  /usr/libexec/apex-input-apply  ──►  Hyprland conf
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
    property bool   dragLock:           true
    property bool   naturalScroll:      true
    property bool   disableWhileTyping: true
    property bool   middleEmulation:    false
    property bool   threeFingerDrag:    false
    property bool   leftHandedPad:      false
    property real   padSpeed:           0.0     // -1.0 … 1.0
    property real   scrollFactor:       1.0     //  0.1 … 10.0
    property string clickMethod:        "clickfinger"  // none|buttonAreas|clickfinger
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
        "dragLock":               { s: "touchpad", k: "drag_lock",            d: true },
        "naturalScroll":          { s: "touchpad", k: "natural_scroll",       d: true },
        "disableWhileTyping":     { s: "touchpad", k: "disable_while_typing", d: true },
        "middleEmulation":        { s: "touchpad", k: "middle_emulation",     d: false },
        "threeFingerDrag":        { s: "touchpad", k: "three_finger_drag",    d: false },
        "leftHandedPad":          { s: "touchpad", k: "left_handed",          d: false },
        "padSpeed":               { s: "touchpad", k: "speed",                d: 0.0 },
        "scrollFactor":           { s: "touchpad", k: "scroll_factor",        d: 1.0 },
        "clickMethod":            { s: "touchpad", k: "click_method",         d: "clickfinger" },
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

    function set(prop, value) {
        if (root.schema[prop] === undefined) {
            console.warn("InputService: no such setting:", prop)
            return
        }
        root[prop] = value
        root._scheduleWrite()
    }

    function resetAll() {
        for (const p of Object.keys(root.schema))
            root[p] = root.schema[p].d
        root._scheduleWrite()
    }

    function isDefault(prop) {
        const e = root.schema[prop]
        return e !== undefined && root[prop] === e.d
    }

    readonly property bool anyChanged: {
        for (const p of Object.keys(root.schema))
            if (root[p] !== root.schema[p].d) return true
        return false
    }

    // ── The model, in the generator's own shape ───────────────────────────────
    function buildModel() {
        const out = { "touchpad": {}, "pointer": {}, "keyboard": {} }
        for (const p of Object.keys(root.schema)) {
            const e = root.schema[p]
            out[e.s][e.k] = root[p]
        }
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
        }
    }
}
