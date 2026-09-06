pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "gaming.js" as GM

// The data behind Config → Gaming (P1-049).
//
// ── WHAT IT READS, AND WHY THOSE THREE ───────────────────────────────────────
//
//   apex gaming --json   whether this machine can boot straight into Gaming
//                        Mode, which of the on-demand packages are installed,
//                        and the CLI's own sentences about what is stopping it.
//                        Read-only, and it EXITS NON-ZERO when Gaming Mode
//                        would not start — so a non-zero exit here is the
//                        answer, not a failure. Treating it as one is how a
//                        page tells a user with a working desktop that its
//                        probe broke.
//
//   apex mode status     the policy the machine is in now: mode, power tier,
//                        game mode. Criterion 6. Text, because there is no
//                        --json on that subcommand yet.
//
//   apex mode set <m>    the one thing here that changes anything, behind a
//                        button, and followed by re-reading `mode status`
//                        rather than assuming it worked. Criterion 7.
//
// ── NO TIMER ─────────────────────────────────────────────────────────────────
//
// Nothing polls. `apex mode set --auto` is documented one-shot — "APEX ships
// nothing that re-evaluates this on a timer" — and a settings page that ran a
// probe every few seconds would be the shell inventing the daemon the OS
// declined to ship. The page reads when it is opened and when the user asks.
//
// ── NO ESCALATION ────────────────────────────────────────────────────────────
//
// `apex mode set` needs no root: the active mode is derived from what apexd
// reports rather than stored. Installing the missing packages DOES need root,
// and this service will not do it — the install line is shown as text for the
// user to run, the same way BlueprintService shows `sudo apex apply`. A button
// here that ran sudo would raise an authentication prompt from a settings page.
QtObject {
    id: root

    // Overridable so a locally built binary can be exercised without installing
    // into /usr. Mirrors BlueprintService's APEX_BLUEPRINT_CLI.
    readonly property string cli: {
        const override = Quickshell.env("APEX_GAMING_CLI") || ""
        return override !== "" ? override : "apex"
    }

    // ── readiness ─────────────────────────────────────────────────────────────
    property var report: null          // readGaming()'d, or null
    property bool loaded: false
    property string lastError: ""

    // True when the CLI could not be run at all, as opposed to running and
    // saying no. The page shows an explanation rather than an empty list.
    property bool available: true
    property string unavailableReason: ""

    readonly property bool ready:        root.report ? root.report.ready : false
    readonly property string readiness:  root.report ? GM.readiness(root.report) : ""
    readonly property var missing:       root.report ? GM.missingTools(root.report) : []
    readonly property var setupChecks:   root.report ? GM.setupChecks(root.report) : []
    readonly property var otherChecks:   root.report ? GM.otherChecks(root.report) : []
    readonly property string installLine: root.report ? GM.installLine(root.report) : ""
    readonly property var blockers:      root.report ? root.report.blockers : []
    readonly property var warnings:      root.report ? root.report.warnings : []
    readonly property var gamepads:      root.report ? root.report.gamepads : []
    readonly property string preselected: root.report ? root.report.preselected : ""

    // ── the policy in force ───────────────────────────────────────────────────
    property var status: null          // readModeStatus()'d, or null
    readonly property string policyLine: root.status ? GM.policyLine(root.status) : ""
    readonly property bool inGaming:    root.status ? GM.inGamingMode(root.status) : false
    readonly property string mode:      root.status && root.status.ok ? root.status.mode : ""

    // ── switching ─────────────────────────────────────────────────────────────
    property bool switching: false
    property string switchError: ""
    property string switchOutput: ""

    // The named modes this page offers. `daily` and `gaming` only: those are the
    // two this page is about, and a settings page for gaming has no business
    // being the place somebody discovers `creator`. `apex mode list` has the
    // rest.
    readonly property var offered: [
        { value: "gaming", label: "Gaming",
          blurb: "Pins the power tier and turns on game mode: core pinning, " +
                 "interrupt steering and GPU clock locks." },
        { value: "daily",  label: "Everyday",
          blurb: "Lets the machine decide for itself, which is what you want " +
                 "when you are not playing." }
    ]

    function refresh() {
        root._gamingProc.running = true
        root._statusProc.running = true
    }

    // Criterion 7: change the policy, then MEASURE it. Never assume the exit
    // code meant the mode took.
    function setMode(name) {
        if (root.switching) return
        root.switchError = ""
        root.switchOutput = ""
        root.switching = true
        root._setCommand = [root.cli, "mode", "set", String(name)]
        root._setProc.running = true
    }

    property var _setCommand: []

    // ── apex gaming --json ────────────────────────────────────────────────────
    property var _gamingProc: Process {
        command: [root.cli, "gaming", "--json"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                const r = GM.readGaming(text)
                if (!r.ok) {
                    root.lastError = r.error
                    root.report = null
                    return
                }
                root.report = r
                root.lastError = ""
                root.available = true
                root.unavailableReason = ""
            }
        }
        stderr: StdioCollector {
            onStreamFinished: {
                const t = text.trim()
                if (t !== "" && root.report === null) root.lastError = t
            }
        }
        // A non-zero exit is how this verb says "Gaming Mode would not start",
        // which is a report and not an error. Only a process that could not run
        // at all — no such command — makes the page unavailable, and that is
        // the ONLY place `available` is cleared, so one transient failure
        // cannot latch the whole page off.
        onExited: function(code, status) {
            root.loaded = true
            if (root.report === null && root.lastError === "") {
                root.available = false
                root.unavailableReason =
                    "`apex gaming` did not run on this image, so nothing here " +
                    "could be checked."
            }
        }
    }

    // ── apex mode status ──────────────────────────────────────────────────────
    property var _statusProc: Process {
        command: [root.cli, "mode", "status"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                root.status = GM.readModeStatus(text)
            }
        }
    }

    // ── apex mode set ─────────────────────────────────────────────────────────
    // The only command here that changes anything. Entered from setMode() and
    // from nothing else: no binding, no timer, no onCompleted.
    property var _setProc: Process {
        command: root._setCommand
        running: false
        stdout: StdioCollector {
            onStreamFinished: { root.switchOutput = text.trim() }
        }
        stderr: StdioCollector {
            onStreamFinished: { root.switchError = text.trim() }
        }
        onExited: function(code, status) {
            root.switching = false
            if (code !== 0 && root.switchError === "")
                root.switchError = "apex mode set exited " + code
            // Re-read either way. A refused switch still has to leave the
            // readout showing what the machine is actually in, and a switch
            // that reported success and did not take is exactly what criterion
            // 7 asks this page to catch.
            root._statusProc.running = true
        }
    }
}
