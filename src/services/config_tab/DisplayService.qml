pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// ─── DisplayService ───────────────────────────────────────────────────────────
// The graphical half of §18's display settings parity.
//
//     display.json  ──►  /usr/libexec/apex-display-apply  ──►  hyprctl keyword
//                                                         ├─►  wlr-randr
//                                                         ├─►  apex-display.conf
//                                                         └─►  kanshi profile
//
// APPLY AND SAVE ARE DIFFERENT ACTIONS, AND THAT MATTERS
//
//   save   writes persistence only — the Hyprland monitor conf and the kanshi
//          profile. Touches no hardware.
//   apply  ALSO reaches the running compositor.
//
// The split exists because of a real incident: a test isolated $HOME, called
// `apply`, and reconfigured the live desktop it was running on — because
// hyprctl does not care what $HOME is. So `apply` is the only action that can
// change what is on screen, and it is the one this service guards.
//
// WHY EVERY CHANGE GOES THROUGH A CONFIRMATION
//
// A wrong display setting can leave a machine with no usable output, and the
// control to undo it is on the output that just went away. So `apply` here is
// never automatic and never debounced: the user presses Apply, gets a countdown
// and reverts unless they confirm. That is the standard pattern for a reason —
// it is the only one that is safe when the failure mode removes your ability to
// interact.
//
// This is the one settings page in the shell that does NOT write live as you
// drag. Deliberately.
// ──────────────────────────────────────────────────────────────────────────────

