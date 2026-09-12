import QtQuick
import "../../../"
import "../../"
import "../../../components"
import "../../../components/config"

// Config → Firewall  (roadmap P1-044)
//
// APEX drops incoming connections by default. That is the right default and
// also the kind of change a user meets as a symptom rather than as a setting:
// a phone that stops casting, a printer that stops being found, a game that
// will not stream. A firewall a user cannot see is a firewall they disable at
// the first confusing symptom, so this page says what is dropped, what is
// open, and what they can open.
//
// ── WHY IT ONLY READS ───────────────────────────────────────────────────────
//
// `apex firewall allow` needs root. The shell's route to root is polkit, and
// P0-016 is the roadmap item where that stops being guesswork. Until then the
// page shows the command rather than running it — the same choice RecoveryPage
// makes for rollback, and for the same reason: a button that raises an
// authentication dialog nobody has tested is worse than a line of text that
// works when pasted.
//
// So the lifecycle is `live` and not `staged`: there is nothing held here. What
// the page shows is what the machine says, and the one thing it can be wrong
// about is named on the page — the unit being active is what it reads, and
// someone with root can flush the ruleset behind it.
CfgScroll {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    lifecycle: "live"

    // Set by ShellConfig: "the Firewall page is genuinely on screen". Without
    // it the service sweeps three processes every 30 seconds from shell startup
    // to logout, for a page most users open once.
    property bool onScreen: false

    ServiceRef {
        service: FirewallService
        active: root.onScreen
    }

    readonly property color _tone: {
        switch (FirewallService.statusTone) {
            case "ok":   return Theme.active
            case "warn": return Theme.danger
            case "bad":  return Theme.danger
            default:     return Theme.subtext
        }
    }

    // ── What is happening right now ──────────────────────────────────────────
    CfgSection {
        title: "Incoming connections"
        first: true

        Rectangle {
            x:      theme.px(10)
            width:  parent.width - theme.px(20)
            height: theme.px(66)
            radius: 8
            color:        Qt.rgba(root._tone.r, root._tone.g, root._tone.b, 0.06)
            border.color: Qt.rgba(root._tone.r, root._tone.g, root._tone.b, 0.18)
            border.width: 1

            Row {
                anchors.left:           parent.left
                anchors.leftMargin:     theme.px(12)
                anchors.verticalCenter: parent.verticalCenter
                spacing:                theme.px(10)

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text:  FirewallService.enforcing ? "󰕥" : "󰦝"
                    color: root._tone
                    font.pixelSize: theme.fs(20)
                }
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: theme.px(3)

                    Text {
                        text: FirewallService.checked
                            ? FirewallService.statusLine
                            : "Reading this machine…"
                        font.pixelSize: theme.fs(13)
                        font.weight:    Font.Medium
                        color:          Theme.text
                    }
                    Text {
                        // Says what was actually read, so the claim above can
                        // be judged. The unit's state is not the same question
                        // as "is the ruleset loaded" — someone with root can
                        // flush the table behind a running unit — and the page
                        // must not pretend it is.
                        text: "apex-firewall.service: " + FirewallService.unit
                            + "  ·  to read the live ruleset: " + FirewallService.readCommand
                        font.pixelSize: theme.fs(10)
                        font.family:    "JetBrains Mono"
                        color:          Theme.subtext
                    }
                }
            }

            CfgButton {
                anchors.right:          parent.right
                anchors.rightMargin:    theme.px(8)
                anchors.verticalCenter: parent.verticalCenter
                label:   FirewallService.busy ? "Checking…" : "Re-check"
                icon:    "󰑐"
                enabled: !FirewallService.busy
                onClicked: FirewallService.refresh()
            }
        }

        CfgRow {
            label:       "Turn it on"
            description: "The firewall ships enabled. If it is off, this is how it comes back. It needs root, so APEX Shell shows the command instead of asking for a password."
            // Not shown for `absent`: the unit is not on this machine, so
            // enabling it cannot work and offering the command would send the
            // user looking for the fault in the wrong place.
            visible:     FirewallService.checked && !FirewallService.enforcing
                         && FirewallService.unit !== "unknown"
                         && FirewallService.unit !== "absent"
            Text {
                text:           FirewallService.startCommand
                font.pixelSize: theme.fs(11)
                font.family:    "JetBrains Mono"
                color:          Theme.active
            }
        }
    }

    // ── The exceptions the policy carries on its own ─────────────────────────
    CfgSection {
        title: "Always allowed"
        visible: FirewallService.alwaysAllowed !== ""

        CfgRow {
            label:       FirewallService.alwaysAllowed
            hoverable:   false
            description: "These are in the policy itself and cannot be closed from here. ssh is the load-bearing one: APEX remote agents and `apex host run` are ssh, so closing it would strand you on the machine you were driving from."
        }
    }

    // ── What this user opened ────────────────────────────────────────────────
    CfgSection {
        title: "Ports you have opened"

        Text {
            x:              theme.px(10)
            width:          parent.width - theme.px(20)
            visible:        FirewallService.exceptions.length === 0
                                && FirewallService.emptyLine !== ""
            text:           FirewallService.emptyLine
            wrapMode:       Text.WordWrap
            font.pixelSize: theme.fs(11)
            color:          Theme.subtext
        }

        Repeater {
            model: FirewallService.exceptions
            delegate: CfgRow {
                required property var modelData
                label: modelData.name
                // A rejected exception is a port the user believes is open and
                // is not. Saying so here is the whole reason this row can be
                // red: the alternative is a page that lists a closed port
                // beside the working ones and lets the user go looking for the
                // problem somewhere else.
                status:      modelData.rejected
                                ? ("could not be applied — " + modelData.detail)
                                : (modelData.proto + " " + modelData.port)
                statusWarns: modelData.rejected
                description: "Close it again with: " + FirewallService.denyCommand(modelData.name)
            }
        }
    }

    // ── What they could open ─────────────────────────────────────────────────
    CfgSection {
        title: "Services you can open"
        visible: FirewallService.openable.length > 0

        Text {
            x:              theme.px(10)
            width:          parent.width - theme.px(20)
            text:           "By name rather than by port number, because \"5353/udp\" is something you paste from a forum and \"mdns\" is something you can decide about — and read back in six months and still understand. Each opens on every interface."
            wrapMode:       Text.WordWrap
            font.pixelSize: theme.fs(10)
            color:          Theme.subtext
        }

        Repeater {
            model: FirewallService.openable
            delegate: CfgRow {
                required property var modelData
                label:       modelData.name
                description: modelData.description
                Text {
                    text:           FirewallService.allowCommand(modelData.name)
                    font.pixelSize: theme.fs(10)
                    font.family:    "JetBrains Mono"
                    color:          Theme.active
                }
            }
        }
    }
}
