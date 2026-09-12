pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "permissions.js" as Perm

// ─── PermissionsService ──────────────────────────────────────────────────────
// The data behind Config → Privacy & Permissions (roadmap P1-061).
//
// Same rule as RecoveryService and AgentService: everything goes through the
// `apex` CLI. `apex permissions` owns the argv, already knows how to read the
// portal permission store, a Flatpak's merged sandbox context and a device
// node's ACL, and already refuses a revocation it cannot perform. Re-deriving
// any of that in QML would produce a second answer that could disagree with
// the first, and on this page a disagreement is a lie about the machine.
//
// ── WHAT THIS MAY RUN ────────────────────────────────────────────────────────
//
// Polled, and the only thing that ever may be:
//
//   apex permissions list --json   reads busctl introspection, the permission
//                                  store, each Flatpak's manifest, and
//                                  access(2) on two device nodes. It writes
//                                  nothing and it changes nothing, so it
//                                  cannot raise an authentication prompt.
//
// User-initiated ONLY, once, on an explicit press:
//
//   apex permissions revoke …      writes to the portal permission store, or
//                                  writes a `flatpak override`. Both are the
//                                  user's own files and neither needs root, so
//                                  no polkit agent is involved here either.
//
// There is no timer in this file that can reach `revoke`.
//
// ── A REFUSAL IS THE ANSWER, NOT AN ERROR ────────────────────────────────────
//
// `apex permissions revoke` exits NON-ZERO when nothing can be revoked, and
// prints why. That is the correct behaviour and this must not render it as a
// failed command: the page never offers a control for such a row in the first
// place (permissions.js's `controlsFor` returns an empty list), so a non-zero
// exit here means something genuinely went wrong with a revocation that WAS
// possible — and that is what `lastError` says.
//
// ── AND AN UNREADABLE ANSWER IS NOT A CLEAN MACHINE ──────────────────────────
//
// `available` is false, with a reason, when the command could not be read at
// all. A page that rendered that as an empty list would tell an owner nothing
// holds any permissions at the exact moment it stopped being able to check.
Singleton {
    id: root

    // ── Demand ───────────────────────────────────────────────────────────────
    //     ServiceRef { service: PermissionsService; active: root.onScreen }
    property int refCount: 0

    // ── Tunables ─────────────────────────────────────────────────────────────
    // Between sweeps while watched. Long: nothing here changes unless the user
    // installs something, answers a portal prompt, or presses a button on this
    // very page — and the last of those refreshes directly.
    readonly property int sweepInterval: 30000
    // Smallest gap between sweep STARTS for anything that is not the Refresh
    // button. Tabbing away and back must not re-run a `flatpak info` per app.
    readonly property int minSweepGap: 5000
    // One `flatpak info --show-permissions` per installed application, and
    // Flatpak is not fast. Generous, and still bounded.
    readonly property int queryTimeout: 30000
    // A store write or an override edit. Neither touches the network.
    readonly property int revokeTimeout: 20000

    // ── What the machine says ────────────────────────────────────────────────
    property var report: Perm.parseList("", 0)

    // True once a sweep has returned at least once, whatever it said. Lets the
    // page tell "nothing to show" from "not asked yet", which look identical
    // and mean opposite things.
    property bool checked: false
    readonly property bool available: root.report.ok
    readonly property string unavailableReason: root.report.reason
    readonly property var apps: root.report.apps
    readonly property var session: root.report.session

    // Non-empty when a revocation that the model said WAS possible failed
    // anyway. Rendered at page level, in the danger tone.
    property string lastError: ""
    readonly property bool busy: root._pending !== "" || root._revoking !== ""

    function controlsFor(row) { return Perm.controlsFor(row) }
    function enforcerLabel(e) { return Perm.enforcerLabel(e) }

    // ── The sweep ────────────────────────────────────────────────────────────
    // "" | "list". A one-shot slot: the first signal to arrive consumes it and
    // every later one is ignored, which is what makes the watchdog kill safe —
    // the SIGTERM's own `exited` finds the slot empty.
    property string _pending: ""
    property string _buf: ""
    property real _lastSweepStart: 0

    // A person asking is not churn, so this alone bypasses the age clamp.
    function refresh() { root._beginSweep(true) }

    function _beginSweep(force) {
        if (root.refCount <= 0 && !force) return
        if (root._pending !== "" || root._revoking !== "") return
        var now = Date.now()
        if (!force && now - root._lastSweepStart < root.minSweepGap) return
        root._lastSweepStart = now
        root._pending = "list"
        root._buf = ""
        root._proc.running = false
        root._proc.command = ["apex", "permissions", "list", "--json"]
        root._proc.running = true
        root._watchdog.interval = root.queryTimeout
        root._watchdog.restart()
    }

    function _settle(code) {
        if (root._pending === "") return
        root._pending = ""
        root._watchdog.stop()
        root.report = Perm.parseList(root._buf, code)
        root.checked = true
    }

    // `running: false` is a CONSTANT here, never `running: refCount > 0`.
    // Assigning to `running` imperatively below would destroy a binding, and a
    // destroyed binding is how a poller comes to run until logout.
    property Process _proc: Process {
        command: []
        running: false
        stdout: StdioCollector {
            onStreamFinished: root._buf = this.text
        }
        onExited: function (code) { root._settle(code) }
    }

    property Timer _watchdog: Timer {
        repeat: false
        onTriggered: {
            root._proc.running = false
            root._settle(124)
        }
    }

    property Timer _tick: Timer {
        interval: root.sweepInterval
        repeat: true
        running: root.refCount > 0
        onTriggered: root._beginSweep(false)
    }

    onRefCountChanged: {
        if (root.refCount > 0) {
            root._beginSweep(true)
        } else {
            root._proc.running = false
            root._watchdog.stop()
            root._pending = ""
        }
    }

    // ── Revocation, on a press and only on a press ───────────────────────────
    // "" | "<app>/<capability>". The argv comes from permissions.js, which
    // returns null for any row that does not offer a control — so a button
    // wired to the wrong row cannot assemble a revocation for something the
    // machine cannot perform. The guard is here as well as there because the
    // two files are edited by different people at different times.
    property string _revoking: ""
    property string _revokeBuf: ""

    function revoke(row, verb) {
        if (root._revoking !== "" || root._pending !== "") return false
        var argv = Perm.revokeArgv(row, verb)
        if (!argv) {
            root.lastError = "There is nothing to withdraw here — " + row.enforcerWhy
            return false
        }
        root.lastError = ""
        root._revoking = row.revokeId + "/" + row.capability
        root._revokeBuf = ""
        root._revokeProc.running = false
        root._revokeProc.command = argv
        root._revokeProc.running = true
        root._revokeWatchdog.interval = root.revokeTimeout
        root._revokeWatchdog.restart()
        return true
    }

    function _settleRevoke(code) {
        if (root._revoking === "") return
        var what = root._revoking
        root._revoking = ""
        root._revokeWatchdog.stop()
        if (code !== 0) {
            root.lastError = root._revokeBuf.trim() !== ""
                ? root._revokeBuf.trim()
                : ("could not change " + what)
        }
        // Re-read whatever happened. The page must show what the machine says
        // now, not what the button meant.
        root._beginSweep(true)
    }

    property Process _revokeProc: Process {
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._revokeBuf = this.text }
        stderr: StdioCollector { onStreamFinished: root._revokeBuf = this.text }
        onExited: function (code) { root._settleRevoke(code) }
    }

    property Timer _revokeWatchdog: Timer {
        repeat: false
        onTriggered: {
            root._revokeProc.running = false
            root._settleRevoke(124)
        }
    }
}
