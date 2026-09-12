import QtQuick
import Quickshell
import "../../../"
import "../../../components"
import "../../../components/config"
// src/services — the module whose qmldir hands out LidService, reached the same
// way RecoveryPage reaches RecoveryService.
import "../../"

// Config → Closing the Lid. Roadmap P1-063.
//
// Andre asked for this in his own words:
//
//   "if i close my laptop lid without shutting down, most things pause to save
//    battery, but all agents and whatever theyre using/doing or whatever can
//    stay running, also staying with the vpn — like if i close my laptop at
//    school and codex is running (which needs vpn to work) it keeps working."
//
// ── The page this deliberately is not ────────────────────────────────────────
//
// The obvious version is a single switch labelled "Keep working with the lid
// closed". It is wrong in the direction that loses somebody's work: it implies
// the machine will do what the switch says, and on this laptop, today, it very
// often will not — and for a reason that has nothing to do with the switch.
// logind consults `HandleLidSwitchDocked` (default `ignore`) BEFORE it consults
// any inhibitor, so an external display makes the lid do nothing at all,
// whatever this page says and whether or not APEX is running. An owner who
// unplugs their monitor at school and finds the machine asleep would have been
// told "on" by that switch every time they looked.
//
// So the page LEADS with what logind will do, before anything it can change,
// and gives three answers where a switch gives two: it acts on the lid, it will
// not act on the lid, or that could not be established. The third is not "yes".
//
// ── Every input, because "why" was a criterion ───────────────────────────────
//
// Criterion 6 is "the owner can see why the machine did what it did". That is
// not one sentence: the decision comes from the lid switch, live agent
// sessions, a temperature, a charge and a pin, and any of the five can be the
// reason. All five are listed with what they read, so the answer to "why is it
// going to suspend" is on the page rather than in a journal.
//
// ── What this page is allowed to do ──────────────────────────────────────────
//
// Read-only except for the pin. `apex lid status --json` and `apex lid report
// --json` write nothing. `apex lid pin` writes the owner's own
// ~/.config/apex/lid.toml and needs no privilege: the inhibitor it controls is
// `allow_active=yes` for an ordinary session, measured three ways. There is no
// `sudo` and no `pkexec` on this surface and no polkit prompt can come from it.
// See LidService's header.
//
// Nothing here suspends the machine, and nothing here can. The driver does
// that, as root, and this is a window onto it.
CfgScroll {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes

    // Live: pressing a pill here rewrites the policy file, and the ROOT driver
    // re-reads it on its next poll. So the press lands within one driver tick
    // rather than at the next login — which is what "live" claims — and the
    // read-back on each row is what proves it did.
    lifecycle: "live"
    lifecycleError: LidService.lastError

    // Set by ShellConfig and Nexus: "this page is genuinely on screen".
    // Declared because LidService spawns two `apex` processes per sweep and is
    // refcounted on it; PageRegistry marks this page needsScreen: true so both
    // hosts bind it. NOT `visible` — an Item inside a hidden window still
    // reports visible: true, which is how the stats page kept six pollers
    // running after the dashboard was closed.
    property bool onScreen: false

    // The whole of "no process runs while nobody is looking".
    ServiceRef {
        service: LidService
        active:  root.onScreen
    }

    // Tone name -> Theme token. The names come from lid.js, which has no Theme
    // and must not: node drives it in tests/lid-test.js.
    //
    // `warn` is its own colour and is NOT `danger`. A docked machine is not
    // broken — it is a machine whose lid APEX does not control — and painting
    // that red would teach the reader that red means nothing here.
    function toneColor(tone) {
        if (tone === "active") return Theme.active
        if (tone === "danger") return Theme.danger
        if (tone === "warn")   return Theme.warning
        return Theme.subtext
    }

    // ── Header: the one-line answer to "can I shut it now?" ──────────────────
    CfgSection {
        title: "Closing the Lid"
        first: true

        Item {
            width:  parent.width
            height: theme.px(66)

            Row {
                x: theme.px(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: theme.px(12)

                Text {
                    text:           "󰶐"
                    font.pixelSize: theme.fs(28)
                    color:          LidService.available
                                      ? root.toneColor(LidService.decision.tone)
                                      : Theme.subtext
                    anchors.verticalCenter: parent.verticalCenter
                }
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: theme.px(3)

                    Text {
                        // "Not asked yet" and "asked, and the answer is
                        // nothing" look identical and mean opposite things.
                        text: LidService.checked
                                ? LidService.headline
                                : "Reading what the lid would do…"
                        font.pixelSize: theme.fs(15)
                        font.weight:    Font.Medium
                        color:          Theme.text
                    }
                    Text {
                        text: LidService.available
                                ? LidService.decision.why
                                : LidService.unavailableReason
                        font.pixelSize: theme.fs(10)
                        color: LidService.available ? Theme.subtext : Theme.danger
                        font.family:    "JetBrains Mono"
                        width:          theme.px(420)
                        wrapMode:       Text.WordWrap
                    }
                }
            }

            CfgButton {
                anchors.right:          parent.right
                anchors.rightMargin:    theme.px(8)
                anchors.verticalCenter: parent.verticalCenter
                label:   LidService.busy ? "Reading…" : "Re-check"
                icon:    "󰑐"
                enabled: !LidService.busy
                onClicked: LidService.refresh()
            }
        }

        // A NOTE, never a failure. On any machine where root has a live
        // /run/user/0 this is present on every single read, because the OS side
        // reports every policy file it could not open rather than silently
        // skipping one — "permission denied is not absence", and a silently
        // skipped pin is a machine doing the opposite of what its owner asked.
        // Painting it in the danger tone would cry wolf on every load and teach
        // the owner to ignore the one time it mattered.
        Item {
            width:   parent.width
            height:  noteText.implicitHeight + theme.px(10)
            visible: LidService.policyNote !== ""

            Text {
                id: noteText
                x:     theme.px(10)
                y:     theme.px(5)
                width: parent.width - theme.px(20)
                text: "Policy files this read could not open: " + LidService.policyNote
                    + ".  Normal on a machine where another account is logged in; "
                    + "the policy actually in force is above."
                font.pixelSize: theme.fs(10)
                color:    Theme.subtext
                wrapMode: Text.WordWrap
            }
        }
    }

    // ── What logind will do, before anything this page controls ──────────────
    CfgSection {
        title: "What this machine does with the lid"
        visible: LidService.available

        Item {
            width:  parent.width
            height: logindCol.implicitHeight + theme.px(16)

            Column {
                id: logindCol
                x:       theme.px(10)
                y:       theme.px(8)
                width:   parent.width - theme.px(20)
                spacing: theme.px(4)

                Text {
                    width:          parent.width
                    text:           LidService.logind.headline
                    font.pixelSize: theme.fs(12)
                    color:          root.toneColor(LidService.logind.tone)
                    wrapMode:       Text.WordWrap
                }
                Text {
                    width:          parent.width
                    text:           LidService.logind.detail
                    font.pixelSize: theme.fs(10)
                    color:          Theme.subtext
                    wrapMode:       Text.WordWrap
                    visible:        LidService.logind.detail !== ""
                }
            }
        }

        CfgRow {
            label: "External displays"
            description: "Counted from the connected DRM connectors that are not this laptop's own panel."
            hoverable: false
            status: LidService.logind.externalDisplays + ""
            // The number is the reason the lid does nothing, so it is the one
            // readout on the page that goes amber on its own.
            statusWarns: LidService.logind.externalDisplays > 0
        }

        CfgRow {
            label: "handle-lid-switch"
            // `BlockInhibited` is the authoritative check and `systemd-inhibit
            // --list` is not: the list says what asked, this says what logind
            // believes it must not do.
            description: "What logind itself reports it is currently blocked from doing."
            hoverable: false
            status: LidService.logind.blockInhibited !== ""
                      ? LidService.logind.blockInhibited
                      : "nothing is blocked"
            statusWarns: false
        }
    }

    // ── The pin: the only thing this page writes ─────────────────────────────
    CfgSection {
        title: "Keep working with the lid closed"

        CfgRow {
            label: "When the lid shuts"
            description: "Follow live work: stay awake only while an agent session is running, "
                       + "which is measured rather than remembered. Always keep working: stay "
                       + "awake whatever is running — the thermal and battery guards still "
                       + "apply. Always suspend: sleep immediately on every close, which will "
                       + "kill an agent mid-task."
            effect: "now"

            CfgSegmented {
                options: [
                    { "value": "auto", "label": LidService.pinLabel("auto") },
                    { "value": "on",   "label": LidService.pinLabel("on") },
                    { "value": "off",  "label": LidService.pinLabel("off") }
                ]
                value: LidService.pin
                enabled: LidService.available && !LidService.busy
                onSelected: function (v) { LidService.setPin(v) }
            }
        }

        Item {
            width:   parent.width
            height:  guardText.implicitHeight + theme.px(10)

            Text {
                id: guardText
                x:     theme.px(10)
                y:     theme.px(5)
                width: parent.width - theme.px(20)
                // Said here rather than only in the report, because the moment
                // to learn that a hot laptop suspends anyway is before the bag,
                // not after it.
                text: "A shut lid has no airflow, so two guards suspend the machine whatever "
                    + "this is set to: a thermal guard when the temperature reaches its own "
                    + "firmware's critical trip less the headroom below, and a battery guard "
                    + "at the floor, which checkpoints live work first. Whichever fires is "
                    + "named in the report after you reopen it."
                font.pixelSize: theme.fs(10)
                color:    Theme.subtext
                wrapMode: Text.WordWrap
            }
        }
    }

    // ── The five inputs the decision is made from ────────────────────────────
    // Criterion 6 is "the owner can see WHY", and the why is these, not a
    // sentence about them.
    CfgSection {
        title: "What the decision is made from"
        visible: LidService.available

        CfgRow {
            label: "Lid"
            description: "Read from the ACPI button, with UPower as a second source."
            hoverable: false
            status: LidService.status.lid
        }
        CfgRow {
            label: "Live work"
            description: "Agent sessions running for any logged-in user. Measured every sweep, "
                       + "never a mode you have to remember to switch off."
            hoverable: false
            status: LidService.work.text
            // "Could not be read" is NOT "nothing is running": the machine
            // suspends on an unanswered question, because a laptop that stays
            // awake on one cooks in a bag.
            statusWarns: LidService.work.tone === "danger"
        }
        CfgRow {
            label: "Temperature"
            description: "The hottest sensor this machine exposes, against the critical trip its "
                       + "own firmware declares."
            hoverable: false
            status: LidService.thermal.text
            statusWarns: LidService.thermal.tone === "danger"
        }
        CfgRow {
            label: "Charge"
            hoverable: false
            status: LidService.charge.text
            statusWarns: LidService.charge.tone === "danger"
        }
        CfgRow {
            label: "VPN"
            description: "NetworkManager's connections AND sing-box's tun device, which "
                       + "NetworkManager never lists."
            hoverable: false
            status: LidService.vpn.text
            statusWarns: LidService.vpn.tone === "danger"
        }
    }

    // ── After you reopened it ────────────────────────────────────────────────
    // Andre's last sentence, and criterion 6's second half: "after reopening,
    // the machine says what happened". Four things — how long it stayed up,
    // what ran, whether the VPN held, what the battery cost — and all four are
    // separate rows, because a summary line naming three of them would read
    // fine and answer less.
    CfgSection {
        title: "The last time the lid was shut"

        Item {
            width:   parent.width
            height:  emptyText.implicitHeight + theme.px(14)
            visible: !LidService.report.has

            Text {
                id: emptyText
                x:     theme.px(10)
                y:     theme.px(7)
                width: parent.width - theme.px(20)
                // Three answers, not two. A record that EXISTS and could not be
                // read is not a machine that has never slept.
                text: !LidService.report.ok
                        ? ("The record could not be read — " + LidService.report.reason)
                        : (LidService.checked
                             ? "No lid-closed period has been recorded on this machine yet."
                             : "Reading the record…")
                font.pixelSize: theme.fs(11)
                color:    LidService.report.ok ? Theme.subtext : Theme.danger
                wrapMode: Text.WordWrap
            }
        }

        Item {
            width:   parent.width
            height:  summaryText.implicitHeight + theme.px(14)
            visible: LidService.report.has

            Text {
                id: summaryText
                x:     theme.px(10)
                y:     theme.px(7)
                width: parent.width - theme.px(20)
                text:  LidService.report.period.summary
                font.pixelSize: theme.fs(12)
                color:          Theme.text
                wrapMode:       Text.WordWrap
            }
        }

        CfgRow {
            label: "How long"
            hoverable: false
            visible: LidService.report.has
            status: LidService.report.period.durationText
                  + (LidService.report.period.stillClosed ? " (still shut)" : "")
        }
        CfgRow {
            label: "What was running"
            hoverable: false
            visible: LidService.report.has
            status: LidService.report.period.sessionsAtClose
                  + " agent session"
                  + (LidService.report.period.sessionsAtClose === 1 ? "" : "s")
        }
        CfgRow {
            label: "The VPN"
            hoverable: false
            visible: LidService.report.has
            status: LidService.report.period.vpnText
            // The answer this whole criterion exists to catch, and the one that
            // could not be produced at all before the driver learned to
            // remember a tunnel that went away.
            statusWarns: LidService.report.period.vpnHeld === false
        }
        CfgRow {
            label: "Battery"
            hoverable: false
            visible: LidService.report.has
            status: LidService.report.period.chargeText
        }
        CfgRow {
            label: "Ended by"
            description: "Which guard suspended the machine, when one did."
            hoverable: false
            visible: LidService.report.has && LidService.report.period.endedBy !== ""
            status: LidService.report.period.endedByLabel
            statusWarns: true
        }

        // What was actually powered down, and — separately — what was not and
        // why. The second list is the half that gets dropped, and it is the
        // half that explains a battery that drained anyway.
        Item {
            width:   parent.width
            height:  downCol.implicitHeight + theme.px(16)
            visible: LidService.report.has
                     && LidService.report.period.poweredDown.length > 0

            Column {
                id: downCol
                x:       theme.px(10)
                y:       theme.px(8)
                width:   parent.width - theme.px(20)
                spacing: theme.px(3)

                Text {
                    text:           "Powered down"
                    font.pixelSize: theme.fs(10)
                    font.weight:    Font.Bold
                    color:          Theme.subtext
                }
                Repeater {
                    // A COUNT, not the array: `model: <JS array>` recreates
                    // every delegate whenever the array's contents change, and
                    // this one changes on every sweep.
                    model: LidService.report.has
                             ? LidService.report.period.poweredDown.length : 0
                    Text {
                        required property int index
                        width:          downCol.width
                        text:           "· " + LidService.report.period.poweredDown[index]
                        font.family:    "JetBrains Mono"
                        font.pixelSize: theme.fs(10)
                        color:          Theme.active
                        wrapMode:       Text.WordWrap
                    }
                }
            }
        }

        Item {
            width:   parent.width
            height:  skipCol.implicitHeight + theme.px(16)
            visible: LidService.report.has
                     && LidService.report.period.skipped.length > 0

            Column {
                id: skipCol
                x:       theme.px(10)
                y:       theme.px(8)
                width:   parent.width - theme.px(20)
                spacing: theme.px(3)

                Text {
                    text:           "Left alone, and why"
                    font.pixelSize: theme.fs(10)
                    font.weight:    Font.Bold
                    color:          Theme.subtext
                }
                Repeater {
                    model: LidService.report.has
                             ? LidService.report.period.skipped.length : 0
                    Text {
                        required property int index
                        readonly property var skip: LidService.report.period.skipped[index]
                        width:          skipCol.width
                        text:           "· " + skip.what + " — " + skip.why
                        font.family:    "JetBrains Mono"
                        font.pixelSize: theme.fs(10)
                        color:          Theme.subtext
                        wrapMode:       Text.WordWrap
                    }
                }
            }
        }
    }
}
