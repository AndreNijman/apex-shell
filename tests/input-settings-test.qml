import Quickshell
import Quickshell.Io
import QtQuick
import "./src/services"
import "./src/services/config_tab"

// ─────────────────────────────────────────────────────────────────────────────
// Behavioural test for the Input settings service (P0-019 / UI-003).
//
//     ./tests/run-input-settings-test.sh
//
// The complaint was "changing Input configuration has no effect", and the
// reason it survived review is that a control which writes a file and runs a
// generator looks identical whether or not anything downstream reads what it
// wrote. So the assertions here are about what CANNOT happen:
//
//   * a control the running compositor cannot honour must be refused, not
//     written. Refused at the service, not only greyed out in the page —
//     greying out is presentation and can be forgotten;
//   * a VALUE the compositor has no spelling for must not be offered;
//   * a per-device setting must reach input.json keyed by the device's own
//     name, so it can mean "the external trackball" rather than "trackballs";
//   * the effective state must come back from the generator's read-back and
//     not be echoed from the model — a page that reads its own writes cannot
//     detect the failure this ticket is about.
//
// Nothing is mocked but the DEVICE LIST, which is a fixture so the assertions
// do not depend on what is plugged into the machine running them. The
// generator is the real /usr/libexec/apex-input-apply, the model is a real
// file in a sandbox HOME, and the compositor answers are the real ones for
// whichever XDG_CURRENT_DESKTOP the harness sets — it runs this file twice,
// once as labwc and once as niri, because the interesting refusals are niri's.
// ─────────────────────────────────────────────────────────────────────────────

