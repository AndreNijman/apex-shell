pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// ─────────────────────────────────────────────────────────────────────────────
// LockedHintService — tells logind the session is locked.
//
// APEX Shell locks the session itself, with ext-session-lock (WlSessionLock in
// windows/Lockscreen.qml), and never told logind about it: SetLockedHint was
// never called anywhere in the shell, so `loginctl show-session <id> -p
// LockedHint` read "no" on a session that had been locked for an hour — the
// same as one nobody had touched. Roadmap P0-015's lock-state policy for
// autonomous sessions (apex-os: apexd/apex-agent-core/src/lock.rs) reads
// exactly that property, and had nothing to read.
//
// This lives in the shell and not in apexd, on purpose: logind only accepts
// SetLockedHint from the process that owns the session, and apex-agentd
// cannot tell the shell apart from any other process running as the same
// user — including a managed agent session reaching its own control socket.
// Only the session owner can make this call and have it mean anything, so
// only the shell can make it. Do not add a socket verb for this.
//
// setLocked(bool) is meant to be driven by the session's ACTUAL lock state —
// WlSessionLock.secure in Lockscreen.qml, which only flips once the
// compositor has itself acknowledged the lock (or its release) — and not by
// the request to lock. A lock that fails to engage must never report itself
// to logind as engaged.
//
// Session target: the invoking user's graphical ("Display") session,
// resolved fresh via `loginctl show-user <user> -p Display --value` on every
// call rather than cached from $XDG_SESSION_ID or read once at startup — the
// shell can be started outside of a login session (e.g. under the agent
// runtime), where XDG_SESSION_ID is unset or names the wrong session. Display
// is the session the lock screen shows up on, whatever spawned the shell.
//
// All of it is best-effort. If a step fails — logind unreachable, no Display
// session, a stale object path — it is logged and dropped; the lock surface
// was already up (or down) before this ever runs, and never waits on it.
// ─────────────────────────────────────────────────────────────────────────────

Singleton {
    id: root

    // `_confirmed` is the value we believe logind currently holds (undefined
    // until the first successful call). `_desired` is the latest value asked
    // for. A call in flight only ever chases the value it was started with
    // (`_target`) — a second setLocked() while busy just updates `_desired`,
    // and _pump() picks it up when the current chain finishes, so a
    // lock/unlock/lock flicker coalesces into one trailing call instead of a
    // pile-up of them.
    property var _confirmed: undefined
    property var _desired:   undefined
    property var _target:    undefined
    property bool _busy:     false

    property string _sessionId:   ""
    property string _sessionPath: ""

    function setLocked(locked) {
        root._desired = locked
        root._pump()
    }

    function _pump() {
        if (root._busy) return
        if (root._desired === root._confirmed) return

        const user = Quickshell.env("USER")
        if (!user) {
            console.warn("LockedHintService: $USER is unset — cannot resolve a session, logind's LockedHint stays stale")
            return
        }

        root._busy   = true
        root._target = root._desired
        root._sessionId   = ""
        root._sessionPath = ""

        showUserProc.command = ["loginctl", "show-user", user, "-p", "Display", "--value"]
        showUserProc.running = false
        showUserProc.running = true
    }

    function _failed(where) {
        console.warn("LockedHintService: " + where + " failed — logind's LockedHint is now stale until the next lock/unlock")
        root._busy = false
        // Deliberately no retry here: a step that fails once (logind not
        // reachable, no graphical session yet) is likely to fail again
        // immediately, and retrying inline is exactly the call storm the
        // idempotence guard above exists to avoid. The next real lock/unlock
        // calls setLocked() again on its own.
    }

    function _succeeded() {
        root._confirmed = root._target
        root._busy = false
        root._pump() // pick up whatever setLocked() asked for while we were busy
    }

    // ── Step 1: resolve the graphical (Display) session id ────────────────
    readonly property Process showUserProc: Process {
        command: []
        running: false
        stdout: SplitParser {
            onRead: function (line) {
                const id = line.trim()
                if (id !== "")
                    root._sessionId = id
            }
        }
        onExited: function (exitCode, exitStatus) {
            if (exitCode !== 0 || root._sessionId === "") {
                root._failed("loginctl show-user")
                return
            }
            root.getSessionProc.command = [
                "busctl", "--system", "call", "org.freedesktop.login1",
                "/org/freedesktop/login1", "org.freedesktop.login1.Manager",
                "GetSession", "s", root._sessionId
            ]
            root.getSessionProc.running = false
            root.getSessionProc.running = true
        }
    }

    // ── Step 2: resolve the session's object path ──────────────────────────
    // Asked of logind rather than built by hand: the object path is NOT
    // `.../session/<id>` — logind escapes it (session "3" on this machine is
    // `/org/freedesktop/login1/session/_33`, confirmed live), and getting
    // that escaping wrong here would be silent — busctl would just fail the
    // next call and this would look identical to logind being unreachable.
    readonly property Process getSessionProc: Process {
        command: []
        running: false
        stdout: SplitParser {
            onRead: function (line) {
                // busctl prints: o "/org/freedesktop/login1/session/_32"
                const m = line.match(/"([^"]+)"/)
                if (m)
                    root._sessionPath = m[1]
            }
        }
        onExited: function (exitCode, exitStatus) {
            if (exitCode !== 0 || root._sessionPath === "") {
                root._failed("busctl GetSession")
                return
            }
            root.setHintProc.command = [
                "busctl", "--system", "call", "org.freedesktop.login1",
                root._sessionPath, "org.freedesktop.login1.Session",
                "SetLockedHint", "b", root._target ? "true" : "false"
            ]
            root.setHintProc.running = false
            root.setHintProc.running = true
        }
    }

    // ── Step 3: the actual hint ─────────────────────────────────────────────
    readonly property Process setHintProc: Process {
        command: []
        running: false
        onExited: function (exitCode, exitStatus) {
            if (exitCode !== 0)
                root._failed("busctl SetLockedHint")
            else
                root._succeeded()
        }
    }
}
