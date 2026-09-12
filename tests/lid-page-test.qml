import Quickshell
import Quickshell.Io
import QtQuick
import "./src"
import "./src/theme"
import "./src/services"
import "./src/nexus"

// ─────────────────────────────────────────────────────────────────────────────
// Config → Closing the Lid, BUILT AND DRAWN. Run via tests/run-lid-page-test.sh
// (roadmap P1-063, criterion 6 — "the owner can see why the machine did what it
// did after reopening").
//
// ── Why this file exists, in one sentence somebody already paid for ─────────
//
// P1-061's privacy page landed with qmllint green, a node suite green and a
// static wiring checker green, and threw a TypeError on every single load:
//
//     WARN scene: PrivacyPage.qml[176:-1]:
//         TypeError: Cannot read property 'brokered' of null
//
// A binding inside an invisible section is still evaluated. This page has
// strictly more nested objects than that one — `logind`, `decision`, `work`,
// `thermal`, `charge`, `vpn`, `period`, and two arrays inside `period` — so it
// has strictly more of that hazard, and `unreadable` below is the phase that
// would find it. The runner treats any TypeError in a phase log as a hard
// failure.
//
// ── It opens ONE window, and that is the point ──────────────────────────────
//
// A Column lays its children out in a polish pass, a polish pass is driven by a
// QQuickWindow, and without one every row keeps height 0 — so "the rows were
// laid out" could not fail. FloatingWindow, never PanelWindow, inside the
// private headless compositor the runner starts: WAYLAND_DISPLAY and DISPLAY
// are unset, XDG_RUNTIME_DIR is a fresh directory, and tests/lib/headless.sh
// aborts the run if the socket it ends up on is not inside that directory. No
// window reaches anybody's desk, which on this machine is not a nicety.
//
// ── The `apex` here is a STUB, and it has to be ─────────────────────────────
//
// `apex lid pin` WRITES the invoking user's ~/.config/apex/lid.toml, and the
// root driver reads that file to decide whether this laptop suspends. A suite
// that ran the real command would repin the machine it is running on, several
// times per run. The runner replaces the stub tests/lib/headless.sh installs
// with one that answers `status --json` and `report --json` from
// tests/fixtures/lid/ and records every argv it is handed.
//
// That is also why the service goes through the CLI rather than reading /sys
// and busctl itself: a stub on PATH is the isolation, and a client that opened
// the D-Bus name directly would walk straight past it.
//
// ── Five phases ─────────────────────────────────────────────────────────────
//
//   docked       the real L16 capture: an external display, so logind ignores
//                the lid and APEX is not why. The page must say that and must
//                render `policy_error` as a note rather than a failure.
//   working      undocked, pinned on, with a real closed period to report
//   guard        a thermal guard, which must outrank the docked frame because
//                a guard suspend is APEX calling systemctl itself
//   unreadable   `apex` fails. The page must say so and must not throw
//   pixels       the built page is rasterised and the image inspected
// ─────────────────────────────────────────────────────────────────────────────
ShellRoot {
    id: root

    readonly property string phase: Quickshell.env("APEX_LP_PHASE") || "docked"
    readonly property string callLog: Quickshell.env("APEX_LP_CALLS") || ""
    readonly property string grabPath: Quickshell.env("APEX_LP_GRAB") || ""

    property int passed: 0
    property int failed: 0

    function check(name, cond, detail) {
        if (cond) {
            root.passed++
            console.log("  PASS  " + name)
        } else {
            root.failed++
            console.log("  FAIL  " + name + (detail ? "  [" + detail + "]" : ""))
        }
    }

    function eq(name, got, want) {
        root.check(name, got === want, "got " + got + ", want " + want)
    }

    // ── finding things in the built page ─────────────────────────────────────
    //
    // By a property only the thing being looked for carries, never by index: a
    // delegate's position in `children` is whatever the component happens to
    // wrap its children in today.

    function collect(obj, has, out) {
        if (!obj) return out
        if (obj[has] !== undefined) out.push(obj)
        const kids = obj.children
        if (kids)
            for (let i = 0; i < kids.length; i++)
                root.collect(kids[i], has, out)
        return out
    }

    function collectNamed(obj, name, out) {
        if (!obj) return out
        if (obj.objectName === name) out.push(obj)
        const kids = obj.children
        if (kids)
            for (let i = 0; i < kids.length; i++)
                root.collectNamed(kids[i], name, out)
        return out
    }

    /// Every Text. `truncated` is QQuickText's, and no other element has it.
    function texts() { return root.collect(root.page, "truncated", []) }

    function showing(needle) {
        const ts = root.texts()
        for (let i = 0; i < ts.length; i++)
            if (ts[i].visible && String(ts[i].text).indexOf(needle) >= 0) return ts[i]
        return null
    }

    /// The pills of every CfgSegmented on the page. Each one names itself.
    function pills() { return root.collectNamed(root.page, "cfgSegmentedPill", []) }

    function pillFor(label) {
        const ps = root.pills()
        for (let i = 0; i < ps.length; i++)
            if (String(ps[i].Accessible.name) === label) return ps[i]
        return null
    }

    function buttons() {
        return root.collect(root.page, "press", []).filter(function (b) {
            return b.label !== undefined && b.variant !== undefined
        })
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
    /// is right for a wait and wrong for "let the polish pass run".
    property var _settleThen: null
    function settle(then) {
        settleTimer.stop()
        root._settleThen = then
        settleTimer.restart()
    }
    Timer {
        id: settleTimer
        interval: 600
        onTriggered: { const t = root._settleThen; root._settleThen = null; t() }
    }

    /// Read the stub's call log back.
    ///
    /// `cat` through a Process rather than a FileView: the file is appended to
    /// by another process while this one runs, and a cached read returning
    /// stale bytes is indistinguishable from a command that never ran.
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
    //
    // Through PageRegistry rather than by naming LidPage directly, so the
    // registration is part of what is under test: a page that is not in the
    // registry cannot be opened from Nexus or from the Config tab, whatever the
    // file itself does.

    FloatingWindow {
        id: stage
        width:  980
        height: 900
        visible: true
        color:  "#101012"

        Loader {
            id: pageLoader
            anchors.fill: parent
            visible: true
            sourceComponent: {
                const ps = PageRegistry.pages
                for (let i = 0; i < ps.length; i++)
                    if (ps[i].id === "lid") return ps[i].component
                return null
            }
        }
    }

    readonly property var page: pageLoader.item

    Component.onCompleted: {
        root.steps = root.phase === "working"    ? root.workingSteps()
                   : root.phase === "guard"      ? root.guardSteps()
                   : root.phase === "unreadable" ? root.unreadableSteps()
                   : root.phase === "pixels"     ? root.pixelSteps()
                   : root.dockedSteps()
        root.next()
    }

    // ── shared opening ───────────────────────────────────────────────────────

    function openPage(then) {
        root.check("the page is registered under 'lid' and built", root.page !== null)
        if (!root.page) {
            console.log("")
            console.log("passed=" + root.passed + " failed=" + root.failed)
            Qt.exit(1)
            return
        }
        // Nothing has been asked of the machine yet. LidService is refcounted
        // on `onScreen` precisely so that a page nobody is looking at spawns no
        // pair of `apex` processes every fifteen seconds, and this is the
        // assertion that says the gate holds.
        root.readLog(function () {
            root.eq("nothing was asked of apex before the page was shown",
                    root.lines.length, 0)
            root.page.onScreen = true
            root.waitFor("the first sweep to return",
                         function () { return LidService.checked },
                         function () { root.settle(then) })
        })
    }

    /// Both reads, and no third one. The service runs status and report one
    /// after the other rather than at once, so a sweep is exactly two
    /// processes; a page that grew a third poller would show up here first.
    function assertSweepShape() {
        root.readLog(function () {
            root.eq("the sweep read the status once",
                    root.matching("lid status --json").length, 1)
            root.eq("and the record once",
                    root.matching("lid report --json").length, 1)
            root.eq("and asked for nothing else", root.lines.length, 2)
            // Criterion: no privilege anywhere on this surface.
            root.eq("nothing was elevated", root.matching("sudo").length, 0)
            root.eq("and nothing went through pkexec", root.matching("pkexec").length, 0)
            root.next()
        })
    }

    // ── phase: docked ────────────────────────────────────────────────────────
    //
    // The real L16 capture. This is the case the page is SHAPED around: an
    // external display means logind consults HandleLidSwitchDocked (default
    // `ignore`) before any inhibitor, so the lid does nothing whatever the pin
    // says and APEX is not the reason it stays awake.

    function dockedSteps() {
        return [
            function () { root.openPage(root.next) },
            root.assertSweepShape,
            root.assertDockedFrame,
            root.assertPolicyNoteIsANote,
            root.assertInputsListed,
            root.assertNoRecord,
            root.assertLaidOut
        ]
    }

    function assertDockedFrame() {
        root.check("the status was readable", LidService.available,
                   LidService.unavailableReason)
        root.eq("logind is known not to act on the lid", LidService.logind.actsOnLid, false)
        root.eq("one external display was counted", LidService.logind.externalDisplays, 1)

        // Three answers, never two — and the one on screen is the one that
        // refuses to claim credit for somebody else's behaviour.
        root.check("the page says the machine already ignores the lid",
                   root.showing("already ignores the lid") !== null)
        root.check("…and that APEX is not why",
                   root.showing("APEX is not why") !== null)
        root.check("…and names the setting that beats the inhibitor",
                   root.showing("HandleLidSwitchDocked") !== null)
        root.check("…and tells the owner what to do about it",
                   root.showing("Unplug the display") !== null)

        // The dock is a WARNING, not a failure. A machine whose lid APEX does
        // not control is not a broken machine, and painting it in the danger
        // tone would teach the reader that red means nothing on this page.
        root.eq("the docked frame is drawn as a warning", LidService.logind.tone, "warn")
        root.check("and the page does not claim the lid keeps the work running",
                   root.showing("keeps the work running") === null)
        root.next()
    }

    function assertPolicyNoteIsANote() {
        // Rule 3 in lid.js's header, on screen. Present on every read by an
        // ordinary user on a machine where root has a live /run/user/0, because
        // the OS side reports every policy candidate it could not open rather
        // than silently skipping one.
        root.check("the capture carries an unreadable root policy",
                   LidService.policyNote.indexOf("Permission denied") >= 0,
                   LidService.policyNote)
        root.check("…and it did NOT make the read a failure", LidService.available)

        const note = root.showing("could not open")
        root.check("the note is on screen", note !== null)
        if (note) {
            // The whole point: it is a note. A colour that said "your machine
            // is broken" here would cry wolf on every single load.
            root.check("…in the note colour, not the danger colour",
                       String(note.color) !== String(root.page.toneColor("danger")),
                       String(note.color))
            root.check("…and it says the policy in force is still shown",
                       String(note.text).indexOf("actually in force") >= 0)
        }
        root.next()
    }

    function assertInputsListed() {
        // Criterion 6 is "the owner can see WHY", and the why is five inputs,
        // not a sentence about them. Any one of the five can be the reason.
        root.check("the lid switch is listed", root.showing("Lid") !== null)
        root.check("live work is listed", root.showing("Live work") !== null)
        root.check("the temperature is listed", root.showing("Temperature") !== null)
        root.check("the charge is listed", root.showing("Charge") !== null)
        root.check("the VPN is listed", root.showing("VPN") !== null)

        // And each with what it actually reads, from the capture.
        root.check("live work says how many sessions",
                   root.showing("No agent session is running") !== null)
        root.check("the temperature is a reading and not a tick",
                   root.showing("°C") !== null)
        root.check("the charge says mains", root.showing("On mains") !== null)
        root.check("the VPN says there is no tunnel",
                   root.showing("No tunnel is up") !== null)

        // The guards, said before the bag rather than after it.
        root.check("the page warns that guards suspend anyway",
                   root.showing("no airflow") !== null)
        root.next()
    }

    function assertNoRecord() {
        // Three answers: a readable "nothing yet", an unreadable record, and a
        // real one. This fixture is the first.
        root.check("the record was readable", LidService.report.ok)
        root.check("and there is nothing in it", !LidService.report.has)
        root.check("the page says so in those words",
                   root.showing("No lid-closed period has been recorded") !== null)
        root.check("…and does not show a period that is not there",
                   root.showing("agent session") !== null)
        root.check("…and claims no battery figure",
                   root.showing("% of battery used") === null)
        root.next()
    }

    function assertLaidOut() {
        // Constructed is not drawn. Every one of these numbers is zero in a
        // scene with no window, which is why this file opens one.
        root.check("the page has a size", root.page.width > 0 && root.page.height > 0,
                   root.page.width + "x" + root.page.height)

        const ps = root.pills()
        root.eq("the three pins are on screen as three pills", ps.length, 3)
        let flat = 0
        for (let i = 0; i < ps.length; i++)
            if (ps[i].width <= 0 || ps[i].height <= 0) flat++
        root.eq("none of them was left with no size", flat, 0)

        // A Text whose paint size is zero is not on screen whatever `visible`
        // says. Checked on the headline specifically, because it is the
        // criterion: the one-line answer to "can I shut it now".
        const head = root.showing("already ignores the lid")
        root.check("the headline has actually been laid out",
                   head !== null && head.paintedWidth > 0 && head.paintedHeight > 0,
                   head ? (head.paintedWidth + "x" + head.paintedHeight) : "not found")
        root.next()
    }

    // ── phase: working ───────────────────────────────────────────────────────
    //
    // Undocked and pinned on, with a real closed period behind it. This is the
    // phase where the pin is pressed and where the four things Andre asked to
    // be told after reopening are asserted one at a time.

    function workingSteps() {
        return [
            function () { root.openPage(root.next) },
            root.assertActing,
            root.assertReport,
            root.pressPin,
            root.refuseBadPin
        ]
    }

    function assertActing() {
        root.eq("an undocked machine acts on its lid", LidService.logind.actsOnLid, true)
        root.check("the page says the inhibitor is what decides",
                   root.showing("the inhibitor is what decides") !== null)
        root.check("…and that it is held right now",
                   root.showing("is blocked right now") !== null)
        root.eq("the pin came back on", LidService.pin, "on")
        root.check("the headline answers the question Andre asked",
                   root.showing("keeps the work running") !== null)
        // The docked wording must be GONE, not merely outranked.
        root.check("and nothing on screen still says the machine is docked",
                   root.showing("reports this machine as docked") === null)
        root.next()
    }

    function assertReport() {
        root.check("a real period came back", LidService.report.has)
        // Andre's four, each its own row. A summary line naming three of them
        // would read fine and answer less.
        root.check("(1) how long it stayed up", root.showing("How long") !== null)
        root.check("(2) what was running", root.showing("What was running") !== null)
        root.check("(3) whether the VPN held", root.showing("The VPN") !== null)
        root.check("(4) what the battery cost", root.showing("Battery") !== null)

        // The power-down, and — separately — what was NOT powered down and why.
        // The second list is the half that gets dropped, and it is the half
        // that explains a battery that drained anyway.
        root.check("what was powered down is listed",
                   root.showing("Powered down") !== null)
        root.check("…including the keyboard backlight, which round 2 found was never zeroed",
                   root.showing("keyboard backlight") !== null)
        root.check("what was left alone is listed separately",
                   root.showing("Left alone, and why") !== null)
        root.check("…with a reason on each", root.showing("could not be asked") !== null)
        root.next()
    }

    function pressPin() {
        // The pill, pressed. Not LidService.setPin() called from here: the
        // wiring from a rendered control to the argv is the part a node suite
        // cannot see.
        const pill = root.pillFor(LidService.pinLabel("auto"))
        root.check("the 'Follow live work' pill is on screen", pill !== null)
        if (!pill) { root.next(); return }

        root.readLog(function () {
            const before = root.lines.length
            pill.Accessible.onPressAction()
            root.waitFor("the pin to be handed to apex",
                         function () { return !LidService.busy },
                         function () {
                             root.readLog(function () {
                                 const hit = root.matching("lid pin auto")
                                 root.eq("pressing it ran exactly that pin", hit.length, 1)
                                 // The line the whole polkit paragraph is about.
                                 root.eq("…with no sudo", root.matching("sudo").length, 0)
                                 root.eq("…and no pkexec", root.matching("pkexec").length, 0)
                                 root.eq("…and nothing failed", LidService.lastError, "")
                                 root.check("…and it re-read the machine afterwards",
                                            root.lines.length > before + 1)
                                 root.next()
                             })
                         })
        })
    }

    function refuseBadPin() {
        // The service's own guard, from the other side: a control wired to the
        // wrong value must not be able to assemble a command. lid.js returns
        // null for the argv and the service refuses; nothing reaches the stub.
        root.readLog(function () {
            const before = root.lines.length
            const took = LidService.setPin("on; rm -rf ~")
            root.check("the service refuses a pin that is not one of the three",
                       took === false)
            root.check("…and says which three",
                       LidService.lastError.indexOf("auto, on or off") >= 0,
                       LidService.lastError)
            root.settle(function () {
                root.readLog(function () {
                    root.eq("…and ran no command at all", root.lines.length, before)
                    root.next()
                })
            })
        })
    }

    // ── phase: guard ─────────────────────────────────────────────────────────
    //
    // A thermal guard on a DOCKED machine. The assertion is an ordering one and
    // it is a defect this suite's node half already found once: a guard suspend
    // is the driver releasing the inhibitor and calling `systemctl suspend`
    // ITSELF, so it fires docked or not, and a page that showed the docked
    // frame instead would tell an owner their lid does nothing while APEX was
    // suspending their laptop.

    function guardSteps() {
        return [
            function () { root.openPage(root.next) },
            root.assertGuardWins
        ]
    }

    function assertGuardWins() {
        root.eq("the decision is guard-suspend", LidService.decision.id, "guard-suspend")
        root.eq("the guard names itself", LidService.decision.guard, "thermal")
        root.check("the page says a suspend is coming",
                   root.showing("guard is about to suspend") !== null)
        root.check("…and which guard it is", root.showing("too hot") !== null)
        root.check("…and the docked frame did not stand in front of it",
                   root.showing("already ignores the lid") === null)
        root.check("the temperature reading is on screen",
                   root.showing("99.0 °C") !== null)
        root.next()
    }

    // ── phase: unreadable ────────────────────────────────────────────────────
    //
    // `apex` fails. This is the phase the TypeError at the top of this file
    // would be found in, and the runner treats any TypeError in the log as a
    // failure for exactly that reason.

    function unreadableSteps() {
        return [
            function () { root.openPage(root.next) },
            root.assertUnreadable
        ]
    }

    function assertUnreadable() {
        root.check("the sweep returned", LidService.checked)
        root.check("and it could not be read", !LidService.available)
        root.check("with a reason", LidService.unavailableReason !== "",
                   LidService.unavailableReason)

        // The shape of the failed status, which is the whole defence. try/catch
        // because before the fix that inspired it, this THROWS rather than
        // returning false.
        let shaped = false
        try {
            shaped = LidService.logind !== null
                && LidService.logind.actsKnown === false
                && LidService.decision !== null
                && LidService.decision.id === "unknown"
                && LidService.work !== null && LidService.work.text !== ""
                && LidService.thermal !== null && LidService.charge !== null
                && LidService.vpn !== null
                && LidService.report.period !== null
                && LidService.report.period.poweredDown.length === 0
                && LidService.report.period.skipped.length === 0
        } catch (e) {
            shaped = false
        }
        root.check("a failed read still hands the page every object it binds", shaped)

        // A calm machine and an unreadable one look identical and mean opposite
        // things. The page must say which.
        root.check("the page says the policy could not be read",
                   root.showing("could not be read") !== null)
        root.check("…and repeats the reason it was given",
                   root.showing(LidService.unavailableReason) !== null)
        root.check("…and does NOT claim the lid suspends as it always did",
                   root.showing("as it always did") === null)
        root.check("…and does NOT claim the work would keep running",
                   root.showing("keeps the work running") === null)
        root.check("…and draws no record it could not read",
                   root.showing("Powered down") === null)
        root.next()
    }

    // ── phase: pixels ────────────────────────────────────────────────────────
    //
    // Everything above is about the object tree. This one rasterises it: the
    // scene graph runs, the glyphs are shaped, and the result is handed to the
    // runner as a PNG for a second opinion. A page whose every binding is
    // correct and which paints nothing would pass every other assertion here.

    function pixelSteps() {
        return [
            function () { root.openPage(root.next) },
            root.grab
        ]
    }

    property bool grabDone: false
    property bool grabOk: false

    // The grab's `image` is a QImage and QML sees no width or height on one, so
    // this half asserts only what QML can actually answer (the callback ran,
    // and saveToFile returned true). The runner reads the geometry back off the
    // PNG with tests/lib/png-ink.py.
    function grab() {
        if (root.grabPath === "") {
            root.check("a path to grab into was given", false)
            root.next()
            return
        }
        const ok = root.page.grabToImage(function (result) {
            root.grabOk = result.saveToFile(root.grabPath)
            root.grabDone = true
        })
        root.check("grabToImage was accepted by the scene graph", ok === true)
        if (!ok) { root.next(); return }
        root.waitFor("the grab to come back",
                     function () { return root.grabDone },
                     function () {
                         root.check("the rasterised page was written out", root.grabOk)
                         root.next()
                     })
    }
}
