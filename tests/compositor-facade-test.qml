import Quickshell
import Quickshell.Io
import QtQuick
import "./src/components"
import "./src/services"
import "./src/nexus"
import "./src/popups"
import "./src"

// ─────────────────────────────────────────────────────────────────────────────
// Behavioural test for CompositorService — the §17 compositor adapter facade.
//
//     ./tests/run-compositor-facade-test.sh      (the live session)
//
// To exercise the labwc backend without rebooting into labwc, stage it and run
// it inside a nested one — the harness starts a filler toplevel, which this
// suite needs (see "the session precondition" below):
//
//     cp tests/compositor-facade-test.qml .facade.qml \
//       && ./tests/run-nested-labwc.sh .facade.qml 30; rm -f .facade.qml
//
// Exit status 0 = all assertions passed, 1 = at least one failed.
//
// ── This test runs against the LIVE compositor, so it never mutates it ───────
// It reads workspaces, windows and the focused title from whatever session is
// running it. It calls actions only where the capability under test is FALSE,
// to prove the refusal path, and those calls are no-ops by construction. It
// never focuses a workspace, moves a window, changes gaps, applies a shader,
// starts hyprsunset or enters a submap. A test suite that reconfigured the
// developer's desktop has happened here before and it is not happening again.
//
// What it proves:
//   1. A backend is selected and matches the detected compositor.
//   2. The capability map has exactly the schema keys and every value is a real
//      boolean, not an undefined that reads as false by accident.
//   3. An action whose capability is false returns false and spawns nothing.
//   4. Window and title tracking follow their backend's OWN refcount contract.
//   5. outputState()/inputState()/version() deliver a success and a failure
//      answer — the first two against stubs, so the result does not depend on
//      what this machine happens to have installed.
//
// ── What is backend-specific, and why that had to be said out loud ───────────
// This suite used to assert "windows are empty with no ref held" and "the title
// is the placeholder with no ref held" flatly, for every backend. Those encode
// HYPRLAND's refcount semantics as universal: Hyprland pays a `hyprctl` per
// refresh, so it genuinely starts empty and reverts when the last ref goes. On
// niri and labwc the same data arrives over a protocol the compositor pushes
// anyway, so both properties are live whether or not anyone asked — and those
// two assertions therefore FAILED there the moment a window existed, while
// "holding a windows ref produces a window list" failed if one did not. The two
// could not both pass, so the suite was Hyprland-only and did not admit it.
//
// So the assertions come in four kinds, and every one of them is labelled:
//
//   • Gated on CompositorService.windowsPolled / .titlePolled — the declared
//     cost model. Polled backends must empty on release; pushed backends must
//     already have the data before any ref is taken. Each branch asserts the
//     thing that would go red if the other contract were implemented.
//   • Gated on a capability (can.windows, can.workspaces, can.gaps, …). A
//     backend that cannot do something is asserted to say so, not skipped.
//   • The session precondition: at least one toplevel must exist, because
//     every window assertion below is empty-loop-vacuous without one. That is
//     a property of the SESSION and not of the facade — on the developer's
//     desktop it is whatever they had open; inside a nested labwc it is the
//     filler the harness starts. It is asserted rather than assumed, so an
//     empty session goes RED instead of passing over nothing.
//   • Backend-independent: the capability schema, the stub-driven state
//     contracts, and loading all four backend files.
// ─────────────────────────────────────────────────────────────────────────────

