pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "lid.js" as Lid

// ─── LidService ──────────────────────────────────────────────────────────────
// The data behind Config → Closing the Lid and the Quick Settings tile
// (roadmap P1-063). Andre's request, in his words:
//
//   "if i close my laptop lid without shutting down, most things pause to save
//    battery, but all agents and whatever theyre using/doing or whatever can
//    stay running, also staying with the vpn — like if i close my laptop at
//    school and codex is running (which needs vpn to work) it keeps working."
//
// Same rule as PermissionsService and RecoveryService: everything goes through
// the `apex` CLI. `apex lid` already knows how to read the lid switch, the
// thermal zones, the battery, logind's Docked and BlockInhibited properties,
// the DRM connectors, NetworkManager AND sing-box's tun device, and every
// live agent session per logged-in user. Re-deriving any of that in QML would
// produce a second answer that could disagree with the driver's — and the
// driver is the thing that actually decides whether the machine suspends, so a
// disagreement here is not a cosmetic bug, it is the page lying about what the
// laptop is going to do.
//
// ── WHAT THIS MAY RUN ────────────────────────────────────────────────────────
//
// Polled, and the only things that ever may be:
//
//   apex lid status --json   reads /proc, /sys, two busctl properties and
//                            NetworkManager. Writes nothing, spawns no
//                            privileged helper, and cannot raise a prompt.
//   apex lid report --json   reads one JSON file under /var/lib/apex/lid.
//
// Both are read-only, and they run one after the other rather than at once, so
// a sweep costs two short-lived processes and never more.
//
// User-initiated ONLY, once, on an explicit press:
//
//   apex lid pin auto|on|off writes the OWNER's ~/.config/apex/lid.toml.
//
// ── AND `pin` NEEDS NO PRIVILEGE, BY DESIGN ─────────────────────────────────
//
// Measured on 2026-09-12, three ways rather than argued about:
// `org.freedesktop.login1.inhibit-handle-lid-switch` ships `allow_active=yes`
// and no rule in /etc/polkit-1/rules.d overrides it; `pkcheck --process $$`
// exits 0 WITHOUT `--allow-user-interaction`, so it could not have prompted;
// and the lock was taken for real as uid 1000 with nothing on screen. So the
// pin is a file in the user's own home and the inhibitor it controls is
// authorised for their own session. There is no `sudo` and no `pkexec`
// anywhere on this surface, and a polkit prompt appearing here would be a
// defect and not an inconvenience. `pinArgv` in lid.js refuses anything that
// is not one of the three words, so a control wired to a bad value cannot
// assemble a command instead of being ignored.
//
// ── NOTHING HERE CLOSES A LID, AND NOTHING HERE SUSPENDS ────────────────────
//
// There is no verb on this service that changes the machine's power state. The
// driver (`apex-lid.service`, running as root) is what holds the inhibitor,
// powers things down and calls `systemctl suspend` when a guard fires. This is
// a window onto it.
//
// ── A FAILED READ IS NOT A CALM MACHINE ─────────────────────────────────────
//
// `available` is false, with a reason, when the command could not be read at
// all — never an empty, calm-looking status. A page that rendered an
// unreadable machine as "nothing running, suspends normally" would tell an
// owner their laptop will behave at the exact moment it stopped being able to
// check. Every accessor below still returns a fully-populated object in that
// state, because a binding inside an invisible section is still evaluated;
// that rule, and the bug behind it, are in lid.js's header.
Singleton {
    id: root

    // ── Demand ───────────────────────────────────────────────────────────────
    //     ServiceRef { service: LidService; active: root.onScreen }
    property int refCount: 0

    // ── Tunables ─────────────────────────────────────────────────────────────
    // Between sweeps while watched. The lid decision changes when an agent
    // session starts or ends, when a display is plugged in, or when the
    // battery crosses the floor — none of which is fast, and all of which the
    // owner is looking at this surface precisely to check.
    readonly property int sweepInterval: 15000
    // Smallest gap between sweep STARTS for anything that is not the Refresh
    // button. Tabbing between the dashboard and this page must not spawn a
    // pair of processes per switch.
    readonly property int minSweepGap: 3000
    // Both reads are /proc, /sys, two busctl calls and one file. A busctl to a
    // logind that is wedged is the only slow path, and it is bounded here.
    readonly property int queryTimeout: 15000
    // One write to a file in the user's own home.
    readonly property int pinTimeout: 10000

    // ── What the machine says ────────────────────────────────────────────────
    property var status: Lid.statusView("", 0)
    property var report: Lid.reportView("", 0)

    // True once a sweep has returned at least once, whatever it said. Lets the
    // surface tell "nothing to show" from "not asked yet", which look identical
    // and mean opposite things.
    property bool checked: false

    readonly property bool available:         root.status.ok
    readonly property string unavailableReason: root.status.reason
    readonly property string pin:             root.status.pin
    readonly property var logind:             root.status.logind
    readonly property var decision:           root.status.decision
    readonly property var work:               root.status.work
    readonly property var thermal:            root.status.thermal
    readonly property var charge:             root.status.charge
    readonly property var vpn:                root.status.vpn
    // A note, never a failure: on any machine where root holds a live
    // /run/user/0, an ordinary user's read ALWAYS carries
    // "/root/.config/apex/lid.toml: Permission denied", because the OS side
    // reports every policy candidate it could not read. Deliberate, correct,
    // and the normal state of a healthy machine — so it is separate from
    // `unavailableReason` and the page paints it in the note tone.
    readonly property string policyNote:      root.status.policyNote

    readonly property string headline:        Lid.headline(root.status)
    readonly property var tile:               Lid.tileView(root.status)

    // Non-empty when a pin the model said WAS valid failed anyway. Rendered at
    // page level, in the danger tone.
    property string lastError: ""
    readonly property bool busy: root._pending !== "" || root._pinning !== ""

    function pinLabel(p) { return Lid.pinLabel(p) }

    // ── The sweep ────────────────────────────────────────────────────────────
    // "" | "status" | "report". A one-shot slot: the first signal to arrive
    // consumes it and every later one is ignored, which is what makes the
    // watchdog kill safe — the SIGTERM's own `exited` finds the slot empty.
    property string _pending: ""
    property string _buf: ""
    property real _lastSweepStart: 0

    // A person asking is not churn, so this alone bypasses the age clamp.
    function refresh() { root._beginSweep(true) }

    function _beginSweep(force) {
        if (root.refCount <= 0 && !force) return
        if (root._pending !== "" || root._pinning !== "") return
        var now = Date.now()
        if (!force && now - root._lastSweepStart < root.minSweepGap) return
        root._lastSweepStart = now
        root._run("status")
    }

    function _run(which) {
        root._pending = which
        root._buf = ""
        root._proc.running = false
        root._proc.command = ["apex", "lid", which, "--json"]
        root._proc.running = true
        root._watchdog.interval = root.queryTimeout
        root._watchdog.restart()
    }

    function _settle(code) {
        if (root._pending === "") return
        var which = root._pending
        root._pending = ""
        root._watchdog.stop()
        if (which === "status") {
            root.status = Lid.statusView(root._buf, code)
            // The report follows the status rather than running beside it: two
            // `apex` processes at once for a surface nobody is urgently
            // watching is a cost with no reader.
            root._run("report")
            return
        }
        root.report = Lid.reportView(root._buf, code)
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

    // ── The pin, on a press and only on a press ─────────────────────────────
    // The argv comes from lid.js, which returns null for anything that is not
    // `auto`, `on` or `off` — so a control wired to the wrong value cannot
    // assemble a command for something the CLI would have to reject. The guard
    // is here as well as there because the two files are edited by different
    // people at different times.
    property string _pinning: ""
    property string _pinBuf: ""

    function setPin(state) {
        if (root._pinning !== "" || root._pending !== "") return false
        var argv = Lid.pinArgv(state)
        if (!argv) {
            root.lastError = "\"" + state + "\" is not one of auto, on or off"
            return false
        }
        root.lastError = ""
        root._pinning = state
        root._pinBuf = ""
        root._pinProc.running = false
        root._pinProc.command = argv
        root._pinProc.running = true
        root._pinWatchdog.interval = root.pinTimeout
        root._pinWatchdog.restart()
        return true
    }

    // What a tap on the Quick Settings tile means: on <-> auto, never `off`.
    // `off` means "suspend on a close whatever is running", which kills an
    // agent mid-build, and that is not something a fingertip on a two-state
    // tile should be able to select by accident. It is reachable from the
    // page, next to the sentence explaining it.
    function toggle() { return root.setPin(Lid.tileToggle(root.status.pin)) }

    function _settlePin(code) {
        if (root._pinning === "") return
        var what = root._pinning
        root._pinning = ""
        root._pinWatchdog.stop()
        if (code !== 0) {
            root.lastError = root._pinBuf.trim() !== ""
                ? root._pinBuf.trim()
                : ("could not pin lid keep-working " + what)
        }
        // Re-read whatever happened. The surface must show what the machine
        // says now, not what the button meant — the pin file is read by the
        // ROOT driver, and a write this process thought succeeded is still not
        // a decision until the driver has seen it.
        root._beginSweep(true)
    }

    property Process _pinProc: Process {
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._pinBuf = this.text }
        stderr: StdioCollector { onStreamFinished: root._pinBuf = this.text }
        onExited: function (code) { root._settlePin(code) }
    }

    property Timer _pinWatchdog: Timer {
        repeat: false
        onTriggered: {
            root._pinProc.running = false
            root._settlePin(124)
        }
    }
}