ShellRoot {
    id: root

    property int passed: 0
    property int failed: 0

    // `detail` is printed only when the assertion fails. A diagnostic welded
    // into the name reads as noise on every passing run and is the first thing
    // someone deletes; one that appears only on a failure is there when it is
    // needed and invisible when it is not.
    function check(name, cond, detail) {
        if (cond) { root.passed++; console.log("  PASS  " + name); return }
        root.failed++
        console.log("  FAIL  " + name + (detail ? " — " + detail : ""))
    }

    readonly property string want: Quickshell.env("APEX_TEST_COMPOSITOR") || ""

    property string _shOut: ""
    property var _shCb: null

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

    // The generator is not fast: it runs `Hyprland --verify-config` and
    // `niri validate` on every apply before it replaces anything. A fixed sleep
    // long enough for that on a loaded machine is a slow suite, and one that is
    // not long enough is a flaky one that reports the PREVIOUS state as a
    // divergence. So wait for the service to say it has finished.
    property var _idleCb: null
    property Timer _idle: Timer {
        interval: 200
        repeat: true
        running: false
        property int tries: 0
        onTriggered: {
            tries++
            if (!InputService.applying || tries > 150) {
                running = false
                const cb = root._idleCb
                root._idleCb = null
                if (cb) cb()
            }
        }
    }
    function whenIdle(cb) {
        root._idleCb = cb
        root._idle.tries = 0
        root._idle.running = true
    }

    // Apply finishes with its own read-back, so this waits for that to land
    // rather than firing a second one and racing it.
    function afterApply(cb) {
        root.sh("sleep 1", function () {          // let the write timer fire
            root.whenIdle(function () {
                root.sh("sleep 2", cb)            // let the read-back land
            })
        })
    }

    function model(cb) {
        root.sh("cat '" + InputService.modelPath + "' 2>/dev/null || echo '{}'",
                function (out) {
                    let parsed = {}
                    try { parsed = JSON.parse(out.trim() || "{}") } catch (e) { parsed = {} }
                    cb(parsed)
                })
    }

    // ── The steps ────────────────────────────────────────────────────────────
    property int _step: 0
    property var steps: []
    function next() {
        if (root._step >= root.steps.length) {
            console.log("")
            console.log("passed=" + root.passed + " failed=" + root.failed)
            Qt.exit(root.failed === 0 ? 0 : 1)
            return
        }
        const fn = root.steps[root._step]
        root._step++
        fn()
    }

    // The service starts three Processes on construction, and NOTHING below can
    // be asked until they have answered. So this timer is the only thing that
    // starts the run — an onCompleted that also called next() would race it and
    // run the whole suite against an empty capability table, where every
    // "supported" answer is the not-asked-yet default and every assertion about
    // a refusal passes for the wrong reason.
    property Timer _settle: Timer {
        interval: 200
        repeat: true
        running: true
        property int tries: 0
        onTriggered: {
            tries++
            const ready = InputService.compositor !== ""
                       && InputService.devices.length > 0
                       && InputService.loaded
            if (ready || tries > 75) {
                running = false
                root.next()
            }
        }
    }

    Component.onCompleted: {
        root.steps = [
            // ── what the running compositor is ───────────────────────────────
            function () {
                root.check("the service learned which compositor is running",
                           InputService.compositor === root.want)
                root.check("the capability table arrived",
                           InputService.capabilities.controls !== undefined)
                root.next()
            },

            // ── a control the compositor cannot honour ───────────────────────
            function () {
                if (root.want === "niri") {
                    root.check("niri: three-finger drag is reported unsupported",
                               !InputService.supported("threeFingerDrag"))
                    root.check("niri: the reason is a sentence, not an option name",
                               InputService.reasonFor("threeFingerDrag").length > 15
                               && InputService.reasonFor("threeFingerDrag").indexOf("_") < 0)
                } else {
                    root.check("labwc: three-finger drag is supported",
                               InputService.supported("threeFingerDrag"))
                    root.check("labwc: a supported control has no reason to show",
                               InputService.reasonFor("threeFingerDrag") === "")
                }
                root.next()
            },

            // ── and it must be REFUSED, not merely greyed out ────────────────
            function () {
                const before = InputService.threeFingerDrag
                InputService.set("threeFingerDrag", !before)
                if (root.want === "niri") {
                    root.check("niri: setting an unsupported control changes nothing",
                               InputService.threeFingerDrag === before)
                    root.check("niri: the refusal says why",
                               InputService.lastNotes.indexOf("three-finger") >= 0)
                } else {
                    root.check("labwc: a supported control takes the value",
                               InputService.threeFingerDrag === !before)
                    root.check("labwc: nothing was refused",
                               InputService.lastNotes.indexOf("three-finger") < 0)
                    InputService.set("threeFingerDrag", before)
                }
                root.next()
            },

            // ── a value with no spelling is not offered ──────────────────────
            function () {
                const all = [
                    { value: "clickfinger", label: "Finger count" },
                    { value: "buttonAreas", label: "Button areas" },
                    { value: "none",        label: "Off" }
                ]
                const offered = InputService.optionsFor("clickMethod", all).map(o => o.value)
                if (root.want === "niri") {
                    root.check("niri: the click method with no button is not offered",
                               offered.indexOf("none") < 0 && offered.length === 2)
                    const before = InputService.clickMethod
                    InputService.set("clickMethod", "none")
                    root.check("niri: and it is refused if something asks anyway",
                               InputService.clickMethod === before)
                } else {
                    root.check("labwc: every click method is offered",
                               offered.length === 3)
                    root.check("labwc: the click method with no button is accepted",
                               InputService.valueSupported("clickMethod", "none"))
                }
                root.next()
            },

            // ── devices, distinguished by kind ───────────────────────────────
            function () {
                const kinds = InputService.configurableDevices.map(d => d.type)
                root.check("the fixture's five kinds of device are all present",
                           kinds.indexOf("touchpad") >= 0 && kinds.indexOf("mouse") >= 0
                           && kinds.indexOf("trackpoint") >= 0 && kinds.indexOf("tablet") >= 0
                           && kinds.indexOf("touchscreen") >= 0)
                root.check("a trackpoint is not filed as a mouse",
                           InputService.configurableDevices.filter(
                               d => d.name === "Fixture TrackPoint")[0].type === "trackpoint")
                root.check("the kernel's non-input devices are left out",
                           InputService.devices.length > InputService.configurableDevices.length)
                root.next()
            },

            function () {
                // A touchscreen has one setting and a touchpad has nine. The
                // page must not decide that; the generator's table does.
                const pad = InputService.deviceKeys["touchpad"] || []
                const screen = InputService.deviceKeys["touchscreen"] || []
                root.check("a touchpad's settings include tap and scroll method",
                           pad.indexOf("tap") >= 0 && pad.indexOf("scroll_method") >= 0)
                root.check("a touchscreen's do not",
                           screen.indexOf("tap") < 0 && screen.length >= 1)
                root.next()
            },

            // ── a per-device setting reaches the model, by name ──────────────
            function () {
                if (root.want === "niri") {
                    root.check("niri: per-device settings are reported unsupported",
                               InputService.perDeviceReason !== "")
                    root.check("niri: the reason says it configures by kind",
                               InputService.perDeviceReason.indexOf("kind") >= 0)
                    root.next()
                    return
                }
                root.check("labwc: per-device settings are supported",
                           InputService.perDeviceReason === "")
                InputService.setDevice("Fixture TrackPoint", "trackpoint", "speed", 0.7)
                root.afterApply(function () {
                    root.model(function (m) {
                        const d = (m.devices || {})["Fixture TrackPoint"] || {}
                        root.check("the override is written under the device's own name",
                                   d.speed === 0.7)
                        root.check("and carries the kind, so the generator can check it",
                                   d.type === "trackpoint")
                        root.next()
                    })
                })
            },

            // ── the effective state comes from the generator ─────────────────
            function () {
                InputService.set("tap", false)
                root.afterApply(function () {
                    root.check("the read-back arrived", InputService.readBackReady)
                    const seen = InputService.effectiveText("tap")
                    root.check("tap reads back as the value that was set",
                               seen.indexOf("off") === 0,
                               "read '" + seen + "', model has " + InputService.tap
                               + ", " + Object.keys(InputService.effective.values || {}).length
                               + " values, notes: " + InputService.lastNotes)
                    root.check("nothing is reported diverged after an apply",
                               InputService.diverged.length === 0,
                               JSON.stringify(InputService.diverged))
                    root.next()
                })
            },

            // ── and it is a READ, not an echo of the model ───────────────────
            function () {
                // Change the generated file behind the service's back. A
                // read-back that still agrees with the model is reading the
                // model.
                const target = root.want === "niri"
                    ? Quickshell.env("HOME") + "/.config/apex-shell/ApexShellInput.kdl"
                    : Quickshell.env("HOME") + "/.config/labwc/rc.xml"
                const edit = root.want === "niri"
                    ? "sed -i 's/^        drag true$/        drag false/' '" + target + "'"
                    : "sed -i 's|<tapAndDrag>yes</tapAndDrag>|<tapAndDrag>no</tapAndDrag>|' '" + target + "'"
                root.sh(edit, function () {
                    InputService.refreshEffective()
                    root.sh("sleep 3", function () {
                        root.check("a value changed behind the page is reported as diverged",
                                   InputService.divergedFrom("tapAndDrag"),
                                   "diverged: " + JSON.stringify(InputService.diverged))
                        root.next()
                    })
                })
            }
        ]
    }

    // A run that hangs is a run that reports nothing. The harness has its own
    // timeout; this one exists so the summary line is still printed.
    Timer {
        interval: 180000
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
