import Quickshell
import Quickshell.Io
import QtQuick
import "./src/services"
import "./src/state"
import "./src/windows"

// LockedHintService and the Lockscreen line that drives it, run for real
// (P0-015, ROADMAP.md §7).
//
// Run through tests/run-locked-hint-test.sh, which stages this at the repo
// root, puts a FAKE loginctl and a FAKE busctl first on PATH, and hosts it on
// a headless wlroots compositor in a private XDG_RUNTIME_DIR. Nothing here
// touches the developer's logind session, and the only session lock it can
// engage is the nested compositor's.
//
// ── WHAT ONLY A LIVE RUN CAN ANSWER ─────────────────────────────────────────
//
// The service is a four-step asynchronous chain — resolve the graphical
// session, resolve its object path, set the property, then pump whatever was
// asked for while it was busy — with an idempotence guard and a coalescing
// rule. Reading the source can show the shape of that. It cannot show:
//
//   1. that the chain runs at all. Every step is a Process whose `onExited`
//      starts the next one, and a typo in a command or a property name is a
//      chain that stops silently.
//   2. the ORDER and the exact argv of the three calls, which is the whole
//      contract with logind.
//   3. that a lock/unlock/lock flicker produces ONE trailing call rather than
//      three overlapping ones.
//   4. that a failure at any of the three steps stops the chain, leaves
//      nothing running, and does not retry.
//   5. that the shell tells logind anything AT ALL at startup. That one is the
//      defect this run exists for: `onSecureStateChanged` fires on a change,
//      so a shell restarted while logind believed the session locked left the
//      hint reading `yes` for as long as nobody locked the screen by hand.
//   6. that `WlSessionLock.secure` really does flip, and really does reach the
//      service, on a compositor that has acknowledged an ext-session-lock.
//
// ── THE FAKES ARE THE TWO TOOLS, NOT THE SERVICE ────────────────────────────
//
// The file under test is the shipped src/services/system/LockedHintService.qml
// and the shipped src/windows/Lockscreen.qml. Only `loginctl` and `busctl` are
// stubs, and they record their argv, so every assertion below is about what
// the shell would have said to logind.

