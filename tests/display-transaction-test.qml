import Quickshell
import Quickshell.Io
import QtQuick
import "./src/components"
import "./src/services"
import "./src/nexus"
import "./src/popups"
import "./src"

// ─────────────────────────────────────────────────────────────────────────────
// Behavioural test for the display apply transaction (P0-018).
//
//     ./tests/run-display-transaction-test.sh
//
// Everything here runs against a REAL wlroots session with two virtual outputs
// and the REAL /usr/libexec/apex-display-apply. Nothing is mocked except one
// thing, named where it happens: a wrapper that can hide an output from `list`,
// because "the monitor was unplugged between staging and Apply" cannot be
// produced any other way — a headless output can be disabled but not removed.
//
// Why not a stub engine for all of it: the bug this suite exists for is partly
// IN the enumeration. `list` reports a per-output `modes` array with a `current`
// flag and no top-level `mode`, so the pre-apply snapshot used to carry no
// resolution and "revert" restored the layout at whatever the compositor thinks
// is preferred. A stub that emitted a tidy `mode` would pass a test the real
// engine fails.
//
// The outputs are shaped like the desk this was reported from: 1920x1200 at 0,0
// and 2560x1080 at 1920,0.
//
// Scenarios, in order:
//   1  enumeration        the active mode is recovered from modes[].current
//   2  confirm            Keep persists, and NOTHING is persisted before Keep
//   3  manual revert      restores the layout and leaves display.json alone
//   4  timeout            reverts on its own, at the resolution that was on
//   5  invalid mode       refused with the output named, staged values kept
//   6  disconnected       refused with the output named, staged values kept
//
// The other two of criterion 8's six — shell restart during the transaction,
// and the dialog on a safe active output — cannot be asked of a service in
// isolation. They live in the harness, which kills the shell and reads the
// full shell's log.
// ─────────────────────────────────────────────────────────────────────────────

