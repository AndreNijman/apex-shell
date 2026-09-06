pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// ─── AgentHelp ────────────────────────────────────────────────────────────────
// Whether the Agents tab still shows its first-run card, and whether the guide
// is open (roadmap §43).
//
// TWO SURFACES, TWO LIFETIMES. §43 asks for both, and they are not the same
// thing:
//
//   * the guide            reachable from the top of the Agents tab, for good.
//                          Not persisted: a panel that reopens itself on the
//                          next login is a panel you close twice.
//   * the first-run card   shown until the user says otherwise, then gone
//                          across restarts, reinstalls of the shell and
//                          reboots. Persisted, and only ever set one way by
//                          the UI.
//
// ── WHY THIS IS NOT A SettingsService KEY ───────────────────────────────────
//
// SettingsService is the user's tunable geometry and behaviour, and it carries
// two properties that make it the wrong home for this flag:
//
//   * `resetAll()` (Config → Misc → Reset all) walks `_keys` and restores every
//     default, so resetting your corner radius would bring the onboarding card
//     back from the dead;
//   * `isDefault` compares against those same defaults, so a user who dismissed
//     a help card would see "modified" against a settings file they never
//     touched.
//
// It also keys off `$HOME` rather than `$XDG_STATE_HOME`, which is the variable
// tests/run-agent-center-smoke.sh already isolates. This file is per-machine
// runtime state, not configuration to sync, so it belongs under the state
// directory the XDG spec has for exactly that.

QtObject {
    id: root

    // ── The guide (session-lived) ─────────────────────────────────────────────
    property bool panelOpen: false
    property string section: "start"

    function open(id) {
        root.section = (id === undefined || id === null || id === "") ? "start" : String(id)
        root.panelOpen = true
        console.info("AgentHelp: guide opened at", root.section)
    }

    function close() {
        if (!root.panelOpen) return
        root.panelOpen = false
        console.info("AgentHelp: guide closed")
    }

    // ── The first-run card (persisted) ────────────────────────────────────────
    property bool onboardingDismissed: false

    // False until the file has been read. The card is gated on it so a slow
    // read cannot flash the card at somebody who dismissed it a year ago —
    // the wrong answer for a quarter of a second is still the wrong answer.
    property bool loaded: false

    readonly property bool showOnboarding: root.loaded && !root.onboardingDismissed

    function dismissOnboarding() {
        if (root.onboardingDismissed) return
        root.onboardingDismissed = true
        _write()
        console.info("AgentHelp: onboarding dismissed, wrote", root.statePath)
    }

    function resetOnboarding() {
        if (!root.onboardingDismissed) return
        root.onboardingDismissed = false
        _write()
        console.info("AgentHelp: onboarding restored, wrote", root.statePath)
    }

    // ── Where it is written ───────────────────────────────────────────────────
    readonly property string _stateHome: {
        const x = Quickshell.env("XDG_STATE_HOME")
        if (x && x.length > 0) return x
        return Quickshell.env("HOME") + "/.local/state"
    }
    readonly property string statePath: _stateHome + "/apex-shell/agent-help.json"

    // Single-quote a value for `bash -c`. `$XDG_STATE_HOME` is whatever the
    // session exported, so a path with a space, a dollar or a quote in it must
    // not become two words or a variable expansion.
    function _sq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

    // ── Load ──────────────────────────────────────────────────────────────────
    // A missing file is the normal first-run answer, not an error, so this
    // prints `{}` rather than failing and leaves `onboardingDismissed` false.
    property var _readProc: Process {
        command: ["bash", "-c", "cat " + root._sq(root.statePath) + " 2>/dev/null || printf '{}'"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const o = JSON.parse(this.text.trim() || "{}")
                    root.onboardingDismissed = !!o.onboardingDismissed
                } catch (e) {
                    // A hand-edited or truncated file means "we learned
                    // nothing", which is the same as a fresh install.
                    console.warn("AgentHelp: unreadable state, treating as first run:", e)
                    root.onboardingDismissed = false
                }
                root.loaded = true
                console.info("AgentHelp: onboarding dismissed =", root.onboardingDismissed)
            }
        }
    }

    // ── Save ──────────────────────────────────────────────────────────────────
    // Not debounced. Unlike a slider this changes on a deliberate click, at most
    // twice in a session, and a dismissal the user made must survive the shell
    // being killed in the next half second.
    property var _writeProc: Process { command: []; running: false }

    function _write() {
        const json = JSON.stringify({ onboardingDismissed: root.onboardingDismissed })
        const p = root._sq(root.statePath)
        _writeProc.command = ["bash", "-c",
            "mkdir -p \"$(dirname " + p + ")\" && printf '%s' " + root._sq(json) + " > " + p]
        _writeProc.running = false
        _writeProc.running = true
    }

    Component.onCompleted: _readProc.running = true
}
