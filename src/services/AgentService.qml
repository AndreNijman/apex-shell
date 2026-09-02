pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// ─── AgentService ─────────────────────────────────────────────────────────────
// The shell's view of the APEX agent runtime (roadmap §2, §3, §7).
//
// The runtime owns every PTY, sandbox and project. This service only reads it
// and asks it to do things, through the `apex` CLI — never by talking to the
// control socket itself. Two reasons: the CLI is a stability surface that
// already handles a daemon which is absent or a protocol version that does not
// match, and duplicating the socket protocol in QML would mean two things to
// keep in step every time it changes.
//
// WHAT THIS IS NOT
//
// Not a replacement for the terminal. §3 is explicit that the graphical Agent
// Center is "a supervisor and navigator, not a replacement for the terminal",
// so every action here ends at the real TUI: clicking a session focuses its
// terminal, and a notification's primary action does the same. There is no
// prompt box, no output rendering and no way to type at an agent from the
// shell, on purpose — a second, worse terminal is not the goal.
//
// POLLING
//
// The control protocol has no push channel, so this polls, at two rates: fast
// while something is looking (a held ServiceRef), slow otherwise. It never
// stops, because a notification has to arrive when nothing is on screen — that
// is the whole point of one.
// ──────────────────────────────────────────────────────────────────────────────