ShellRoot {
    id: rootScope

    property int pass: 0
    property int fail: 0
    // How many log lines have already been accounted for.
    property int consumed: 0
    property var lines: []
    property string logPath: Quickshell.env("HINT_LOG")
    property string ctlPath: Quickshell.env("HINT_CTL")

    function ok(what)  { console.log("  PASS  " + what); rootScope.pass++ }
    function bad(what) { console.log("  FAIL  " + what); rootScope.fail++ }
    function check(what, cond) { if (cond) rootScope.ok(what); else rootScope.bad(what) }

    // ── the shipped lock screen, instantiated exactly as shell.qml does ─────
    // Its Component.onCompleted is the initial sync, and it runs before any
    // step below — which is why phase 0 asserts on what is already in the log.
    Lockscreen { id: lock }

    // ── reading the fakes' log ─────────────────────────────────────────────
    // `cat` through a Process rather than a FileView: the file is appended to
    // by other processes while this one is running, and a cached read that
    // returned yesterday's bytes would be indistinguishable from a chain that
    // did not run.
    property var afterRead: null
    readonly property Process catProc: Process {
        command: []
        running: false
        stdout: SplitParser {
            onRead: function (line) {
                if (line.length > 0)
                    rootScope.lines = rootScope.lines.concat([line])
            }
        }
        onExited: function () {
            const f = rootScope.afterRead
            rootScope.afterRead = null
            if (f) f()
        }
    }

    function readLog(then) {
        rootScope.lines = []
        rootScope.afterRead = then
        catProc.command = ["cat", rootScope.logPath]
        catProc.running = false
        catProc.running = true
    }

    // Lines written since the last checkpoint.
    function fresh() {
        return rootScope.lines.slice(rootScope.consumed)
    }
    function keep() {
        rootScope.consumed = rootScope.lines.length
    }

    // ── the stubs' failure mode ────────────────────────────────────────────
    property var afterCtl: null
    readonly property Process ctlProc: Process {
        command: []
        running: false
        onExited: function () {
            const f = rootScope.afterCtl
            rootScope.afterCtl = null
            if (f) f()
        }
    }
    function setMode(mode, then) {
        rootScope.afterCtl = then
        ctlProc.command = ["sh", "-c", "printf '%s' \"$1\" > \"$2\"", "sh", mode, rootScope.ctlPath]
        ctlProc.running = false
        ctlProc.running = true
    }

    // ── waiting ────────────────────────────────────────────────────────────
    // Settled means the service is not mid-chain. Bounded, because a chain
    // that never finishes is exactly the defect this run is looking for and
    // must be reported rather than waited on forever.
    property var afterSettle: null
    readonly property Timer settleTimer: Timer {
        interval: 40
        repeat: true
        property int tries: 0
        onTriggered: {
            tries++
            if (!LockedHintService._busy || tries > 150) {
                stop()
                tries = 0
                const f = rootScope.afterSettle
                rootScope.afterSettle = null
                if (f) f()
            }
        }
    }
    function settle(then) {
        rootScope.afterSettle = then
        settleTimer.tries = 0
        settleTimer.restart()
    }

    property var afterPause: null
    readonly property Timer pauseTimer: Timer {
        interval: 500
        repeat: false
        onTriggered: {
            const f = rootScope.afterPause
            rootScope.afterPause = null
            if (f) f()
        }
    }
    function pause(ms, then) {
        rootScope.afterPause = then
        pauseTimer.interval = ms
        pauseTimer.restart()
    }

    // ── assertions over a chain ────────────────────────────────────────────
    function isShowUser(l)  { return l.indexOf("loginctl show-user") === 0 && l.indexOf("-p Display --value") >= 0 }
    function isGetSession(l){ return l.indexOf("busctl") === 0 && l.indexOf("GetSession") >= 0 }
    function isSetHint(l)   { return l.indexOf("busctl") === 0 && l.indexOf("SetLockedHint") >= 0 }

    function expectChain(what, got, value) {
        if (got.length !== 3) {
            rootScope.bad(what + " — expected three calls, got " + got.length + ": " + JSON.stringify(got))
            return
        }
        rootScope.check(what + ": step 1 asks logind which session is the graphical one", isShowUser(got[0]))
        rootScope.check(what + ": step 2 asks logind for the object path", isGetSession(got[1]))
        rootScope.check(what + ": step 3 sets the hint to " + value,
                        isSetHint(got[2]) && got[2].indexOf("b " + value) >= 0)
    }

    // ── the run ────────────────────────────────────────────────────────────

    Component.onCompleted: settle(phase0)

    // Phase 0 — the initial sync. Nothing below has called setLocked yet; the
    // only thing that can have written to the log is Lockscreen's own
    // Component.onCompleted.
    function phase0() {
        readLog(function () {
            const got = rootScope.fresh()
            rootScope.check("the shell tells logind something at startup without being locked first",
                            got.length > 0)
            rootScope.expectChain("the initial sync", got, "false")
            if (got.length === 3) {
                // The escaping claim: logind's object path for session "3" is
                // /org/freedesktop/login1/session/_33, and building it by hand
                // would fail silently — busctl would just refuse the next call.
                rootScope.check("the object path came from logind rather than being built by hand",
                                got[2].indexOf("/org/freedesktop/login1/session/_33") >= 0)
                rootScope.check("the hint is set on the session, not on the manager",
                                got[2].indexOf("org.freedesktop.login1.Session") >= 0)
            }
            rootScope.keep()
            phase1()
        })
    }

    // Phase 1 — a lock is mirrored.
    function phase1() {
        LockedHintService.setLocked(true)
        settle(function () {
            readLog(function () {
                rootScope.expectChain("a lock reaches logind", rootScope.fresh(), "true")
                rootScope.keep()
                phase2()
            })
        })
    }

    // Phase 2 — asking for the value logind already holds does nothing.
    function phase2() {
        LockedHintService.setLocked(true)
        settle(function () {
            pause(300, function () {
                readLog(function () {
                    rootScope.check("setting the hint to the value it already has costs no calls",
                                    rootScope.fresh().length === 0)
                    rootScope.keep()
                    phase3()
                })
            })
        })
    }

    // Phase 3 — a lock/unlock/lock flicker coalesces into one trailing call.
    //
    // The stub's first step sleeps, so the second and third flips genuinely
    // arrive mid-chain rather than in the same JavaScript tick. That is what
    // makes the in-flight guard observable at all: without it each flip
    // restarts the chain from step one, and step one runs three times.
    function phase3() {
        setMode("slow", function () {
            LockedHintService.setLocked(false)
            pause(120, function () {
                LockedHintService.setLocked(true)
                pause(120, function () {
                    LockedHintService.setLocked(false)
                    settle(function () {
                        pause(900, function () {
                            setMode("ok", function () {
                                readLog(function () {
                                    const got = rootScope.fresh()
                                    rootScope.check(
                                        "three flips during one in-flight call make one chain, not three",
                                        got.length === 3)
                                    if (got.length >= 1)
                                        rootScope.check(
                                            "the step already running was not restarted underneath itself",
                                            got.filter(isShowUser).length === 1)
                                    if (got.length >= 3)
                                        rootScope.check(
                                            "and the value that lands is the last one asked for",
                                            isSetHint(got[got.length - 1])
                                            && got[got.length - 1].indexOf("b false") >= 0)
                                    rootScope.keep()
                                    phase4()
                                })
                            })
                        })
                    })
                })
            })
        })
    }

    // Phase 4 — the hint call itself fails.
    function phase4() {
        setMode("fail-sethint", function () {
            LockedHintService.setLocked(true)
            settle(function () {
                pause(600, function () {
                    readLog(function () {
                        const got = rootScope.fresh()
                        rootScope.check("a failed SetLockedHint stops after three calls and does not retry",
                                        got.length === 3)
                        rootScope.check("and the service is idle again rather than stuck busy",
                                        !LockedHintService._busy)
                        rootScope.keep()
                        phase5()
                    })
                })
            })
        })
    }

    // Phase 5 — and the next real lock recovers, because the confirmed value
    // was never advanced past the failure.
    function phase5() {
        setMode("ok", function () {
            LockedHintService.setLocked(true)
            settle(function () {
                readLog(function () {
                    rootScope.expectChain("the next lock retries what the failure left undone",
                                          rootScope.fresh(), "true")
                    rootScope.keep()
                    phase6()
                })
            })
        })
    }

    // Phase 6 — the object path lookup fails: two calls, no hint.
    function phase6() {
        setMode("fail-getsession", function () {
            LockedHintService.setLocked(false)
            settle(function () {
                pause(400, function () {
                    readLog(function () {
                        const got = rootScope.fresh()
                        rootScope.check("a failed GetSession stops before the hint is set",
                                        got.length === 2 && !isSetHint(got[1]))
                        rootScope.keep()
                        phase7()
                    })
                })
            })
        })
    }

    // Phase 7 — the session lookup fails: one call, no busctl at all.
    //
    // `false`, not `true`. Phase 6 failed on its way to `false`, so logind is
    // still believed to hold `true` — and asking for the value it already
    // holds is the no-op phase 2 measured, which would produce no calls for a
    // reason that has nothing to do with show-user. The guard is on the
    // CONFIRMED value, so a failed attempt leaves the desired and confirmed
    // values apart and the next call has to differ from the confirmed one to
    // reach the tools at all.
    function phase7() {
        setMode("fail-showuser", function () {
            LockedHintService.setLocked(false)
            settle(function () {
                pause(400, function () {
                    readLog(function () {
                        const got = rootScope.fresh()
                        rootScope.check("a failed show-user never reaches the bus",
                                        got.length === 1 && isShowUser(got[0]))
                        rootScope.keep()
                        phase8()
                    })
                })
            })
        })
    }

    // Phase 8 — logind answers, but names no graphical session. Exit 0 and an
    // empty line, which is what a user with no seat looks like. It must not be
    // read as a session id.
    function phase8() {
        setMode("empty-display", function () {
            LockedHintService.setLocked(false)
            settle(function () {
                pause(400, function () {
                    readLog(function () {
                        const got = rootScope.fresh()
                        rootScope.check("an empty Display is not a session id",
                                        got.length === 1 && isShowUser(got[0]))
                        rootScope.keep()
                        setMode("ok", phase8b)
                    })
                })
            })
        })
    }

    // Phase 8b — three failures in a row, and then the tools come back. The
    // unlock the failures could not deliver is still owed and is delivered
    // now, which is also what puts logind's believed state back to `false` so
    // the compositor lock below is a real transition rather than a no-op.
    function phase8b() {
        LockedHintService.setLocked(false)
        settle(function () {
            readLog(function () {
                rootScope.expectChain("the unlock three failures could not deliver still lands",
                                      rootScope.fresh(), "false")
                rootScope.keep()
                phase9()
            })
        })
    }

    // Phase 9 — end to end. Nothing calls the service; the compositor does.
    //
    // LockState.locked drives the shipped WlSessionLock, ext-session-lock
    // engages on the nested compositor, `secure` flips once the compositor has
    // acknowledged it, and `onSecureStateChanged` is what reaches logind. That
    // is the whole path P0-015 depends on and none of it has ever been run.
    function phase9() {
        LockState.locked = true
        waitFor(function () { return lock.secure }, 200, function (got) {
            if (!got) {
                console.log("locked-hint: compositor-did-not-acknowledge")
                LockState.locked = false
                finish()
                return
            }
            settle(function () {
                readLog(function () {
                    rootScope.expectChain("a real compositor lock reaches logind", rootScope.fresh(), "true")
                    rootScope.keep()
                    LockState.locked = false
                    waitFor(function () { return !lock.secure }, 200, function (released) {
                        rootScope.check("the lock was released again", released)
                        settle(function () {
                            readLog(function () {
                                rootScope.expectChain("and so does the unlock", rootScope.fresh(), "false")
                                rootScope.keep()
                                finish()
                            })
                        })
                    })
                })
            })
        })
    }

    property var waitCond: null
    property var waitThen: null
    readonly property Timer waitTimer: Timer {
        interval: 50
        repeat: true
        property int tries: 0
        property int limit: 100
        onTriggered: {
            tries++
            const c = rootScope.waitCond
            if ((c && c()) || tries >= limit) {
                stop()
                const met = c ? c() : false
                const f = rootScope.waitThen
                rootScope.waitCond = null
                rootScope.waitThen = null
                tries = 0
                if (f) f(met)
            }
        }
    }
    function waitFor(cond, tries, then) {
        rootScope.waitCond = cond
        rootScope.waitThen = then
        waitTimer.limit = tries
        waitTimer.tries = 0
        waitTimer.restart()
    }

    function finish() {
        console.log("locked-hint: passed=" + rootScope.pass + " failed=" + rootScope.fail)
        Qt.exit(rootScope.fail === 0 ? 0 : 1)
    }
}
