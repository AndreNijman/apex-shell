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
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    // Criterion 1. Live: every control here acts on the machine when pressed.
    // The one thing that does not take effect where you press it says so on its
    // own row.
    lifecycle: "live"

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

        // StatusHero's geometry, written out here rather than used: this page's
        // accessibility contract (P2-003) is read out of THIS file by brace
        // depth — tests/check-recovery-a11y.sh — so the headline's Text and its
        // Accessible.* have to live here. Same edge, sizes and bound as the
        // shared hero on Firewall, Privacy and the Lid (UI/UX Phase 17).
        Item {
            id: heroBox
            width:  parent.width
            height: Math.max(theme.px(62), heroText.implicitHeight + theme.spaceL)

            Row {
                anchors.left: parent.left
                anchors.right: heroRecheck.left
                anchors.rightMargin: theme.spaceL
                anchors.verticalCenter: parent.verticalCenter
                spacing: theme.spaceM

                // Deliberately carries NO Accessible.* — see the block at the
                // foot of this file. Every glyph on this page is a private-use
                // codepoint, and a reader that reaches one says "private use
                // character" out loud in place of the words it was meant to
                // read. The state it encodes is in the summary below, in
                // words. tests/check-recovery-a11y.sh asserts that no icon on
                // this page ever acquires a role.
                Text {
                    id: heroGlyph
                    text:           "󰑙"
                    font.pixelSize: theme.fs(28)
                    color: RecoveryService.needsAttention > 0 ? Theme.warning : Theme.active
                    anchors.verticalCenter: parent.verticalCenter
                }
                Column {
                    id: heroText
                    width: parent.width - heroGlyph.width - parent.spacing
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: theme.px(3)

                    // The headline fact of the whole page. Named explicitly
                    // rather than left to Qt's fallback from `text`: that
                    // fallback exists, but it is silent when it stops
                    // applying, and this is the one string a reader must get.
                    Text {
                        id: summaryText
                        text: {
                            if (!RecoveryService.checked)  return "Checking this machine…"
                            if (!RecoveryService.available) return "The recovery surface is unavailable"
                            if (RecoveryService.needsAttention === 0)
                                return "Nothing needs attention"
                            // The verb agrees too. It did not until this
                            // string became something a screen reader says out
                            // loud, and "1 component need attention" is a
                            // sentence nobody reading it aloud would write.
                            return RecoveryService.needsAttention
                                + (RecoveryService.needsAttention === 1
                                   ? " component needs attention"
                                   : " components need attention")
                        }
                        width:          parent.width
                        wrapMode:       Text.WordWrap
                        font.family:    Theme.fontUi
                        font.pixelSize: theme.typeHeading
                        font.weight:    Font.DemiBold
                        color:          Theme.textPrimary
                        Accessible.role: Accessible.StaticText
                        Accessible.name: summaryText.text
                    }
                    Text {
                        id: summaryDetail
                        text: RecoveryService.available
                            ? ("bootloader " + RecoveryService.status.bootloader
                               + "  ·  diagnostics: " + RecoveryService.doctorSummary)
                            : "`apex recover` is not on this machine, or predates this shell. Nothing below could be read."
                        width:          parent.width
                        // A sentence when nothing could be read; a status line otherwise.
                        wrapMode:       RecoveryService.available ? Text.NoWrap : Text.WordWrap
                        elide:          RecoveryService.available ? Text.ElideRight : Text.ElideNone
                        font.pixelSize: theme.typeCaption
                        color:          Theme.textSecondary
                        font.family:    Theme.fontMono
                        Accessible.role: Accessible.StaticText
                        Accessible.name: summaryDetail.text
                    }
                }
            }

            CfgButton {
                id: heroRecheck
                anchors.right:          parent.right
                anchors.verticalCenter: parent.verticalCenter
                label:   RecoveryService.busy ? "Checking…" : "Re-check"
                icon:    "󰑐"
                enabled: !RecoveryService.busy
                onClicked: RecoveryService.refresh()
            }
        }

        Text {
            id: pageIntro
            width: parent.width
            text: "Everything on this page is read from the machine, not from a "
                + "cache. Checking it changes nothing and needs no password: "
                + "`apex recover status` and `apex doctor` read files. The two "
                + "verbs that do change something — repair, and the factory "
                + "reset — run only when you press them."
            font.pixelSize: theme.typeCaption
            color:    Theme.subtext
            wrapMode: Text.WordWrap
            Accessible.role: Accessible.StaticText
            Accessible.name: pageIntro.text
        }
        Item { width: parent.width; height: theme.px(6) }
    }

    // ── Components ────────────────────────────────────────────────────────────
    // The eight rows §19 names. Their ids are a compatibility surface on the OS
    // side; recovery.js orders by them and appends anything it does not know
    // rather than dropping it.
    CfgSection {
        title: "Components"
        // No heading over nothing (UI/UX Phase 17): with zero rows it drew
        // "Components" above an empty space.
        visible: RecoveryService.available && RecoveryService.status.rows.length > 0

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
                height: compCol.implicitHeight + theme.px(16)

                // The row is ONE node, composed from its words. Its three
                // Texts stay unmarked: a reader that met them separately would
                // get "Secure Boot", "Needs attention" and the detail as three
                // unrelated labels, and the state icon beside them is a
                // private-use glyph that must never reach a name. The row's
                // state is therefore carried as the STATE LABEL, which is the
                // same string the eye reads.
                Accessible.role: Accessible.ListItem
                Accessible.name: (compRow.row ? compRow.row.label : "")
                    + " — "
                    + RecoveryService.stateLabel(compRow.row ? compRow.row.state : "")
                Accessible.description: (compRow.row ? compRow.row.detail : "")
                    + ((compRow.row && compRow.row.action !== "")
                       ? (". Run in a terminal: " + compRow.row.action) : "")

                // No hover (UI/UX Phase 17, CfgRow's rule): a row lights up only when
                // it holds something to press, and these hold none — it lit at
                // .03 and did nothing.

                Text {
                    id: compIcon
                    anchors.top:       parent.top
                    anchors.topMargin: theme.px(9)
                    text:           RecoveryService.stateIcon(compRow.row ? compRow.row.state : "")
                    font.pixelSize: theme.fs(13)
                    color:          root.toneColor(RecoveryService.stateTone(compRow.row ? compRow.row.state : ""))
                    Behavior on color { MotionColor { role: "state" } }
                }

                Column {
                    id: compCol
                    anchors.left:        compIcon.right
                    anchors.leftMargin:  theme.px(10)
                    anchors.right:       parent.right
                    anchors.rightMargin: 0
                    anchors.top:         parent.top
                    anchors.topMargin:   theme.px(8)
                    spacing: theme.px(3)

                    Row {
                        spacing: theme.px(8)
                        Text {
                            text:           compRow.row ? compRow.row.label : ""
                            font.pixelSize: theme.fs(12)
                            color:          Theme.text
                        }
                        Text {
                            text:           RecoveryService.stateLabel(compRow.row ? compRow.row.state : "")
                            font.pixelSize: theme.typeCaption
                            font.weight:    Font.Medium
                            color:          root.toneColor(RecoveryService.stateTone(compRow.row ? compRow.row.state : ""))
                            anchors.verticalCenter: parent.verticalCenter
                            Behavior on color { MotionColor { role: "state" } }
                        }
                    }
                    Text {
                        width:          parent.width
                        text:           compRow.row ? compRow.row.detail : ""
                        font.pixelSize: theme.typeCaption
                        color:          Theme.subtext
                        wrapMode:       Text.WordWrap
                    }
                    // The command that addresses this row, when there is one.
                    // Shown rather than run: every one of them starts `sudo`.
                    Text {
                        visible:        compRow.row && compRow.row.action !== ""
                        width:          parent.width
                        text:           "→ " + (compRow.row ? compRow.row.action : "")
                        font.pixelSize: theme.typeCaption
                        font.family:    Theme.fontMono
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
                height: stepCol.implicitHeight + theme.px(12)

                // "What it will do" is the name; "why that is safe" is the
                // description, because a reader deciding whether to press
                // Repair needs the second sentence and a list of bare verbs
                // does not give it to them.
                Accessible.role: Accessible.ListItem
                Accessible.name: stepRow.step ? stepRow.step.what : ""
                Accessible.description: (stepRow.step ? stepRow.step.whySafe : "")
                    + ((stepRow.step && !stepRow.step.runnableHere)
                       ? (". This one is not run from here. Run in a terminal: "
                          + RecoveryService.repairSystemCommand) : "")

                Column {
                    id: stepCol
                    x: theme.px(20)
                    width: parent.width - theme.px(30)
                    anchors.top:       parent.top
                    anchors.topMargin: theme.px(6)
                    spacing: theme.px(2)

                    Text {
                        width:          parent.width
                        text:           (stepRow.step ? stepRow.step.what : "")
                        font.pixelSize: theme.fs(11)
                        color:          Theme.text
                        wrapMode:       Text.WordWrap
                    }
                    Text {
                        width:          parent.width
                        text:           stepRow.step ? stepRow.step.whySafe : ""
                        font.pixelSize: theme.fs(9)
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
                        font.pixelSize: theme.fs(9)
                        font.family:    Theme.fontMono
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
            id: rollbackHintText
            width: parent.width
            text:  RecoveryService.rollbackHint
            font.pixelSize: theme.typeCaption
            color:    Theme.subtext
            wrapMode: Text.WordWrap
            Accessible.role: Accessible.StaticText
            Accessible.name: rollbackHintText.text
        }
        Item { width: parent.width; height: theme.px(8) }

        // a11yExtra, not a name on the Text. CfgRow adopts a child with no
        // accessible name and gives it the ROW's label, so naming the command
        // here would replace "Boot the previous deployment" rather than add to
        // it — and leaving it alone drops the command entirely, which is the
        // one thing this row exists to hand over. Measured over AT-SPI: before
        // this, the node read `name=Boot the previous deployment` and the
        // command appeared nowhere in the tree.
        CfgRow {
            label:       "Boot the previous deployment"
            description: "Run this in a terminal. It needs root, so APEX Shell shows it instead of asking for a password."
            a11yExtra:   "The command is: " + RecoveryService.rollbackCommand
            effect:      "reboot"
            Text {
                // A command to copy — the same treatment as Firewall's (UI/UX Phase 17).
                text:           RecoveryService.rollbackCommand
                font.pixelSize: theme.typeMono
                font.family:    Theme.fontMono
                color:          Theme.accentText
            }
        }

        CfgRow {
            label:       "Keep the current one first"
            description: "bootc keeps only the booted and previous images, so two bad updates in a row can evict the last good one. Pinning stops that."
            a11yExtra:   "The command is: " + RecoveryService.pinCommand
            Text {
                text:           RecoveryService.pinCommand
                font.pixelSize: theme.fs(11)
                font.family:    Theme.fontMono
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
        visible: RecoveryService.available && RecoveryService.status.routes.length > 0

        Repeater {
            model: RecoveryService.status.routes.length

            delegate: Item {
                id: routeRow
                required property int index
                readonly property var route: RecoveryService.status.routes[routeRow.index]
                readonly property string mark:
                    RecoveryService.routeMark(routeRow.route ? routeRow.route.available : null)

                width:  parent ? parent.width : 0
                height: routeCol.implicitHeight + theme.px(14)

                // The tri-state is spoken, not drawn. `unknown` is NOT `no` —
                // a running system cannot tell whether you have install media
                // — and the tick/cross/dash that carries that distinction for
                // the eye is a private-use glyph a reader cannot use.
                Accessible.role: Accessible.ListItem
                Accessible.name: (routeRow.route ? routeRow.route.id : "")
                    + " — "
                    + (routeRow.mark === "yes" ? "available"
                       : (routeRow.mark === "no" ? "not available"
                          : "cannot be determined from a running system"))
                Accessible.description: routeRow.route ? routeRow.route.how : ""

                Text {
                    id: routeIcon
                    anchors.top:       parent.top
                    anchors.topMargin: theme.px(8)
                    text: routeRow.mark === "yes" ? "󰄬" : (routeRow.mark === "no" ? "󰅘" : "󰇙")
                    font.pixelSize: theme.fs(12)
                    // `unknown` is not `no`. A running system cannot tell
                    // whether you have install media, and painting that red
                    // would be a claim nobody made.
                    color: routeRow.mark === "yes" ? Theme.success : Theme.subtext
                }

                Column {
                    id: routeCol
                    anchors.left:        routeIcon.right
                    anchors.leftMargin:  theme.px(10)
                    anchors.right:       parent.right
                    anchors.rightMargin: 0
                    anchors.top:         parent.top
                    anchors.topMargin:   theme.px(7)
                    spacing: theme.px(2)

                    Text {
                        text:           routeRow.route ? routeRow.route.id : ""
                        font.pixelSize: theme.fs(11)
                        font.family:    Theme.fontMono
                        color:          routeRow.mark === "yes" ? Theme.text : Theme.subtext
                    }
                    Text {
                        width:          parent.width
                        text:           routeRow.route ? routeRow.route.how : ""
                        font.pixelSize: theme.typeCaption
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
            id: doctorIntro
            width: parent.width
            text:  RecoveryService.doctorSummary
                   + " — a warning here is information, not a fault: not every machine has every capability."
            font.pixelSize: theme.typeCaption
            color:    Theme.subtext
            wrapMode: Text.WordWrap
            Accessible.role: Accessible.StaticText
            Accessible.name: doctorIntro.text
        }
        Item { width: parent.width; height: theme.px(8) }

        Repeater {
            model: RecoveryService.doctor.checks.length

            delegate: Item {
                id: checkRow
                required property int index
                readonly property var check: RecoveryService.doctor.checks[checkRow.index]

                width:  parent ? parent.width : 0
                height: checkText.implicitHeight + theme.px(10)

                // "pass" / "warning" in words, because the tick and the
                // exclamation that separate them for the eye are private-use
                // glyphs. The doctor's own comment says a WARN is information
                // rather than a fault, so the word is "warning" and not
                // "failed" — inventing a severity the payload does not carry
                // would be worse spoken than drawn.
                Accessible.role: Accessible.ListItem
                Accessible.name: ((checkRow.check && checkRow.check.ok) ? "pass" : "warning")
                    + " — " + (checkRow.check ? checkRow.check.check : "")

                Text {
                    id: checkMark
                    // Continuation lines in the doctor's output are indented by
                    // two spaces and belong to the check above them. Dropping
                    // that turns the touchpad block into five unrelated
                    // sentences, so the depth is carried through and spent
                    // here.
                    x: theme.px(10) + theme.px(14) * (checkRow.check ? checkRow.check.depth : 0)
                    anchors.top:       parent.top
                    anchors.topMargin: theme.px(5)
                    text:           (checkRow.check && checkRow.check.ok) ? "󰄬" : "󰀪"
                    font.pixelSize: theme.fs(11)
                    color:          (checkRow.check && checkRow.check.ok) ? Theme.success : Theme.warning
                }
                Text {
                    id: checkText
                    anchors.left:        checkMark.right
                    anchors.leftMargin:  theme.px(8)
                    anchors.right:       parent.right
                    anchors.rightMargin: theme.px(10)
                    anchors.top:         parent.top
                    anchors.topMargin:   theme.px(5)
                    text:           checkRow.check ? checkRow.check.check : ""
                    font.pixelSize: theme.typeCaption
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
            height: resetCol.implicitHeight + theme.px(24)
            radius: theme.px(10)
            color:  Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.06)
            border.width: 1
            border.color: Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.30)

            Column {
                id: resetCol
                anchors.left:        parent.left
                anchors.right:       parent.right
                anchors.top:         parent.top
                anchors.leftMargin:  theme.px(12)
                anchors.rightMargin: theme.px(12)
                anchors.topMargin:   theme.px(12)
                spacing: theme.px(8)

                // ── the disclosure ───────────────────────────────────────────
                Item {
                    width:  parent.width
                    height: theme.px(26)

                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: theme.px(8)
                        Text {
                            text:           "󰀦"
                            font.pixelSize: theme.fs(14)
                            color:          Theme.danger
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            id: resetHeading
                            text:           "Reset this account's APEX state"
                            font.pixelSize: theme.fs(12)
                            font.weight:    Font.Medium
                            color:          Theme.text
                            anchors.verticalCenter: parent.verticalCenter
                            Accessible.role: Accessible.StaticText
                            Accessible.name: resetHeading.text
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
                    id: resetBlurb
                    width: parent.width
                    text: "This removes APEX Shell's own settings for this account and, "
                        + "at the wider scope, your blueprint and per-game profiles. It "
                        + "does NOT touch your documents, your ssh or gnupg keys, your "
                        + "compositor configuration, your packages or your deployments. "
                        + "A machine indistinguishable from a fresh install is a "
                        + "reinstall, and the installer is what does that."
                    font.pixelSize: theme.typeCaption
                    color:    Theme.subtext
                    wrapMode: Text.WordWrap
                    Accessible.role: Accessible.StaticText
                    Accessible.name: resetBlurb.text
                }

                // ── everything below is inside the disclosure ────────────────
                Column {
                    width:   parent.width
                    spacing: theme.px(8)
                    visible: root.resetOpen

                    Text {
                        width:          parent.width
                        text:           "How much"
                        font.pixelSize: theme.fs(9)
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
                        id: scopeSummary
                        width: parent.width
                        text: {
                            const scopes = RecoveryService.status.resetScopes
                            for (let i = 0; i < scopes.length; i++)
                                if (scopes[i].id === scopeSeg.chosen)
                                    return scopes[i].summary
                            return ""
                        }
                        font.pixelSize: theme.typeCaption
                        color:    Theme.subtext
                        wrapMode: Text.WordWrap
                        // What the CHOSEN scope covers. The two radio buttons
                        // name themselves; this is the sentence that says what
                        // picking one actually means, and it changes when they
                        // change.
                        Accessible.role: Accessible.StaticText
                        Accessible.name: scopeSummary.text
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
                        spacing: theme.px(4)
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

                        // …and when the PHASE moves, which is the trigger
                        // that was missing. acknowledgeLossList() refuses
                        // while the phase is not yet "planned", and until
                        // 2026-09-19 RecoveryService assigned `plan` before
                        // `resetPhase` — so the only acknowledgement this
                        // list ever sent was the one that gets refused, and
                        // commitReady was false for ever. The service's order
                        // is fixed too; this is here so that the order stops
                        // being load-bearing. The guard is in
                        // acknowledgeLossList(), so a phase change to
                        // anything else re-acks harmlessly and is refused.
                        Connections {
                            target: RecoveryService
                            function onResetPhaseChanged() { lossList._ack() }
                        }

                        Text {
                            id: lossHeadline
                            width: parent.width
                            text: {
                                const p = lossList.plan
                                if (!p) return ""
                                return p.losses.length === 0
                                    ? "Nothing to remove: none of the paths this scope covers exists on this machine."
                                    : (p.losses.length + " item(s) will be changed. Everything except caches is copied to ~/apex-reset-backup-<timestamp> first.")
                            }
                            font.pixelSize: theme.typeCaption
                            font.weight:    Font.Medium
                            color:          Theme.danger
                            wrapMode:       Text.WordWrap
                            Accessible.role: Accessible.StaticText
                            Accessible.name: lossHeadline.text
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
                                height: lossCol.implicitHeight + theme.px(8)

                                // The evidence. Before this, the loss list was
                                // invisible on the accessibility bus: measured
                                // 2026-09-19, pressing "Show what would be
                                // lost" over AT-SPI ran the dry run and added
                                // exactly ZERO nodes to the tree. A reader
                                // could reach the third step of the four this
                                // section is built around and then be told
                                // nothing about what the fourth would erase.
                                //
                                // "NOT backed up" is in the name and not only
                                // the description, because it is the one row
                                // property a reader must not be able to skim
                                // past: the cache is the single thing this
                                // operation does not copy aside first.
                                Accessible.role: Accessible.ListItem
                                Accessible.name: (lossRow.loss ? lossRow.loss.relative : "")
                                    + (lossRow.loss && !lossRow.loss.backedUp
                                       ? " — NOT backed up" : "")
                                Accessible.description: lossRow.loss
                                    ? (lossRow.loss.verb + ". " + lossRow.loss.what) : ""

                                Column {
                                    id: lossCol
                                    x:     theme.px(6)
                                    width: parent.width - theme.px(12)
                                    anchors.top:       parent.top
                                    anchors.topMargin: theme.px(4)
                                    spacing: theme.px(1)

                                    Text {
                                        width:          parent.width
                                        text:           lossRow.loss ? lossRow.loss.relative : ""
                                        font.pixelSize: theme.typeCaption
                                        font.family:    Theme.fontMono
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
                                        font.pixelSize: theme.fs(9)
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
                            id: preservedHeading
                            width:          parent.width
                            text:           "Preserved"
                            font.pixelSize: theme.fs(9)
                            font.weight:    Font.Bold
                            color:          Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.55)
                            Accessible.role: Accessible.StaticText
                            Accessible.name: preservedHeading.text
                        }

                        Repeater {
                            model: lossList.plan ? lossList.plan.preserved.length : 0

                            delegate: Text {
                                id: preservedRow
                                required property int index
                                readonly property string line:
                                    lossList.plan ? lossList.plan.preserved[index] : ""

                                width:          lossList.width - theme.px(12)
                                x:              theme.px(6)
                                text:           "· " + line
                                font.pixelSize: theme.fs(9)
                                color:          Theme.subtext
                                wrapMode:       Text.WordWrap
                                // The name is the LINE, not the rendered text:
                                // the middle dot is a bullet for the eye and a
                                // reader would say it out loud.
                                Accessible.role: Accessible.ListItem
                                Accessible.name: preservedRow.line
                            }
                        }

                        Item { width: parent.width; height: theme.px(4) }

                        // ── the commit ───────────────────────────────────────
                        // dangerFill / dangerFillHover: the fill pair that
                        // exists for exactly this class of control, and the
                        // only place on this page that uses it. Every other
                        // destructive-looking thing here is a tint or an
                        // accent; this is the one button that erases.
                        // ── the one control here that a reader could not
                        // reach, and a keyboard could not press ─────────────
                        //
                        // Measured 2026-09-19 over real AT-SPI: every SAFE
                        // control on this page — Re-check, Check, Open, the
                        // two scope radio buttons, "Show what would be lost" —
                        // arrived on the bus with a Press action, because each
                        // is a CfgButton or a CfgSegmented. This one is a bare
                        // Rectangle with a MouseArea, so it was absent
                        // entirely: no role, no name, no action, no key
                        // handling, no tab stop. A keyboard user could walk the
                        // whole four-step reset and not finish it.
                        //
                        // It stays a Rectangle rather than becoming a
                        // CfgButton because dangerFill/dangerFillHover is the
                        // fill pair that exists for exactly this class of
                        // control and CfgButton's danger variant is a tint. So
                        // the reachability is added here instead, in
                        // CfgButton's own shape: one press() that both the
                        // pointer and the reader go through, Space and Return,
                        // a focus ring, and a tab stop that exists only while
                        // the button does.
                        //
                        // Exposing it is NOT a way around the gate, and that is
                        // checked rather than asserted. The gate is in
                        // RecoveryService.commitReset(), not in this item's
                        // visibility: it returns early unless resetPhase is
                        // "planned", and commitArgv refuses unless the
                        // acknowledged token and the number of rows the
                        // Repeater actually instantiated both match the plan.
                        // A reader pressing this before the list is on screen
                        // gets the same refusal a mouse would.
                        // tests/run-recovery-atspi-shim.sh presses it over the
                        // bus at exactly that moment and requires the stub
                        // `apex` to have recorded no `--commit`.
                        Rectangle {
                            id: commitBtn
                            width:  Math.min(parent.width, theme.px(260))
                            height: theme.px(36)
                            radius: theme.px(8)
                            visible: RecoveryService.commitReady
                            color:  commitHov.hovered ? Theme.dangerFillHover : Theme.dangerFill
                            Behavior on color { MotionColor {} }

                            readonly property string a11yLabel: {
                                const p = lossList.plan
                                return p ? ("Erase " + p.losses.length + " item(s) now") : "Erase"
                            }

                            function press() {
                                if (!RecoveryService.commitReady) return
                                RecoveryService.commitReset()
                            }

                            // Only while it is on screen. An invisible tab stop
                            // on the most destructive control in the product is
                            // worse than none: Tab would stop somewhere the
                            // user cannot see and Space would fire it.
                            activeFocusOnTab: RecoveryService.commitReady
                            // …and the bus has to SAY it is unavailable, not
                            // merely behave that way. Measured: with only
                            // `visible` gating it, the node arrives before the
                            // loss list exists carrying `enabled,sensitive`
                            // and a Press action, named "Erase" — FOUND 16,
                            // an invisible Qt Quick item still publishes. A
                            // reader met a live-looking destructive button,
                            // pressed it, and was told nothing, because
                            // press() refuses in silence. `enabled` is what
                            // Qt maps to the enabled/sensitive states, so
                            // binding it to the same condition is the
                            // difference between a control that is inert and
                            // one that says so.
                            enabled: RecoveryService.commitReady
                            Accessible.role: Accessible.Button
                            Accessible.name: commitBtn.a11yLabel
                            Accessible.description:
                                "Runs the factory reset now. This is the last step and it "
                                + "cannot be undone; everything except caches has been copied "
                                + "to a backup directory in your home first."
                            Accessible.onPressAction: commitBtn.press()

                            Keys.onPressed: function (event) {
                                if (event.key === Qt.Key_Space || event.key === Qt.Key_Return
                                    || event.key === Qt.Key_Enter) {
                                    commitBtn.press()
                                    event.accepted = true
                                }
                            }

                            Text {
                                anchors.centerIn: parent
                                text:           commitBtn.a11yLabel
                                font.pixelSize: theme.fs(12)
                                font.bold:      true
                                color:          Theme.fixedLight
                            }

                            // The hover tint is the only "you are here" a
                            // pointer gets, and a keyboard never triggers it.
                            Rectangle {
                                anchors.fill:    parent
                                anchors.margins: -2
                                radius:          theme.px(10)
                                color:           "transparent"
                                border.width:    2
                                border.color:    Theme.danger
                                visible:         commitBtn.activeFocus
                            }

                            HoverHandler { id: commitHov; cursorShape: Qt.PointingHandCursor }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: { commitBtn.forceActiveFocus(); commitBtn.press() }
                            }
                        }

                        Text {
                            id: notReadyText
                            width:   parent.width
                            visible: !RecoveryService.commitReady
                            text:    "The confirmation is not ready. It is derived from this "
                                   + "scope and the exact paths above, so it cannot be built "
                                   + "without the list being on screen."
                            font.pixelSize: theme.fs(9)
                            color:    Theme.subtext
                            wrapMode: Text.WordWrap
                            // Why there is no button. Without this a reader
                            // reaches the end of the section and finds nothing
                            // at all, which is indistinguishable from a page
                            // that failed to render.
                            Accessible.role: Accessible.StaticText
                            Accessible.name: notReadyText.text
                        }
                    }

                    // ── outcome ──────────────────────────────────────────────
                    // apexd's refusals name what did not match and what to do
                    // about it, so the message is shown as it was written
                    // rather than replaced with "failed".
                    Text {
                        id: resetOutcome
                        width:   parent.width
                        visible: RecoveryService.resetMessage !== ""
                                 || RecoveryService.resetPhase === "committing"
                        text: RecoveryService.resetPhase === "committing"
                              ? "Resetting. Backing up first; leave this alone until it finishes."
                              : RecoveryService.resetMessage
                        font.pixelSize: theme.typeCaption
                        font.family:    Theme.fontMono
                        color: RecoveryService.resetPhase === "done" ? Theme.success : Theme.warning
                        wrapMode: Text.WordWrap
                        // apexd's refusals name what did not match and what to
                        // do about it, and they are the only feedback this
                        // operation gives. A reader that presses the button and
                        // is told nothing cannot tell a refusal from a success.
                        // Note what this is NOT: a description change is not
                        // speech (FOUND 12), so a reader whose focus is still
                        // on the button does not hear this arrive. Announcing
                        // it needs Accessible.announce and belongs with the
                        // rest of that work.
                        Accessible.role: Accessible.StaticText
                        Accessible.name: resetOutcome.text
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
                font.pixelSize: theme.fs(11)
                color:          Theme.subtext
            }
        }

        CfgRow {
            label:       "What this machine should be"
            description: "The blueprint page reports drift; this page reports damage."
            hoverable:   false
            Text {
                text:           "Config → Blueprint"
                font.pixelSize: theme.fs(11)
                color:          Theme.subtext
            }
        }
    }

    Item { width: parent.width; height: theme.px(10) }

    // ── What a screen reader gets from this page, and what it still does not ─
    //
    // Added 2026-09-19 (p2-b round 31). Before it this file contained ZERO
    // Accessible.* in 892 lines and everything a reader got came from the
    // shared Cfg* controls it instantiates. Measured over real AT-SPI with the
    // shell on a nested headless labwc and Qt's factory restored by the
    // round-30 shim, against an `apex` answering the captured fixtures: the
    // page published its buttons and NOT ONE of its 8 component rows, 6
    // recovery routes, 7 doctor checks, its status line, or its section
    // titles. Worse, pressing "Show what would be lost" over the bus ran the
    // dry run and added exactly zero nodes, and the `Erase` button did not
    // exist on the bus at all — so the destructive path could be walked three
    // steps and then dead-ended with no information and no way to finish.
    //
    // Two rules this page follows, and tests/check-recovery-a11y.sh enforces
    // both because neither is visible in a diff:
    //
    //   1. EVERY GLYPH HERE IS A PRIVATE-USE CODEPOINT and none of them may
    //      carry a role or reach a name. A reader that meets one says "private
    //      use character" before the words it was supposed to read. The state
    //      a glyph encodes is always composed into its row's name IN WORDS —
    //      stateLabel(), "available"/"not available"/"cannot be determined",
    //      "pass"/"warning" — which is also what the eye reads beside it.
    //   2. A ROLE WITHOUT AN EXPLICIT NAME IS NOT ALLOWED. Qt does fall back
    //      to an item's `text` property when Accessible.name is unset, and the
    //      fallback is silent the day it stops applying.
    //
    // Still missing, named rather than left to be discovered: the outcome line
    // is a StaticText and not an announcement, so a reader whose focus is on
    // the Erase button is not told what happened (FOUND 12 — a description is
    // not speech; Accessible.announce is the fix and it is Qt 6.8+).
}
