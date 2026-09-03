import QtQuick
import "../../../"
import "../../../components"
import "../../../components/config"
// src/services — the module whose qmldir hands out RecoveryService, reached
// the same way MiscPage reaches SystemStats.
import "../../"

// Config → Recovery. Roadmap §19's recovery surface, and the half of §25 that
// says recovery and rollback belong in normal UX rather than in expert
// documentation.
//
// ── Why this is a PAGE and not a section on Misc ─────────────────────────────
//
// §19 describes eight component rows, four actions, a route table and the
// doctor's results. That is not a row on somebody else's page. It is also the
// consumer `apex recover --help` already advertised — "safe for APEX Settings
// to poll" — and until this file existed that consumer was never written, so
// recovery had no graphical surface anywhere in the shell.
//
// It sits between Blueprint and Keybinds in PageRegistry: after the page that
// says what this machine should be, before the ones that tune it. Both hosts
// — the dashboard's Config tab and the Nexus window — read that registry, so
// it appears in both from one declaration.
//
// ── What this page is allowed to do ──────────────────────────────────────────
//
// Read-only by default. The two polled verbs are `apex recover status --json`
// and `apex doctor --json`; both are file reads on the OS side, neither can
// raise an authentication prompt, and nothing else is ever on a timer. Repair
// and factory reset are user-initiated only. Rollback is SHOWN as a command
// and never run, because running it means root and this shell raises no
// authentication prompt of its own — see RecoveryService's header.
//
// ── Ordering ─────────────────────────────────────────────────────────────────
//
// §19 lists [Repair automatically] [Boot previous deployment] [Factory reset]
// [Hardware diagnostics]. The sections here are ordered by consequence rather
// than by that list: what is wrong, what fixes it cheaply, what rolls the
// machine back, how to get in if it will not boot, what the hardware says —
// and the factory reset LAST, on its own, behind its own disclosure, because
// it is the most destructive verb in the product and nothing above it should
// put a finger near it.
CfgScroll {
    id: root

    // Set by ShellConfig and Nexus: "the Recovery page is genuinely on screen".
    // Declared because RecoveryService costs a subprocess per sweep and is
    // refcounted on it; PageRegistry marks this page needsScreen: true so both
    // hosts bind it. NOT `visible` — an Item inside a hidden window still
    // reports visible: true, which is how the stats page kept six pollers
    // running after the dashboard was closed.
    property bool onScreen: false

    // The factory reset's disclosure. Starts closed on every construction, so
    // a page that was left open never comes back open.
    property bool resetOpen: false

    // The whole of "no process runs while nobody is looking".
    ServiceRef {
        service: RecoveryService
        active:  root.onScreen
    }

    // Tone name -> Theme token. The names come from recovery.js, which has no
    // Theme and must not: it is driven by a node process in the test suite.
    // `available` and `unavailable` deliberately share `subtext` — docs
    // /recovery.md is explicit that neither is a synonym for "fine", so
    // neither may be green.
    function toneColor(tone) {
        if (tone === "ok")   return Theme.success
        if (tone === "warn") return Theme.warning
        return Theme.subtext
    }

    // ── Header ────────────────────────────────────────────────────────────────
    CfgSection {
        title: "Recovery"
        first: true

        Item {
            width:  parent.width
            height: Theme.px(62)

            Row {
                x: Theme.px(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.px(12)

                Text {
                    text:           "󰑙"
                    font.pixelSize: Theme.fs(28)
                    color: RecoveryService.needsAttention > 0 ? Theme.warning : Theme.active
                    anchors.verticalCenter: parent.verticalCenter
                }
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.px(3)

                    Text {
                        text: {
                            if (!RecoveryService.checked)  return "Checking this machine…"
                            if (!RecoveryService.available) return "The recovery surface is unavailable"
                            if (RecoveryService.needsAttention === 0)
                                return "Nothing needs attention"
                            return RecoveryService.needsAttention
                                + " component" + (RecoveryService.needsAttention === 1 ? "" : "s")
                                + " need attention"
                        }
                        font.pixelSize: Theme.fs(15)
                        font.weight:    Font.Medium
                        color:          Theme.text
                    }
                    Text {
                        text: RecoveryService.available
                            ? ("bootloader " + RecoveryService.status.bootloader
                               + "  ·  diagnostics: " + RecoveryService.doctorSummary)
                            : "`apex recover` is not on this machine, or predates this shell. Nothing below could be read."
                        font.pixelSize: Theme.fs(10)
                        color:          Theme.subtext
                        font.family:    "JetBrains Mono"
                    }
                }
            }

            CfgButton {
                anchors.right:          parent.right
                anchors.rightMargin:    Theme.px(8)
                anchors.verticalCenter: parent.verticalCenter
                label:   RecoveryService.busy ? "Checking…" : "Re-check"
                icon:    "󰑐"
                enabled: !RecoveryService.busy
                onClicked: RecoveryService.refresh()
            }
        }

        Text {
            x:     Theme.px(10)
            width: parent.width - Theme.px(20)
            text: "Everything on this page is read from the machine, not from a "
                + "cache. Checking it changes nothing and needs no password: "
                + "`apex recover status` and `apex doctor` read files. The two "
                + "verbs that do change something — repair, and the factory "
                + "reset — run only when you press them."
            font.pixelSize: Theme.fs(10)
            color:    Theme.subtext
            wrapMode: Text.WordWrap
        }
        Item { width: parent.width; height: Theme.px(6) }
    }

    // ── Components ────────────────────────────────────────────────────────────
    // The eight rows §19 names. Their ids are a compatibility surface on the OS
    // side; recovery.js orders by them and appends anything it does not know
    // rather than dropping it.
    CfgSection {
        title: "Components"
        visible: RecoveryService.available

        Repeater {
            // A COUNT, not the array. `model: <JS array>` recreates every
            // delegate whenever the array's contents change, and `state` and
            // `detail` change on every sweep — so all eight rows would be
            // destroyed and rebuilt every 20 seconds, which kills the colour
            // Behaviour below and flickers the list. See
            // src/modules/Left/Workspaces.qml, which measured this.
            model: RecoveryService.status.rows.length

            delegate: Item {
                id: compRow
                required property int index
                readonly property var row: RecoveryService.status.rows[compRow.index]

                width:  parent ? parent.width : 0
                height: compCol.implicitHeight + Theme.px(16)

                Rectangle {
                    anchors.fill: parent
                    radius: Theme.px(8)
                    color:  compHov.hovered ? Qt.rgba(1, 1, 1, 0.03) : "transparent"
                    Behavior on color { ColorAnimation { duration: 120 } }
                }
                HoverHandler { id: compHov }

                Text {
                    id: compIcon
                    x: Theme.px(10)
                    anchors.top:       parent.top
                    anchors.topMargin: Theme.px(9)
                    text:           RecoveryService.stateIcon(compRow.row ? compRow.row.state : "")
                    font.pixelSize: Theme.fs(13)
                    color:          root.toneColor(RecoveryService.stateTone(compRow.row ? compRow.row.state : ""))
                    Behavior on color { ColorAnimation { duration: 160 } }
                }

                Column {
                    id: compCol
                    anchors.left:        compIcon.right
                    anchors.leftMargin:  Theme.px(10)
                    anchors.right:       parent.right
                    anchors.rightMargin: Theme.px(10)
                    anchors.top:         parent.top
                    anchors.topMargin:   Theme.px(8)
                    spacing: Theme.px(3)

                    Row {
                        spacing: Theme.px(8)
                        Text {
                            text:           compRow.row ? compRow.row.label : ""
                            font.pixelSize: Theme.fs(12)
                            color:          Theme.text
                        }
                        Text {
                            text:           RecoveryService.stateLabel(compRow.row ? compRow.row.state : "")
                            font.pixelSize: Theme.fs(10)
                            font.weight:    Font.Medium
                            color:          root.toneColor(RecoveryService.stateTone(compRow.row ? compRow.row.state : ""))
                            anchors.verticalCenter: parent.verticalCenter
                            Behavior on color { ColorAnimation { duration: 160 } }
                        }
                    }
                    Text {
                        width:          parent.width
                        text:           compRow.row ? compRow.row.detail : ""
                        font.pixelSize: Theme.fs(10)
                        color:          Theme.subtext
                        wrapMode:       Text.WordWrap
                    }
                    // The command that addresses this row, when there is one.
                    // Shown rather than run: every one of them starts `sudo`.
                    Text {
                        visible:        compRow.row && compRow.row.action !== ""
                        width:          parent.width
                        text:           "→ " + (compRow.row ? compRow.row.action : "")
                        font.pixelSize: Theme.fs(10)
                        font.family:    "JetBrains Mono"
                        color:          Theme.active
                        wrapMode:       Text.WordWrap
                    }
                }
            }
        }
    }

    // ── Repair ────────────────────────────────────────────────────────────────
    // §19's [Repair automatically]. Every step apexd will offer here is
    // idempotent and removes no data — its own table test asserts that, and
    // that no step's argv contains `sudo`, `pkexec`, `su`, `run0` or
    // `systemd-run`. That is what makes one button defensible: pressing it
    // twice does nothing the second time, and pressing it by accident costs
    // nothing.
    CfgSection {
        title: "Repair"
        visible: RecoveryService.available

        CfgRow {
            label: "Automatic repair"
            description: {
                if (RecoveryService.repairPhase === "checking")  return "Looking for anything that can be fixed safely…"
                if (RecoveryService.repairPhase === "repairing") return "Repairing…"
                if (RecoveryService.repairMessage !== "")        return RecoveryService.repairMessage
                if (RecoveryService.repairPhase === "checked")
                    return RecoveryService.repairSteps.length === 0
                        ? "Nothing to repair: every component this can fix reports fine."
                        : (RecoveryService.repairSteps.length + " step(s) found")
                return "Idempotent, and removes nothing. Dry run first."
            }
            CfgButton {
                label:   RecoveryService.repairPhase === "checked"
                             && RecoveryService.repairHere.length > 0
                         ? "Repair now" : "Check"
                icon:    "󰅢"
                enabled: RecoveryService.repairPhase !== "checking"
                         && RecoveryService.repairPhase !== "repairing"
                variant: (RecoveryService.repairPhase === "checked"
                          && RecoveryService.repairHere.length > 0) ? "accent" : "default"
                onClicked: {
                    if (RecoveryService.repairPhase === "checked"
                        && RecoveryService.repairHere.length > 0)
                        RecoveryService.runRepairs()
                    else
                        RecoveryService.checkRepairs()
                }
            }
        }

        Repeater {
            model: RecoveryService.repairSteps.length

            delegate: Item {
                id: stepRow
                required property int index
                readonly property var step: RecoveryService.repairSteps[stepRow.index]

                width:  parent ? parent.width : 0
                height: stepCol.implicitHeight + Theme.px(12)

                Column {
                    id: stepCol
                    x: Theme.px(20)
                    width: parent.width - Theme.px(30)
                    anchors.top:       parent.top
                    anchors.topMargin: Theme.px(6)
                    spacing: Theme.px(2)

                    Text {
                        width:          parent.width
                        text:           (stepRow.step ? stepRow.step.what : "")
                        font.pixelSize: Theme.fs(11)
                        color:          Theme.text
                        wrapMode:       Text.WordWrap
                    }
                    Text {
                        width:          parent.width
                        text:           stepRow.step ? stepRow.step.whySafe : ""
                        font.pixelSize: Theme.fs(9)
                        color:          Theme.subtext
                        wrapMode:       Text.WordWrap
                    }
                    // A step in the other privilege domain is reported, never
                    // run. `apex apply` behaves the same way, and running it
                    // from here would mean an authentication prompt.
                    Text {
                        visible:        stepRow.step && !stepRow.step.runnableHere
                        width:          parent.width
                        text:           "→ " + RecoveryService.repairSystemCommand
                        font.pixelSize: Theme.fs(9)
                        font.family:    "JetBrains Mono"
                        color:          Theme.active
                        wrapMode:       Text.WordWrap
                    }
                }
            }
        }
    }

    // ── Rollback ──────────────────────────────────────────────────────────────
    // §19's [Boot previous deployment], and the half of §25 that says rollback
    // must not be CLI-only. There is no `apex recover previous` and there
    // should not be: docs/recovery.md is explicit that it would be a second
    // name for `apex rollback`. So this section makes the operation visible —
    // whether a target exists, what it costs, and the exact two commands —
    // rather than hiding root behind a button.
    CfgSection {
        title: "Roll back to the previous deployment"
        visible: RecoveryService.available

        Text {
            x:     Theme.px(10)
            width: parent.width - Theme.px(20)
            text:  RecoveryService.rollbackHint
            font.pixelSize: Theme.fs(10)
            color:    Theme.subtext
            wrapMode: Text.WordWrap
        }
        Item { width: parent.width; height: Theme.px(8) }

        CfgRow {
            label:       "Boot the previous deployment"
            description: "Run this in a terminal, then reboot. It needs root, so APEX Shell shows it instead of asking for a password."
            Text {
                text:           RecoveryService.rollbackCommand
                font.pixelSize: Theme.fs(11)
                font.family:    "JetBrains Mono"
                color:          Theme.active
            }
        }

        CfgRow {
            label:       "Keep the current one first"
            description: "bootc keeps only the booted and previous images, so two bad updates in a row can evict the last good one. Pinning stops that."
            Text {
                text:           RecoveryService.pinCommand
                font.pixelSize: Theme.fs(11)
                font.family:    "JetBrains Mono"
                color:          Theme.active
            }
        }
    }

    // ── Recovery routes ───────────────────────────────────────────────────────
    // Not uniform between machines, and that is the point: the rescue route is
    // conditional on the UKI rather than on the bootloader's name, and on the
    // opt-in systemd-boot path it does not exist on exactly the machines that
    // are hardest to get into.
    CfgSection {
        title: "Ways back into this machine"
        visible: RecoveryService.available

        Repeater {
            model: RecoveryService.status.routes.length

            delegate: Item {
                id: routeRow
                required property int index
                readonly property var route: RecoveryService.status.routes[routeRow.index]
                readonly property string mark:
                    RecoveryService.routeMark(routeRow.route ? routeRow.route.available : null)

                width:  parent ? parent.width : 0
                height: routeCol.implicitHeight + Theme.px(14)

                Text {
                    id: routeIcon
                    x: Theme.px(10)
                    anchors.top:       parent.top
                    anchors.topMargin: Theme.px(8)
                    text: routeRow.mark === "yes" ? "󰄬" : (routeRow.mark === "no" ? "󰅘" : "󰇙")
                    font.pixelSize: Theme.fs(12)
                    // `unknown` is not `no`. A running system cannot tell
                    // whether you have install media, and painting that red
                    // would be a claim nobody made.
                    color: routeRow.mark === "yes" ? Theme.success : Theme.subtext
                }

                Column {
                    id: routeCol
                    anchors.left:        routeIcon.right
                    anchors.leftMargin:  Theme.px(10)
                    anchors.right:       parent.right
                    anchors.rightMargin: Theme.px(10)
                    anchors.top:         parent.top
                    anchors.topMargin:   Theme.px(7)
                    spacing: Theme.px(2)

                    Text {
                        text:           routeRow.route ? routeRow.route.id : ""
                        font.pixelSize: Theme.fs(11)
                        font.family:    "JetBrains Mono"
                        color:          routeRow.mark === "yes" ? Theme.text : Theme.subtext
                    }
                    Text {
                        width:          parent.width
                        text:           routeRow.route ? routeRow.route.how : ""
                        font.pixelSize: Theme.fs(10)
                        color:          Theme.subtext
                        wrapMode:       Text.WordWrap
                    }
                }
            }
        }
    }

    // ── Hardware diagnostics ──────────────────────────────────────────────────
    // §19's [Hardware diagnostics], and its "expose `apex doctor` results
    // graphically". The same list the text form prints — apexd builds it once
    // and renders it twice, so this and the terminal cannot disagree.
    //
    // There is no severity here because the payload carries none: `apex
    // doctor`'s own comment says a WARN is information rather than a fault, so
    // a laptop with no ACPI platform_profile is not broken. Painting an
    // invented judgement red is worse than showing two states.
    CfgSection {
        title: "Hardware diagnostics"
        visible: RecoveryService.doctor.ok

        Text {
            x:     Theme.px(10)
            width: parent.width - Theme.px(20)
            text:  RecoveryService.doctorSummary
                   + " — a warning here is information, not a fault: not every machine has every capability."
            font.pixelSize: Theme.fs(10)
            color:    Theme.subtext
            wrapMode: Text.WordWrap
        }
        Item { width: parent.width; height: Theme.px(8) }

        Repeater {
            model: RecoveryService.doctor.checks.length

            delegate: Item {
                id: checkRow
                required property int index
                readonly property var check: RecoveryService.doctor.checks[checkRow.index]

                width:  parent ? parent.width : 0
                height: checkText.implicitHeight + Theme.px(10)

                Text {
                    id: checkMark
                    // Continuation lines in the doctor's output are indented by
                    // two spaces and belong to the check above them. Dropping
                    // that turns the touchpad block into five unrelated
                    // sentences, so the depth is carried through and spent
                    // here.
                    x: Theme.px(10) + Theme.px(14) * (checkRow.check ? checkRow.check.depth : 0)
                    anchors.top:       parent.top
                    anchors.topMargin: Theme.px(5)
                    text:           (checkRow.check && checkRow.check.ok) ? "󰄬" : "󰀪"
                    font.pixelSize: Theme.fs(11)
                    color:          (checkRow.check && checkRow.check.ok) ? Theme.success : Theme.warning
                }
                Text {
                    id: checkText
                    anchors.left:        checkMark.right
                    anchors.leftMargin:  Theme.px(8)
                    anchors.right:       parent.right
                    anchors.rightMargin: Theme.px(10)
                    anchors.top:         parent.top
                    anchors.topMargin:   Theme.px(5)
                    text:           checkRow.check ? checkRow.check.check : ""
                    font.pixelSize: Theme.fs(10)
                    color:          (checkRow.check && checkRow.check.ok) ? Theme.text : Theme.subtext
                    wrapMode:       Text.WordWrap
                }
            }
        }
    }

    // ── Factory reset ─────────────────────────────────────────────────────────
    //
    // The most destructive verb in the product, and the whole reason this
    // section looks unlike everything above it: its own bordered card, in the
    // danger tint, at the bottom, behind a disclosure that starts closed.
    //
    // Reaching a reset takes four deliberate acts and cannot be done by one
    // mis-click:
    //
    //   1. open this section
    //   2. choose a scope (desktop is preselected; user is never the default)
    //   3. press "Show what would be lost", which runs the DRY RUN
    //   4. press the danger button, which only exists once the loss list is
    //      on screen and has acknowledged itself
    //
    // Step 4 is not a timer and not a second click. `apex recover reset
    // --commit` needs `--confirm <scope>:<count>:<hash>` computed over the
    // exact paths the plan found — apexd built it that way specifically so a
    // UI cannot commit without having rendered the loss list. The list below
    // acknowledges itself with the token and the number of rows it actually
    // instantiated, and RecoveryService refuses to build a commit unless that
    // count matches both the plan's own and the one encoded in the token. So
    // "the user saw what will be lost" is a precondition the code can check,
    // rather than an ordering the code hopes for.
    //
    // Not to be confused with Misc → "Reset appearance & layout", which
    // restores sliders and toggles and touches nothing on disk outside the
    // shell's own settings file.
    CfgSection {
        title: "Factory reset"
        visible: RecoveryService.available

        Rectangle {
            width:  parent.width
            height: resetCol.implicitHeight + Theme.px(24)
            radius: Theme.px(10)
            color:  Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.06)
            border.width: 1
            border.color: Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.30)

            Column {
                id: resetCol
                anchors.left:        parent.left
                anchors.right:       parent.right
                anchors.top:         parent.top
                anchors.leftMargin:  Theme.px(12)
                anchors.rightMargin: Theme.px(12)
                anchors.topMargin:   Theme.px(12)
                spacing: Theme.px(8)

                // ── the disclosure ───────────────────────────────────────────
                Item {
                    width:  parent.width
                    height: Theme.px(26)

                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.px(8)
                        Text {
                            text:           "󰀦"
                            font.pixelSize: Theme.fs(14)
                            color:          Theme.danger
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text:           "Reset this account's APEX state"
                            font.pixelSize: Theme.fs(12)
                            font.weight:    Font.Medium
                            color:          Theme.text
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    CfgButton {
                        anchors.right:          parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        label: root.resetOpen ? "Close" : "Open"
                        icon:  root.resetOpen ? "󰅖" : "󰅀"
                        onClicked: {
                            root.resetOpen = !root.resetOpen
                            // Closing it drops the plan, so a confirm token can
                            // never outlive the list it was printed with.
                            if (!root.resetOpen) RecoveryService.cancelReset()
                        }
                    }
                }

                Text {
                    width: parent.width
                    text: "This removes APEX Shell's own settings for this account and, "
                        + "at the wider scope, your blueprint and per-game profiles. It "
                        + "does NOT touch your documents, your ssh or gnupg keys, your "
                        + "compositor configuration, your packages or your deployments. "
                        + "A machine indistinguishable from a fresh install is a "
                        + "reinstall, and the installer is what does that."
                    font.pixelSize: Theme.fs(10)
                    color:    Theme.subtext
                    wrapMode: Text.WordWrap
                }

                // ── everything below is inside the disclosure ────────────────
                Column {
                    width:   parent.width
                    spacing: Theme.px(8)
                    visible: root.resetOpen

                    Text {
                        width:          parent.width
                        text:           "How much"
                        font.pixelSize: Theme.fs(9)
                        font.weight:    Font.Bold
                        color:          Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.55)
                    }

                    CfgSegmented {
                        id: scopeSeg
                        width: parent.width
                        // `desktop` is preselected and `user` never is. The
                        // wider scope takes the blueprint and the recorded
                        // agent sessions with it, and a default that reaches
                        // further than the user asked for is the kind of
                        // mistake this whole section is shaped against.
                        property string chosen: "desktop"
                        options: [
                            { value: "desktop", label: "Desktop settings" },
                            { value: "user",    label: "Everything APEX owns for this account" }
                        ]
                        value: scopeSeg.chosen
                        onSelected: function (v) {
                            scopeSeg.chosen = v
                            // A plan belongs to the scope it was made for.
                            RecoveryService.cancelReset()
                        }
                    }

                    Text {
                        width: parent.width
                        text: {
                            const scopes = RecoveryService.status.resetScopes
                            for (let i = 0; i < scopes.length; i++)
                                if (scopes[i].id === scopeSeg.chosen)
                                    return scopes[i].summary
                            return ""
                        }
                        font.pixelSize: Theme.fs(10)
                        color:    Theme.subtext
                        wrapMode: Text.WordWrap
                    }

                    CfgButton {
                        label:   RecoveryService.resetPhase === "planning"
                                 ? "Working…" : "Show what would be lost"
                        icon:    "󰈙"
                        enabled: RecoveryService.resetPhase !== "planning"
                                 && RecoveryService.resetPhase !== "committing"
                        onClicked: RecoveryService.planReset(scopeSeg.chosen)
                    }

                    // ── the loss list ────────────────────────────────────────
                    // The rows the plan says exist, which is exactly the set
                    // apexd hashed into the confirm token. This container is
                    // what acknowledges having rendered them.
                    Column {
                        id: lossList
                        width:   parent.width
                        spacing: Theme.px(4)
                        visible: RecoveryService.resetPhase === "planned"
                                 && RecoveryService.plan !== null

                        readonly property var plan: RecoveryService.plan
                        readonly property int shown: lossRepeater.count

                        // The acknowledgement. Re-sent whenever the plan or the
                        // number of instantiated rows changes, and revoked when
                        // this Column goes away — an acknowledgement that
                        // outlived the list it describes would be exactly the
                        // evidence it is supposed to be.
                        function _ack() {
                            if (!lossList.plan) { RecoveryService.revokeLossList(); return }
                            RecoveryService.acknowledgeLossList(lossList.plan.confirmToken,
                                                                lossList.shown)
                        }
                        onPlanChanged:  lossList._ack()
                        onShownChanged: lossList._ack()
                        Component.onCompleted:   lossList._ack()
                        Component.onDestruction: RecoveryService.revokeLossList()

                        Text {
                            width: parent.width
                            text: {
                                const p = lossList.plan
                                if (!p) return ""
                                return p.losses.length === 0
                                    ? "Nothing to remove: none of the paths this scope covers exists on this machine."
                                    : (p.losses.length + " item(s) will be changed. Everything except caches is copied to ~/apex-reset-backup-<timestamp> first.")
                            }
                            font.pixelSize: Theme.fs(10)
                            font.weight:    Font.Medium
                            color:          Theme.danger
                            wrapMode:       Text.WordWrap
                        }

                        Repeater {
                            id: lossRepeater
                            // Count, not the array — same reason as every other
                            // list on this page.
                            model: lossList.plan ? lossList.plan.losses.length : 0

                            delegate: Item {
                                id: lossRow
                                required property int index
                                readonly property var loss:
                                    lossList.plan ? lossList.plan.losses[lossRow.index] : null

                                width:  parent ? parent.width : 0
                                height: lossCol.implicitHeight + Theme.px(8)

                                Column {
                                    id: lossCol
                                    x:     Theme.px(6)
                                    width: parent.width - Theme.px(12)
                                    anchors.top:       parent.top
                                    anchors.topMargin: Theme.px(4)
                                    spacing: Theme.px(1)

                                    Text {
                                        width:          parent.width
                                        text:           lossRow.loss ? lossRow.loss.relative : ""
                                        font.pixelSize: Theme.fs(10)
                                        font.family:    "JetBrains Mono"
                                        color:          Theme.text
                                        elide:          Text.ElideMiddle
                                    }
                                    Text {
                                        width: parent.width
                                        text: {
                                            const l = lossRow.loss
                                            if (!l) return ""
                                            return l.verb + " · " + l.what
                                                 + (l.backedUp ? "" : " · NOT backed up")
                                        }
                                        font.pixelSize: Theme.fs(9)
                                        color:          lossRow.loss && lossRow.loss.backedUp
                                                        ? Theme.subtext : Theme.warning
                                        wrapMode:       Text.WordWrap
                                    }
                                }
                            }
                        }

                        // What survives. Printed by the dry run, and worth as
                        // much space as the losses: a reset nobody can predict
                        // the boundary of is one nobody should press.
                        Text {
                            width:          parent.width
                            text:           "Preserved"
                            font.pixelSize: Theme.fs(9)
                            font.weight:    Font.Bold
                            color:          Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.55)
                        }

                        Repeater {
                            model: lossList.plan ? lossList.plan.preserved.length : 0

                            delegate: Text {
                                required property int index
                                readonly property string line:
                                    lossList.plan ? lossList.plan.preserved[index] : ""

                                width:          lossList.width - Theme.px(12)
                                x:              Theme.px(6)
                                text:           "· " + line
                                font.pixelSize: Theme.fs(9)
                                color:          Theme.subtext
                                wrapMode:       Text.WordWrap
                            }
                        }

                        Item { width: parent.width; height: Theme.px(4) }

                        // ── the commit ───────────────────────────────────────
                        // dangerFill / dangerFillHover: the fill pair that
                        // exists for exactly this class of control, and the
                        // only place on this page that uses it. Every other
                        // destructive-looking thing here is a tint or an
                        // accent; this is the one button that erases.
                        Rectangle {
                            width:  Math.min(parent.width, Theme.px(260))
                            height: Theme.px(36)
                            radius: Theme.px(8)
                            visible: RecoveryService.commitReady
                            color:  commitHov.hovered ? Theme.dangerFillHover : Theme.dangerFill
                            Behavior on color { ColorAnimation { duration: 120 } }

                            Text {
                                anchors.centerIn: parent
                                text: {
                                    const p = lossList.plan
                                    return p ? ("Erase " + p.losses.length + " item(s) now")
                                             : "Erase"
                                }
                                font.pixelSize: Theme.fs(12)
                                font.bold:      true
                                color:          Theme.fixedLight
                            }

                            HoverHandler { id: commitHov; cursorShape: Qt.PointingHandCursor }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: RecoveryService.commitReset()
                            }
                        }

                        Text {
                            width:   parent.width
                            visible: !RecoveryService.commitReady
                            text:    "The confirmation is not ready. It is derived from this "
                                   + "scope and the exact paths above, so it cannot be built "
                                   + "without the list being on screen."
                            font.pixelSize: Theme.fs(9)
                            color:    Theme.subtext
                            wrapMode: Text.WordWrap
                        }
                    }

                    // ── outcome ──────────────────────────────────────────────
                    // apexd's refusals name what did not match and what to do
                    // about it, so the message is shown as it was written
                    // rather than replaced with "failed".
                    Text {
                        width:   parent.width
                        visible: RecoveryService.resetMessage !== ""
                                 || RecoveryService.resetPhase === "committing"
                        text: RecoveryService.resetPhase === "committing"
                              ? "Resetting. Backing up first; leave this alone until it finishes."
                              : RecoveryService.resetMessage
                        font.pixelSize: Theme.fs(10)
                        font.family:    "JetBrains Mono"
                        color: RecoveryService.resetPhase === "done" ? Theme.success : Theme.warning
                        wrapMode: Text.WordWrap
                    }
                }
            }
        }
    }

    // ── Where the rest of it is ───────────────────────────────────────────────
    CfgSection {
        title: "Elsewhere"

        CfgRow {
            label:       "Reset appearance & layout"
            description: "A different thing entirely: Misc → Reset restores this shell's sliders and toggles and removes nothing from disk."
            hoverable:   false
            Text {
                text:           "Config → Misc"
                font.pixelSize: Theme.fs(11)
                color:          Theme.subtext
            }
        }

        CfgRow {
            label:       "What this machine should be"
            description: "The blueprint page reports drift; this page reports damage."
            hoverable:   false
            Text {
                text:           "Config → Blueprint"
                font.pixelSize: Theme.fs(11)
                color:          Theme.subtext
            }
        }
    }

    Item { width: parent.width; height: Theme.px(10) }
}