QtObject {
    id: root

    // ── What the runtime says ─────────────────────────────────────────────────
    property var sessions: []          // SessionInfo records, newest last
    property var requests: []          // pending privilege requests
    property bool daemonUp: false
    property bool everChecked: false   // false until the first poll returns

    readonly property int liveCount:
        sessions.filter(function(s) { return _isLive(s) }).length
    readonly property int attentionCount:
        sessions.filter(function(s) {
            return s.state === "waiting_for_user" || s.state === "permission_request"
        }).length + requests.length

    // ── Demand ────────────────────────────────────────────────────────────────
    // The shell's refcount convention: consumers declare
    //     ServiceRef { service: AgentService; active: root.onScreen }
    // and the service runs fast while at least one is held. `refCount` is the
    // name components/ServiceRef.qml expects — a service with its own
    // differently-named counter cannot be used with it, and a hand-rolled
    // counter at each call site is exactly the drift ServiceRef exists to stop.
    property int refCount: 0
    onRefCountChanged: if (refCount > 0) root.refresh()

    // Unlike most services this one never stops entirely. Notifications have to
    // arrive whether or not anything is on screen — "an agent finished while I
    // was in a browser" is the common case, not the edge one — so zero refs
    // means SLOW, not off. The cost at rest is one `apex agent list` and one
    // `apex request pending` every fifteen seconds.
    readonly property int _interval: refCount > 0 ? 2000 : 15000

    function refresh() {
        if (!_sessionProc.running) { _sessionBuf = ""; _sessionProc.running = true }
        if (!_requestProc.running) { _requestBuf = ""; _requestProc.running = true }
    }

    property string _sessionBuf: ""
    property string _requestBuf: ""

    property var _timer: Timer {
        interval: root._interval
        repeat:   true
        running:  true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    property var _sessionProc: Process {
        command: ["apex", "agent", "list", "--all", "--json"]
        running: false
        stdout: SplitParser { onRead: function(line) { root._sessionBuf += line } }
        onExited: function(code) {
            root.everChecked = true
            if (code !== 0) {
                // A non-zero exit is the daemon being absent, which is a normal
                // state (the runtime is opt-in). Keep the last known list
                // rather than blanking the page: a flicker to empty and back
                // reads as "my sessions were lost".
                root.daemonUp = false
                return
            }
            root.daemonUp = true
            try {
                var fresh = JSON.parse(root._sessionBuf)
                if (Array.isArray(fresh)) {
                    root._noticeChanges(fresh)
                    root.sessions = fresh
                    // Once, on the first successful poll. Makes the data path
                    // observable: without it a page that never polled looks
                    // exactly like a page with nothing to show, both in a bug
                    // report and to the smoke test.
                    if (!root._announced) {
                        root._announced = true
                        console.info("AgentService: runtime up,",
                                     fresh.length, "session(s)")
                    }
                }
            } catch (e) {
                // Malformed output is a bug, not a state. Say so once rather
                // than every two seconds.
                if (root._lastParseError !== String(e)) {
                    root._lastParseError = String(e)
                    console.warn("AgentService: cannot parse session list:", e)
                }
            }
        }
    }
    property string _lastParseError: ""
    property bool _announced: false

    property var _requestProc: Process {
        command: ["apex", "request", "pending", "--json"]
        running: false
        stdout: SplitParser { onRead: function(line) { root._requestBuf += line } }
        onExited: function(code) {
            if (code !== 0) return
            try {
                var fresh = JSON.parse(root._requestBuf)
                if (Array.isArray(fresh)) {
                    root._noticeRequests(fresh)
                    root.requests = fresh
                }
            } catch (e) { /* same reasoning as above */ }
        }
    }

    // ── Notifications ─────────────────────────────────────────────────────────
    // §3: "Notifications should take users back to the real TUI." Every one
    // therefore carries a Focus action that ends at the terminal.
    //
    // Fired on TRANSITIONS, not on state. Polling means the same state is seen
    // repeatedly, and a notification per poll is how a monitor gets muted — the
    // lesson from the modai watchdog, which re-fired a critical notification
    // every fifteen seconds because systemd kept restarting it after it exited
    // on "complete".
    property var _lastState: ({})   // session id -> last state seen
    property var _seenRequests: ({})

    function _noticeChanges(fresh) {
        var next = {}
        for (var i = 0; i < fresh.length; i++) {
            var s = fresh[i]
            next[s.id] = s.state
            var before = root._lastState[s.id]
            if (before === undefined) continue          // first sight, not a change
            if (before === s.state)   continue

            if (s.state === "waiting_for_user" || s.state === "permission_request") {
                root._notify(s, s.state === "permission_request"
                    ? "needs a permission decision"
                    : "is waiting for you", "critical")
            } else if (s.state === "complete") {
                root._notify(s, "finished", "normal")
            } else if (s.state === "failed") {
                root._notify(s, "failed", "critical")
            }
        }
        root._lastState = next
    }

    function _noticeRequests(fresh) {
        var next = {}
        for (var i = 0; i < fresh.length; i++) {
            var r = fresh[i]
            next[r.id] = true
            if (root._seenRequests[r.id]) continue
            root._notifyRequest(r)
        }
        root._seenRequests = next
    }

    property var _notifyProc: Process { command: []; running: false }

    function _notify(session, what, urgency) {
        var who = _agentLabel(session)
        var where = session.project_name || _basename(session.cwd)
        // --wait blocks until the notification is dismissed or an action is
        // chosen, and prints the chosen action id. That is why this runs
        // through `sh -c`: the action has to be dispatched after the wait
        // returns, and Process cannot express "then".
        _notifyProc.command = ["sh", "-c",
            'a=$(notify-send --app-name "APEX Agents" --wait ' +
            '--urgency ' + urgency + ' ' +
            '--action focus=Focus\\ terminal --action logs=View\\ output ' +
            _q(who + " " + what) + " " + _q(where) + ' 2>/dev/null); ' +
            'case "$a" in ' +
            '  focus) exec /usr/libexec/apex-agent-focus ' + session.id + ' ;; ' +
            '  logs)  exec /usr/libexec/apex-agent-focus ' + session.id + ' ;; ' +
            'esac']
        _notifyProc.running = true
    }

    function _notifyRequest(req) {
        // A privilege request cannot be approved from a notification, and that
        // is deliberate: approving performs the operation with the user's own
        // root, so it belongs in a terminal where the prompt and the sudo
        // authentication are visible. The action opens that terminal.
        var op = "apex " + (req.verb === "install" || req.verb === "remove"
            ? req.verb + " " + (req.packages || []).join(" ")
            : req.verb)
        _notifyProc.command = ["sh", "-c",
            'a=$(notify-send --app-name "APEX Agents" --wait --urgency critical ' +
            '--action review=Review ' +
            _q((req.agent || "An agent") + " requests privilege") + " " +
            _q(op + "\n" + (req.reason || "")) + ' 2>/dev/null); ' +
            '[ "$a" = review ] && exec /usr/libexec/apex-agent-review ' + req.id]
        _notifyProc.running = true
    }

    // Single-quote for `sh -c`. Embedded single quotes are closed, escaped and
    // reopened — the standard dance, spelled out because getting it wrong turns
    // an agent's own output into a shell injection.
    function _q(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'"
    }

    // ── Actions. All of them end at the runtime or the real terminal. ─────────
    property var _actionProc: Process { command: []; running: false }

    function focusTerminal(id) {
        _actionProc.command = ["/usr/libexec/apex-agent-focus", String(id)]
        _actionProc.running = true
    }
    function reviewRequest(id) {
        _actionProc.command = ["/usr/libexec/apex-agent-review", String(id)]
        _actionProc.running = true
    }
    function pause(id)  { _act(["apex", "agent", "pause",  String(id)]) }
    function resume(id) { _act(["apex", "agent", "resume", String(id)]) }
    function kill(id)   { _act(["apex", "agent", "kill",   String(id)]) }
    function _act(cmd) {
        _actionProc.command = cmd
        _actionProc.running = true
        // Reflect it without waiting for the next tick.
        root.refresh()
    }

    // ── Display helpers ───────────────────────────────────────────────────────
    function _isLive(s) {
        return s.exit_code === null && s.exit_signal === null
    }
    function _basename(p) {
        if (!p) return ""
        var parts = String(p).replace(/\/+$/, "").split("/")
        return parts[parts.length - 1] || p
    }
    function _agentLabel(s) {
        return (s.agent || "agent").charAt(0).toUpperCase() + (s.agent || "agent").slice(1)
    }

    readonly property var stateIcons: ({
        starting:           "󰚭",
        working:            "󰜎",
        waiting_for_user:   "󰅺",
        permission_request: "󰌾",
        complete:           "󰄬",
        failed:             "󰅚",
        exited:             "󰩈"
    })
    readonly property var stateLabels: ({
        starting:           "starting",
        working:            "working",
        waiting_for_user:   "waiting for you",
        permission_request: "needs permission",
        complete:           "complete",
        failed:             "failed",
        exited:             "exited"
    })

    function stateIcon(s)  { return root.stateIcons[s]  || "󰘦" }
    function stateLabel(s) { return root.stateLabels[s] || s }

    // Elapsed time, rendered the way a supervisor reads it: coarse and short.
    function elapsed(s) {
        if (!s || !s.started) return ""
        var end = _isLive(s) ? (Date.now() / 1000) : (s.last_activity || s.started)
        var secs = Math.max(0, Math.floor(end - s.started))
        if (secs < 60)   return secs + "s"
        if (secs < 3600) return Math.floor(secs / 60) + "m"
        var h = Math.floor(secs / 3600)
        var m = Math.floor((secs % 3600) / 60)
        return m > 0 ? h + "h " + m + "m" : h + "h"
    }
}
