import Quickshell
import QtQuick
import "./src/theme"
import "./src/services"
import "./src/services/config_tab/pages"
import "./src/services/agents"

// The Always Unrestricted toggle, driven for real (P0-016, ROADMAP.md §42.1).
//
// Run through tests/run-agent-settings-test.sh, which stages this at the repo
// root, puts a FAKE pkcheck and a FAKE apex first on PATH, points
// XDG_CONFIG_HOME at a scratch directory holding a known agent.json, and hosts
// it on a headless compositor in a private XDG_RUNTIME_DIR.
//
// ── WHY A LIVE RUN AND NOT MORE GREPS ───────────────────────────────────────
//
// tests/check-agent-settings.sh reads the source and can prove the shape of
// the code. It cannot prove three things that only Qt can answer:
//
//   1. the page LOADS. Every type this feature adds is reached through
//      src/services/qmldir, and a missing entry there is not a broken page —
//      it is "AgentsPage is not a type" and the whole shell fails to start.
//   2. the write actually preserves the other five dimensions. The node test
//      proves nextConfig does; this proves the Process that runs it does, with
//      a real file on a real disk and a real `mv`.
//   3. pkcheck is invoked on exactly one of the two transitions. The fake
//      records every call, so switching OFF and then ON must leave exactly
//      ONE line in the log — zero would mean the password gate is not wired,
//      and two would mean disabling asks for one, which §42.1 forbids.
//
// ── NO REAL PASSWORD PROMPT, EVER ───────────────────────────────────────────
//
// The fake pkcheck exits 1 without asking anybody anything. That is the whole
// reason the decision and the prompt are separate: the rule about when to
// authenticate is testable, the dialog is not, and a test suite that raised a
// real polkit dialog would be unrunnable in CI and unwelcome on a desktop.
//
// It opens no window. The compositor is headless and private, and there is no
// PanelWindow or Window here at all — the components are instantiated inside a
// plain Item, which is enough to load and evaluate every binding.

ShellRoot {
    id: rootScope

    property int pass: 0
    property int fail: 0
    property int step: 0

    function ok(what)  { console.log("  PASS  " + what); rootScope.pass++ }
    function bad(what) { console.log("  FAIL  " + what); rootScope.fail++ }
    function check(what, cond) { if (cond) rootScope.ok(what); else rootScope.bad(what) }

    // ── the components load at all ────────────────────────────────────────────
    Item {
        id: stage
        width: 800
        height: 600

        AgentsPage { id: settingsPage; anchors.fill: parent }

        // Bound the way both real surfaces bind it, because the binding is
        // what criterion 9 rests on: the indicator has to follow the setting
        // without anybody telling it to. A hardcoded `visible: true` here
        // would test nothing at all.
        UnrestrictedBanner {
            id: liveBanner
            width: 400
            visible: AgentPolicyService.alwaysUnrestricted
        }
        SessionRow {
            id: sampleRow
            width: 400
            session: ({
                "id": 7, "agent": "claude", "program": "claude", "args": [],
                "cwd": "/home/tester/proj", "project": null, "project_name": "proj",
                "worktree": null, "state": "working", "detail": null, "paused": false,
                "sandbox": "unrestricted", "native": "bypass", "system": "none",
                "secrets": "brokered", "network": "open",
                "origin": "local_elevation_only",
                "pid": 1234, "started": 1000, "last_activity": 1000,
                "exit_code": null, "exit_signal": null
            })
        }
    }

    // ── the run ───────────────────────────────────────────────────────────────
    // A small state machine rather than nested timers: the file is read and
    // written asynchronously, so every step waits for the service to settle
    // instead of guessing how long a `mv` takes.
    Timer {
        id: driver
        interval: 200
        repeat: true
        running: true

        property int waited: 0

        onTriggered: {
            driver.waited++
            if (driver.waited > 100) {           // 20 seconds
                rootScope.bad("the run did not settle")
                rootScope.finish()
                return
            }
            if (!AgentPolicyService.loaded || AgentPolicyService.busy)
                return

            switch (rootScope.step) {
            case 0:
                // The staged file says unrestricted. If this is wrong, either
                // the path is not the one apex resolves or effectiveDefault is.
                rootScope.check("the staged unrestricted default is read back",
                                AgentPolicyService.defaultSandbox === "unrestricted")
                rootScope.check("the toggle reads as on",
                                AgentPolicyService.alwaysUnrestricted === true)
                rootScope.check("the banner is showing while it is on",
                                liveBanner.visible === true)
                rootScope.check("nothing refuses the change on this file",
                                AgentPolicyService.enableRefusal === "")
                rootScope.step = 1
                // Criterion 5: no password on the way out.
                AgentPolicyService.setAlwaysUnrestricted(false)
                driver.waited = 0
                return
            case 1:
                rootScope.check("switching off lands on the project sandbox",
                                AgentPolicyService.defaultSandbox === "project")
                rootScope.check("switching off reported no error",
                                AgentPolicyService.lastError === "")
                rootScope.check("the banner followed the setting down",
                                liveBanner.visible === false)
                rootScope.step = 2
                // Criterion 4: a password on the way in. The fake refuses it.
                AgentPolicyService.setAlwaysUnrestricted(true)
                driver.waited = 0
                return
            case 2:
                rootScope.check("a refused password changes nothing",
                                AgentPolicyService.defaultSandbox === "project")
                rootScope.check("a refused password is reported",
                                AgentPolicyService.lastError !== "")
                rootScope.check("the row shows the session's own mode, not the default",
                                sampleRow.sandboxMode === "unrestricted")
                rootScope.finish()
                return
            }
        }
    }

    function finish() {
        driver.running = false
        console.log("agent-settings: passed=" + rootScope.pass
                     + " failed=" + rootScope.fail)
        Qt.exit(rootScope.fail === 0 ? 0 : 1)
    }
}
