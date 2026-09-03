import QtQuick
import "../"
import "../../"

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
// while the verbs above are not.

Item {
    id: srow

    required property var session

    readonly property bool live:
        srow.session.exit_code === null && srow.session.exit_signal === null
    readonly property bool needsYou:
        srow.session.state === "waiting_for_user"
        || srow.session.state === "permission_request"

    height: Theme.fs(30)

    Row {
        anchors.fill: parent
        anchors.leftMargin: Theme.fs(30)
        anchors.rightMargin: Theme.fs(8)
        spacing: Theme.fs(8)

        // The tree line, so a session reads as belonging to the host above it
        // rather than as a sibling of it.
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "└"
            color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.25)
            font.pixelSize: Theme.fs(10)
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.fs(16)
            horizontalAlignment: Text.AlignHCenter
            text: AgentService.stateIcon(srow.session.state)
            font.pixelSize: Theme.fs(13)
            color: srow.needsYou ? Theme.active
                 : srow.session.state === "failed" ? Theme.wsUrgent
                 : srow.live ? Theme.text : Theme.subtext

            // Same rule as the local row: a working session animates and
            // nothing else does, so motion in the list means "this is
            // changing". Deliberately identical, because a remote agent working
            // and a local one working are the same fact about the world.
            SequentialAnimation on opacity {
                running: srow.session.state === "working"
                loops: Animation.Infinite
                NumberAnimation { to: 0.45; duration: 900; easing.type: Easing.InOutQuad }
                NumberAnimation { to: 1.0;  duration: 900; easing.type: Easing.InOutQuad }
            }
            onOpacityChanged: if (srow.session.state !== "working") opacity = 1.0
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: ((srow.session.agent || "agent").charAt(0).toUpperCase()
                   + (srow.session.agent || "agent").slice(1))
            color: Theme.text
            font.pixelSize: Theme.fs(11)
            font.bold: true
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "#" + srow.session.id
            color: Theme.subtext
            font.pixelSize: Theme.fs(9)
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: srow.width - Theme.fs(190)
            elide: Text.ElideRight
            text: {
                var bits = []
                var where = srow.session.project_name
                    || AgentService._basename(srow.session.cwd)
                if (where) bits.push(where)
                bits.push(AgentService.stateLabel(srow.session.state))
                var e = AgentService.elapsed(srow.session)
                if (e) bits.push(e)
                return bits.join("  ·  ")
            }
            color: srow.needsYou ? Theme.active : Theme.subtext
            font.pixelSize: Theme.fs(9)
        }
    }
}
