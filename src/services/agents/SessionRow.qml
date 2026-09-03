import QtQuick
import "../"
import "../../"

// One agent session in the Agent Center.
//
// §3 asks for project, process, elapsed time and high-level state, and for a
// click to focus the existing terminal. That last one is the reason this row is
// a button and not a label: the row IS the navigation.
//
// The controls are deliberately few. Pause, resume and kill are here because
// they are lifecycle operations the runtime owns and no terminal offers. Diff,
// undo and checkpoint are NOT here — they change a project's contents, and a
// destructive action behind one unconfirmed click in a status list is how
// people lose work. Those stay in the CLI where `apex agent undo` asks first.

Rectangle {
    id: row

    required property var session

    readonly property bool live:
        session.exit_code === null && session.exit_signal === null
    readonly property bool needsYou:
        session.state === "waiting_for_user" || session.state === "permission_request"

    height: Theme.px(52)
    radius: Theme.px(8)
    color: hover.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07)
                         : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.03)
    border.width: row.needsYou ? 1 : 0
    border.color: Theme.active

    Behavior on color { ColorAnimation { duration: 90 } }

    HoverHandler { id: hover }

    // The whole row focuses the terminal. §3: "Focus the existing terminal when
    // the user clicks an agent in APEX Shell."
    TapHandler {
        onTapped: AgentService.focusTerminal(row.session.id)
    }

    Row {
        anchors.fill: parent
        anchors.leftMargin: Theme.px(10)
        anchors.rightMargin: Theme.px(8)
        spacing: Theme.px(10)

        // ── State ─────────────────────────────────────────────────────────────
        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.px(22)
            horizontalAlignment: Text.AlignHCenter
            text: AgentService.stateIcon(row.session.state)
            font.pixelSize: Theme.fs(17)
            color: row.needsYou ? Theme.active
                 : row.session.state === "failed" ? Theme.wsUrgent
                 : row.live ? Theme.text : Theme.subtext

            // A working session animates; nothing else does. Motion in a status
            // list should mean "this is changing", or it is just noise.
            SequentialAnimation on opacity {
                running: row.session.state === "working"
                loops: Animation.Infinite
                NumberAnimation { to: 0.45; duration: 900; easing.type: Easing.InOutQuad }
                NumberAnimation { to: 1.0;  duration: 900; easing.type: Easing.InOutQuad }
            }
            onOpacityChanged: if (row.session.state !== "working") opacity = 1.0
        }

        // ── Identity ──────────────────────────────────────────────────────────
        Column {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Theme.fs(22) - controls.width - Theme.fs(40)
            spacing: Theme.px(2)

            Row {
                spacing: Theme.px(6)
                Text {
                    text: AgentService._agentLabel(row.session)
                    color: Theme.text
                    font.pixelSize: Theme.fs(12)
                    font.bold: true
                }
                Text {
                    text: "#" + row.session.id
                    color: Theme.subtext
                    font.pixelSize: Theme.fs(10)
                    anchors.verticalCenter: parent.verticalCenter
                }
                // §7: a worktree is the unit of parallel work, so say which one
                // rather than making every branch's session look identical.
                Rectangle {
                    visible: !!row.session.worktree
                    anchors.verticalCenter: parent.verticalCenter
                    radius: Theme.px(3)
                    color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.18)
                    width: wtLabel.implicitWidth + Theme.fs(8)
                    height: wtLabel.implicitHeight + Theme.fs(3)
                    Text {
                        id: wtLabel
                        anchors.centerIn: parent
                        text: "󰘬 " + row.session.worktree
                        color: Theme.active
                        font.pixelSize: Theme.fs(9)
                    }
                }
            }

            Text {
                width: parent.width
                elide: Text.ElideRight
                text: {
                    var bits = []
                    var where = row.session.project_name
                        || AgentService._basename(row.session.cwd)
                    if (where) bits.push(where)
                    bits.push(AgentService.stateLabel(row.session.state))
                    var e = AgentService.elapsed(row.session)
                    if (e) bits.push(e)
                    if (!row.live && row.session.exit_code !== null
                        && row.session.exit_code !== 0)
                        bits.push("exit " + row.session.exit_code)
                    return bits.join("  ·  ")
                }
                color: row.needsYou ? Theme.active : Theme.subtext
                font.pixelSize: Theme.fs(10)
            }
        }

        // ── Controls ──────────────────────────────────────────────────────────
        Row {
            id: controls
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.px(2)

            // Pause and Resume are the same slot, not two buttons. Showing
            // both means one of them is always wrong, and the runtime reports
            // `paused` precisely so the shell does not have to guess.
            SmallIconButton {
                visible: row.live
                icon: row.session.paused ? "󰐊" : "󰏤"
                tip:  row.session.paused ? "Resume" : "Pause"
                onActivated: row.session.paused
                    ? AgentService.resume(row.session.id)
                    : AgentService.pause(row.session.id)
            }
            SmallIconButton {
                visible: row.live
                icon: "󰓛"
                tip: "Stop"
                onActivated: AgentService.kill(row.session.id)
            }
            SmallIconButton {
                icon: "󰆍"
                tip: row.live ? "Open terminal" : "Show output"
                onActivated: AgentService.focusTerminal(row.session.id)
            }
        }
    }
}
