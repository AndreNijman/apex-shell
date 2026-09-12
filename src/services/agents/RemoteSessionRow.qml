import QtQuick
import "../"
import "../../"
import "../agentstate.js" as AgentState
import "../agentlifecycle.js" as Lifecycle

// One agent session on a REMOTE device.
//
// ── Read-only, and that is the point ────────────────────────────────────────
//
// SessionRow.qml is a button: the row IS the navigation, and its controls call
// AgentService.pause / .kill / .focusTerminal with `session.id`. Reusing it
// here would be a real defect, not a cosmetic one. A session id is issued by
// the runtime that owns the session, so `#3` on the desktop and `#3` on this
// laptop are different agents — and AgentService talks to the LOCAL daemon.
// Clicking Stop on a remote row would have killed an unrelated local agent, and
// clicking the row would have focused a local terminal belonging to something
// else entirely. Nothing would have logged an error.
//
// So this row has no TapHandler, no MouseArea and no controls at all. Not
// "disabled" ones: absent ones, because a greyed-out Stop button still invites
// the question of why it is there. Getting to a remote session means a terminal
// on the far side of an ssh, and §3 is explicit that the Agent Center is a
// supervisor and a navigator rather than a replacement for the terminal — so
// the section prints the `apex host run -t …` line once and this row prints
// status.
//
// It does read AgentService's stateIcon / stateLabel / elapsed. Those are pure
// formatters over a state string and a record's own timestamps: they take no id
// and they reach no runtime, which is the distinction that makes them safe here
// while the verbs above are not. StateBadge is safe on the same grounds: it
// takes a state string and returns a picture of it.

Item {
    id: srow
    readonly property ThemeSet theme: Theme.setForHeight(Screen.height)   // P1-040: this output's sizes


    required property var session

    readonly property bool live:
        srow.session.exit_code === null && srow.session.exit_signal === null
    readonly property bool needsYou: AgentState.needsYou(srow.session.state)

    height: theme.px(30)

    Row {
        anchors.fill: parent
        anchors.leftMargin: theme.px(30)
        anchors.rightMargin: theme.px(8)
        spacing: theme.px(8)

        // The tree line, so a session reads as belonging to the host above it
        // rather than as a sibling of it.
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "└"
            color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.25)
            font.pixelSize: theme.fs(10)
        }

        // The same badge the local row draws, smaller. Deliberately identical,
        // because a remote agent working and a local one working are the same
        // fact about the world — including the pulse, which lives in the badge
        // so the two rows cannot drift apart again.
        StateBadge {
            id: badge
            anchors.verticalCenter: parent.verticalCenter
            sessionState: srow.session.state
            size: theme.px(18)
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: AgentState.agentName(srow.session.agent)
            color: Theme.text
            font.pixelSize: theme.fs(11)
            font.bold: true
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "#" + srow.session.id
            color: Theme.subtext
            font.pixelSize: theme.fs(9)
        }

        // Same split as the local row: the state word carries the tone, the
        // rest stays muted, and only the project elides.
        Row {
            id: meta
            anchors.verticalCenter: parent.verticalCenter
            width: srow.width - theme.fs(190)
            spacing: 0

            readonly property string where:
                srow.session.project_name
                || AgentService._basename(srow.session.cwd)
                || ""
            readonly property string tail: {
                var e = AgentService.elapsed(srow.session)
                return e ? "  ·  " + e : ""
            }

            Text {
                text: meta.where === "" ? "" : meta.where + "  ·  "
                color: Theme.subtext
                font.pixelSize: theme.fs(9)
                elide: Text.ElideRight
                width: Math.max(0, Math.min(implicitWidth,
                         meta.width - stateWord.implicitWidth - tailText.implicitWidth))
            }
            // §19's "remote-host agent", and the reason the classifier takes
            // a source at all: this record's own `request_origin` says
            // `local-terminal`, because from that machine's point of view a
            // person is in front of a terminal. Reading the field alone would
            // label every one of these a local PTY on this machine.
            Text {
                text: "  ·  " + Lifecycle.badge(srow.session, Lifecycle.FROM_HOST)
                color: Theme.subtext
                font.pixelSize: theme.fs(9)
            }
            Text {
                id: stateWord
                text: AgentService.stateLabel(srow.session.state)
                color: badge.toneColor
                font.pixelSize: theme.fs(9)
                font.bold: true
            }
            Text {
                id: tailText
                text: meta.tail
                color: Theme.subtext
                font.pixelSize: theme.fs(9)
            }
        }
    }
}
