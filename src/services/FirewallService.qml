pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "firewall.js" as Fw

// ─────────────────────────────────────────────────────────────────────────────
//  What is reachable from the network, for the Firewall settings page
//  (roadmap P1-044).
//
//  ── WHY THIS EXISTS AT ALL ──────────────────────────────────────────────────
//
//  APEX now drops incoming connections by default. That is the right default
//  and it is also the kind of change a user meets as a symptom: a phone that
//  stops casting, a printer that stops being found, a game that will not
//  stream. A firewall a user cannot see is a firewall they turn off at the
//  first confusing symptom — so there is a page, and it says what is dropped,
//  what is open, and what they can open.
//
//  ── THREE READS, NO WRITES ──────────────────────────────────────────────────
//
//  Everything below is a question. `apex firewall allow` needs root, the
//  shell's route to root is polkit, and P0-016 is where that stops being
//  guesswork; until then this shows the command instead of running it — the
//  same choice RecoveryPage makes for rollback, and for the same reason.
//
//  Nothing on a timer can change this machine. That is not a comment, it is
//  what tests/check-firewall-ui.sh asserts: every argv here is a read.
//
//  ── PROCESS LIFETIME ────────────────────────────────────────────────────────
//
//  Nothing runs while nobody is looking. `refCount` is the name
//  components/ServiceRef.qml expects; demand dropping to zero kills the sweep
//  in flight rather than letting it finish.
//
//  The Quickshell 0.3.0 Process facts this depends on are the ones
//  RecoveryService.qml documents: `streamFinished` precedes `exited`, a binary
//  that cannot exec emits NEITHER and only drops `running` to false, and
//  assigning `running = false` produces its own `exited(15)`. The settle timer
//  is TAGGED with the step that armed it for the same reason RecoveryService's
//  is — three steps share one process and one slot, and an untagged settle
//  resolves the wrong one.
// ─────────────────────────────────────────────────────────────────────────────
Singleton {
    id: root

    // ── Demand ───────────────────────────────────────────────────────────────
    //     ServiceRef { service: FirewallService; active: root.onScreen }
    property int refCount: 0

    // ── Tunables ─────────────────────────────────────────────────────────────
    // Long, because nothing here changes without a person running a command in
    // a terminal. The sweep exists so the page catches up after they do, not so
    // it watches for weather.
    readonly property int sweepInterval: 30000
    readonly property int minSweepGap:   4000
    readonly property int queryTimeout:  10000
    readonly property int stepDelay:     60

    // ── What the machine says ────────────────────────────────────────────────
    property string unit: "unknown"
    property var status: ({ ok: false, exceptions: [], alwaysAllowed: "", policy: "unknown" })
    property var catalogue: []

    // True once a sweep has returned at least once, whatever it said. Lets the
    // page tell "nothing is open" from "not asked yet", which look identical
    // and mean opposite things.
    property bool checked: false

    readonly property bool enforcing: root.unit === "active"
    readonly property string statusLine: Fw.statusLine(root.unit, root.status)
    readonly property string statusTone: Fw.statusTone(root.unit)
    readonly property var exceptions: root.status.exceptions || []
    readonly property var openable: Fw.unopened(root.catalogue, root.exceptions)
    readonly property string alwaysAllowed: root.status.alwaysAllowed
    readonly property int rejectedCount: {
        var n = 0
        for (var i = 0; i < root.exceptions.length; i++)
            if (root.exceptions[i].rejected) n++
        return n
    }

    readonly property string readCommand:  Fw.READ_COMMAND
    readonly property string startCommand: Fw.START_COMMAND
    function allowCommand(name) { return Fw.allowCommand(name) }
    function denyCommand(name)  { return Fw.denyCommand(name) }

    readonly property bool busy: root._pending !== "" || root._advance.running

    // ── The sweep: the unit, then the exceptions, then the catalogue ─────────
    property string _pending: ""
    property var    _queue: []
    property string _buf: ""
    property real   _lastSweepStart: 0

    // A person asking is not churn, so this alone bypasses the age clamp.
    function refresh() { root._beginSweep(true) }

    function _beginSweep(force) {
        if (root.refCount <= 0 && !force) return
        // `_advance.running` must be in this guard: between one step resolving
        // and the next starting there is a stepDelay gap in which `_pending` is
        // "" and the sweep is still going. Without it, Refresh landing in that
        // window starts a second sweep whose exit is consumed by the first
        // sweep's next slot.
        if (root._pending !== "" || root._advance.running) return
        if (!force && (Date.now() - root._lastSweepStart) < root.minSweepGap) return

        root._lastSweepStart = Date.now()
        root._queue = ["unit", "status", "catalogue"]
        root._next()
    }

    // Every one of these is a read. `systemctl show` reports without touching
    // anything; `apex firewall status` and `list` are the helper's two
    // unprivileged verbs. There is deliberately no fourth entry.
    //
    // `show` and not `is-active`: is-active says "inactive" for a unit that
    // does not exist, which is the same word it says for one that is merely
    // stopped. See the note in firewall.js.
    readonly property var _stepArgv: ({
        unit:      ["systemctl", "show", "apex-firewall.service",
                    "-p", "LoadState", "-p", "ActiveState"],
        status:    ["apex", "firewall", "status"],
        catalogue: ["apex", "firewall", "list"]
    })

    function _next() {
        if (root.refCount <= 0) { root._standDown(); return }
        if (root._queue.length === 0) { root._sweepDone(); return }

        const step = root._queue[0]
        root._queue = root._queue.slice(1)
        // The settle timer belongs to the step that is FINISHING, and this line
        // starts the next one.
        root._settle.stop()
        root._pending = step
        root._settleFor = ""
        root._buf = ""
        root._proc.command = root._stepArgv[step]
        root._proc.running = false
        root._proc.running = true
        root._watchdog.restart()
    }

    function _standDown() {
        root._advance.stop()
        root._watchdog.stop()
        root._settle.stop()
        root._settleFor = ""
        root._queue = []
        if (root._pending !== "") {
            root._pending = ""
            root._proc.running = false
        }
    }

    onRefCountChanged: {
        if (root.refCount > 0) root._beginSweep(false)
        else                   root._standDown()
    }

    function _resolve(code, text) {
        const step = root._pending
        if (step === "") return          // a later signal for a consumed slot
        root._pending = ""
        root._watchdog.stop()
        root._settle.stop()
        root._settleFor = ""

        if (step === "unit")           root.unit = Fw.parseUnit(code, text)
        else if (step === "status")    root.status = Fw.parseStatus(code, text)
        else if (step === "catalogue") root.catalogue = Fw.parseCatalogue(code, text)

        root._advance.restart()
    }

    function _sweepDone() {
        root.checked = true
        if (root.refCount > 0) root._cooldown.restart()
    }

    property Process _proc: Process {
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._buf = this.text }
        onExited: function (code) { root._resolve(code, root._buf) }
        // The "never started" case: a binary that cannot exec emits neither
        // `exited` nor `streamFinished`, only `runningChanged` -> false. An
        // image with no `apex firewall` verb reaches the page through here.
        onRunningChanged: if (!running) {
            root._settleFor = root._pending
            root._settle.restart()
        }
    }

    // Tagged, so a fire is ignored unless the step that armed it is still the
    // pending one. Three steps share one process and one `_pending`; an
    // untagged settle armed by step N resolves step N+1 with empty output.
    property string _settleFor: ""
    property Timer _settle: Timer {
        interval: 150
        onTriggered: if (root._pending !== "" && root._pending === root._settleFor)
            root._resolve(null, "")
    }

    property Timer _watchdog: Timer {
        interval: root.queryTimeout
        onTriggered: if (root._pending !== "") root._proc.running = false
    }

    property Timer _advance: Timer {
        interval: root.stepDelay
        onTriggered: root._next()
    }

    property Timer _cooldown: Timer {
        interval: root.sweepInterval
        running: root.refCount > 0 && !root.busy
        repeat: true
        onTriggered: root._beginSweep(false)
    }
}
