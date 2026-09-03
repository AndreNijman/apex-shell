pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "remoteagents.js" as Remote

// ─── RemoteAgentService ───────────────────────────────────────────────────────
// What agents are running on the user's trusted remote devices (roadmap §20,
// P2 phase 9.3).
//
// The OS side already exists. `apex host list --json` enumerates the registered
// devices and their cached capability probe; `apex host run <name> -- <argv…>`
// runs a command on one with its argument boundaries intact. So remote agent
// status is: read the registry, and for each device a probe has actually shown
// to have the agent runtime, run `apex agent list --all --json` over there.
//
// Same rule as AgentService: everything goes through the `apex` CLI. It is the
// stability surface that already handles an absent daemon and a version
// mismatch, and it owns the ssh argv — including the `--` before the
// destination and the per-argument quoting of the remote command, both of which
// are places an injection would land if this file built the ssh line itself.
//
// ── EVERY QUERY IS AN SSH CONNECTION TO ANOTHER MACHINE ─────────────────────
//
// That is the single fact this file is shaped around, and it makes this service
// differ from AgentService in the one place they look alike.
//
// AgentService never stops polling; with no refs it slows to 15 s rather than
// stopping, because a notification about a local agent has to arrive when
// nothing is on screen. That reasoning does not transfer. There is no
// notification here — see below — and the cost is not a local `fork`, it is a
// TCP connection, a key exchange and a login on a machine somewhere else. A bar
// widget that opened an ssh connection every few seconds forever would be a
// defect, so idle here is genuinely ZERO connections:
//
//   * the sweep timer only exists while refCount > 0;
//   * demand dropping to zero kills the query in flight rather than letting it
//     finish, so "closed the dashboard" means "no ssh from this shell";
//   * nothing is queried on a timer at rest, at any interval.
//
// ── refCount CHURN IS THE HOLE THAT WOULD REOPEN IT ─────────────────────────
//
// AgentService refreshes on every `refCount > 0` transition. Copied here, that
// makes tabbing Home → Agents → Home → Agents open an ssh connection per
// toggle, which is the same defect arrived at from a different direction. So a
// sweep is also debounced on `minSweepGap` since the last one STARTED, and the
// explicit Refresh button is the only caller that bypasses the age check —
// because a person asking is not churn.
//
// ── ONE CONNECTION AT A TIME ────────────────────────────────────────────────
//
// The hosts are walked serially: at most one ssh process exists at any instant.
// A parallel fan-out would show a slow host's neighbours sooner, at the cost of
// N simultaneous connections and N dynamically created Process objects. Serial
// is a property that can be stated and checked ("never more than one"), and
// each host's result publishes the moment it lands, so the first device appears
// immediately either way. The cost is that a dead host delays the ones behind
// it by its own timeout; that is bounded and it is the honest trade.
//
// ── AN UNREACHABLE HOST IS A NORMAL STATE ───────────────────────────────────
//
// A laptop is off the LAN most of the time. So: no notification, no toast, no
// console.warn per sweep, and one dead host never stops the others being shown.
// `apex host` already passes BatchMode=yes and ConnectTimeout=8 so a dead host
// fails instead of prompting — but that bounds only the CONNECT. A host that
// completes TCP and then stalls (an auth stall, a wedged remote agentd socket)
// has no timeout anywhere in the chain, which is what _watchdog is for.
//
// ── WHAT THIS DELIBERATELY DOES NOT DO ──────────────────────────────────────
//
// It does not act on a remote session. A session id is only meaningful on the
// host that issued it, so a Pause button here would hand a foreign id to the
// LOCAL daemon and stop an unrelated agent — see RemoteSessionRow.qml, which is
// read-only for exactly that reason. Attaching means a terminal on the far side
// of an ssh; §3 is explicit that this page is a supervisor and a navigator, so
// the section prints the `apex host run -t …` line instead of growing a worse
// terminal.
//
// It also raises no notifications. AgentService's exist so that "an agent
// finished while I was in a browser" reaches the user, and they can only do
// that because it keeps polling at rest. Notifying about remote agents would
// require exactly the idle ssh traffic this file refuses.
//
// ── MEASURED Process BEHAVIOUR THIS FILE DEPENDS ON ─────────────────────────
//
// Five facts, measured on the Quickshell in this checkout (0.3.0) rather than
// assumed, because each one has a plausible opposite that would break a
// different part of the state machine:
//
//   1. StdioCollector's `streamFinished` fires BEFORE `exited`. So reading the
//      collected text inside `onExited` is safe and the two do not need to be
//      joined. (Quickshell's own docs warn the other way round; on 0.3.0 it is
//      this way, and the `_watchdog` covers us if a future version is not.)
//   2. `streamFinished` fires even when the process produced no output at all,
//      so a silent failure still lands in the same handler.
//   3. StdioCollector.text is RESET between runs of the same Process — it does
//      not accumulate. Measured: AAAA / BB / BB across three runs, not
//      AAAA / AAAABB. That is what makes reusing one Process for every host
//      safe.
//   4. Killing a process by assigning `running = false` DOES emit
//      streamFinished and then exited, with exitCode 15 (SIGTERM) and
//      exitStatus 1. That is why `_watchdog` clears `_pending` *before* the
//      kill: the resulting exit must land on an already-consumed slot.
//   5. A binary that cannot exec emits NEITHER exited NOR streamFinished, only
//      `runningChanged` → false. That is the wedge `_listSettle` exists for.
// ──────────────────────────────────────────────────────────────────────────────

