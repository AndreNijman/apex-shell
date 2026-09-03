pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "recovery.js" as Rec

// ─── RecoveryService ─────────────────────────────────────────────────────────
// The data behind Config → Recovery (roadmap §19, and §25: "make recovery and
// rollback part of normal UX, not expert documentation").
//
// The OS side already exists and is deliberately shaped for this consumer.
// `apex recover status --json` reports the eight components §19 names, the
// four action buttons, the recovery routes and the reset scopes; `apex doctor
// --json` is §19's "expose `apex doctor` results graphically" from the other
// end. `apex recover --help` said the status was "safe for APEX Settings to
// poll" and this is the poller it meant — until now that consumer did not
// exist, and recovery had no graphical surface on any branch of this shell.
//
// Same rule as AgentService and RemoteAgentService: everything goes through
// the `apex` CLI. It is the stability surface that already handles an absent
// daemon and a version mismatch, and it owns the argv.
//
// ── WHAT THIS IS ALLOWED TO RUN, AND WHAT IT IS NOT ─────────────────────────
//
// Two verbs are polled and they are the only two that may ever be:
//
//   apex recover status --json     every fact is a file read — /proc/cmdline,
//                                  /proc/mounts, the efivars, the
//                                  /ostree/deploy listing. It spawns no
//                                  subprocess and contacts nothing, so it
//                                  cannot raise an authentication prompt and
//                                  cannot hang. docs/recovery.md asserts all
//                                  three on the OS side.
//   apex doctor --json             the same checks the text form prints, built
//                                  once and rendered twice. One D-Bus
//                                  connection and one 200 ms TCP connect to
//                                  127.0.0.1:9723; no subprocess.
//
// Everything else in `apex recover` — repair, reset — changes the machine and
// is therefore user-initiated ONLY, once, on an explicit press. There is no
// timer anywhere in this file that can reach them. `apex rollback` and
// `apex pin` need root and this shell raises no authentication prompt of its
// own, so they are SHOWN as commands and never executed: see below.
//
// ── EXIT 1 FROM `status` IS THE REPORT, NOT A FAILURE ───────────────────────
//
// `apex recover status` returns 1 when any component needs attention. A
// service that treated non-zero as failure would blank the panel on precisely
// the machines it is for. The decision is made on the parsed stdout;
// recovery.js's `parseStatus` is written around that and the node suite
// asserts it.
//
// ── ROLLBACK IS SHOWN, NOT RUN ──────────────────────────────────────────────
//
// §19 asks for a `[Boot previous deployment]` button and docs/recovery.md is
// explicit that the button's verb is `sudo apex rollback` — there is no second
// name for it. Running it from here would mean `pkexec` or a polkit agent, and
// the whole point of the status surface is that nothing it does needs
// authorising. So the panel makes rollback VISIBLE — whether a target exists,
// what it costs, the exact command, and the `sudo apex pin` advice that stops
// two bad updates evicting the last good image — which is what §25 asks for.
// Half of §25 is rollback not being expert documentation; a command a user can
// see, understand and copy from Settings is that, and a hidden pkexec is not.
//
// ── THE FACTORY RESET, AND WHY THE TOKEN IS THE WHOLE DESIGN ────────────────
//
// `apex recover reset --commit` requires `--confirm <scope>:<count>:<hash>`,
// where the hash covers the exact set of paths the plan found. The OS side
// built it that way SPECIFICALLY so a UI cannot commit a reset without having
// run the plan — and running the plan is the step that produces the loss list.
//
// This file honours that rather than working around it:
//
//   1. `planReset(scope)` runs the dry run. No `--commit`, ever.
//   2. The page renders every path the plan says exists.
//   3. The rendered list ACKNOWLEDGES itself — `acknowledgeLossList(token,
//      count)` — from the container that actually instantiated the rows.
//   4. `commitReset()` builds its argv through recovery.js's `commitArgv`,
//      which refuses unless the acknowledged token is the one this plan
//      printed AND the acknowledged row count equals both the plan's loss
//      count and the count encoded in the token itself.
//
// So the precondition is a rendered state, not a timer. MiscPage's two-click
// arm-for-2500ms idiom is right for "reset the sliders" and wrong here: a
// timer proves somebody clicked twice, and this needs "the loss list was on
// screen". The token is never constructed, never derived from the scope, and
// never carried across a close — `_standDown` drops the plan, so reopening the
// page re-plans from scratch and a machine that changed in between produces a
// different token, which is exactly the refusal apexd designed.
//
// ── PROCESS LIFETIME ────────────────────────────────────────────────────────
//
// Nothing runs while nobody is looking. `refCount` is the name
// components/ServiceRef.qml expects; the sweep timer only exists above zero,
// and demand dropping to zero kills the poll in flight rather than letting it
// finish. The one exception is a reset COMMIT, which is not a poll: it is a
// one-shot the user explicitly asked for, and killing it half-way would leave
// the state nobody planned that apexd's all-or-nothing safety pass exists to
// prevent. It is allowed to finish and reports when it does.
//
// The measured Quickshell 0.3.0 Process facts this file depends on are the
// five RemoteAgentService.qml documents — in particular that `streamFinished`
// precedes `exited`, that a binary which cannot exec emits NEITHER and only
// drops `running` to false, and that assigning `running = false` produces its
// own `exited(15)`. The one-shot slots below are what make each of those safe.
// ─────────────────────────────────────────────────────────────────────────────

