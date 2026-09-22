import Quickshell
import Quickshell.Io
import QtQuick
import "./src"
import "./src/theme"
import "./src/services"
import "./src/nexus"

// ─────────────────────────────────────────────────────────────────────────────
// Behavioural test for the Display page's colour section (P1-041).
//
//     ./tests/run-colour-page-test.sh
//
// ── The engine here is a FAKE, and that is deliberate ────────────────────────
//
// The transaction suite next door runs the real /usr/libexec/apex-display-apply
// because the bug it guards is partly in the enumeration. This one must not.
// `color-assign` writes colord's own database at `normal` scope — the only
// scope a one-shot tool can use, because a `temp` device dies with the D-Bus
// client that made it — and `colormgr delete-device` does NOT remove the
// device-to-profile rows it leaves behind in /var/lib/colord/mapping.db. A
// suite that ran the real verb would silently accumulate assignments in the
// developer's own colour database, and there is no HOME or PATH that isolates
// a system D-Bus service. So the engine is a script in a sandbox that logs its
// argv, and every claim below is about what the shell ASKED FOR.
//
// ── Two engines, because the shell must survive the older one ────────────────
//
// APEX Shell and the OS image land independently, and this page ships before
// the image that answers it. The engine's argparse has the verbs in a `choices`
// list, so an engine that predates them answers `color` with exit 2 and
// "invalid choice" — which is why the shell probes `--help` first and why the
// legacy phase's central assertion is a NEGATIVE one: the call log must contain
// no colour verb at all. A page that asked and handled the failure would still
// have put an error on the screen of every machine running an older image.
//
//   modern   --help lists color-assign; `color` prints fixture JSON
//   legacy   --help lists neither; `color` exits 2, as argparse would
//
// ── Why it builds the real page ──────────────────────────────────────────────
//
// One assertion cannot be made any other way. The engine's reason is ~300
// characters, and CfgRow's description is `maximumLineCount: 2` with
// ElideRight — so a reason put in a row is shown as its first two lines and an
// ellipsis. The page would then claim to state the engine's reason while
// hiding the half that says the assignment never reaches the screen. `Text`
// answers `truncated` itself, so the page is built at a real width and asked.
// A grep for the binding cannot tell those two pages apart.
//
// It opens no window: the page is built inside a plain Item, which is enough to
// construct every object, run every binding and lay out every line of text.
// ─────────────────────────────────────────────────────────────────────────────

