import QtQuick
import "../../../"
import "../"
import "../../../components/config"

// Config → Gaming  (roadmap P1-049, "understandable toggles")
//
// ── THE STATE THIS PAGE IS DESIGNED FOR ──────────────────────────────────────
//
// Not installed. Steam, gamescope and the overlay are on-demand `apex install`
// packages; a fresh APEX image has none of them, and the machine this page was
// written against had none of them. A Gaming page whose first screen is a row
// of switches would be offering to configure software that is not there, so the
// first thing here is what is missing and the one command that fixes it.
//
// The command is TEXT. Installing needs root, and this page raises no
// authentication prompt — the same rule BlueprintService follows for
// `sudo apex apply`, for the same reason: `apex` can report across a privilege
// boundary it cannot cross, and a button here that ran sudo would throw that
// away.
//
// ── WHY THERE IS NO "OPTIMISE AUTOMATICALLY" SWITCH ──────────────────────────
//
// P1-049 asks for one. `apex mode set --auto` is documented one-shot — "APEX
// ships nothing that re-evaluates this on a timer", and `apex workload` says it
// again — so a switch with that label would promise a daemon that deliberately
// does not exist, and would keep promising it every time the user looked at the
// page. What is offered instead is the choice itself, with the mode the machine
// is actually in read back underneath it. A switch that lies is worse than a
// button that is honest about being a button.
//
// ── WHAT IS NOT HERE YET, AND WHY ────────────────────────────────────────────
//
// Criterion 2 also names VRR, background-update suppression and per-game
// profiles. `apex game profile` exists and the other two have no verb at all.
// None of the three is stubbed with a control that does nothing: a switch whose
// backend is missing reads exactly like one whose backend is broken, and this
// page would rather be short than pretend.
CfgScroll {
    id: root

    // Criterion 1 of P0-023. Live: pressing a control here changes the machine
    // now, and there is nothing to save afterwards — the mode is derived from
    // what the daemon reports rather than written to a file.
    lifecycle: "live"
    lifecycleError: GamingService.lastError

    Component.onCompleted: GamingService.refresh()

    readonly property bool usable: GamingService.available && GamingService.loaded

    // ── The CLI is not on this image ──────────────────────────────────────────
    CfgSection {
        title: "Gaming"
        first: true
        visible: GamingService.loaded && !GamingService.available

        CfgRow {
            label: "Not available on this image"
            description: GamingService.unavailableReason
            hoverable: false
        }
        CfgRow {
            label: "Try again"
            description: "Re-runs `apex gaming`"
            CfgButton {
                label: "Retry"
                onClicked: GamingService.refresh()
            }
        }
    }

    // ── Where this machine stands ─────────────────────────────────────────────
    CfgSection {
        title: "Gaming Mode"
        first: !(GamingService.loaded && !GamingService.available)
        visible: root.usable

        CfgRow {
            label: GamingService.readiness
            description: "Gaming Mode logs you out and back in with just the " +
                         "game on screen, driven by a controller. Your games " +
                         "still run on the normal desktop either way — this is " +
                         "about the separate, controller-first way in."
            hoverable: false
        }
        CfgRow {
            label: "At the login screen"
            description: GamingService.preselected === ""
                ? "Which session is preselected could not be read."
                : "\"" + GamingService.preselected + "\" is preselected right now."
            hoverable: false
            visible: GamingService.preselected !== ""
        }
        CfgRow {
            label: "Controllers"
            description: GamingService.gamepads.length === 0
                ? "Nothing attached that reports gamepad buttons. Big Picture " +
                  "still works with a keyboard."
                : GamingService.gamepads.length + " attached."
            hoverable: false
        }
    }

    // ── What is missing ───────────────────────────────────────────────────────
    // The section this page exists to get right. Each package says what it is
    // for, because "mangoapp: no" is not something anybody can act on.
    CfgSection {
        title: "Not installed yet"
        visible: root.usable && GamingService.missing.length > 0

        Repeater {
            model: GamingService.missing

            delegate: CfgRow {
                required property var modelData
                label: modelData.label
                description: modelData.why
                status: "missing"
                statusWarns: true
                hoverable: false
            }
        }

        CfgRow {
            label: "Install them"
            description: GamingService.installLine +
                         "  —  run it in a terminal. Installing needs an " +
                         "administrator, and this page does not ask for one."
            hoverable: false
        }
    }

    // ── What the CLI says is stopping it ──────────────────────────────────────
    // Verbatim. These are the sentences the session launcher prints when it
    // refuses to start, and rewriting them here would give the user two
    // different explanations of one failure.
    CfgSection {
        title: "Why it would not start"
        visible: root.usable && GamingService.blockers.length > 0

        Repeater {
            model: GamingService.blockers

            delegate: CfgRow {
                required property var modelData
                label: String(modelData)
                hoverable: false
            }
        }
    }

    CfgSection {
        title: "Worth knowing"
        visible: root.usable && GamingService.warnings.length > 0

        Repeater {
            model: GamingService.warnings

            delegate: CfgRow {
                required property var modelData
                label: String(modelData)
                hoverable: false
            }
        }
    }

    // ── The one control ───────────────────────────────────────────────────────
    // Criterion 1, in the shape the CLI can actually keep, and criterion 7: the
    // readout under it is re-measured after every switch rather than set from
    // what was clicked.
    CfgSection {
        title: "Performance while you play"
        visible: root.usable

        CfgRow {
            label: "What this machine is set to now"
            description: GamingService.policyLine === ""
                ? "Reading the current mode…"
                : GamingService.policyLine
            hoverable: false
        }

        Repeater {
            model: GamingService.offered

            delegate: CfgRow {
                required property var modelData
                label: modelData.label
                description: modelData.blurb
                CfgButton {
                    label: GamingService.mode === modelData.value ? "In use" : "Use"
                    enabled: !GamingService.switching
                             && GamingService.mode !== modelData.value
                    onClicked: GamingService.setMode(modelData.value)
                }
            }
        }

        CfgRow {
            label: "It stays where you put it"
            description: "APEX does not switch modes for you while you work, " +
                         "and nothing on this page runs on a timer. Set it back " +
                         "to Everyday when you have finished playing."
            hoverable: false
        }
        CfgRow {
            label: "That did not work"
            description: GamingService.switchError
            hoverable: false
            visible: GamingService.switchError !== ""
        }
    }

    // ── Advanced ──────────────────────────────────────────────────────────────
    // Criterion 4. The setup checks are here rather than above because none of
    // them is fixed by installing a package: they are files an image ships, so a
    // reader can see what is missing and nobody is invited to fix it from a
    // settings page.
    CfgSection {
        title: "Advanced"
        visible: root.usable

        CfgRow {
            label: "How the machine is set up for Gaming Mode"
            description: "These come from the image, not from anything you can " +
                         "install. They are here so you can see what a machine " +
                         "is missing without opening a terminal."
            hoverable: false
        }

        Repeater {
            model: GamingService.setupChecks

            delegate: CfgRow {
                required property var modelData
                label: modelData.label
                description: modelData.source
                status: modelData.passed ? "present" : "absent"
                statusWarns: !modelData.passed
                hoverable: false
            }
        }

        // Anything the CLI reported that this build does not have a name for.
        // Listed by its raw key, which is ugly on purpose: a probe added on the
        // OS side shows up here looking unfinished rather than not showing up.
        Repeater {
            model: GamingService.otherChecks

            delegate: CfgRow {
                required property var modelData
                label: modelData.key
                description: "This version of APEX Shell has no description " +
                             "for this check.  " + modelData.source
                status: modelData.passed ? "present" : "absent"
                statusWarns: !modelData.passed
                hoverable: false
            }
        }

        CfgRow {
            label: "Check again"
            description: "Re-runs `apex gaming` and `apex mode status`"
            CfgButton {
                label: "Refresh"
                onClicked: GamingService.refresh()
            }
        }
    }
}
