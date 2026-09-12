import Quickshell
import Quickshell.Io
import QtQuick
import "./src"
import "./src/theme"
import "./src/services"
import "./src/nexus"

// ─────────────────────────────────────────────────────────────────────────────
// Config → Privacy & Permissions, BUILT AND DRAWN. Run via
// tests/run-privacy-page-test.sh (roadmap P1-061, criteria 3 and 4).
//
// ── Why this file had to exist ──────────────────────────────────────────────
//
// P1-061 landed with three kinds of verification and none of them was a
// running page: qmllint proved the syntax (with a deliberately broken copy as
// the negative control), tests/permissions-test.js proved what permissions.js
// decides, and tests/check-privacy-ui.sh proved the wiring with 35 checks and
// 7 mutants. The round that landed it said so plainly rather than claiming the
// criterion: "PrivacyPage.qml has never been instantiated under a compositor."
//
// The first run of tests/run-popup-smoke.sh against this page found, in the
// first second, a defect all three had missed:
//
//     WARN scene: PrivacyPage.qml[176:-1]:
//         TypeError: Cannot read property 'brokered' of null
//
// `parseList` returned `session: null` for a report it could not read, the
// "What this session can broker" section binds `session.brokered.join(", ")`,
// and a binding inside an invisible section is still evaluated. Nothing static
// can see that: the property exists, the file parses, the wiring is correct,
// and the type is only wrong at runtime with one particular payload. That is
// the class of bug this file is for.
//
// ── It opens ONE window, and that is the point ──────────────────────────────
//
// A Column lays its children out in a polish pass, a polish pass is driven by
// a QQuickWindow, and without one every row keeps height 0 — so "the rows were
// laid out" could not fail. tests/agent-graph-render-test.qml and
// tests/nav-geometry-test.qml open one for the same reason.
//
// FloatingWindow, never PanelWindow, inside the private headless compositor
// the runner starts: WAYLAND_DISPLAY and DISPLAY are unset, XDG_RUNTIME_DIR is
// a fresh directory, and tests/lib/headless.sh aborts the run if the socket it
// ends up on is not inside that directory. No window reaches anybody's desk.
//
// ── The `apex` here is a STUB, and it has to be ─────────────────────────────
//
// `apex permissions revoke` WRITES: it puts `no` into the portal permission
// store or edits a `flatpak override`. A suite that ran the real command would
// take a camera or a microphone grant away from whoever is logged in, several
// times per run, and a page test is not worth that. The runner replaces the
// stub tests/lib/headless.sh already installs with one that answers
// `permissions list --json` from tests/fixtures/permissions-list.json and
// records every argv it is handed.
//
// That is also why the whole service goes through the CLI: a stub on PATH is
// the isolation, and anything that opened a socket or a D-Bus name directly
// would walk straight past it.
//
// ── Three phases ────────────────────────────────────────────────────────────
//
//   fixture      the captured report: 3 applications, 30 rows, 15 controls
//   unreadable   `apex` fails. The page must say so and must not throw
//   pixels       the built page is rasterised and the image inspected
//
// `unreadable` is the phase that caught the defect above, and it is the one
// worth keeping: an empty list and an unreadable machine look identical and
// mean opposite things, and this is the only test in the tree that renders the
// second one.
// ─────────────────────────────────────────────────────────────────────────────
ShellRoot {
    id: root

    readonly property string phase: Quickshell.env("APEX_PP_PHASE") || "fixture"
    readonly property string callLog: Quickshell.env("APEX_PP_CALLS") || ""
    readonly property string grabPath: Quickshell.env("APEX_PP_GRAB") || ""

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
    // By a property only the thing being looked for carries, never by index:
    // a delegate's position in `children` is whatever the component happens to
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

    /// Every application section. `app` is appSection's own readonly property.
    function sections() { return root.collect(root.page, "app", []) }

    /// Every capability row. `controls` is rowItem's own readonly property,
    /// and nothing else on this page has one.
    function rows() { return root.collect(root.page, "controls", []) }

    /// Every CfgButton. Three properties together, because `label` alone
    /// matches a CfgRow and `variant` alone would match anything else that
    /// grows one later.
    function buttons() {
        return root.collect(root.page, "press", []).filter(function (b) {
            return b.label !== undefined && b.variant !== undefined
        })
    }

    function buttonsIn(item) {
        return root.collect(item, "press", []).filter(function (b) {
            return b.label !== undefined && b.variant !== undefined
        })
    }

    function labelled(list, want) {
        return list.filter(function (b) { return b.label === want })
    }

    /// Every Text. `truncated` is QQuickText's, and no other element has it.
    function texts() { return root.collect(root.page, "truncated", []) }

    /// Visible Texts whose content starts with `prefix`. The count is what is
    /// asserted: "one row somewhere says where it came from" is not the
    /// criterion, "every row does" is.
    function textsStarting(prefix) {
        return root.texts().filter(function (t) {
            return t.visible && String(t.text).indexOf(prefix) === 0
        })
    }

    function showing(needle) {
        const ts = root.texts()
        for (let i = 0; i < ts.length; i++)
            if (ts[i].visible && String(ts[i].text).indexOf(needle) >= 0) return ts[i]
        return null
    }

    function sectionFor(id) {
        const ss = root.sections()
        for (let i = 0; i < ss.length; i++)
            if (ss[i].app && ss[i].app.id === id) return ss[i]
        return null
    }

    /// The one row for an application AND a capability.
    ///
    /// All three of app, capability and enforcer, because the fixture
    /// deliberately carries the same capability under two different enforcers
    /// — that pair IS the item — and two different applications under the same
    /// one. `camera` alone matches three rows and `camera`+`logind_acl`
    /// matches two: the Flatpak carrying devices=all and the native program,
    /// which is the correct answer and the reason the lookup has to name the
    /// app as well.
    function rowFor(appId, capability, enforcer) {
        const section = root.sectionFor(appId)
        if (!section) {
            root.check("a section for " + appId, false)
            return null
        }
        const hit = root.collect(section, "controls", []).filter(function (r) {
            return r.row && r.row.capability === capability && r.row.enforcer === enforcer
        })
        root.eq("exactly one " + appId + "/" + capability + "/" + enforcer + " row",
                hit.length, 1)
        return hit.length === 1 ? hit[0] : null
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

    /// A pause, not a wait. `waitFor` records a failure when it gives up,
    /// which is right for a wait and wrong for "let the polish pass run".
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
    /// `cat` through a Process rather than a FileView, for the reason
    /// tests/remote-pairing-page-test.qml gives for the same choice: the file
    /// is appended to by another process while this one runs, and a cached
    /// read returning stale bytes is indistinguishable from a command that
    /// never ran.
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
    // Through PageRegistry rather than by naming PrivacyPage directly, so the
    // registration is part of what is under test: a page that is not in the
    // registry cannot be opened from Nexus or from the Config tab, whatever
    // the file itself does.

    FloatingWindow {
        id: stage
        width:  980
        height: 760
        visible: true
        color:  "#101012"

        Loader {
            id: pageLoader
            anchors.fill: parent
            visible: true
            sourceComponent: {
                const ps = PageRegistry.pages
                for (let i = 0; i < ps.length; i++)
                    if (ps[i].id === "privacy") return ps[i].component
                return null
            }
        }
    }

    readonly property var page: pageLoader.item

    Component.onCompleted: {
        root.steps = root.phase === "unreadable" ? root.unreadableSteps()
                   : root.phase === "pixels"     ? root.pixelSteps()
                   : root.fixtureSteps()
        root.next()
    }

    // ── shared opening ───────────────────────────────────────────────────────

    function openPage(then) {
        root.check("the page is registered under 'privacy' and built", root.page !== null)
        if (!root.page) {
            console.log("")
            console.log("passed=" + root.passed + " failed=" + root.failed)
            Qt.exit(1)
            return
        }
        // Nothing has been asked of the machine yet. PermissionsService is
        // refcounted on `onScreen` precisely so that a page nobody is looking
        // at runs no `flatpak info` per installed application every thirty
        // seconds, and this is the assertion that says the gate holds.
        root.readLog(function () {
            root.eq("nothing was asked of apex before the page was shown",
                    root.lines.length, 0)
            root.page.onScreen = true
            root.waitFor("the first sweep to return",
                         function () { return PermissionsService.checked },
                         function () { root.settle(then) })
        })
    }

    // ── phase: fixture ───────────────────────────────────────────────────────

    function fixtureSteps() {
        return [
            function () { root.openPage(root.next) },
            root.assertHeader,
            root.assertRows,
            root.assertControls,
            root.assertLaidOut,
            root.pressNever,
            root.refuseUnrevocable
        ]
    }

    function assertHeader() {
        root.check("the report was readable", PermissionsService.available,
                   PermissionsService.unavailableReason)
        root.eq("three applications came back", PermissionsService.apps.length, 3)
        root.check("the header counts them on screen", root.showing("3 applications") !== null)
        root.check("the header names the session's desktop",
                   root.showing("Hyprland") !== null)

        // Which portal interfaces exist is a property of the LOGIN, and the
        // page's whole session section exists to say so. The fixture was
        // captured under `default=hyprland;gtk`, which reaches Camera and does
        // NOT reach Usb.
        const brokered = root.showing("ScreenCast")
        root.check("the brokered interfaces are on screen", brokered !== null)
        if (brokered) {
            root.check("…and Camera is among them",
                       String(brokered.text).indexOf("Camera") >= 0)
            root.check("…and Usb, which this session does not broker, is not",
                       String(brokered.text).indexOf("Usb") < 0)
        }

        root.eq("one section per application", root.sections().length, 3)
        root.check("the native program is flagged as one",
                   root.showing("A program installed outside a sandbox") !== null)
        root.next()
    }

    function assertRows() {
        const rs = root.rows()
        root.eq("every capability row was built", rs.length, 30)

        // Criterion 3 is "effective capabilities AND origin". These two counts
        // are that sentence, checked per row rather than per page: a page that
        // said it once in a header would satisfy a grep and not the criterion.
        root.eq("every row on screen says where the permission came from",
                root.textsStarting("from: ").length, 30)
        root.eq("every row on screen names its enforcer",
                root.textsStarting("· enforced by ").length, 30)

        // The pair the whole item exists for. `io.github.cosmic_utils.camera`
        // is a Flatpak carrying devices=all: it opens /dev/video0 directly and
        // the portal never sees the request, so its camera is enforced by
        // exactly what a native binary's is. The page must not draw those two
        // the same as the portal-brokered one.
        const brokeredCam = root.rowFor("com.spotify.Client", "camera", "portal_store")
        const directCam = root.rowFor("io.github.cosmic_utils.camera", "camera", "logind_acl")
        const nativeCam = root.rowFor("zed", "camera", "logind_acl")
        if (brokeredCam && directCam && nativeCam) {
            root.check("the brokered camera and the direct one do not read alike",
                       brokeredCam.row.headline !== directCam.row.headline,
                       brokeredCam.row.headline + " vs " + directCam.row.headline)
            // And the assertion in the other direction, which is the one the
            // whole item turns on: a Flatpak carrying devices=all and a native
            // binary have the SAME enforcer — the ACL logind writes on
            // /dev/video0 — so the page must draw them identically. A design
            // that split the world into sandboxed and unsandboxed would not.
            root.eq("the sandboxed-but-direct camera reads exactly like the native one",
                    directCam.row.headline, nativeCam.row.headline)
            root.eq("…and names the same enforcer",
                    directCam.row.enforcerLabel, nativeCam.row.enforcerLabel)
            root.eq("the direct one offers no control at all",
                    root.buttonsIn(directCam).length, 0)
            root.eq("nor does the native one", root.buttonsIn(nativeCam).length, 0)
        }
        root.next()
    }

    function assertControls() {
        const bs = root.buttons()

        // 5 store_deny rows × (Never + Ask again) + 5 context_edit rows ×
        // (Turn off) + the header's Re-check. Counted from the fixture rather
        // than from the page, so a page that dropped a button fails here.
        root.eq("Never appears once per store-backed row", root.labelled(bs, "Never").length, 5)
        root.eq("Ask again does too", root.labelled(bs, "Ask again").length, 5)
        root.eq("Turn off appears once per sandbox row", root.labelled(bs, "Turn off").length, 5)
        root.eq("Re-check is the only other button", root.labelled(bs, "Re-check").length, 1)
        root.eq("and there are no buttons besides those", bs.length, 16)

        // The negative that the page exists for. `zed` is a native program: the
        // machine can withdraw nothing from it alone, so there is NO control on
        // any of its ten rows — not a disabled one, which would invite the
        // owner to wonder what is broken about their machine.
        const zed = root.sectionFor("zed")
        root.check("the native program has a section", zed !== null)
        if (zed) {
            root.eq("…with ten rows", root.collect(zed, "controls", []).length, 10)
            root.eq("…and not one control on any of them", root.buttonsIn(zed).length, 0)
            root.check("…and it says why instead",
                       root.showing("nothing can withdraw") !== null)
        }

        // Criterion 4's other half: a control that CAN act says when the change
        // lands, beside the button rather than implied by it.
        root.check("a store-backed control says it lands at the next request",
                   root.showing("takes effect the next time the app asks") !== null)
        root.check("a sandbox control says it lands at the next launch",
                   root.showing("takes effect the next time the app starts") !== null)
        root.next()
    }

    function assertLaidOut() {
        // Constructed is not drawn. Every one of these numbers is zero in a
        // scene with no window, which is why this file opens one.
        root.check("the page has a size", root.page.width > 0 && root.page.height > 0,
                   root.page.width + "x" + root.page.height)

        const rs = root.rows()
        let flat = 0
        let tallest = 0
        for (let i = 0; i < rs.length; i++) {
            if (rs[i].height <= 0) flat++
            if (rs[i].height > tallest) tallest = rs[i].height
        }
        root.eq("no row was left with no height", flat, 0)
        root.check("the rows are as tall as their content", tallest > 20, "tallest " + tallest)

        // A Text whose paint size is zero is not on screen whatever its
        // `visible` says. Checked on the origin lines specifically, because
        // they are the criterion.
        const origins = root.textsStarting("from: ")
        let unpainted = 0
        for (let i = 0; i < origins.length; i++)
            if (origins[i].paintedWidth <= 0 || origins[i].paintedHeight <= 0) unpainted++
        root.eq("every origin line has actually been laid out", unpainted, 0)
        root.next()
    }

    function pressNever() {
        // The button, pressed. Not PermissionsService.revoke() called from
        // here: the wiring from a rendered control to the argv is the part a
        // node suite cannot see.
        const cam = root.rowFor("com.spotify.Client", "camera", "portal_store")
        if (!cam) { root.next(); return }
        const never = root.labelled(root.buttonsIn(cam), "Never")
        root.eq("the brokered camera row has a Never button", never.length, 1)
        if (never.length !== 1) { root.next(); return }

        never[0].press()
        root.waitFor("the revocation to be handed to apex",
                     function () { return !PermissionsService.busy },
                     function () {
                         root.readLog(function () {
                             const hit = root.matching("permissions revoke com.spotify.Client camera")
                             root.eq("pressing Never ran exactly that revocation", hit.length, 1)
                             root.check("…and it did not carry --forget",
                                        hit.length === 1 && hit[0].indexOf("--forget") < 0)
                             root.eq("…and nothing failed", PermissionsService.lastError, "")
                             root.next()
                         })
                     })
    }

    function refuseUnrevocable() {
        // The service's own guard, from the other side: a button wired to the
        // wrong row must not be able to assemble a revocation for something
        // the machine cannot perform. permissions.js returns null for the argv
        // and the service refuses; nothing reaches the stub.
        const zedRow = root.rows().filter(function (r) {
            return r.row && r.row.capability === "usb-device" && r.row.enforcer === "nothing"
                && r.row.state === "granted"
        })
        root.eq("the native program's usb row was found", zedRow.length, 1)
        if (zedRow.length !== 1) { root.next(); return }

        root.readLog(function () {
            const before = root.lines.length
            const took = PermissionsService.revoke(zedRow[0].row, "deny")
            root.check("the service refuses a row nothing can revoke", took === false)
            root.check("…and says so in the words the OS side gave it",
                       PermissionsService.lastError.indexOf("nothing to withdraw") >= 0,
                       PermissionsService.lastError)
            root.settle(function () {
                root.readLog(function () {
                    root.eq("…and ran no command at all", root.lines.length, before)
                    root.next()
                })
            })
        })
    }

    // ── phase: unreadable ────────────────────────────────────────────────────
    //
    // `apex` fails. This is the phase that found the TypeError quoted at the
    // top of this file, and the runner treats any TypeError in the log as a
    // failure for exactly that reason.

    function unreadableSteps() {
        return [
            function () { root.openPage(root.next) },
            root.assertUnreadable
        ]
    }

    function assertUnreadable() {
        root.check("the sweep returned", PermissionsService.checked)
        root.check("and it could not be read", !PermissionsService.available)
        root.check("with a reason", PermissionsService.unavailableReason !== "",
                   PermissionsService.unavailableReason)

        // The shape of the failed report, and the assertion the defect at the
        // top of this file went red on. `parseList` returned `session: null`,
        // the session section binds `session.brokered.join(", ")`, and a
        // binding inside an invisible section is still evaluated. try/catch,
        // because before the fix this THROWS rather than returning false.
        let shaped = false
        try {
            shaped = PermissionsService.session !== null
                && PermissionsService.session.brokered.length === 0
                && PermissionsService.session.summary !== ""
        } catch (e) {
            shaped = false
        }
        root.check("a failed read still hands the page a session it can render", shaped)

        // An empty list and an unreadable machine look identical and mean
        // opposite things. The page must say which.
        root.eq("no application section is drawn", root.sections().length, 0)
        root.eq("no capability row is drawn", root.rows().length, 0)
        root.eq("and no control", root.labelled(root.buttons(), "Never").length, 0)
        root.check("the page says nothing could be read",
                   root.showing("Nothing below this line was checked") !== null)
        root.check("…and repeats the reason it was given",
                   root.showing(PermissionsService.unavailableReason) !== null)
        root.check("…and does not claim the machine is clean",
                   root.showing("nothing to report") === null)
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

    // The grab's `image` is a QImage, and QML sees no width or height on one —
    // measured here rather than assumed: `result.image.width` came back
    // `undefined`, not 980. So this half asserts only what QML can actually
    // answer (the callback ran, and saveToFile returned true) and the runner
    // reads the geometry back off the PNG with tests/lib/png-ink.py. A size
    // taken from a property that is undefined would be a number nobody
    // measured, which is the failure tests/lib/headless.sh's mode handling
    // exists to prevent.
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