ShellRoot {
    id: root

    property int passed: 0
    property int failed: 0

    function check(name, cond) {
        if (cond) { root.passed++; console.log("  PASS  " + name) }
        else      { root.failed++; console.log("  FAIL  " + name) }
    }

    readonly property string phase: Quickshell.env("APEX_COLOUR_PHASE") || "modern"
    readonly property bool modern: root.phase === "modern"
    readonly property string callLog:    Quickshell.env("APEX_COLOUR_CALLS")  || ""
    readonly property string reasonPath: Quickshell.env("APEX_COLOUR_REASON") || ""

    // The engine's sentence, read from the same file the fake engine's JSON was
    // built from. Compared byte for byte: "the page paraphrases it well" is not
    // the property being tested.
    property string wantReason: ""
    property var    wantTitles: []
    property string calls: ""

    // ── A serial shell helper ────────────────────────────────────────────────
    // One command at a time, callback with stdout. The callback runs off a
    // short timer rather than straight out of onExited so a stdout collector
    // that finishes after the exit still lands first.
    property string _shOut: ""
    property var    _shCb: null

    property Process _sh: Process {
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._shOut = text }
        onExited: function (code) { _shSettle.restart() }
    }

    property Timer _shSettle: Timer {
        interval: 40
        onTriggered: {
            const cb = root._shCb
            root._shCb = null
            if (cb) cb(root._shOut)
        }
    }

    function sh(cmd, cb) {
        root._shOut = ""
        root._shCb = cb
        root._sh.command = ["bash", "-c", cmd]
        root._sh.running = true
    }

    function readCalls(cb) {
        root.sh("cat '" + root.callLog + "' 2>/dev/null || true", function (out) {
            root.calls = out
            cb(out)
        })
    }

    /// Lines of the fake engine's log whose first field is `verb`.
    function callsFor(verb) {
        const out = []
        const lines = root.calls.split("\n")
        for (let i = 0; i < lines.length; i++) {
            const l = lines[i].trim()
            if (l === "") continue
            if (l === verb || l.indexOf(verb + " ") === 0) out.push(l)
        }
        return out
    }

    // ── The page under test ──────────────────────────────────────────────────
    // Through PageRegistry rather than by importing the file, so the shipped
    // registration is on the path too: a page that is not registered is not a
    // broken page, it is a shell that does not start.
    Item {
        id: host
        // The width the page really gets, not a generous one. Nexus's card is
        // `Math.min(parent.width - 80, 920)` with a 240-wide NavPane beside it,
        // so 680 is the widest a settings page is ever laid out at and every
        // real screen gives it less.
        //
        // This is load-bearing. At 900 the engine's ~300-character reason fits
        // inside CfgRow's two-line limit, so `truncated` came back false and
        // the mutant that put the reason in a row description passed the
        // behavioural suite. A test width wider than the product is a test that
        // agrees with itself.
        width:  680
        height: 620

        Loader {
            id: pageLoader
            anchors.fill: parent
            // VISIBLE, unlike tests/settings-pages-test.qml's loaders, and the
            // difference is the point. Item.visible is EFFECTIVE visibility: it
            // is false whenever any ancestor is invisible, whatever the item's
            // own binding says. Under an invisible loader every section in the
            // page answers `visible === false`, so "the colour section is shown
            // when the engine has colour" cannot fail and "it is hidden when
            // the engine has none" passes for the wrong reason. That is exactly
            // what the first run of this suite did.
            //
            // Nothing is drawn by making it true: this file opens no window,
            // and an item with no window has nothing to render into.
            visible: true
            sourceComponent: {
                const ps = PageRegistry.pages
                for (let i = 0; i < ps.length; i++)
                    if (ps[i].id === "display") return ps[i].component
                return null
            }
        }
    }

    // ── Walking the built page ───────────────────────────────────────────────
    // By what an object IS, not where it sits: the section nesting is the
    // page's own business and a path expression would break on the next edit.
    function collect(obj, has, out) {
        if (!obj) return out
        if (obj[has] !== undefined) out.push(obj)
        const kids = obj.children
        if (kids)
            for (let i = 0; i < kids.length; i++)
                root.collect(kids[i], has, out)
        return out
    }

    /// Every Text in the page. `truncated` is a Text property and nothing else
    /// in the tree has one, which makes it the predicate as well as the answer.
    function textsIn(page) { return root.collect(page, "truncated", []) }

    function sectionTitled(page, title) {
        const found = root.collect(page, "title", [])
        for (const o of found)
            if (o.title === title) return o
        return null
    }

    function textShowing(page, needle) {
        const ts = root.textsIn(page)
        for (const t of ts)
            if (typeof t.text === "string" && t.text.indexOf(needle) >= 0) return t
        return null
    }

    function textExactly(page, want) {
        const ts = root.textsIn(page)
        for (const t of ts)
            if (t.text === want) return t
        return null
    }

    // ── The step driver ──────────────────────────────────────────────────────
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
        root._waitTicks = maxTicks || 150      // ticks are 100 ms
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

    /// A short settle, for the cases where the claim is that NOTHING happened.
    /// A negative asserted immediately is a negative about scheduling.
    ///
    /// Its own timer and not waitFor with a predicate that never comes true:
    /// waitFor records a FAILED assertion when it gives up, which is right for
    /// a wait and wrong for a pause. The first version of this did that and put
    /// three "waited for: a moment to pass" failures in a green suite.
    property var _settleThen: null
    function settle(then) {
        root._settleThen = then
        _settler.restart()
    }

    property Timer _settler: Timer {
        interval: 800
        onTriggered: {
            const then = root._settleThen
            root._settleThen = null
            if (then) then()
        }
    }

    property string assignedId: ""
    property int callsBeforeAssign: 0

    Component.onCompleted: {
        console.log("[colour-page] phase=" + root.phase
                    + " engine=" + DisplayService.engine)

        root.steps = [
            // ── The page is built and the probe has answered ─────────────────
            function () {
                root.check("the Display page builds", pageLoader.item !== null)
                // DisplayPage's own Component.onCompleted calls refresh(), and
                // the colour section's calls refreshColour(). Nothing here asks
                // for either: whether the page asks is part of the claim.
                root.waitFor("the engine to be probed",
                             function () { return DisplayService.engineProbed },
                             root.next)
            },

            function () {
                root.sh("cat '" + root.reasonPath + "' 2>/dev/null || true",
                        function (out) { root.wantReason = out; root.next() })
            },

            // ── The probe's verdict ──────────────────────────────────────────
            function () {
                if (root.modern) {
                    root.check("the probe finds the colour verbs in --help",
                               DisplayService.engineCanColour === true)
                    root.waitFor("the colour state to be read",
                                 function () { return DisplayService.colourProfiles.length > 0 },
                                 root.next)
                    return
                }
                root.check("the probe refuses colour on an engine whose --help has none",
                           DisplayService.engineCanColour === false)
                root.settle(root.next)
            },

            // ── What the shell asked the engine for ──────────────────────────
            function () {
                root.readCalls(function () {
                    const colour = root.callsFor("color")
                    const assign = root.callsFor("color-assign")
                    if (root.modern) {
                        root.check("the shell ran the color verb once the probe allowed it",
                                   colour.length - assign.length >= 1)
                    } else {
                        // The point of the probe, and the only assertion that
                        // could have caught the bug: not "the failure is
                        // handled" but "the failing call is never made".
                        root.check("no colour verb is run against an engine that would reject it",
                                   colour.length === 0)
                        root.check("an unsupported engine is not reported as an error",
                                   DisplayService.colourError === "")
                        root.check("nothing is claimed about a curve the engine never described",
                                   DisplayService.curveReason === "")
                        root.check("no profiles are offered by an engine that lists none",
                                   DisplayService.colourProfiles.length === 0)
                    }
                    root.next()
                })
            },

            // ── The engine's JSON, carried and not recomputed ────────────────
            function () {
                if (!root.modern) { root.next(); return }

                root.check("colord's reachability is taken from the engine",
                           DisplayService.colordAvailable === true)
                // The finding this whole section exists for: colord runs, has
                // profiles, and had no devices. Zero is a number the page has
                // to be able to say.
                root.check("the registered-device count is read (0 on APEX)",
                           DisplayService.colordRegistered === 0)

                const ps = DisplayService.colourProfiles
                root.check("every profile the engine offered is offered on",
                           ps.length === 6)
                root.wantTitles = ps.map(function (p) { return p.title })

                // vcgt has THREE answers and the shell must keep all three.
                // `false` is "there is no calibration in this file" and `null`
                // is "I cannot read this file", which are opposite things to
                // tell someone about their monitor profile — a service that
                // coerced either to a boolean would collapse them.
                let withCurve = 0, unreadable = 0
                for (const p of ps) {
                    if (p.vcgt === true) withCurve++
                    if (p.vcgt === null || p.vcgt === undefined) unreadable++
                }
                root.check("a profile that carries a gamma table is marked as one",
                           withCurve === 1)
                root.check("a profile whose file cannot be read is not called uncalibrated",
                           unreadable === 1)

                root.check("the curve reason is carried through byte for byte",
                           DisplayService.curveReason === root.wantReason
                           && root.wantReason.length > 200)
                root.check("a curve with no loader is reported as not loadable",
                           DisplayService.curveLoadable === false)

                const outs = DisplayService.colourOutputs
                root.check("both outputs arrive", outs.length === 2)
                const by = {}
                for (const o of outs) by[o.name] = o
                root.check("an output carries the EDID-derived colord device id",
                           !!by["eDP-1"]
                           && by["eDP-1"].device === "apex-display-LEN-MNG007QT1-2")
                root.check("an assigned profile is read back from the engine",
                           !!by["eDP-1"] && !!by["eDP-1"].profile
                           && by["eDP-1"].profile.title === "sRGB")
                root.check("an output with no profile says nothing else",
                           !!by["DP-2"] && !by["DP-2"].profile)
                root.check("the HDR verdict is per output, from its own EDID",
                           !!by["eDP-1"] && !!by["DP-2"]
                           && by["eDP-1"].hdr.static_metadata === false
                           && by["DP-2"].hdr.static_metadata === true)
                root.next()
            },

            // ── Assigning ───────────────────────────────────────────────────
            function () {
                if (!root.modern) { root.next(); return }
                root.readCalls(function () {
                    root.callsBeforeAssign = root.callsFor("color").length
                    // A profile with no gamma table on purpose. It is the case
                    // the user most needs told about — the assignment is real,
                    // colord has it, and there is no curve in the file to load
                    // even on a machine that could load one — and the engine
                    // says so in a note only this path produces.
                    const ps = DisplayService.colourProfiles
                    for (const p of ps)
                        if (p.title === "AdobeRGB1998") root.assignedId = p.id
                    root.check("the profile to assign is on offer",
                               root.assignedId !== "")
                    DisplayService.assignProfile("DP-2", root.assignedId)
                    root.waitFor("the assignment to be reported",
                                 function () { return DisplayService.colourNotice !== "" },
                                 root.next)
                })
            },

            function () {
                if (!root.modern) { root.next(); return }
                root.readCalls(function () {
                    const assign = root.callsFor("color-assign")
                    root.check("assigning runs color-assign with the output and the profile id",
                               assign.length === 1
                               && assign[0] === "color-assign DP-2 " + root.assignedId)
                    root.check("the engine's own note is what the page is given",
                               DisplayService.colourNotice.indexOf("is now the profile for DP-2") >= 0)
                    // The caveat, not just the success. A page that showed only
                    // "assigned" would leave a creator believing a calibration
                    // is in effect that is not even in the file.
                    root.check("the note keeps the engine's per-profile caveat",
                               DisplayService.colourNotice.indexOf("carries no vcgt") >= 0)
                    root.check("the engine's log prefix is not shown to the user",
                               DisplayService.colourNotice.indexOf("apex-display:") < 0)
                    root.next()
                })
            },

            // ── And the readback is believed ────────────────────────────────
            function () {
                if (!root.modern) { root.next(); return }
                root.waitFor("the new assignment to arrive from the engine",
                             function () {
                                 const outs = DisplayService.colourOutputs
                                 for (const o of outs)
                                     if (o.name === "DP-2" && o.profile
                                         && o.profile.id === root.assignedId)
                                         return true
                                 return false
                             },
                             function () {
                                 const outs = DisplayService.colourOutputs
                                 let dp2 = null
                                 for (const o of outs) if (o.name === "DP-2") dp2 = o
                                 root.check("the assigned profile is what the engine reports back",
                                            !!dp2 && !!dp2.profile
                                            && dp2.profile.title === "AdobeRGB1998")
                                 root.check("the output that was not assigned is unchanged",
                                            (function () {
                                                for (const o of outs)
                                                    if (o.name === "eDP-1")
                                                        return !!o.profile
                                                               && o.profile.title === "sRGB"
                                                return false
                                            })())
                                 // Optimism is how a page ends up showing a
                                 // profile that was never stored: the only
                                 // thing that knows what colord accepted is
                                 // the engine, so it is asked again. Counted
                                 // here rather than beside the assign, because
                                 // at that moment the readback is still in
                                 // flight and the count would be a race.
                                 root.readCalls(function () {
                                     root.check("the assignment is read back rather than assumed",
                                                root.callsFor("color").length
                                                > root.callsBeforeAssign)
                                     root.next()
                                 })
                             })
            },

            function () {
                if (!root.modern) { root.next(); return }
                root.readCalls(function () {
                    const before = root.callsFor("color-assign").length
                    DisplayService.assignProfile("DP-2", "")
                    DisplayService.assignProfile("", root.assignedId)
                    root.settle(function () {
                        root.readCalls(function () {
                            root.check("an assignment missing an output or a profile runs nothing",
                                       root.callsFor("color-assign").length === before)
                            root.next()
                        })
                    })
                })
            },

            // ── Assigning on an engine that cannot ──────────────────────────
            function () {
                if (root.modern) { root.next(); return }
                DisplayService.assignProfile("eDP-1", "some-profile-id")
                root.settle(function () {
                    root.readCalls(function () {
                        root.check("assigning on an unsupported engine says why",
                                   DisplayService.colourError !== "")
                        root.check("assigning on an unsupported engine runs nothing",
                                   root.callsFor("color-assign").length === 0)
                        root.next()
                    })
                })
            },

            // ── What is actually on the page ────────────────────────────────
            function () {
                const page = pageLoader.item
                const section = root.sectionTitled(page, "Colour")
                root.check("the page has a Colour section", section !== null)
                if (section === null) { root.next(); return }

                if (!root.modern) {
                    // Hidden rather than empty or apologetic: on an older image
                    // there is nothing the user could do here.
                    root.check("the Colour section is hidden on an engine without colour",
                               section.visible === false)
                    root.next()
                    return
                }

                root.check("the Colour section is shown when the engine has colour",
                           section.visible === true)

                const shown = root.textShowing(page, root.wantReason)
                root.check("the page states the engine's reason, verbatim",
                           shown !== null)
                // The four below are NOT guarded on `shown`, and that is the
                // point. They were, with `if (shown !== null) {`, and a mutant
                // that replaced the engine's reason with a sentence hardcoded
                // in the page made all four SILENTLY VANISH instead of failing
                // — the element is located BY ITS TEXT, so rewording the text
                // loses the element and takes its assertions with it. The
                // phase reported 32 passed where a green run reports 36, which
                // is above the runner's floor, so nothing noticed. The
                // verbatim check above did catch that particular mutation, but
                // a mutation that both reworded the reason AND clipped it
                // would have walked past the truncation assertions unopposed.
                // A conditional assertion is not an assertion; a missing
                // element fails these instead of skipping them.
                const gone = shown === null ? " (nothing on the page carries the reason)" : ""
                // THE assertion. In a CfgRow description this comes back
                // true, and the user is shown two lines and an ellipsis of
                // the reason their calibration is not on screen.
                root.check("the reason is not truncated where the user reads it" + gone,
                           shown !== null && shown.truncated === false)
                // And the two properties that made it true, asked of the
                // live element rather than of the source. These hold at any
                // width: `truncated` alone is a fact about this window's
                // geometry, and a wide enough test window would let a
                // two-line limit through.
                root.check("the element showing the reason elides nothing" + gone,
                           shown !== null && shown.elide === Text.ElideNone)
                root.check("the element showing the reason caps no line count" + gone,
                           shown !== null && shown.maximumLineCount > 100)
                root.check("the reason is laid out at a real width" + gone,
                           shown !== null && shown.width > 200 && shown.contentHeight > 0)
                root.check("the page says how many devices colord has registered",
                           root.textShowing(page, "0 device(s) registered") !== null)
                root.check("the page says how many profiles are installed",
                           root.textShowing(page, "6 display profile(s) installed") !== null)

                let missing = ""
                for (const t of root.wantTitles)
                    if (root.textExactly(page, t) === null) missing = t
                root.check("every offered profile is a control on the page"
                           + (missing !== "" ? " (missing " + missing + ")" : ""),
                           missing === "")
                root.next()
            },

            // ── The probe race, reproduced ──────────────────────────────────
            //
            // Last, because it resets the service's probe state. The page calls
            // refresh() and refreshColour() both, so a colour read arriving
            // while the --help probe is still in flight is the ordinary case —
            // and a service that only remembers the wait when it STARTED the
            // probe drops that read on the floor and leaves the section
            // permanently empty. It survives today only because
            // Component.onCompleted runs children before parents, which is not
            // a property to build a page on.
            //
            // Asking for the layout first and the colour second is exactly the
            // order that hides the bug from the page's own completion order.
            function () {
                if (!root.modern) { root.next(); return }
                DisplayService.colour = ({})
                DisplayService.engineCanColour = false
                DisplayService.engineProbed = false
                root.check("the reset left nothing behind to pass on",
                           DisplayService.colourProfiles.length === 0)
                DisplayService.refresh()            // starts the probe
                DisplayService.refreshColour()      // arrives while it is in flight
                root.waitFor("the raced colour read to be served",
                             function () { return DisplayService.colourProfiles.length > 0 },
                             function () {
                                 root.check("a colour read that raced the probe is still served",
                                            DisplayService.colourProfiles.length === 6)
                                 root.next()
                             })
            }
        ]
        root.next()
    }
}