Singleton {
    id: root

    // ── Demand ────────────────────────────────────────────────────────────────
    //     ServiceRef { service: RemoteAgentService; active: root.onScreen }
    // `refCount` is the name components/ServiceRef.qml expects.
    property int refCount: 0

    // ── Tunables, all named so the CI check can point at them ────────────────
    // Between the end of one sweep and the start of the next, while watched.
    readonly property int sweepInterval: 15000
    // Smallest gap between sweep STARTS, for anything that is not the Refresh
    // button. This is the anti-churn clamp.
    readonly property int minSweepGap: 5000
    // How long one host gets before it is abandoned. ConnectTimeout=8 bounds
    // the connect; this bounds everything after it.
    readonly property int queryTimeout: 20000
    // A short pause between hosts, so that a signal arriving late from the
    // process we just finished with cannot be mistaken for the next host's.
    // See _advance.
    readonly property int stepDelay: 60

    // ── What the registry says ────────────────────────────────────────────────
    // Normalised host records: { name, ssh, port, note, probed, caps, agentd }.
    // `caps` always has every key; see remoteagents.js.
    property var hosts: []
    // True once `apex host list` has returned at least once, whatever it said.
    property bool registryChecked: false
    // True when that return was actually readable. A machine with no `apex` at
    // all lands here as false with an empty host list, which renders as nothing
    // — the Agent Center already tells the user the runtime is absent.
    //
    // The same is true of a machine whose installed `apex` predates `apex host`:
    // apex 0.1.0, which is what is on this developer's box today, answers
    // `unrecognized subcommand 'host'` and exits non-zero. Verified. So on a
    // current install the remote section simply does not appear, which is the
    // correct behaviour and worth knowing before concluding it is broken.
    property bool registryReadable: false

    // name -> { status, sessions, checkedAt }. Reassigned wholesale on every
    // change: mutating a property of a `var` object emits no change signal, so
    // a view bound to it would never update.
    property var results: ({})

    function resultFor(name) {
        const r = root.results[name]
        return r ? r : { status: Remote.STATUS.UNKNOWN, sessions: [], checkedAt: 0 }
    }

    function statusFor(name) {
        const r = root.results[name]
        if (r) return r.status
        for (let i = 0; i < root.hosts.length; i++)
            if (root.hosts[i].name === name)
                return Remote.restingStatus(root.hosts[i])
        return Remote.STATUS.UNKNOWN
    }

    readonly property var overview: Remote.overview(root.hosts, root.results)

    // The section heading's suffix. Counts what is running, never what is down:
    // a heading that counts dead laptops is a heading that nags.
    readonly property string overviewLabel: Remote.overviewLabel(root.overview)

    // True while any part of a sweep is in flight — drives the spinner on the
    // Refresh button and nothing else.
    //
    // `_advance.running` is in here for the same reason it is in _beginSweep's
    // guard: between one host resolving and the next one starting, both slots
    // are empty and the sweep is nonetheless still going. Without it the
    // spinner blinks off once per host.
    readonly property bool busy: root._listPending || root._pending !== ""
                                 || root._advance.running

    // ── The sweep ─────────────────────────────────────────────────────────────
    property var    _queue: []          // host names left in this sweep
    property string _pending: ""        // the host whose ssh is in flight, or ""
    property string _buf: ""
    property bool   _listPending: false // one-shot slot for the registry read
    property real   _lastSweepStart: 0
    property bool   _announced: false

    // Ask now, regardless of how recently the last sweep ran. The Refresh
    // button, and nothing else: a person asking is not churn.
    function refresh() { root._beginSweep(true) }

    function _beginSweep(force) {
        if (root.refCount <= 0 && !force) return

        // Something is already in flight. Never two sweeps at once — that is
        // how one dead host turns into two connections per host.
        //
        // `_advance.running` MUST be part of this. Between one host resolving
        // and the next one starting there is a 60 ms gap in which `_pending` is
        // "" and `_listPending` is false, so without it the guard reads "idle"
        // while the sweep is very much still walking the queue. `refresh()`
        // forces past the age clamp, so clicking Refresh while the page is
        // checking landed exactly there, and the result was not two harmless
        // sweeps — it was WRONG DATA ON THE WRONG HOST:
        //
        //   1. _advance fires, _next() starts the laptop's query
        //   2. the second sweep's registry read returns, resets the queue and
        //      calls _next(), which restarts _queryProc — killing the laptop
        //      query — with _pending now "katana"
        //   3. the kill's own exited(15) arrives, _resolve consumes the katana
        //      slot with the LAPTOP query's exit code, and katana is recorded
        //      as having no runtime
        //
        // Which is the shared-settle-timer bug from CompositorService in a new
        // costume: one process's signal delivered to another's slot. The
        // one-shot slot stops a LATE signal; it cannot stop a slot that has
        // been legitimately refilled in between, so the sweep has to be
        // recognised as in-flight for its whole duration and not just while a
        // process is running.
        if (root._listPending || root._pending !== "" || root._advance.running)
            return
        if (!force && (Date.now() - root._lastSweepStart) < root.minSweepGap)
            return

        root._lastSweepStart = Date.now()
        root._cooldown.stop()
        root._listPending = true
        root._buf = ""
        root._listBuf = ""
        root._listProc.running = false
        root._listProc.running = true
    }

    // Stop everything, now. Called when the last ServiceRef is handed back.
    //
    // The in-flight ssh is KILLED rather than allowed to finish. It would only
    // take a few more seconds, but "the shell holds no ssh connection while
    // nobody is looking" is a property worth being literally true, and the host
    // it abandons goes back to "not checked yet" rather than being recorded as
    // unreachable — we stopped asking, we did not learn anything.
    function _standDown() {
        root._cooldown.stop()
        root._advance.stop()
        root._watchdog.stop()
        root._queue = []
        if (root._pending !== "") {
            const abandoned = root._pending
            root._pending = ""
            root._queryProc.running = false
            root._setStatus(abandoned, Remote.STATUS.UNKNOWN, [])
        }
        if (root._listPending) {
            root._listPending = false
            root._listProc.running = false
        }
    }

    onRefCountChanged: {
        if (root.refCount > 0) root._beginSweep(false)
        else                   root._standDown()
    }

    // ── 1. The registry. Local, cheap, no ssh. ────────────────────────────────
    // This runs first in every sweep, which also makes it the place a missing
    // `apex` is detected. Quickshell reports a binary that cannot exec by
    // dropping `running` back to false with no exit code and no stream — so the
    // per-host query below needs no such guard, because by the time it runs the
    // same binary has demonstrably started once.
    property string _listBuf: ""

    property Process _listProc: Process {
        command: ["apex", "host", "list", "--json"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: root._listBuf = this.text
        }
        onExited: function (code) {
            root._onRegistry(code === 0, root._listBuf)
        }
        // The "never started" case. Guarded by the one-shot `_listPending` slot
        // rather than by a timing assumption, the way CompositorService guards
        // its display/input helpers: a late fire finds the slot already cleared
        // and does nothing.
        onRunningChanged: if (!running) root._listSettle.restart()
    }

    property Timer _listSettle: Timer {
        interval: 150
        repeat: false
        onTriggered: if (root._listPending) root._onRegistry(false, "")
    }

    function _onRegistry(exitedOk, text) {
        if (!root._listPending) return
        root._listPending = false
        root.registryChecked = true

        const parsed = Remote.parseHostList(exitedOk ? text : "")
        root.registryReadable = exitedOk && parsed.ok
        root.hosts = parsed.hosts

        // Drop results for hosts that are no longer registered, so a removed
        // device cannot leave a row behind.
        const keep = {}
        for (let i = 0; i < parsed.hosts.length; i++) {
            const n = parsed.hosts[i].name
            if (root.results[n]) keep[n] = root.results[n]
        }
        root.results = keep

        root._queue = Remote.queryTargets(parsed.hosts)
        // Say "checking…" before the first ssh, not "unreachable". Claiming a
        // host is down before having asked is a lie that reads as a bug.
        for (let q = 0; q < root._queue.length; q++)
            root._setStatus(root._queue[q], Remote.STATUS.QUERYING, [])

        root._next()
    }

    // ── 2. One host at a time ─────────────────────────────────────────────────
    property Process _queryProc: Process {
        command: []
        running: false
        stdout: StdioCollector {
            onStreamFinished: root._buf = this.text
        }
        onExited: function (code) {
            root._resolve(code, root._buf)
        }
    }

    function _next() {
        if (root.refCount <= 0) { root._standDown(); return }
        if (root._queue.length === 0) { root._sweepDone(); return }

        const name = root._queue[0]
        root._queue = root._queue.slice(1)
        root._pending = name
        root._buf = ""

        // The argv is built here and quoted by `apex host run`, which is the
        // only reason a host name or a path with a space in it is safe. Nothing
        // in this file interpolates a model value into a shell string.
        root._queryProc.command = ["apex", "host", "run", name,
                                   "--", "apex", "agent", "list", "--all", "--json"]
        root._queryProc.running = false
        root._queryProc.running = true
        root._watchdog.restart()
    }

    // `_pending` is a one-shot slot, exactly like `_listPending`: the first
    // signal to arrive for this host consumes it and every later one is
    // ignored. That is what makes a watchdog kill safe — the SIGTERM's own
    // `exited` finds the slot already empty.
    function _resolve(exitCode, text) {
        if (root._pending === "") return
        const name = root._pending
        root._pending = ""
        root._watchdog.stop()

        const read = Remote.readSessions(exitCode, text)
        root._setStatus(name, read.status, read.sessions)

        // Deferred rather than a direct _next(). A signal from the process we
        // have just finished with can still be in flight, and if the next host
        // were already pending it would be resolved by the previous host's exit
        // code. One turn of the event loop plus stepDelay closes that window,
        // and it is the same class of bug as CompositorService's shared settle
        // timer settling the wrong callback.
        root._advance.restart()
    }

    property Timer _advance: Timer {
        interval: root.stepDelay
        repeat: false
        onTriggered: root._next()
    }

    // ConnectTimeout=8 bounds getting there. Nothing bounds what happens after,
    // so this does: the query is killed and the host reads as unreachable,
    // which is the truth — we could not get an answer out of it.
    property Timer _watchdog: Timer {
        interval: root.queryTimeout
        repeat: false
        onTriggered: {
            if (root._pending === "") return
            const name = root._pending
            root._pending = ""          // cleared BEFORE the kill, so the
            root._queryProc.running = false   // resulting exited() is ignored
            root._setStatus(name, Remote.STATUS.UNREACHABLE, [])
            root._advance.restart()
        }
    }

    function _setStatus(name, status, sessions) {
        const next = {}
        const keys = Object.keys(root.results)
        for (let i = 0; i < keys.length; i++) next[keys[i]] = root.results[keys[i]]
        next[name] = {
            status: status,
            sessions: sessions || [],
            checkedAt: Math.floor(Date.now() / 1000)
        }
        root.results = next
    }

    function _sweepDone() {
        // Only re-arm while somebody is still looking. This is the whole of
        // "idle is zero connections": there is no other place a sweep starts.
        if (root.refCount > 0) root._cooldown.restart()

        // Once per shell run. Makes the data path observable — a section that
        // never queried anything looks exactly like a section with nothing to
        // show, both in a bug report and to the smoke test.
        if (!root._announced && root.registryChecked) {
            root._announced = true
            const o = root.overview
            console.info("RemoteAgentService:", o.hosts, "host(s),",
                         o.withRuntime, "with the agent runtime,",
                         o.reachable, "reachable,",
                         o.sessions, "remote session(s)")
        }
    }

    property Timer _cooldown: Timer {
        interval: root.sweepInterval
        repeat: false
        onTriggered: root._beginSweep(false)
    }

    // ── Display helpers, so the rows hold no logic ────────────────────────────
    function summaryFor(host) {
        return Remote.hostSummary(host, root.resultFor(host.name),
                                  Math.floor(Date.now() / 1000))
    }
    function sessionsFor(name) {
        return Remote.visibleSessions(root.resultFor(name).sessions)
    }
    function attachCommand(name, id) { return Remote.attachCommand(name, id) }

    // Which glyph a host's status gets. Same vocabulary as AgentService's
    // stateIcons, and every status in remoteagents.js has an entry — a missing
    // key here would render as an empty box, which reads as a font problem
    // rather than as a missing case.
    readonly property var statusIcons: ({
        not_probed:  "󰋗",
        no_agentd:   "󰅘",
        unknown:     "󰇙",
        querying:    "󰑖",
        ok:          "󰄬",
        unreachable: "󰅛",
        no_apex:     "󰋗",
        no_runtime:  "󰒲",
        unreadable:  "󰀪"
    })
    function statusIcon(s) { return root.statusIcons[s] || "󰇙" }
    function statusLabel(s) { return Remote.statusLabel(s) }
}
