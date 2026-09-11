import Quickshell
import Quickshell.Io
import QtQuick
import "./src"
import "./src/theme"
import "./src/services"
import "./src/nexus"
import "./src/services/qr.js" as QR

// ─────────────────────────────────────────────────────────────────────────────
// Behavioural test for the two APEX Remote pages (P1-051, criteria 1, 3, 5).
//
//     ./tests/run-remote-pairing-page-test.sh
//
// ── The `apex` here is a STUB, and it has to be ─────────────────────────────
//
// `apex remote pair` mints a ONE-TIME pairing token and arms the real daemon
// to accept the next device presenting it. A suite that ran the real command
// would arm the developer's own machine, three times per run, for a phone
// nobody is holding. tests/lib/headless.sh already puts a stub `apex` on PATH
// for exactly this class of problem; the runner replaces it with one that
// answers the four `remote` verbs and logs its argv.
//
// That is also why the service goes through the CLI rather than opening
// apex-remoted's control socket directly. A socket client would walk straight
// past the stub. The service's own header says so from the other side, and
// this file is the half that would notice.
//
// ── What the phases are for ─────────────────────────────────────────────────
//
//   pair-ok     the daemon answers; a code is on screen
//   pair-fail   `apex remote pair` exits 1; there must be NO code on screen
//   devices     three paired devices, one revoked, one connected right now
//
// `pair-fail` is not an error-handling afterthought. "A wrong QR is worse than
// none — a phone scans it, fails, and the person concludes their camera is
// broken" is the sentence `apex remote pair` gives for refusing to draw one in
// a terminal, and it is the whole reason this feature exists as a page. A page
// that drew a placeholder, a stale code, or a greyed square when it had no
// offer would reintroduce exactly that. So the central assertion of that phase
// is a NEGATIVE one: nothing in the page holds a QR matrix.
//
// ── Assert on the model, not on pixels ──────────────────────────────────────
//
// Reading pixels back out of a Canvas under pixman is fragile and would be
// testing Qt's software rasteriser. The matrix QrCode decided to draw is the
// part that can be wrong — a truncated payload, the wrong field, the wrong
// error-correction level — so that is what is asserted, plus one constant
// derived from the payload's byte length rather than from the encoder.
// ─────────────────────────────────────────────────────────────────────────────
ShellRoot {
    id: root

    readonly property string phase: Quickshell.env("APEX_RP_PHASE") || "pair-ok"
    readonly property string pageId: Quickshell.env("APEX_RP_PAGE") || "remote-pair"
    readonly property string callLog: Quickshell.env("APEX_RP_CALLS") || ""

    property int passed: 0
    property int failed: 0

    function check(name, cond) {
        if (cond) { root.passed++; console.log("  PASS  " + name) }
        else      { root.failed++; console.log("  FAIL  " + name) }
    }

    // ── finding things in the built page ─────────────────────────────────────

    function collect(obj, has, out) {
        if (!obj) return out
        if (obj[has] !== undefined) out.push(obj)
        const kids = obj.children
        if (kids)
            for (let i = 0; i < kids.length; i++)
                root.collect(kids[i], has, out)
        return out
    }

    /// Every object carrying `has`, with the COUNT asserted rather than the
    /// first match taken.
    ///
    /// A lookup that returns the first hit goes quiet when the thing it looked
    /// for is renamed or duplicated: the assertions built on it stop running
    /// instead of failing, and a suite four assertions lighter still reports
    /// green. So every lookup here says how many it expected to find.
    function theOne(page, has, label) {
        const found = root.collect(page, has, [])
        root.check("exactly one " + label + " in the page (found " + found.length + ")",
                   found.length === 1)
        return found.length === 1 ? found[0] : null
    }

    function textsIn(page) { return root.collect(page, "truncated", []) }

    function textShowing(page, needle) {
        const ts = root.textsIn(page)
        for (let i = 0; i < ts.length; i++)
            if (ts[i].visible && String(ts[i].text).indexOf(needle) >= 0) return ts[i]
        return null
    }

    function rowFor(page, id) {
        const rows = root.collect(page, "deviceId", [])
        for (let i = 0; i < rows.length; i++)
            if (rows[i].deviceId === id) return rows[i]
        return null
    }

    // ── the harness ──────────────────────────────────────────────────────────

    property var steps: []
    property int stepIndex: 0

    function next() {
        if (root.stepIndex >= root.steps.length) {
            console.log("")
            console.log("passed=" + root.passed + " failed=" + root.failed)
            Qt.exit(root.failed === 0 ? 0 : 1)
            return
        }
        const fn = root.steps[root.stepIndex++]
        fn()
    }

    property int _ticks: 0
    property var _cond: null
    property var _then: null
    property string _waitName: ""
    property int _maxTicks: 150

    function waitFor(name, cond, then, maxTicks) {
        root._waitName = name
        root._cond = cond
        root._then = then
        root._ticks = 0
        root._maxTicks = maxTicks || 150
        waiter.restart()
    }

    Timer {
        id: waiter
        interval: 100
        repeat: true
        onTriggered: {
            if (root._cond()) {
                stop()
                const t = root._then
                root._then = null
                t()
                return
            }
            root._ticks++
            if (root._ticks >= root._maxTicks) {
                stop()
                // A wait that gives up is a FAILED assertion, not a silent
                // continue: otherwise a page that never loads produces a green
                // suite with fewer assertions in it.
                root.check("waited for: " + root._waitName, false)
                root.next()
            }
        }
    }

    /// A pause, not a wait. `waitFor` records a failure when it gives up, which
    /// is right for a wait and wrong for "let a moment pass before claiming
    /// nothing happened".
    function settle(then) {
        settleTimer.stop()
        root._settleThen = then
        settleTimer.restart()
    }
    property var _settleThen: null
    Timer {
        id: settleTimer
        interval: 800
        onTriggered: { const t = root._settleThen; root._settleThen = null; t() }
    }

    /// Read the stub's call log back.
    ///
    /// `cat` through a Process rather than a FileView, for the reason
    /// tests/locked-hint-test.qml gives for the same choice: the file is
    /// appended to by other processes while this one runs, and a cached read
    /// returning stale bytes would be indistinguishable from a command that
    /// never ran. Asynchronous as a result, so every assertion about the log
    /// is made inside a callback rather than off a property.
    property var lines: []
    property var _afterRead: null

    readonly property Process catProc: Process {
        command: []
        running: false
        stdout: SplitParser {
            onRead: function (line) {
                if (line.length > 0) root.lines = root.lines.concat([line])
            }
        }
        onExited: function () {
            const f = root._afterRead
            root._afterRead = null
            if (f) f()
        }
    }

    function readLog(then) {
        root.lines = []
        root._afterRead = then
        catProc.command = ["cat", root.callLog]
        catProc.running = false
        catProc.running = true
    }

    function matching(needle) {
        return root.lines.filter(function (l) { return l.indexOf(needle) >= 0 })
    }

    // ── the page under test, built the way the shell builds it ───────────────

    Item {
        width: 900
        height: 700
        // Item.visible is EFFECTIVE visibility. Under an invisible parent every
        // section in the page answers `visible === false`, so any assertion
        // about what is shown could not fail.
        visible: true

        Loader {
            id: pageLoader
            anchors.fill: parent
            visible: true
            sourceComponent: {
                const ps = PageRegistry.pages
                for (let i = 0; i < ps.length; i++)
                    if (ps[i].id === root.pageId) return ps[i].component
                return null
            }
        }
    }

    readonly property var page: pageLoader.item

    Component.onCompleted: {
        root.steps = root.phase === "devices" ? root.devicesSteps()
                   : root.phase === "pair-fail" ? root.pairFailSteps()
                   : root.pairOkSteps()
        root.next()
    }

    // ── shared opening ───────────────────────────────────────────────────────

    function openPage(then) {
        root.check("the page is registered and built", root.page !== null)
        if (!root.page) { Qt.exit(1); return }
        // Nothing has been asked of the daemon yet. This is the assertion that
        // says the page is not built for somebody who never opened it -- which
        // matters more here than on any other settings page, because one of
        // the things it would ask for mints a one-time pairing token.
        root.readLog(function () {
            root.check("nothing was asked of apex before the page was shown (saw "
                       + root.lines.length + " calls)", root.lines.length === 0)
            root.page.onScreen = true
            then()
        })
    }

    // ── pair-ok ──────────────────────────────────────────────────────────────

    function pairOkSteps() {
        return [
            function () { root.openPage(root.next) },

            function () {
                root.waitFor("a pairing code to arrive",
                    function () { return RemotePairingService.offerLive },
                    root.next)
            },

            function () {
                const payload = RemotePairingService.payload
                root.check("the payload carries apex-remote-core's scheme",
                           payload.indexOf("apex-remote:") === 0)
                root.check("the offer's expiry came from the payload, not from prose",
                           RemotePairingService.payloadExpiresMs > 0)
                root.check("the countdown is running and inside the three minutes",
                           RemotePairingService.secondsLeft > 0
                           && RemotePairingService.secondsLeft <= 180)
                root.next()
            },

            function () {
                const qr = root.theOne(root.page, "moduleCount", "QR code")
                if (!qr) { root.next(); return }

                root.check("the QR code is on screen", qr.visible)
                root.check("the QR was given the whole payload, not a truncation",
                           qr.payload === RemotePairingService.payload)

                // Derived from the payload's byte length and the error
                // correction level, not from the encoder: a 275-byte offer at
                // level m is a version 12 symbol, 65 modules on a side. This
                // reds if the page ever feeds the QR a truncated payload, a
                // different field, or a different level -- independently of
                // whether the encoder agrees with itself.
                root.check("a 275-byte offer at level m is a 65-module symbol (got "
                           + qr.moduleCount + ")", qr.moduleCount === 65)
                root.check("...which is version 12 (got " + qr.version + ")",
                           qr.version === 12)
                root.check("the error correction level is m, not the encoder's default l",
                           qr.level === "m")

                // The quiet zone is part of the symbol. ISO/IEC 18004 requires
                // four modules of light on every side and qr.js returns none,
                // saying in its own header that the caller owes them.
                root.check("four modules of quiet zone are accounted for",
                           qr.quietZone === 4)
                root.check("the drawn span includes the quiet zone on both sides",
                           qr.span === qr.moduleCount + 8)

                // The matrix is the encoder's, module for module. Proves the
                // page fed the payload field and not, say, expires_ms.
                //
                // Guarded on the size first. Without it an empty matrix is a
                // TypeError rather than a failure, and a TypeError aborts the
                // step chain -- so the suite ends with no summary line at all
                // and the remaining assertions VANISH instead of failing.
                // That is exactly what this file's `theOne` exists to stop,
                // and it happened here before the guard was added.
                const want = QR.encode(RemotePairingService.payload, { level: "m" })
                if (qr.modules.length !== want.size) {
                    root.check("the drawn matrix is " + want.size + " rows (got "
                               + qr.modules.length + ")", false)
                    root.next()
                    return
                }
                let differ = 0
                for (let y = 0; y < want.size; y++)
                    for (let x = 0; x < want.size; x++)
                        if (qr.modules[y][x] !== want.modules[y][x]) differ++
                root.check("every module of the drawn symbol is the encoder's ("
                           + differ + " differ)", differ === 0)
                root.next()
            },

            function () {
                root.readLog(function () {
                    const pairs = root.matching("remote pair")
                    root.check("exactly one pairing code was minted (got " + pairs.length + ")",
                               pairs.length === 1)
                    root.check("the payload was asked for alone, not wrapped in qr_block's prose",
                               pairs.length === 1 && pairs[0].indexOf("--text") >= 0)
                    root.check("nothing was revoked", root.matching("remote revoke").length === 0)
                    root.next()
                })
            },

            function () {
                // Returning to a page must not burn the code being scanned.
                root.page.onScreen = false
                root.page.onScreen = true
                root.settle(function () {
                    root.readLog(function () {
                        root.check("coming back to the page does not mint a second code",
                                   root.matching("remote pair").length === 1)
                        root.check("...and the code on screen is still the same one",
                                   RemotePairingService.offerLive)
                        root.next()
                    })
                })
            },

            function () {
                // And asking explicitly does. Waits on the service rather than
                // on the log, because the log read is asynchronous and polling
                // it would start a `cat` every 100 ms.
                const before = RemotePairingService.payload
                RemotePairingService.requestCode()
                root.waitFor("a second code, asked for explicitly",
                    function () { return !RemotePairingService.pairing
                                         && RemotePairingService.payload !== ""
                                         && RemotePairingService.payload !== before },
                    function () {
                        root.readLog(function () {
                            root.check("asking for a new code mints exactly one more (got "
                                       + root.matching("remote pair").length + ")",
                                       root.matching("remote pair").length === 2)
                            root.next()
                        })
                    })
            }
        ]
    }

    // ── pair-fail ────────────────────────────────────────────────────────────

    function pairFailSteps() {
        return [
            function () { root.openPage(root.next) },

            function () {
                root.waitFor("the failure to come back",
                    function () { return RemotePairingService.pairError !== "" },
                    root.next)
            },

            function () {
                // THE assertion of this suite. Not a placeholder, not a stale
                // code, not a greyed square: nothing in the page holds a QR
                // matrix at all.
                const qrs = root.collect(root.page, "moduleCount", [])
                let withMatrix = 0
                for (let i = 0; i < qrs.length; i++)
                    if (qrs[i].moduleCount > 0) withMatrix++
                root.check("no QR code is drawn when there is no offer (found "
                           + withMatrix + " with a matrix)", withMatrix === 0)
                root.check("the QR component is present but empty, not filled with junk",
                           qrs.length === 1 && qrs[0].modules.length === 0)
                root.check("no offer is considered live", !RemotePairingService.offerLive)
                root.next()
            },

            function () {
                root.check("the page says the command failed, in the command's words",
                           root.textShowing(root.page, "apex remote pair exited") !== null)
                root.check("...and points at the thing that is usually wrong",
                           root.textShowing(root.page, "apex remote enable") !== null)
                root.next()
            },

            function () {
                root.readLog(function () {
                    root.check("the failure was a real attempt, not a refusal to try",
                               root.matching("remote pair").length === 1)
                    root.next()
                })
            }
        ]
    }

    // ── devices ──────────────────────────────────────────────────────────────

    function devicesSteps() {
        return [
            function () { root.openPage(root.next) },

            function () {
                root.waitFor("the device list to arrive",
                    function () { return RemotePairingService.devicesChecked
                                         && RemotePairingService.devices.length > 0 },
                    root.next)
            },

            function () {
                root.check("every paired device is listed",
                           RemotePairingService.devices.length === 3)
                root.check("the summary counts what can still connect, not the records",
                           RemotePairingService.summary === "2 devices paired.")
                root.next()
            },

            function () {
                const rows = root.collect(root.page, "deviceId", [])
                root.check("one row per device (found " + rows.length + ")", rows.length === 3)

                const live = root.rowFor(root.page, "AAAAAQIDBAUGBwgJ")
                const revoked = root.rowFor(root.page, "BBBBAQIDBAUGBwgJ")
                const never = root.rowFor(root.page, "CCCCAQIDBAUGBwgJ")
                root.check("each device has its own row",
                           live !== null && revoked !== null && never !== null)
                if (!live || !revoked || !never) { root.next(); return }

                // The state comes from `status --json`'s connection list, not
                // from how recently the device was seen.
                root.check("a device with a connection open right now reads connected",
                           live.deviceState === "connected")
                root.check("a revoked device reads revoked", revoked.deviceState === "revoked")
                root.check("a device that never handshook says so",
                           never.deviceState === "never connected"
                           || never.deviceState === "never")

                // The non-hue channel. Two states that differed only in hue
                // would be one state to a deuteranope, and this is the pair
                // that costs the most to confuse.
                root.check("connected and revoked differ in weight, not only in colour",
                           live.weight !== revoked.weight)
                root.next()
            },

            function () {
                root.check("the state word is on the row, not only its colour",
                           root.textShowing(root.page, "revoked") !== null
                           && root.textShowing(root.page, "connected") !== null)
                root.check("how long ago each was seen is shown",
                           root.textShowing(root.page, "last seen") !== null)
                root.check("the path the last connection came in on is shown",
                           root.textShowing(root.page, "over lan") !== null)
                root.next()
            },

            function () {
                // The claim, as a sentence, naming the device -- and not as a
                // tick, which would read as a fact this machine had checked.
                root.check("the biometric claim is shown as the device's claim",
                           root.textShowing(root.page, "device's own claim") !== null)
                root.check("...and says this machine cannot verify it",
                           root.textShowing(root.page, "cannot verify it") !== null)
                root.check("...and names the device making it",
                           root.textShowing(root.page, "Pixel 8") !== null)
                root.next()
            },

            function () {
                const revoked = root.rowFor(root.page, "BBBBAQIDBAUGBwgJ")
                const live = root.rowFor(root.page, "AAAAAQIDBAUGBwgJ")
                const revokedBtns = root.collect(revoked, "label", []).filter(
                    function (b) { return b.label === "Revoke" && b.visible })
                const liveBtns = root.collect(live, "label", []).filter(
                    function (b) { return b.label === "Revoke" && b.visible })
                root.check("a revoked device offers no revoke button",
                           revokedBtns.length === 0)
                root.check("a paired device offers exactly one", liveBtns.length === 1)
                root.next()
            },

            function () {
                const live = root.rowFor(root.page, "AAAAAQIDBAUGBwgJ")
                const btn = root.collect(live, "label", []).filter(
                    function (b) { return b.label === "Revoke" && b.visible })[0]
                if (!btn) { root.check("a revoke button to press", false); root.next(); return }
                btn.clicked()
                // Waits on the service's own state, not on the log: polling
                // the log would start a `cat` every 100 ms.
                root.waitFor("the revoke to run",
                    function () { return RemotePairingService.revoking === "" },
                    function () {
                        root.readLog(function () {
                            const r = root.matching("remote revoke")
                            root.check("pressing revoke runs exactly one revoke (got "
                                       + r.length + ")", r.length === 1)
                            root.check("...naming the device that was pressed",
                                       r.length === 1 && r[0].indexOf("AAAAAQIDBAUGBwgJ") >= 0)
                            root.next()
                        })
                    })
            },

            function () {
                root.readLog(function () {
                    // The devices page is a listing. It must never mint a
                    // one-time pairing token as a side effect of being looked
                    // at -- each one invalidates the code somebody may be
                    // holding their phone up to on the other page.
                    root.check("looking at the device list mints no pairing code",
                               root.matching("remote pair").length === 0)
                    root.check("the list was read as json",
                               root.matching("remote devices --json").length > 0)
                    root.next()
                })
            }
        ]
    }
}
