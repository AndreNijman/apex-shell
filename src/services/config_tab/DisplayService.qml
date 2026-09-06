pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// ─── DisplayService ───────────────────────────────────────────────────────────
// The graphical half of §18's display settings parity.
//
//     display.json  ──►  /usr/libexec/apex-display-apply  ──►  hyprctl eval
//                                                         ├─►  wlr-randr
//                                                         ├─►  apex/monitors.lua
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
//
// ── P0-018: apply is a transaction, not a function call ──────────────────────
//
// It used to be one. `apply()` wrote the user's model straight over
// display.json, ran the engine, and started a QML Timer. Three things were
// wrong with that, and the user lost a monitor layout to all three:
//
//   The countdown lived in the shell.  A shell that dies during the countdown
//   takes the revert with it, and the machine stays on the layout nobody could
//   confirm. src/scripts/apex-display-guard.sh is now the second owner of the
//   deadline, detached from this process.
//
//   A failed apply had already persisted.  display.json was written BEFORE the
//   engine was asked whether the layout was even valid, so a mode the panel
//   does not have was rejected on screen and applied at the next login. The
//   staged model now goes to a transaction file and is promoted to display.json
//   only when the user keeps it.
//
//   Nothing checked that the outputs still existed.  The draft is reconciled
//   against a fresh enumeration immediately before the apply, so unplugging a
//   monitor and pressing Apply says which output is gone instead of sending the
//   engine a layout for hardware that is not there.
//
// The confirmation UI moved too, for the reason the ticket was actually filed —
// see src/windows/DisplayConfirm.qml.
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

    readonly property string guard:
        Quickshell.shellDir + "/src/scripts/apex-display-guard.sh"

    // Under XDG_RUNTIME_DIR, and at a FIXED name. Both matter: the runtime dir
    // is wiped when the session ends, which is exactly the lifetime a live
    // display transaction has, and a fixed name is what lets a restarted shell
    // find a transaction its predecessor left open.
    readonly property string txnDir: {
        const override = Quickshell.env("APEX_DISPLAY_TXN_DIR") || ""
        if (override !== "") return override
        const rt = Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
        return rt + "/apex-display"
    }

    // Fifteen seconds is the number the page promises and the number the user
    // was told. It is a property only so the transaction suite does not have to
    // sit through it six times; nothing in the shell writes it.
    readonly property int confirmTotal: {
        const override = parseInt(Quickshell.env("APEX_DISPLAY_CONFIRM_SECONDS") || "", 10)
        return (!isNaN(override) && override > 0) ? override : 15
    }

    // ── What the hardware says ────────────────────────────────────────────────
    // Enumerated from the compositor, never guessed. `modes` is per-output and
    // is the only legitimate source for what a monitor will accept.
    property var outputs: []          // as reported by `apex-display-apply list`
    property bool loaded: false
    property string lastError: ""
    // A one-line account of what the transaction machinery last did on its own:
    // an abandoned apply rolled back at startup, a guard that reverted while
    // nobody was looking. Separate from lastError because it is not a failure.
    property string lastNotice: ""

    // ── What the user has staged ──────────────────────────────────────────────
    // A copy of `outputs`, edited. Kept separate so the page can show both
    // "what is" and "what you asked for", and so Revert is just discarding it.
    property var draft: []
    property bool dirty: false

    // How many fields the draft changes, so the commit bar can say what it is
    // holding rather than only that it is holding something. Counted per
    // FIELD, not per output: turning off one monitor and rescaling another is
    // two changes, and "1 staged change" for both would be a worse lie than no
    // number at all.
    readonly property int stagedCount: {
        if (!root.dirty) return 0
        const was = {}
        for (const o of root.outputs) was[o.name] = o
        let n = 0
        for (const d of root.draft) {
            const w = was[d.name]
            if (!w) { n++; continue }          // an output the list did not have
            if ((d.enabled !== false) !== (w.enabled !== false)) n++
            if (Number(d.scale || 1) !== Number(w.scale || 1)) n++
            if (String(d.transform || "normal") !== String(w.transform || "normal")) n++
            if (!!d.adaptive_sync !== !!w.adaptive_sync) n++
            if (Math.round(d.x || 0) !== Math.round(w.x || 0)
                || Math.round(d.y || 0) !== Math.round(w.y || 0)) n++
            const dm = d.mode || {}
            const wm = w.mode || {}
            if (dm.width !== wm.width || dm.height !== wm.height
                || Number(dm.refresh || 0).toFixed(2) !== Number(wm.refresh || 0).toFixed(2)) n++
        }
        return n
    }

    // ── Apply state ───────────────────────────────────────────────────────────
    property bool applying: false
    // Seconds left before an unconfirmed apply is reverted. 0 = not pending.
    property int confirmSeconds: 0
    property var _preApply: []
    // The model currently being tried, so the dialog can avoid an output this
    // very apply is turning off.
    property var _target: []
    // Epoch milliseconds. The countdown is derived from a deadline rather than
    // decremented, so it agrees with the guard's deadline to the second and a
    // restarted shell can re-attach to the remaining time instead of guessing.
    property double _deadline: 0

    readonly property int refCount: 0    // reserved: enumeration is on demand

    readonly property bool pending: root.confirmSeconds > 0

    // ── The output the confirmation is safe to appear on ─────────────────────
    //
    // This is the whole bug. The dialog used to be a section inside whichever
    // settings surface happened to be open, so an apply that closed, moved or
    // destroyed that surface took the only Keep button with it.
    //
    // Quickshell.screens is the post-apply truth: a disabled output leaves it,
    // verified against a headless wlroots session. So "still listed" already
    // means "still lit". The check against the target model is for a compositor
    // that keeps a disabled output advertised anyway — being wrong in that
    // direction puts the dialog on a black screen.
    readonly property string confirmScreen: {
        const live = Quickshell.screens
        if (!live || live.length === 0) return ""
        const off = {}
        for (const o of root._target)
            if (o && o.enabled === false) off[o.name] = true
        for (let i = 0; i < live.length; i++)
            if (!off[live[i].name]) return live[i].name
        return live[0].name
    }

    function refresh() {
        root._listProc.running = true
    }

    // ── Enumeration ──────────────────────────────────────────────────────────
    // On demand. The singleton is now constructed at startup (shell.qml holds a
    // reference so an abandoned transaction is settled even if nobody opens the
    // page), and enumerating from here would put an `apex-display-apply list`
    // in every login. The Display page calls refresh() when it loads, which is
    // exactly when this used to run.
    property var _listProc: Process {
        command: [root.engine, "list"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const fresh = JSON.parse(text.trim() || "[]")
                    if (Array.isArray(fresh)) {
                        root.outputs = root._normalize(fresh)
                        if (!root.dirty) root.draft = root._copy(root.outputs)
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

    /// Fill in the active mode from the mode list.
    ///
    /// `list` reports a per-output `modes` array with a `current` flag but no
    /// top-level `mode`, so the pre-apply snapshot carried no resolution at all
    /// and "revert" restored the layout at whatever the compositor considers
    /// preferred. On a panel whose preferred mode is not the one you were
    /// using, undo changed your resolution.
    ///
    /// Hyprland is still short here: apex-display-apply's Hyprland enumeration
    /// hardcodes `current: false` on every mode and emits no `mode` either, so
    /// there is nothing to recover. That needs the engine; see the P0-018
    /// report.
    function _normalize(list) {
        const out = root._copy(list)
        for (const o of out) {
            if (o.mode && o.mode.width) continue
            for (const m of (o.modes || [])) {
                if (!m.current) continue
                o.mode = { width: m.width, height: m.height, refresh: m.refresh }
                break
            }
        }
        return out
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
    function buildModel(from) {
        const outs = []
        for (const o of (from || root.draft)) {
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

    // ── Reconciling the draft against the hardware ───────────────────────────
    //
    // Between staging a change and pressing Apply the user can unplug a
    // monitor, and the shell would happily send the engine a layout for an
    // output that is no longer there. wlr-randr fails the whole invocation on
    // an unknown output, so the visible result was "nothing happened", with no
    // countdown, no dialog and no explanation.
    //
    // Returns a list of sentences, each naming an output and what is wrong with
    // it. Empty means the layout can be tried.
    function problemsWith(draftList, liveList) {
        const live = {}
        for (const o of liveList) live[o.name] = o
        const problems = []
        for (const d of draftList) {
            const l = live[d.name]
            if (!l) {
                problems.push("“" + d.name + "” is no longer connected.")
                continue
            }
            if (d.enabled === false) continue
            if (!d.mode || !d.mode.width) continue
            let ok = false
            for (const m of (l.modes || [])) {
                if (m.width === d.mode.width && m.height === d.mode.height
                    && Math.abs((m.refresh || 0) - (d.mode.refresh || 0)) < 0.5) {
                    ok = true
                    break
                }
            }
            if (!ok)
                problems.push("“" + d.name + "” does not offer "
                              + root.modeLabel(d.mode) + ".")
        }
        return problems
    }

    // ── save: persistence only, no hardware ──────────────────────────────────
    // Write and persist in one invocation. Two Processes would race, and the
    // loser would generate the kanshi profile from the previous model.
    function save() {
        root._pendingAction = "save"
        root._reverting = false
        root._applyProc.command = ["bash", "-c",
            'set -e\n' +
            'mkdir -p "$(dirname "$1")"\n' +
            'printf %s "$2" > "$1"\n' +
            'exec "$3" save --model "$1"',
            "--", root.modelPath, JSON.stringify(root.buildModel(), null, 2), root.engine]
        root.applying = true
        root.lastError = ""
        root._applyProc.running = true
    }

    // ── apply: a transaction ─────────────────────────────────────────────────
    //
    //   1. re-enumerate, so the snapshot and the validation are both current
    //   2. refuse a layout the hardware cannot take, keeping the staged values
    //   3. write target + rollback into the transaction directory
    //   4. detach a guard that owns the deadline whatever happens to the shell
    //   5. apply the TARGET FILE — display.json is untouched until Keep
    function apply() {
        if (root.applying || root.pending) return
        root.applying = true
        root.lastError = ""
        root.lastNotice = ""
        root._probeProc.running = true
    }

    property var _probeProc: Process {
        command: [root.engine, "list"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                let fresh = []
                try {
                    const parsed = JSON.parse(text.trim() || "[]")
                    if (Array.isArray(parsed)) fresh = root._normalize(parsed)
                } catch (e) {
                    root.lastError = "Cannot read the display layout: " + e
                    root.applying = false
                    return
                }
                if (fresh.length === 0) {
                    // Guarded, because onExited may already have reported why
                    // the enumeration failed and that message is the better one.
                    if (root.lastError === "")
                        root.lastError =
                            "This session reported no outputs, so there is " +
                            "nothing to apply to. Your changes are still staged."
                    root.applying = false
                    return
                }
                root.outputs = fresh
                const problems = root.problemsWith(root.draft, fresh)
                if (problems.length > 0) {
                    // Criterion 7: the draft is NOT touched. The user keeps
                    // every value they staged and can fix the one that is wrong.
                    root.lastError = problems.join(" ")
                                   + " Your other changes are still staged."
                    root.applying = false
                    return
                }
                // Snapshot from the hardware rather than from the draft: the
                // revert has to restore what is actually on screen, and the
                // draft is by definition what is not.
                root._preApply = root._copy(fresh)
                root._begin()
            }
        }
        onExited: function(code) {
            if (code !== 0 && root.applying && root.lastError === "") {
                root.lastError =
                    "Could not read the current layout (exit " + code + "), so " +
                    "there is nothing safe to undo to. Nothing reached the screen."
                root.applying = false
            }
        }
    }

    /// Write the transaction, detach the guard, and try the layout.
    function _begin() {
        const target   = root.buildModel(root.draft)
        const rollback = root.buildModel(root._preApply)
        root._target   = target.outputs
        root._deadline = Date.now() + root.confirmTotal * 1000

        // One bash invocation, every value an argv element. Output names come
        // off EDID, which is attacker-controlled in the sense that nobody
        // validates what a monitor claims to be called.
        root._pendingAction = "apply"
        root._reverting = false
        root._applyProc.command = ["bash", "-c",
            'set -e\n' +
            'mkdir -p "$1"\n' +
            'printf %s "$2" > "$1/target.json"\n' +
            'printf %s "$3" > "$1/rollback.json"\n' +
            'printf %s "$4" > "$1/deadline"\n' +
            'rm -f "$1/verdict" "$1/state" "$1/guard.pid"\n' +
            'bash "$5" spawn "$1"\n' +
            'exec "$6" apply --model "$1/target.json"',
            "--",
            root.txnDir,
            JSON.stringify(target, null, 2),
            JSON.stringify(rollback, null, 2),
            String(Math.round(root._deadline / 1000)),
            root.guard,
            root.engine]
        root._applyProc.running = true
    }

    /// Called by the dialog when the user confirms the new layout is usable.
    function confirm() {
        if (!root.pending) return
        root._countdown.stop()
        root.confirmSeconds = 0
        root._deadline = 0
        root._verdict("keep")
        // Promote: the model the user kept becomes the model that comes back at
        // the next login, and `save` regenerates the kanshi profile and the
        // Hyprland conf from it. Only now, and only on this path.
        root._pendingAction = "keep"
        root._reverting = false
        root._applyProc.command = ["bash", "-c",
            'set -e\n' +
            'mkdir -p "$(dirname "$1")"\n' +
            'cp -f "$2/target.json" "$1"\n' +
            'exec "$3" save --model "$1"',
            "--", root.modelPath, root.txnDir, root.engine]
        root.applying = true
        root._applyProc.running = true
        root._preApply = []
        root._target = []
    }

    /// Put back what was on screen before the last apply.
    function revertApplied() {
        if (root._preApply.length === 0 && !root.pending) return
        root._countdown.stop()
        root.confirmSeconds = 0
        root._deadline = 0
        // The guard is told first. If this process dies between here and the
        // apply below, the guard still restores the same rollback file.
        root._verdict("revert")
        root.draft = root._copy(root._preApply)
        root._preApply = []
        root._target = []
        root._pendingAction = "apply"
        root._reverting = true
        // Through the guard, not straight to the engine. The guard restores
        // from the rollback FILE and carries the fallback for a mode the
        // compositor will no longer take, so the button and the deadline put
        // back exactly the same thing in exactly the same way.
        root._applyProc.command = ["bash", root.guard, "restore", root.txnDir]
        root.applying = true
        root._applyProc.running = true
    }

    function _verdict(v) {
        root._verdictProc.command = ["bash", root.guard, "verdict", root.txnDir, v]
        root._verdictProc.running = true
    }

    property var _verdictProc: Process {
        command: []
        running: false
    }

    // Derived from the deadline rather than decremented. A repeating Timer that
    // subtracts one drifts, and — more to the point — cannot be re-attached to
    // by a shell that restarted halfway through.
    property var _countdown: Timer {
        interval: 250
        repeat: true
        running: false
        onTriggered: {
            const left = Math.ceil((root._deadline - Date.now()) / 1000)
            root.confirmSeconds = Math.max(0, left)
            if (left <= 0) root.revertApplied()
        }
    }

    property bool _reverting: false
    property string _pendingAction: ""

    function _writeModel(path, model) {
        root._writeProc.command = ["bash", "-c",
            'mkdir -p "$(dirname "$1")" && printf %s "$2" > "$1"',
            "--", path, JSON.stringify(model, null, 2)]
        root._writeProc.running = true
    }

    property var _writeProc: Process {
        command: []
        running: false
    }

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
            const action = root._pendingAction
            root._pendingAction = ""

            if (code !== 0) {
                if (root.lastError === "")
                    root.lastError = "apex-display-apply exited " + code
                if (action === "apply" && !root._reverting) {
                    // The engine refused the layout. Nothing reached the
                    // hardware on wlr-randr, which applies the whole model in
                    // one invocation; Hyprland applies output by output and can
                    // stop halfway, so the rollback is applied either way and
                    // the guard is stood down.
                    root.lastError = root.lastError +
                        "  Nothing reached the screen, and your settings are still staged."
                    root._verdict("revert")
                    root._rollbackProc.command =
                        ["bash", root.guard, "restore", root.txnDir]
                    root._rollbackProc.running = true
                }
                root.confirmSeconds = 0
                root._deadline = 0
                root._target = []
                root._countdown.stop()
                root._reverting = false
                return
            }

            if (action === "apply" && !root._reverting) {
                // Start the countdown only once the engine has reported
                // success. Starting it optimistically would tick down against
                // an apply that never happened, and then "revert" a layout
                // that was never changed.
                root.confirmSeconds = root.confirmTotal
                root._countdown.restart()
            } else {
                root.dirty = false
                root.refresh()
            }
            root._reverting = false
        }
    }

    property var _rollbackProc: Process {
        command: []
        running: false
    }

    // ── Re-attaching to a transaction this shell did not start ───────────────
    //
    // The shell can die between the apply and the verdict — that is the whole
    // reason the guard exists. When it comes back, one of three things is true
    // of the transaction directory, and `apex-display-guard.sh reconcile` says
    // which:
    //
    //   pending, guard alive   → the countdown is still running. Re-attach to
    //                            the remaining seconds and put the dialog back
    //                            up, so the user can still keep the layout.
    //   pending, guard gone    → nobody was watching. reconcile reverts if the
    //                            deadline passed, adopts it if it has not.
    //   reverted / kept        → already settled; say so once and stop.
    property var _reconcileProc: Process {
        command: ["bash", root.guard, "reconcile", root.txnDir]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                const parts = text.trim().split(/\s+/)
                const state = parts[0] || "none"
                const left  = parseInt(parts[1] || "0", 10) || 0
                if (state === "pending" && left > 0) {
                    root._deadline = Date.now() + left * 1000
                    root.confirmSeconds = left
                    root._countdown.restart()
                    root.lastNotice =
                        "A display change from before the shell restarted is " +
                        "still waiting to be confirmed."
                    root._adoptProc.running = true
                } else if (state === "reverted") {
                    root.lastNotice =
                        "The last display change went unconfirmed, so the " +
                        "previous layout came back."
                }
            }
        }
    }

    // The rollback the previous shell recorded, so Revert on the re-attached
    // dialog restores the same layout the guard would.
    property var _adoptProc: Process {
        command: ["cat", root.txnDir + "/rollback.json"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const m = JSON.parse(text.trim() || "{}")
                    if (m.outputs && m.outputs.length > 0) root._preApply = m.outputs
                } catch (e) {
                    // An unreadable rollback means Revert has nothing to
                    // restore; the guard's own deadline still does.
                }
            }
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