Singleton {
    id: root

    // ── Demand ───────────────────────────────────────────────────────────────
    //     ServiceRef { service: RecoveryService; active: root.onScreen }
    property int refCount: 0

    // ── Tunables ─────────────────────────────────────────────────────────────
    // Between the end of one sweep and the start of the next, while watched.
    // Long, because nothing here changes without the user doing something: a
    // deployment appears after an update, Secure Boot after a firmware change.
    readonly property int sweepInterval: 20000
    // Smallest gap between sweep STARTS for anything that is not the Refresh
    // button. Tabbing away and back must not re-run both verbs each time.
    readonly property int minSweepGap: 4000
    // Neither polled verb can hang by construction, but "cannot hang" is a
    // property of the code as it is today and this outlives it.
    readonly property int queryTimeout: 15000
    // A plan stats every path under $HOME in its table. Still bounded.
    readonly property int planTimeout: 20000
    // A commit copies aside, removes, and re-runs the provisioner.
    readonly property int commitTimeout: 120000
    // One turn plus a pause between the two polled verbs, so a signal arriving
    // late from the first cannot be consumed by the second's slot.
    readonly property int stepDelay: 60

    // ── What the machine says ────────────────────────────────────────────────
    property var status: Rec.parseStatus(null, "")
    property var doctor: Rec.parseDoctor(null, "")

    // True once a sweep has returned at least once, whatever it said. Lets the
    // page distinguish "nothing to show" from "not asked yet", which look
    // identical and mean opposite things.
    property bool checked: false
    // True when `apex recover status` was actually readable. False on a
    // machine with no `apex`, or one whose `apex` predates `recover` — apex
    // 0.1.0 answers `unrecognized subcommand` and exits non-zero with nothing
    // on stdout, so the panel says the runtime is absent rather than drawing
    // eight empty rows.
    readonly property bool available: root.status.ok

    readonly property int needsAttention: root.status.ok ? root.status.needsAttention : 0

    readonly property string doctorSummary: Rec.doctorSummary(root.doctor)

    readonly property string rollbackCommand: Rec.ROLLBACK_COMMAND
    readonly property string pinCommand:      Rec.PIN_COMMAND
    readonly property string rollbackHint:    Rec.rollbackHint(root.status.rows)

    readonly property bool busy: root._pending !== "" || root._advance.running

    function stateLabel(s) { return Rec.stateLabel(s) }
    function stateTone(s)  { return Rec.stateTone(s) }
    function routeMark(a)  { return Rec.routeMark(a) }

    // Which glyph a component state gets. Same vocabulary as
    // RemoteAgentService.statusIcons, and every state in recovery.js has an
    // entry — a missing key renders as an empty box, which reads as a font
    // problem rather than as a missing case.
    readonly property var stateIcons: ({
        verified:    "󰄬",
        available:   "󰋗",
        attention:   "󰀪",
        unavailable: "󰇙"
    })
    function stateIcon(s) { return root.stateIcons[s] || "󰇙" }

    // ── The sweep: status, then doctor, then stop ────────────────────────────
    // "" | "status" | "doctor". A one-shot slot: the first signal to arrive for
    // a step consumes it and every later one is ignored, which is what makes a
    // watchdog kill safe — the SIGTERM's own `exited` finds the slot empty.
    property string _pending: ""
    // Steps left in this sweep. A QUEUE rather than "run doctor unless we
    // already have one": `doctor.ok` stays true after the first sweep, so a
    // have-we-got-one test would poll the status forever and the doctor
    // exactly once — a panel whose top half is live and whose bottom half
    // silently froze on the numbers it happened to start with.
    property var    _queue: []
    property string _buf: ""
    property real   _lastSweepStart: 0
    property bool   _announced: false

    // A person asking is not churn, so this alone bypasses the age clamp.
    function refresh() { root._beginSweep(true) }

    function _beginSweep(force) {
        if (root.refCount <= 0 && !force) return
        // `_advance.running` MUST be part of this guard. Between status
        // resolving and doctor starting there is a stepDelay gap in which
        // `_pending` is "" and the sweep is nonetheless still going; without
        // it, Refresh landing in that window starts a second sweep whose
        // status exit is consumed by the first sweep's doctor slot. That is
        // RemoteAgentService's wrong-data-on-the-wrong-host bug in a shorter
        // costume, and the fix is the same.
        if (root._pending !== "" || root._advance.running) return
        if (!force && (Date.now() - root._lastSweepStart) < root.minSweepGap) return

        root._lastSweepStart = Date.now()
        root._cooldown.stop()
        root._queue = ["status", "doctor"]
        root._next()
    }

    // The two polled verbs, in order, through ONE process — never two `apex`
    // invocations at once.
    readonly property var _stepArgv: ({
        status: ["apex", "recover", "status", "--json"],
        doctor: ["apex", "doctor", "--json"]
    })

    function _next() {
        if (root.refCount <= 0) { root._standDown(); return }
        if (root._queue.length === 0) { root._sweepDone(); return }

        const step = root._queue[0]
        root._queue = root._queue.slice(1)
        root._pending = step
        root._buf = ""
        root._proc.command = root._stepArgv[step]
        root._proc.running = false
        root._proc.running = true
        root._watchdog.restart()
    }

    // Stop everything that is a POLL, now. Called when the last ServiceRef is
    // handed back. The plan is dropped with it: a confirm token must never
    // survive the panel being closed, because the machine can change while
    // nobody is looking and a token that outlived its plan is the one thing
    // apexd's design is built to refuse.
    function _standDown() {
        root._cooldown.stop()
        root._advance.stop()
        root._watchdog.stop()
        root._queue = []
        if (root._pending !== "") {
            root._pending = ""
            root._proc.running = false
        }
        root._dropPlan()
    }

    onRefCountChanged: {
        if (root.refCount > 0) root._beginSweep(false)
        else                   root._standDown()
    }

    property Process _proc: Process {
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._buf = this.text }
        onExited: function (code) { root._resolve(code, root._buf) }
        // The "never started" case: a binary that cannot exec emits neither
        // `exited` nor `streamFinished`, only `runningChanged` -> false.
        // Guarded by the one-shot slot rather than by a timing assumption.
        onRunningChanged: if (!running) root._settle.restart()
    }

    property Timer _settle: Timer {
        interval: 150
        repeat: false
        onTriggered: if (root._pending !== "") root._resolve(null, "")
    }

    function _resolve(exitCode, text) {
        if (root._pending === "") return
        const step = root._pending
        root._pending = ""
        root._watchdog.stop()

        if (step === "status") {
            root.status = Rec.parseStatus(exitCode, text)
            // No `apex recover` on this machine means no `apex doctor --json`
            // either — both landed in the same release. Asking anyway would
            // cost a second failed exec per sweep to learn what the first one
            // already said.
            if (!root.status.ok) root._queue = []
        } else {
            root.doctor = Rec.parseDoctor(exitCode, text)
        }

        root.checked = true

        // Deferred rather than a direct call. A signal from the process just
        // finished with can still be in flight, and if the next step were
        // already pending it would be resolved by the previous one's exit code.
        root._advance.restart()
    }

    property Timer _advance: Timer {
        interval: root.stepDelay
        repeat: false
        onTriggered: root._next()
    }

    property Timer _watchdog: Timer {
        interval: root.queryTimeout
        repeat: false
        onTriggered: {
            if (root._pending === "") return
            root._pending = ""          // cleared BEFORE the kill, so the
            root._proc.running = false  // resulting exited() is ignored
            root._advance.restart()
        }
    }

    function _sweepDone() {
        // Only re-arm while somebody is still looking. This is the whole of
        // "no process runs when nobody is looking": there is no other place a
        // sweep starts.
        if (root.refCount > 0) root._cooldown.restart()

        if (!root._announced && root.checked) {
            root._announced = true
            console.info("RecoveryService:",
                         root.status.ok ? root.status.rows.length + " component row(s)"
                                        : "apex recover status unavailable",
                         "-", root.needsAttention, "needing attention;",
                         "doctor:", root.doctorSummary)
        }
    }

    property Timer _cooldown: Timer {
        interval: root.sweepInterval
        repeat: false
        onTriggered: root._beginSweep(false)
    }

    // ── Automatic repair ─────────────────────────────────────────────────────
    // §19's [Repair automatically]. Dry run first, always — apexd's own table
    // test asserts that no repair step's argv contains a destructive argument
    // or any of `sudo`, `pkexec`, `su`, `run0`, `systemd-run`, and that every
    // step is idempotent and removes no data. That invariant is what makes a
    // single button defensible, and it is also why committing one cannot raise
    // an authentication prompt.
    //
    // Repair converges only the privilege domain it is already running in and
    // REPORTS the other, exactly as `apex apply` does. The system-domain half
    // is shown as a command to run rather than executed, for the same reason
    // rollback is.
    //
    // "idle" | "checking" | "checked" | "repairing" | "failed"
    property string repairPhase: "idle"
    property var    repairSteps: []
    property string repairMessage: ""

    readonly property var repairHere:
        root.repairSteps.filter(function (s) { return s.runnableHere === true })
    readonly property var repairElsewhere:
        root.repairSteps.filter(function (s) { return s.runnableHere !== true })

    readonly property string repairSystemCommand: "sudo apex recover repair --commit"

    function checkRepairs() {
        if (root.repairPhase === "repairing") return
        root.repairPhase = "checking"
        root.repairMessage = ""
        root.repairSteps = []
        root._repairBuf = ""
        root._repairProc.command = ["apex", "recover", "repair", "--json"]
        root._repairProc.running = false
        root._repairProc.running = true
        root._repairWatchdog.restart()
    }

    // The commit. Reachable only from a press, never from a timer, and only
    // after a dry run found something for THIS domain to do — a button that
    // proposes work on every healthy machine is one people learn to ignore,
    // which is the reasoning apexd's `applicable_repairs` filter already
    // encodes.
    function runRepairs() {
        if (root.repairPhase !== "checked") return
        if (root.repairHere.length === 0) return
        root.repairPhase = "repairing"
        root.repairMessage = ""
        root._repairBuf = ""
        root._repairProc.command = ["apex", "recover", "repair", "--commit", "--json"]
        root._repairProc.running = false
        root._repairProc.running = true
        root._repairWatchdog.restart()
    }

    property string _repairBuf: ""

    property Process _repairProc: Process {
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._repairBuf = this.text }
        onExited: function (code) { root._onRepair(code, root._repairBuf) }
        onRunningChanged: if (!running) root._repairSettle.restart()
    }

    property Timer _repairSettle: Timer {
        interval: 150
        repeat: false
        onTriggered: if (root.repairPhase === "checking" || root.repairPhase === "repairing")
            root._onRepair(null, "")
    }

    property Timer _repairWatchdog: Timer {
        interval: root.planTimeout
        repeat: false
        onTriggered: {
            if (root.repairPhase !== "checking" && root.repairPhase !== "repairing") return
            root.repairPhase = "failed"
            root._repairProc.running = false
            root.repairMessage = "`apex recover repair` did not answer in time."
        }
    }

    function _onRepair(exitCode, text) {
        if (root.repairPhase !== "checking" && root.repairPhase !== "repairing") return
        const wasCommit = root.repairPhase === "repairing"
        root._repairWatchdog.stop()

        const doc = Rec.parseRepair(exitCode, text)
        if (!doc.ok) {
            root.repairPhase = "failed"
            root.repairSteps = []
            root.repairMessage = "Could not read a repair plan from `apex`."
            return
        }
        if (wasCommit) {
            // The list the commit echoed is the list it was ABOUT to run, so
            // keeping it on screen afterwards would show work already done as
            // work still outstanding. Cleared; the next press re-checks, and
            // the component rows are re-swept because they are what actually
            // answer "did it help".
            root.repairSteps = []
            root.repairPhase = "idle"
            root.repairMessage = (exitCode === 0)
                ? "Repair finished. Re-checking the components."
                : "Repair reported a problem — see `apex recover repair --commit` in a terminal for the detail."
            root.refresh()
            return
        }
        root.repairSteps = doc.steps
        root.repairPhase = "checked"
    }

    // ── The factory reset ────────────────────────────────────────────────────
    // "idle" | "planning" | "planned" | "committing" | "done" | "failed"
    property string resetPhase: "idle"
    // The parsed dry run, or null. Never populated by a timer.
    property var    plan: null
    property string resetMessage: ""

    // What the page has actually put on screen. Set by the loss list itself
    // (see acknowledgeLossList) and cleared by anything that invalidates it.
    property string _ackToken: ""
    property int    _ackCount: -1

    // True only when a commit could be built right now. The button binds to
    // this; recovery.js's commitArgv re-derives the same verdict at press
    // time, so the two would have to fail together for a reset to go out
    // unrendered.
    readonly property bool commitReady:
        root.resetPhase === "planned"
        && root.plan !== null
        && Rec.commitArgv(root.plan, root._ackCount, root._ackToken) !== null

    function _dropPlan() {
        // A commit in flight owns the plan; dropping it under the process
        // would leave nothing to report against when it exits.
        if (root.resetPhase === "committing") return
        root.plan = null
        root._ackToken = ""
        root._ackCount = -1
        root.resetPhase = "idle"
        root.resetMessage = ""
        root._planProc.running = false
        root._planWatchdog.stop()
    }

    function cancelReset() { root._dropPlan() }

    // The dry run. `planArgv` refuses any scope that is not one apexd has, and
    // there is no branch here that can append `--commit`.
    function planReset(scope) {
        if (root.resetPhase === "committing") return
        const argv = Rec.planArgv(scope)
        if (!argv) return

        root.plan = null
        root._ackToken = ""
        root._ackCount = -1
        root.resetMessage = ""
        root.resetPhase = "planning"
        root._planBuf = ""
        root._planProc.command = argv
        root._planProc.running = false
        root._planProc.running = true
        root._planWatchdog.restart()
    }

    property string _planBuf: ""

    property Process _planProc: Process {
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._planBuf = this.text }
        onExited: function (code) { root._onPlan(code, root._planBuf) }
        onRunningChanged: if (!running) root._planSettle.restart()
    }

    property Timer _planSettle: Timer {
        interval: 150
        repeat: false
        onTriggered: if (root.resetPhase === "planning") root._onPlan(null, "")
    }

    property Timer _planWatchdog: Timer {
        interval: root.planTimeout
        repeat: false
        onTriggered: {
            if (root.resetPhase !== "planning") return
            root.resetPhase = "failed"
            root._planProc.running = false
            root.resetMessage = "`apex recover reset` did not answer in time. Nothing has been changed."
        }
    }

    function _onPlan(exitCode, text) {
        if (root.resetPhase !== "planning") return
        root._planWatchdog.stop()

        const p = Rec.parseResetPlan(exitCode, text)
        if (!p.ok) {
            root.resetPhase = "failed"
            root.plan = null
            root.resetMessage = "Could not read a reset plan from `apex`. "
                + "Nothing has been changed, and nothing will be without one."
            return
        }
        root.plan = p
        root.resetPhase = "planned"
    }

    // Called by the container that instantiated the loss rows, with the token
    // the plan printed and the number of delegates the Repeater actually made.
    //
    // A count is used rather than a bare "I rendered it" flag on purpose: the
    // number is cross-checked against BOTH the plan's own loss count and the
    // count encoded in the token, so a list that rendered a subset — an
    // accidental `visible:` filter, a delegate that failed to build — cannot
    // acknowledge a token covering more paths than are on screen.
    function acknowledgeLossList(token, count) {
        if (root.resetPhase !== "planned") return
        if (!root.plan || token !== root.plan.confirmToken) return
        root._ackToken = token
        root._ackCount = count
    }

    // The list went away. Whatever was acknowledged is no longer on screen, so
    // it stops counting as evidence immediately.
    function revokeLossList() {
        root._ackToken = ""
        root._ackCount = -1
    }

    function commitReset() {
        if (root.resetPhase !== "planned") return
        const argv = Rec.commitArgv(root.plan, root._ackCount, root._ackToken)
        // Refused rather than repaired. Every reason commitArgv can return
        // null is a reason not to reset this machine: no plan, a token that is
        // not this plan's, or a rendered list that does not match the token's
        // own count.
        if (!argv) {
            root.resetPhase = "failed"
            root.resetMessage = "Refusing: the list of what would be lost is not the "
                + "one this confirmation covers. Plan it again."
            return
        }
        root.resetPhase = "committing"
        root.resetMessage = ""
        root._commitOut = ""
        root._commitErr = ""
        root._commitProc.command = argv
        root._commitProc.running = false
        root._commitProc.running = true
        root._commitWatchdog.restart()
    }

    property string _commitOut: ""
    property string _commitErr: ""

    property Process _commitProc: Process {
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._commitOut = this.text }
        stderr: StdioCollector { onStreamFinished: root._commitErr = this.text }
        onExited: function (code) { root._onCommit(code) }
        onRunningChanged: if (!running) root._commitSettle.restart()
    }

    property Timer _commitSettle: Timer {
        interval: 150
        repeat: false
        onTriggered: if (root.resetPhase === "committing") root._onCommit(null)
    }

    // Long, and it does NOT kill the process. A reset that was interrupted
    // half-way is the state apexd's all-or-nothing safety pass exists to
    // prevent, so the timeout reports rather than intervenes.
    property Timer _commitWatchdog: Timer {
        interval: root.commitTimeout
        repeat: false
        onTriggered: {
            if (root.resetPhase !== "committing") return
            root.resetMessage = "Still running. `apex recover reset` backs up before it "
                + "removes anything; leave it alone until it finishes."
        }
    }

    function _onCommit(exitCode) {
        if (root.resetPhase !== "committing") return
        root._commitWatchdog.stop()

        const r = Rec.readCommit(exitCode, root._commitOut, root._commitErr)
        // apexd's refusal names both tokens and says what to do. Carried
        // through verbatim: a generic "failed" throws away the only sentence
        // that explains it.
        root.resetMessage = r.message
        root.plan = null
        root._ackToken = ""
        root._ackCount = -1
        root.resetPhase = (r.result === Rec.COMMIT.OK) ? "done" : "failed"

        // The shell's own settings were part of what was removed, so the
        // status surface it renders is stale from here on.
        if (r.result === Rec.COMMIT.OK)
            root.refresh()
    }
}