ShellRoot {
    id: root

    property int passed: 0
    property int failed: 0

    function check(name, cond) {
        if (cond) { root.passed++; console.log("  PASS  " + name) }
        else      { root.failed++; console.log("  FAIL  " + name) }
    }

    // The capability schema, duplicated on purpose: if CompositorService's own
    // _CAPS changes, this list must be updated deliberately rather than the test
    // silently following along and asserting nothing.
    readonly property var expectedCaps: [
        "workspaces", "workspaceSwitch", "specialWorkspace",
        "windows", "windowGeometry", "outputGeometry",
        "windowFocus", "windowMove", "windowClose",
        "overview", "accentBorder", "gaps", "tilingLayout",
        "keyboardInterception", "screenShader", "nightLight"
    ]

    // ── Refs, toggled by the phases below ────────────────────────────────────
    property bool wantWindows: false
    property bool wantTitle:   false

    ServiceRef { service: CompositorService.windowsRef; active: root.wantWindows }
    ServiceRef { service: CompositorService.titleRef;   active: root.wantTitle }

    // ── Stubs for the outputState()/inputState() contract ────────────────────
    readonly property string stubDir: Quickshell.env("XDG_RUNTIME_DIR") + "/apex-compositor-test"
    property bool stubsReady: false

    property Process _mkStubs: Process {
        command: ["bash", "-c",
            "set -e; d=\"$1\"; mkdir -p \"$d\"; " +
            "printf '#!/bin/sh\\necho \\x27[{\"name\":\"TEST-1\",\"enabled\":true}]\\x27\\n' > \"$d/ok\"; " +
            "printf '#!/bin/sh\\nexit 1\\n' > \"$d/fail\"; " +
            "chmod +x \"$d/ok\" \"$d/fail\"",
            "--", root.stubDir]
        running: false
        onExited: function (code) { root.stubsReady = (code === 0) }
    }

    property var outputResult: null
    property var inputResult:  null
    property var missingResult: null
    property var gapsResult:    null
    property var versionResult: null

    // The no-ref baseline, captured in phase 2 and compared in phases 3 and 7.
    // A pushed backend has to already have this data; a polled one must not.
    property int  noRefWindowCount: -1
    property string noRefTitle:     "<unread>"

    // ── Loading every backend, not only the selected one ─────────────────────
    readonly property var backendFiles: [
        "NullBackend.qml", "HyprlandBackend.qml", "NiriBackend.qml", "LabwcBackend.qml"
    ]
    property int probeIndex: 0

    property Loader probe: Loader { asynchronous: false }

    function probeBackends() {
        for (let i = 0; i < root.backendFiles.length; i++) {
            const f = root.backendFiles[i]
            root.probe.source = "src/services/compositor/" + f
            const item = root.probe.item
            check(f + " loads and constructs", item !== null)
            if (item === null) continue

            const caps = item.capabilities
            let complete = caps !== undefined && caps !== null
            let bools    = complete
            let extra    = false
            if (complete) {
                for (let j = 0; j < root.expectedCaps.length; j++) {
                    const k = root.expectedCaps[j]
                    if (!(k in caps))                complete = false
                    else if (typeof caps[k] !== "boolean") bools = false
                }
                // A key the schema does not know about is a typo that would
                // otherwise read as a silent false through the facade.
                const declared = Object.keys(caps)
                for (let m = 0; m < declared.length; m++)
                    if (root.expectedCaps.indexOf(declared[m]) === -1) extra = true
            }
            check(f + " declares every capability", complete)
            check(f + " declares them as booleans", bools)
            check(f + " declares no capability outside the schema", !extra)
        }
        root.probe.source = ""
    }

    // ── Phases ────────────────────────────────────────────────────────────────
    property int phase: 0

    property Timer driver: Timer {
        interval: 700
        repeat: true
        running: true
        onTriggered: root.step()
    }

    function step() {
        root.phase++
        switch (root.phase) {

        case 1: {
            // ── A backend is selected ────────────────────────────────────────
            check("a backend is loaded", CompositorService.backend !== null)
            check("the facade name matches detection",
                  CompositorService.name === Compositor.name)

            // ── The capability map is complete and strictly boolean ──────────
            const can  = CompositorService.can
            const keys = Object.keys(can)
            check("the capability map has exactly the schema keys",
                  keys.length === root.expectedCaps.length)

            let allPresent = true
            let allBool    = true
            for (let i = 0; i < root.expectedCaps.length; i++) {
                const k = root.expectedCaps[i]
                if (!(k in can))               allPresent = false
                if (typeof can[k] !== "boolean") allBool   = false
            }
            check("every schema capability is declared", allPresent)
            check("every capability is a real boolean, never undefined", allBool)

            // ── Refusal, proven only on the actions that cannot fire ─────────
            // Every action is called here EXCEPT the ones this backend can
            // actually perform. Calling a capable action to see it return true
            // is not a test, it is a live reconfiguration of the machine running
            // the suite: an earlier draft asserted `setGaps(0,0) === can.gaps`
            // and set the developer's Hyprland gaps to zero, because on Hyprland
            // that capability is true and the call went through.
            //
            // So the capable half is checked by shape — the method exists and is
            // callable — and never invoked.
            // setScreenShader and setNightLight are in here for the refusal
            // path and are unreachable on Hyprland for the same reason
            // setGaps(0, 0) is: on a capable backend the first would blank
            // every monitor for a moment (the shader apply cycles DPMS to
            // force a redraw) and the second would start hyprsunset on the
            // developer's desktop and leave it running.
            const actions = [
                ["specialWorkspace",     function () { return CompositorService.toggleSpecialWorkspace("x") }],
                ["windowMove",           function () { return CompositorService.moveWindowToWorkspace("x", 1) }],
                ["overview",             function () { return CompositorService.toggleOverview() }],
                ["accentBorder",         function () { return CompositorService.setAccentBorder("000000") }],
                ["gaps",                 function () { return CompositorService.setGaps(0, 0) }],
                ["keyboardInterception", function () { return CompositorService.setKeyboardInterception(true) }],
                ["screenShader",         function () { return CompositorService.setScreenShader("") }],
                ["nightLight",           function () { return CompositorService.setNightLight(true) }]
            ]

            let refusedCount  = 0
            let allRefused    = true
            let allDeclared   = true
            for (let a = 0; a < actions.length; a++) {
                const capName = actions[a][0]
                if (can[capName]) continue        // capable: never invoked
                refusedCount++
                if (actions[a][1]() !== false) allRefused = false
            }
            for (let b = 0; b < root.expectedCaps.length; b++)
                if (!(root.expectedCaps[b] in can)) allDeclared = false

            check("there is at least one incapable action to refuse", refusedCount > 0)
            check("every incapable action returns false and does nothing", allRefused)
            check("no capability is missing from the map", allDeclared)

            // ── State that must be inert where the capability is false ──────
            // A backend that cannot do a thing must not report having done it.
            // Both of these would go red on a backend that declared false and
            // then wired the property up anyway, which is how a hidden tile
            // ends up lit.
            check("no screen shader is reported without the capability",
                  can.screenShader || CompositorService.screenShader === "")
            check("night light is not reported active without the capability",
                  can.nightLight || CompositorService.nightLightActive === false)

            // displayName is how the About panel writes the compositor down.
            // "" means the null backend, and the caller falls back to
            // XDG_CURRENT_DESKTOP; anything else must be a real name.
            check("displayName is set exactly when there is an adapter",
                  CompositorService.name === ""
                      ? CompositorService.displayName === ""
                      : CompositorService.displayName !== "")

            root._mkStubs.running = true
            break
        }

        case 2: {
            // ── Refcounting, on this backend's own terms ─────────────────────
            // Baseline first, so phases 3 and 7 have something to compare
            // against, then the half of the contract that is observable with
            // no ref held.
            root.noRefWindowCount = CompositorService.windows.length
            root.noRefTitle       = CompositorService.focusedTitle

            if (CompositorService.windowsPolled) {
                // Enumeration costs a subprocess, so nothing may have run.
                check("a polled backend lists no windows with no ref held",
                      root.noRefWindowCount === 0)
            } else if (CompositorService.can.windows) {
                // The compositor pushes the list, so it is already there. This
                // is the assertion that goes red if somebody later gates a
                // pushed backend's list on windowsWanted — the failure the flat
                // "windows are empty with no ref held" could never catch,
                // because it asserted the opposite.
                check("a pushed backend already lists windows with no ref held",
                      root.noRefWindowCount > 0)
            } else {
                check("a backend without windows lists none, ref or not",
                      root.noRefWindowCount === 0)
            }

            if (CompositorService.titlePolled) {
                check("a polled backend reports the placeholder title with no ref held",
                      root.noRefTitle === "Desktop")
            } else if (CompositorService.can.windows) {
                // Same shape for the title. "Desktop" here would mean either
                // no focused window — which the session precondition in phase
                // 3 rules out — or a title that is in fact ref-gated.
                check("a pushed backend already reports the focused title with no ref held",
                      root.noRefTitle !== "Desktop")
            } else {
                check("a backend without windows reports the placeholder title",
                      root.noRefTitle === "Desktop")
            }

            root.wantWindows = true
            root.wantTitle   = true
            break
        }

        case 3: {
            // ── Live data with a ref held ───────────────────────────────────
            const w = CompositorService.windows
            if (CompositorService.can.windows) {
                // ── The session precondition ────────────────────────────────
                // Everything below loops over the window list, so all of it is
                // vacuous without at least one window. Whether one exists is a
                // property of the session and not of the facade: on a desktop
                // it is whatever the user had open, and inside a nested labwc
                // it is the filler run-nested-labwc.sh starts. Asserted, not
                // assumed, so an empty session is a FAILED run and not a green
                // one over an empty loop.
                check("the session provides at least one toplevel (precondition)",
                      w.length > 0)

                // Holding the ref is what MAKES the list exist on a polled
                // backend; on a pushed one it must not change it. Both halves
                // are asserted, so neither contract can be implemented by
                // accident.
                if (CompositorService.windowsPolled)
                    check("holding a windows ref produces a window list", w.length > 0)
                else
                    check("taking a windows ref does not change a pushed list",
                          w.length === root.noRefWindowCount)

                if (CompositorService.titlePolled)
                    check("holding a title ref produces the focused title",
                          CompositorService.focusedTitle !== "Desktop")
                else
                    check("taking a title ref does not change a pushed title",
                          CompositorService.focusedTitle === root.noRefTitle)

                let shaped = w.length > 0
                for (let i = 0; i < w.length; i++) {
                    const e = w[i]
                    if (!("handle" in e) || !("title" in e) || !("appId" in e)
                        || !("workspaceId" in e) || !("focused" in e))
                        shaped = false
                }
                check("every window carries the documented fields", shaped)

                if (CompositorService.can.windowGeometry) {
                    let anyBox = false
                    for (let j = 0; j < w.length; j++)
                        if (w[j].width > 0 && w[j].height > 0) anyBox = true
                    check("windowGeometry means real boxes, not zeros", anyBox)
                } else {
                    check("no windowGeometry means the picker script is empty",
                          CompositorService.windowBoxScript === "")
                }
            } else {
                check("a backend without windows reports an empty list",
                      w.length === 0)
            }

            if (CompositorService.can.workspaces) {
                const ws = CompositorService.workspaces
                check("workspaces are listed without any ref", ws.length > 0)

                // The bar builds its dots straight from these, and passes `ref`
                // back to focusWorkspace() without knowing whether it is an id,
                // an index or a list position. A missing field renders a blank
                // dot that does nothing when clicked.
                let shaped  = ws.length > 0
                let focused = 0
                for (let k = 0; k < ws.length; k++) {
                    const w = ws[k]
                    if (w.ref === undefined || w.occupied === undefined
                        || w.isFocused === undefined || w.isUrgent === undefined
                        || w.name === undefined)
                        shaped = false
                    if (w.isFocused) focused++
                }
                check("every workspace carries ref, occupied, focus and urgency", shaped)
                check("exactly one workspace is focused", focused === 1)

                // A fixed grid means the bar synthesises the empty slots; a
                // dynamic one means the list is already complete. Either is
                // fine, but 0 must mean dynamic and not "forgot to declare it".
                const slots = CompositorService.workspaceSlots
                check("workspaceSlots is a sane count",
                      slots === 0 || (slots >= ws.length && slots <= 64))
            } else {
                check("a backend without workspaces reports an empty list",
                      CompositorService.workspaces.length === 0)
            }

            // The layout indicator hides entirely without the capability, so an
            // empty name there is correct rather than a failed read.
            check("a layout name is present only where layouts exist",
                  CompositorService.can.tilingLayout
                      ? CompositorService.layouts.length > 0
                      : (CompositorService.layouts.length === 0
                         && CompositorService.layoutName === ""))

            check("the output picker script is present when advertised",
                  CompositorService.can.outputGeometry
                      ? CompositorService.outputBoxScript !== ""
                      : CompositorService.outputBoxScript === "")

            // ── The success contract for outputState() ──────────────────────
            check("the stubs were created", root.stubsReady)
            CompositorService.displayEngine = root.stubDir + "/ok"
            CompositorService.outputState(function (ok, data) { root.outputResult = [ok, data] })

            CompositorService.inputEngine = root.stubDir + "/fail"
            CompositorService.inputState(function (ok, data) { root.inputResult = [ok, data] })
            break
        }

        case 4: {
            // ── readGaps is a read, so it is safe to actually call ───────────
            // Unlike setGaps. It has to answer on every backend: (true, values)
            // where gaps are a runtime concept and (false, null) where they are
            // not, so a caller can tell "no gaps here" from "the read failed"
            // and decline to apply a change it could never undo.
            CompositorService.readGaps(function (ok, g) { root.gapsResult = [ok, g] })

            // ── version() is a read too ─────────────────────────────────────
            // It executes the compositor's own CLI, which is why it is a
            // callback and why it carries the same settle timer: `hyprctl`,
            // `niri` and `labwc` are all independently installable and a
            // missing one must answer (false, "") rather than hang the caller.
            CompositorService.version(function (ok, v) { root.versionResult = [ok, v] })

            // ── A helper that is not installed must still answer ─────────────
            // Not the same path as "exited non-zero": a missing binary never
            // starts, so there is no exit code and nothing collects stdout. The
            // callback has to be settled anyway or the caller waits forever —
            // and this is the realistic case, because apex-shell updates from
            // git while the helpers ship in the OS image.
            CompositorService.displayEngine = root.stubDir + "/does-not-exist"
            CompositorService.outputState(function (ok, data) { root.missingResult = [ok, data] })
            break
        }

        case 5: {
            check("readGaps always answers, capable or not",
                  root.gapsResult !== null
                  && (CompositorService.can.gaps
                        ? (root.gapsResult[0] === true
                           && root.gapsResult[1] !== null
                           && root.gapsResult[1].inner >= 0
                           && root.gapsResult[1].outer >= 0)
                        : (root.gapsResult[0] === false && root.gapsResult[1] === null)))

            check("a helper that cannot start still answers (false, null)",
                  root.missingResult !== null
                  && root.missingResult[0] === false
                  && root.missingResult[1] === null)

            // An adapted compositor answers with a version; the null backend
            // has no CLI to ask and answers (false, ""). Either way it answers
            // — a pending callback here would mean the About panel never shows
            // a WM row at all.
            check("version() always answers, adapted or not",
                  root.versionResult !== null
                  && (CompositorService.displayName !== ""
                        ? (root.versionResult[0] === true
                           && /^[0-9]+\.[0-9]+/.test(root.versionResult[1]))
                        : (root.versionResult[0] === false
                           && root.versionResult[1] === "")))
            break
        }

        case 6: {
            check("outputState delivers (true, parsed) on success",
                  root.outputResult !== null
                  && root.outputResult[0] === true
                  && root.outputResult[1] !== null
                  && root.outputResult[1][0].name === "TEST-1")

            check("inputState delivers (false, null) when the helper fails",
                  root.inputResult !== null
                  && root.inputResult[0] === false
                  && root.inputResult[1] === null)

            root.wantWindows = false
            root.wantTitle   = false
            break
        }

        case 7: {
            // ── Handing the refs back ───────────────────────────────────────
            // Polled backends must stop AND forget: a poller that "stopped" but
            // left its last result behind is the stale-data bug this refcount
            // exists to prevent. Pushed backends must be untouched by the
            // release, because there was nothing to stop.
            if (CompositorService.windowsPolled)
                check("releasing the windows ref clears the list",
                      CompositorService.windows.length === 0)
            else if (CompositorService.can.windows)
                check("releasing the windows ref leaves a pushed list intact",
                      CompositorService.windows.length > 0)

            if (CompositorService.titlePolled)
                check("releasing the title ref restores the placeholder",
                      CompositorService.focusedTitle === "Desktop")
            else if (CompositorService.can.windows)
                check("releasing the title ref leaves a pushed title intact",
                      CompositorService.focusedTitle !== "Desktop")

            // ── Every backend, not just the one that happens to be running ──
            // Only one backend is ever selected, so a typo in the other three
            // would sit undetected until somebody logged into that session.
            // Loading all four here parses and constructs each of them, which is
            // the whole class of error CI can catch without four compositors.
            //
            // Constructing a backend is safe, but no longer free: HyprlandBackend
            // reads `hyprctl getoption decoration:screen_shader` and `pgrep -x
            // hyprsunset` from Component.onCompleted so its screenShader and
            // nightLightActive properties are honest from the start. Both are
            // READS. Everything that costs more than that — window enumeration
            // and the focused title — is still gated on windowsWanted /
            // titleWanted, which nothing sets on these probes.
            root.probeIndex = 0
            root.probeBackends()
            break
        }

        default: {
            root.driver.running = false
            console.log("passed=" + root.passed + " failed=" + root.failed)
            Qt.exit(root.failed === 0 ? 0 : 1)
        }
        }
    }
}