QtObject {
    id: root

    readonly property string modelPath:
        Quickshell.env("HOME") + "/.config/apex-shell/display.json"
    // Overridable for development and for the smoke test, which has to exercise
    // the real enumeration path without installing into /usr. The default is
    // the installed path, so a normal session needs no environment at all.
    readonly property string engine: {
        const override = Quickshell.env("APEX_DISPLAY_ENGINE") || ""
        return override !== "" ? override : "/usr/libexec/apex-display-apply"
    }

    // ── What the hardware says ────────────────────────────────────────────────
    // Enumerated from the compositor, never guessed. `modes` is per-output and
    // is the only legitimate source for what a monitor will accept.
    property var outputs: []          // as reported by `apex-display-apply list`
    property bool loaded: false
    property string lastError: ""

    // ── What the user has staged ──────────────────────────────────────────────
    // A copy of `outputs`, edited. Kept separate so the page can show both
    // "what is" and "what you asked for", and so Revert is just discarding it.
    property var draft: []
    property bool dirty: false

    // ── Apply state ───────────────────────────────────────────────────────────
    property bool applying: false
    // Seconds left before an unconfirmed apply is reverted. 0 = not pending.
    property int confirmSeconds: 0
    property var _preApply: []

    readonly property int refCount: 0    // reserved: enumeration is on demand

    function refresh() {
        root._listProc.running = true
    }

    property var _listProc: Process {
        command: [root.engine, "list"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const fresh = JSON.parse(text.trim() || "[]")
                    if (Array.isArray(fresh)) {
                        root.outputs = fresh
                        if (!root.dirty) root.draft = root._copy(fresh)
                        root.lastError = ""
                    }
                } catch (e) {
                    root.lastError = "Cannot read the display layout: " + e
                }
                root.loaded = true
            }
        }
        stderr: StdioCollector {
            onStreamFinished: {
                const t = text.trim()
                // The engine says "neither wlr-randr nor hyprctl available" on a
                // session it cannot query. Reported, because the alternative is
                // a page that looks like the machine has no monitors.
                if (t !== "" && root.outputs.length === 0) root.lastError = t
            }
        }
        // A process that never STARTS emits neither stdout nor stderr, so
        // without this `loaded` stays false and the page renders completely
        // blank — no outputs, no error, nothing to explain it. That is the
        // state on any machine where the engine is not installed: a dev
        // checkout, or an image predating it.
        onExited: function(code) {
            root.loaded = true
            if (code !== 0 && root.outputs.length === 0 && root.lastError === "") {
                root.lastError =
                    "Could not run " + root.engine + " (exit " + code + "). " +
                    "It ships with APEX-OS; on another distribution the display " +
                    "page has nothing to talk to."
            }
        }
    }

    function _copy(list) {
        return JSON.parse(JSON.stringify(list))
    }

    function _find(name) {
        for (let i = 0; i < root.draft.length; i++)
            if (root.draft[i].name === name) return i
        return -1
    }

    /// Stage one field of one output. Nothing reaches hardware until apply().
    function stage(name, field, value) {
        const i = root._find(name)
        if (i < 0) return
        const next = root._copy(root.draft)
        next[i][field] = value
        root.draft = next
        root.dirty = true
    }

    /// Stage a mode by its index in that output's own `modes` list.
    function stageMode(name, modeIndex) {
        const i = root._find(name)
        if (i < 0) return
        const modes = root.draft[i].modes || []
        if (modeIndex < 0 || modeIndex >= modes.length) return
        const m = modes[modeIndex]
        const next = root._copy(root.draft)
        next[i].mode = { width: m.width, height: m.height, refresh: m.refresh }
        root.draft = next
        root.dirty = true
    }

    function revert() {
        root.draft = root._copy(root.outputs)
        root.dirty = false
        root.lastError = ""
    }

    /// The model the engine reads. Only the fields it uses, so a stray key from
    /// `list` output (description, make, serial, the whole modes array) is not
    /// written into the persisted model.
    function buildModel() {
        const outs = []
        for (const o of root.draft) {
            const entry = {
                name:          o.name,
                enabled:       o.enabled !== false,
                x:             Math.round(o.x || 0),
                y:             Math.round(o.y || 0),
                scale:         Number(o.scale || 1),
                transform:     String(o.transform || "normal"),
                adaptive_sync: !!o.adaptive_sync
            }
            if (o.mode && o.mode.width && o.mode.height) {
                entry.mode = {
                    width:   Math.round(o.mode.width),
                    height:  Math.round(o.mode.height),
                    refresh: Number(o.mode.refresh)
                }
            }
            outs.push(entry)
        }
        return { outputs: outs }
    }

    // ── save: persistence only, no hardware ──────────────────────────────────
    function save() {
        root._run("save")
    }

    // ── apply: reaches the compositor, then asks ─────────────────────────────
    function apply() {
        // Snapshot BEFORE, from the hardware rather than from the draft: the
        // revert has to restore what was actually on screen, and the draft is by
        // definition what is not.
        root._preApply = root._copy(root.outputs)
        root._run("apply")
    }

    /// Called by the page when the user confirms the new layout is usable.
    function confirm() {
        root.confirmSeconds = 0
        root._countdown.stop()
        root.dirty = false
        root._preApply = []
        root.refresh()
    }

    /// Put back what was on screen before the last apply.
    function revertApplied() {
        root.confirmSeconds = 0
        root._countdown.stop()
        if (root._preApply.length === 0) return
        root.draft = root._copy(root._preApply)
        root._preApply = []
        // Applied, not saved: the point is to get the picture back.
        root._run("apply", true)
        root.dirty = false
    }

    property var _countdown: Timer {
        interval: 1000
        repeat: true
        running: false
        onTriggered: {
            root.confirmSeconds -= 1
            if (root.confirmSeconds <= 0) root.revertApplied()
        }
    }

    property bool _reverting: false

    function _run(action, isRevert) {
        root.applying = true
        root.lastError = ""
        root._reverting = !!isRevert
        root._pendingAction = action
        // JSON passed as an argument, never interpolated: output names come off
        // EDID, which is attacker-controlled in the sense that nobody validates
        // what a monitor claims to be called.
        root._applyProc.command = ["bash", "-c",
            'mkdir -p "$(dirname "$1")" && printf %s "$2" > "$1" && exec "$3" "$4"',
            "--", root.modelPath,
            JSON.stringify(root.buildModel(), null, 2), root.engine, action]
        root._applyProc.running = true
    }
    property string _pendingAction: ""

    property var _applyProc: Process {
        command: []
        running: false
        stderr: StdioCollector {
            onStreamFinished: {
                const t = text.trim()
                if (t !== "") root.lastError = t
            }
        }
        onExited: function(code) {
            root.applying = false
            if (code !== 0) {
                if (root.lastError === "")
                    root.lastError = "apex-display-apply exited " + code
                root.confirmSeconds = 0
                root._countdown.stop()
                return
            }
            if (root._pendingAction === "apply" && !root._reverting) {
                // Start the countdown only once the engine has reported
                // success. Starting it optimistically would tick down against
                // an apply that never happened, and then "revert" a layout
                // that was never changed.
                root.confirmSeconds = 15
                root._countdown.restart()
            } else {
                root.dirty = false
                root.refresh()
            }
            root._reverting = false
        }
    }

    // ── Display helpers ───────────────────────────────────────────────────────
    function modeLabel(m) {
        if (!m || !m.width) return "—"
        return m.width + "×" + m.height + " @ " + Number(m.refresh).toFixed(2).replace(/\.?0+$/, "") + " Hz"
    }

    function currentModeIndex(o) {
        if (!o || !o.modes) return -1
        const want = o.mode
        for (let i = 0; i < o.modes.length; i++) {
            const m = o.modes[i]
            if (want && m.width === want.width && m.height === want.height
                && Math.abs(m.refresh - want.refresh) < 0.5) return i
            if (!want && m.current) return i
        }
        return -1
    }

    readonly property var transforms: [
        { value: "normal", label: "None"  },
        { value: "90",     label: "90°"   },
        { value: "180",    label: "180°"  },
        { value: "270",    label: "270°"  }
    ]
}