ShellRoot {
    id: root

    property int passed: 0
    property int failed: 0

    function check(name, cond) {
        if (cond) { root.passed++; console.log("  PASS  " + name) }
        else      { root.failed++; console.log("  FAIL  " + name) }
    }

    readonly property string sandbox: Quickshell.env("APEX_TEST_SANDBOX") || ""
    readonly property string modelPath: DisplayService.modelPath
    readonly property string kanshiPath: Quickshell.env("HOME") + "/.config/kanshi/config"
    readonly property string txnDir: DisplayService.txnDir
    readonly property string hideFlag: root.sandbox + "/hide-headless-2"

    readonly property string first:  "HEADLESS-1"
    readonly property string second: "HEADLESS-2"

    // Read through confirmSeconds, not through the properties this fix adds.
    // A suite that asks `DisplayService.pending` reports "undefined is not
    // true" on a tree without it, which proves nothing about behaviour — and
    // proving the behaviour is different is the entire point of running this
    // against the unfixed tree.
    function pendingNow() { return DisplayService.confirmSeconds > 0 }
    readonly property int timeoutSeconds: DisplayService.confirmTotal || 15

    // ── A serial shell helper ────────────────────────────────────────────────
    // One Process, one command at a time, callback with (stdout, exitCode). The
    // callback runs from a short timer rather than straight out of onExited so
    // a stdout collector that finishes after the exit still lands first.
    property string _shOut: ""
    property int _shCode: 0
    property var _shCb: null

    property Process _sh: Process {
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._shOut = text }
        onExited: function (code) { root._shCode = code; _shSettle.restart() }
    }

    property Timer _shSettle: Timer {
        interval: 40
        onTriggered: {
            const cb = root._shCb
            root._shCb = null
            if (cb) cb(root._shOut, root._shCode)
        }
    }

    function sh(cmd, cb) {
        root._shOut = ""
        root._shCb = cb
        root._sh.command = ["bash", "-c", cmd]
        root._sh.running = true
    }

    // wlr-randr is the independent witness. Asking DisplayService what it
    // applied would only prove it is self-consistent.
    function live(cb) {
        root.sh("wlr-randr --json", function (out) {
            let parsed = []
            try { parsed = JSON.parse(out.trim() || "[]") } catch (e) { parsed = [] }
            const by = {}
            for (const o of parsed) by[o.name] = o
            cb(by)
        })
    }

    function digest(path, cb) {
        root.sh("md5sum '" + path + "' 2>/dev/null | cut -d' ' -f1 || echo missing", function (out) {
            cb(out.trim())
        })
    }

    function readText(path, cb) {
        root.sh("cat '" + path + "' 2>/dev/null || true", function (out) { cb(out) })
    }

    // ── The step driver ──────────────────────────────────────────────────────
    // Steps are functions that end by calling next(). `waitFor` polls a
    // predicate so a step can sit on an asynchronous service without either
    // guessing at a sleep or hanging the run forever.
    property int stepIndex: -1
    property var steps: []

    function next() {
        root.stepIndex += 1
        if (root.stepIndex >= root.steps.length) {
            console.log("")
            console.log("passed=" + root.passed + " failed=" + root.failed)
            Qt.exit(root.failed === 0 ? 0 : 1)
            return
        }
        root.steps[root.stepIndex]()
    }

    property var _waitCond: null
    property var _waitThen: null
    property int _waitTicks: 0
    property string _waitName: ""

    function waitFor(name, cond, then, maxTicks) {
        root._waitName = name
        root._waitCond = cond
        root._waitThen = then
        root._waitTicks = maxTicks || 200      // ticks are 100 ms
        _waiter.restart()
    }

    property Timer _waiter: Timer {
        interval: 100
        repeat: true
        onTriggered: {
            if (root._waitCond()) {
                stop()
                const then = root._waitThen
                root._waitThen = null
                then()
                return
            }
            root._waitTicks -= 1
            if (root._waitTicks <= 0) {
                stop()
                root.check("waited for: " + root._waitName, false)
                const then = root._waitThen
                root._waitThen = null
                then()
            }
        }
    }

    /// Wait for the service to be idle again: no apply running and no countdown.
    function settled(then) {
        root.waitFor("the transaction to settle",
                     function () { return !DisplayService.applying && !root.pendingNow() },
                     then)
    }

    function scaleOf(byName, output) {
        const o = byName[output]
        return o ? Number(o.scale) : -1
    }

    // ── Scenario state carried between steps ─────────────────────────────────
    property string modelDigestBefore: ""
    property real baselineScale1: 1.0
    property real baselineScale2: 1.0

    Component.onCompleted: {
        console.log("[display-transaction] engine=" + DisplayService.engine)
        console.log("[display-transaction] txn=" + root.txnDir
                    + " timeout=" + root.timeoutSeconds + "s")

        root.steps = [
            // ── 0  enumeration ───────────────────────────────────────────────
            function () {
                DisplayService.refresh()
                root.waitFor("the outputs to be enumerated",
                             function () { return DisplayService.loaded
                                                  && DisplayService.draft.length > 0 },
                             root.next)
            },
            function () {
                const d = DisplayService.draft
                const by = {}
                for (const o of d) by[o.name] = o
                root.check("both virtual outputs are enumerated",
                           !!by[root.first] && !!by[root.second])

                // THE ENUMERATION GAP. `list` never emits a top-level `mode`;
                // it emits modes[].current. Without recovering it here the
                // pre-apply snapshot has no resolution, and every revert
                // restores "whatever is preferred" instead of what was on.
                const m1 = by[root.first] ? by[root.first].mode : null
                root.check("the active mode of " + root.first + " is recovered from the mode list",
                           !!m1 && m1.width === 1920 && m1.height === 1200)
                const m2 = by[root.second] ? by[root.second].mode : null
                root.check("the active mode of " + root.second + " is recovered from the mode list",
                           !!m2 && m2.width === 2560 && m2.height === 1080)

                root.live(function (byLive) {
                    root.baselineScale1 = root.scaleOf(byLive, root.first)
                    root.baselineScale2 = root.scaleOf(byLive, root.second)
                    root.next()
                })
            },

            // ── 1  confirm ───────────────────────────────────────────────────
            function () {
                console.log("[scenario] confirm")
                DisplayService.stage(root.first, "scale", 1.25)
                root.check("the change is staged", DisplayService.dirty)
                root.digest(root.modelPath, function (d) {
                    root.modelDigestBefore = d
                    DisplayService.apply()
                    root.waitFor("the countdown to start",
                                 function () { return root.pendingNow() },
                                 root.next)
                })
            },
            function () {
                root.check("a countdown is running after a successful apply",
                           root.pendingNow())
                root.check("the countdown starts at the full timeout",
                           DisplayService.confirmSeconds === root.timeoutSeconds)
                root.check("the dialog is aimed at an output that is still on",
                           DisplayService.confirmScreen !== "")
                root.live(function (by) {
                    root.check("the temporary layout really reached the compositor",
                               Math.abs(root.scaleOf(by, root.first) - 1.25) < 0.001)
                    root.digest(root.modelPath, function (d) {
                        // Criterion 6, the half that is about disk: an
                        // unconfirmed layout must not be the one that comes
                        // back at the next login.
                        root.check("nothing is persisted while the countdown runs",
                                   d === root.modelDigestBefore)
                        DisplayService.confirm()
                        root.settled(root.next)
                    })
                })
            },
            function () {
                root.readText(root.modelPath, function (txt) {
                    let m = null
                    try { m = JSON.parse(txt.trim() || "{}") } catch (e) { m = null }
                    let scale = -1
                    for (const o of ((m && m.outputs) || []))
                        if (o.name === root.first) scale = Number(o.scale)
                    root.check("Keep persists the layout it was asked about",
                               Math.abs(scale - 1.25) < 0.001)
                    root.check("Keep clears the staged state", !DisplayService.dirty)
                    root.readText(root.kanshiPath, function (k) {
                        root.check("Keep regenerates the hotplug profile",
                                   k.indexOf("scale 1.25") >= 0)
                        root.next()
                    })
                })
            },

            // ── 2  manual revert ─────────────────────────────────────────────
            function () {
                console.log("[scenario] manual revert")
                DisplayService.stage(root.first, "scale", 1.75)
                root.digest(root.modelPath, function (d) {
                    root.modelDigestBefore = d
                    DisplayService.apply()
                    root.waitFor("the countdown to start",
                                 function () { return root.pendingNow() },
                                 root.next)
                })
            },
            function () {
                DisplayService.revertApplied()
                root.settled(function () {
                    root.live(function (by) {
                        root.check("Revert puts the previous scale back",
                                   Math.abs(root.scaleOf(by, root.first) - 1.25) < 0.001)
                        root.check("Revert stops the countdown", !root.pendingNow())
                        root.digest(root.modelPath, function (d) {
                            root.check("a reverted apply leaves the persisted model untouched",
                                       d === root.modelDigestBefore)
                            root.readText(root.txnDir + "/state", function (s) {
                                root.check("the guard is told the transaction is over",
                                           s.trim() === "reverted")
                                root.next()
                            })
                        })
                    })
                })
            },

            // ── 3  timeout ───────────────────────────────────────────────────
            function () {
                console.log("[scenario] timeout")
                DisplayService.stage(root.second, "scale", 1.5)
                DisplayService.apply()
                root.waitFor("the countdown to start",
                             function () { return root.pendingNow() },
                             root.next)
            },
            function () {
                // Nobody answers. Wait past the deadline plus the engine's own
                // run time, then look at the hardware.
                root.waitFor("the countdown to run out",
                             function () { return !root.pendingNow() },
                             function () { root.settled(root.next) },
                             (root.timeoutSeconds + 20) * 10)
            },
            function () {
                root.live(function (by) {
                    root.check("the timeout restores the previous scale",
                               Math.abs(root.scaleOf(by, root.second) - root.baselineScale2) < 0.001)
                    root.readText(root.kanshiPath, function (k) {
                        // The exact-configuration half of criterion 5. A
                        // rollback with no resolution in it re-applies the
                        // preferred mode, which on a real panel is a different
                        // resolution than the one the user was looking at.
                        root.check("the restored layout names the resolution that was on screen",
                                   k.indexOf("mode 2560x1080@60") >= 0)
                        root.next()
                    })
                })
            },

            // ── 4  invalid mode ──────────────────────────────────────────────
            function () {
                console.log("[scenario] invalid mode")
                // Staged directly rather than through stageMode(), which can
                // only ever pick a mode the output reported. This is the state
                // you reach by staging a mode and then having the panel
                // renegotiate — and it is the state a hand-edited display.json
                // arrives in.
                DisplayService.stage(root.first, "mode",
                                     { width: 3840, height: 2160, refresh: 60 })
                DisplayService.stage(root.second, "y", 40)
                root.digest(root.modelPath, function (d) {
                    root.modelDigestBefore = d
                    DisplayService.apply()
                    root.waitFor("the apply to be refused",
                                 function () { return !DisplayService.applying },
                                 root.next)
                })
            },
            function () {
                root.check("a rejected layout starts no countdown", !root.pendingNow())
                root.check("the error names the output",
                           DisplayService.lastError.indexOf(root.first) >= 0)
                root.check("the error names the mode that was refused",
                           DisplayService.lastError.indexOf("3840") >= 0)
                root.check("a failed apply keeps the staged state", DisplayService.dirty)
                let keptY = -1
                let keptMode = null
                for (const o of DisplayService.draft) {
                    if (o.name === root.second) keptY = o.y
                    if (o.name === root.first) keptMode = o.mode
                }
                root.check("a failed apply keeps the OTHER staged values too", keptY === 40)
                root.check("a failed apply keeps the value that was wrong, to be fixed",
                           !!keptMode && keptMode.width === 3840)
                root.digest(root.modelPath, function (d) {
                    root.check("a failed apply persists nothing",
                               d === root.modelDigestBefore)
                    root.live(function (by) {
                        root.check("a failed apply changes no hardware",
                                   Math.abs(root.scaleOf(by, root.first) - 1.25) < 0.001)
                        DisplayService.revert()
                        root.next()
                    })
                })
            },

            // ── 5  disconnected output ───────────────────────────────────────
            function () {
                console.log("[scenario] disconnected output")
                root.waitFor("the outputs to be re-read",
                             function () { return DisplayService.draft.length === 2 },
                             root.next)
            },
            function () {
                DisplayService.stage(root.second, "x", 3000)
                // The injector: from here `list` stops reporting HEADLESS-2,
                // exactly as if it had been unplugged. Every other verb is the
                // real engine, unchanged.
                root.sh("touch '" + root.hideFlag + "'", function () {
                    root.digest(root.modelPath, function (d) {
                        root.modelDigestBefore = d
                        DisplayService.apply()
                        root.waitFor("the apply to be refused",
                                     function () { return !DisplayService.applying },
                                     root.next)
                    })
                })
            },
            function () {
                root.check("an unplugged output starts no countdown", !root.pendingNow())
                root.check("the error names the output that went away",
                           DisplayService.lastError.indexOf(root.second) >= 0)
                root.check("the error says what is wrong with it",
                           DisplayService.lastError.indexOf("no longer connected") >= 0)
                root.check("the staged values survive an unplug", DisplayService.dirty)
                root.digest(root.modelPath, function (d) {
                    root.check("an unplugged output persists nothing",
                               d === root.modelDigestBefore)
                    root.sh("rm -f '" + root.hideFlag + "'", function () { root.next() })
                })
            }
        ]

        root.next()
    }

    // A run that hangs is a run that reports nothing. The harness has its own
    // timeout; this one exists so the summary line is still printed.
    Timer {
        interval: 240000
        running: true
        onTriggered: {
            console.log("  FAIL  the suite did not finish")
            root.failed += 1
            console.log("")
            console.log("passed=" + root.passed + " failed=" + root.failed)
            Qt.exit(1)
        }
    }
}
