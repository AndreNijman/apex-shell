import QtQuick
import Quickshell
import "../../../"
import "../../../components"
import "../../../components/config"
// src/services — the module whose qmldir hands out PermissionsService, reached
// the same way RecoveryPage reaches RecoveryService.
import "../../"

// Config → Privacy & Permissions. Roadmap P1-061.
//
// ── The page this deliberately is not ────────────────────────────────────────
//
// The obvious version has one column of application names, one column of
// capability names, and a tick. It is wrong in the direction that gets somebody
// hurt: a tick beside "Camera" for a native binary reads as a claim that
// unticking it would stop the camera, and nothing on this system would.
//
// The second-most-obvious version fixes that by splitting the world into
// sandboxed and unsandboxed, and is also wrong. `io.github.cosmic_utils.camera`
// is a Flatpak whose manifest says `devices=all`: the host /dev is inside its
// sandbox, it opens /dev/video0 directly, the portal never sees the request,
// and its camera access is enforced by exactly what a native binary's is — the
// ACL logind writes on the device node. And there is no microphone portal in
// any version of xdg-desktop-portal, so no Flatpak's microphone is brokered
// either.
//
// So every row here carries the answer AND the enforcer, never one without the
// other, and there is NO CONTROL AT ALL on a row nothing can revoke. Not a
// disabled switch — a disabled switch invites the owner to wonder what is
// broken about their machine, where a sentence tells them the truth, which is
// that nothing on this system can do what they are asking for.
//
// ── Ordering ─────────────────────────────────────────────────────────────────
//
// Rows are ordered by enforcer strength rather than alphabetically, so that
// everything the machine actually controls sits above everything it merely
// observes. The sort lives in permissions.js, where the node suite can assert
// it.
//
// ── What this page is allowed to do ──────────────────────────────────────────
//
// Read-only by default. `apex permissions list --json` writes nothing and
// raises no authentication prompt. A revocation runs only on an explicit
// press, writes to the user's own permission store or override file, and needs
// no root — so this page raises no polkit prompt either. See
// PermissionsService's header.
CfgScroll {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes

    // Criterion 1. Live: a control here acts when pressed. The rows whose
    // change lands at the next launch rather than at the press say so on their
    // own row, in their own words, from the OS side.
    lifecycle: "live"
    lifecycleError: PermissionsService.lastError

    // Set by ShellConfig and Nexus: "this page is genuinely on screen".
    // Declared because PermissionsService costs a `flatpak info` per installed
    // application per sweep and is refcounted on it; PageRegistry marks this
    // page needsScreen: true so both hosts bind it. NOT `visible` — an Item
    // inside a hidden window still reports visible: true, which is how the
    // stats page kept six pollers running after the dashboard was closed.
    property bool onScreen: false

    // The whole of "no process runs while nobody is looking".
    ServiceRef {
        service: PermissionsService
        active:  root.onScreen
    }

    // Tone name -> Theme token. The names come from permissions.js, which has
    // no Theme and must not: node drives it in the test suite.
    //
    // `never_asked` and `no_primitive` share `subtext`, and neither is green.
    // "Nothing has asked yet" is not "you are protected", and "this session
    // brokers nothing here" is not "it is switched off" — a colour that said
    // either would be the tick, in another form.
    function toneColor(tone) {
        if (tone === "active") return Theme.active
        if (tone === "danger") return Theme.danger
        return Theme.subtext
    }

    // ── Header ───────────────────────────────────────────────────────────────
    CfgSection {
        title: "Privacy & Permissions"
        first: true

        Item {
            width:  parent.width
            height: theme.px(62)

            Row {
                x: theme.px(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: theme.px(12)

                Text {
                    text:           "󰒃"
                    font.pixelSize: theme.fs(28)
                    color:          PermissionsService.available ? Theme.active : Theme.subtext
                    anchors.verticalCenter: parent.verticalCenter
                }
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: theme.px(3)

                    Text {
                        text: {
                            if (!PermissionsService.checked) return "Reading what this session enforces…"
                            if (!PermissionsService.available) return "Permissions could not be read"
                            return PermissionsService.apps.length
                                + " application" + (PermissionsService.apps.length === 1 ? "" : "s")
                        }
                        font.pixelSize: theme.fs(15)
                        font.weight:    Font.Medium
                        color:          Theme.text
                    }
                    Text {
                        text: PermissionsService.available
                            ? (PermissionsService.session.desktop + "  ·  " + PermissionsService.session.summary)
                            : PermissionsService.unavailableReason
                        font.pixelSize: theme.fs(10)
                        color:          Theme.subtext
                        font.family:    "JetBrains Mono"
                    }
                }
            }

            CfgButton {
                anchors.right:          parent.right
                anchors.rightMargin:    theme.px(8)
                anchors.verticalCenter: parent.verticalCenter
                label:   PermissionsService.busy ? "Reading…" : "Re-check"
                icon:    "󰑐"
                enabled: !PermissionsService.busy
                onClicked: PermissionsService.refresh()
            }
        }

        Text {
            x:     theme.px(10)
            width: parent.width - theme.px(20)
            text: "These are not all the same kind of permission, and this page "
                + "will not pretend they are. Some are brokered by the desktop "
                + "portal and can be withdrawn from one app. Some are built into "
                + "an app's sandbox and change only when it next starts. And some "
                + "come from your login session itself — every program you run "
                + "has them, and nothing here can take them from one app alone. "
                + "Each row says which it is."
            font.pixelSize: theme.fs(10)
            color:    Theme.subtext
            wrapMode: Text.WordWrap
        }
        Item { width: parent.width; height: theme.px(6) }
    }

    // ── What this session brokers at all ─────────────────────────────────────
    // Which portal interfaces exist is a property of the LOGIN, not of the
    // machine: APEX's Hyprland session resolves `default=hyprland;gtk` and
    // reaches neither Usb nor Secret, where its niri session reaches
    // gnome.portal and gets both. An owner who sees a capability go missing
    // between two logins is owed the reason.
    CfgSection {
        title: "What this session can broker"
        visible: PermissionsService.available

        CfgRow {
            label: "Portal interfaces"
            description: "Only a capability with one of these behind it can be refused per app."
            hoverable: false

            Text {
                width: theme.px(230)
                text: PermissionsService.session.brokered.join(", ")
                font.family:    "JetBrains Mono"
                font.pixelSize: theme.fs(10)
                color:          Theme.active
                wrapMode:       Text.WordWrap
            }
        }
    }

    // ── One section per application ──────────────────────────────────────────
    Repeater {
        // A COUNT, not the array. `model: <JS array>` recreates every delegate
        // whenever the array's contents change, and every row changes on every
        // sweep — so the whole page would be destroyed and rebuilt every 30
        // seconds. See src/modules/Left/Workspaces.qml, which measured this.
        model: PermissionsService.available ? PermissionsService.apps.length : 0

        CfgSection {
            id: appSection
            required property int index
            readonly property var app: PermissionsService.apps[index]

            title: app ? app.id : ""
            visible: !!app

            Text {
                x:     theme.px(10)
                width: parent.width - theme.px(20)
                text: (app && app.native
                       ? "A program installed outside a sandbox. "
                       : "")
                    + (app ? app.summary : "")
                font.pixelSize: theme.fs(10)
                color:          Theme.subtext
                wrapMode:       Text.WordWrap
            }

            Repeater {
                model: appSection.app ? appSection.app.rows.length : 0

                Item {
                    id: rowItem
                    required property int index
                    // Through the section's id, never a parent chain: a
                    // delegate's parent is whatever the component happens to
                    // wrap its children in today.
                    readonly property var row: appSection.app.rows[index]
                    readonly property var controls: PermissionsService.controlsFor(rowItem.row)

                    width:  parent.width
                    height: col.implicitHeight + theme.px(14)

                    Column {
                        id: col
                        x:       theme.px(10)
                        width:   parent.width - theme.px(20)
                        y:       theme.px(7)
                        spacing: theme.px(3)

                        Row {
                            width:   parent.width
                            spacing: theme.px(8)

                            Text {
                                width:          theme.px(150)
                                text:           rowItem.row.label
                                font.pixelSize: theme.fs(12)
                                color:          Theme.text
                                elide:          Text.ElideRight
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            // The answer and the enforcer, always together.
                            // Never one without the other, and never a tick.
                            Text {
                                text:           rowItem.row.headline
                                font.pixelSize: theme.fs(12)
                                color:          root.toneColor(rowItem.row.tone)
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                text:           "· enforced by " + rowItem.row.enforcerLabel
                                font.family:    "JetBrains Mono"
                                font.pixelSize: theme.fs(10)
                                color:          Theme.subtext
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        // Where it came from. Criterion 3 asks for origin, and
                        // this is the provenance of the permission itself, not
                        // of the request — "who decided" rather than "who is
                        // asking".
                        Text {
                            width:          parent.width
                            text:           "from: " + rowItem.row.originLabel
                            font.pixelSize: theme.fs(10)
                            color:          Theme.subtext
                            wrapMode:       Text.WordWrap
                        }

                        // The sentence that replaces the control on a row
                        // nothing can revoke, and the measured uncertainty
                        // where there is one. Both come from the OS side; the
                        // page does not compose either.
                        Text {
                            width:          parent.width
                            visible:        text !== ""
                            text:           rowItem.controls.length === 0 ? rowItem.row.enforcerWhy : ""
                            font.pixelSize: theme.fs(10)
                            color:          Theme.subtext
                            wrapMode:       Text.WordWrap
                        }
                        Text {
                            width:          parent.width
                            visible:        rowItem.row.caveat !== ""
                            text:           rowItem.row.caveat
                            font.pixelSize: theme.fs(10)
                            color:          Theme.warning
                            wrapMode:       Text.WordWrap
                        }

                        // Controls, only where there are any. "Never" and "Ask
                        // again" are two different intentions and get two
                        // buttons; a single button would be answering a
                        // question the owner did not ask.
                        // When a change lands. Stated beside the buttons
                        // rather than implied by them: a sandbox override does
                        // nothing to a window that is already open, and a page
                        // that let the owner assume otherwise would be making
                        // the same kind of promise this whole item is about.
                        Text {
                            width:          parent.width
                            visible:        rowItem.controls.length > 0
                            text:           rowItem.row.timingLabel
                            font.pixelSize: theme.fs(10)
                            color:          Theme.subtext
                            wrapMode:       Text.WordWrap
                        }

                        Row {
                            visible: rowItem.controls.length > 0
                            spacing: theme.px(8)

                            Repeater {
                                model: rowItem.controls.length

                                CfgButton {
                                    required property int index
                                    readonly property var control: rowItem.controls[index]

                                    label:   control.label
                                    variant: control.verb === "deny" ? "danger" : "default"
                                    enabled: !PermissionsService.busy
                                    onClicked: PermissionsService.revoke(rowItem.row, control.verb)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ── When nothing could be read ───────────────────────────────────────────
    // An empty list and an unreadable machine look identical and mean opposite
    // things. This page says which, because a permissions page that rendered a
    // failed read as "nothing holds any permissions" would reassure an owner at
    // the exact moment it stopped being able to check.
    CfgSection {
        title: "Nothing could be read"
        visible: PermissionsService.checked && !PermissionsService.available

        Text {
            x:     theme.px(10)
            width: parent.width - theme.px(20)
            text: PermissionsService.unavailableReason
                + "\n\nThis is not the same as having no permissions. Nothing "
                + "below this line was checked, so nothing below this line is "
                + "being claimed."
            font.pixelSize: theme.fs(11)
            color:          Theme.warning
            wrapMode:       Text.WordWrap
        }
        Item { width: parent.width; height: theme.px(6) }
    }

    Item { width: parent.width; height: 10 }
}
