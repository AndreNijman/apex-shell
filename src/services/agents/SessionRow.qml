import QtQuick
import "../"
import "../../"
import "../agentstate.js" as AgentState

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
//
// ── THE THREE PLACES THE STATE IS VISIBLE ───────────────────────────────────
//
// A badge, a stripe down the left edge, and the state word itself, all in the
// one tone StateBadge resolves. Three because one was not enough: a single
// glyph in a 22px column, on a row whose every other pixel is the palette's
// foreground, is a page that reads as white — which is how P0-021 was reported.
// The stripe is what makes the LIST look like a status list from across the
// desk, before anything has been read.

Rectangle {
    id: row

    required property var session

    readonly property bool live:
        session.exit_code === null && session.exit_signal === null
    readonly property bool needsYou: AgentState.needsYou(session.state)

    height: Theme.px(52)
    radius: Theme.px(8)
    color: hover.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07)
                         : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.03)
    // Bordered while the session is asking for something, in that state's own
    // tone rather than in one shared accent — "it went quiet" and "it asked for
    // root" arrive at the same place in the list and must not look alike.
    border.width: row.needsYou ? Math.max(1, Theme.px(1)) : 0
    border.color: badge.toneColor

    Behavior on color { ColorAnimation { duration: 90 } }

    HoverHandler { id: hover }

    // The whole row focuses the terminal. §3: "Focus the existing terminal when
    // the user clicks an agent in APEX Shell."
    TapHandler {
        onTapped: AgentService.focusTerminal(row.session.id)
    }

    // The state, at the scale you notice without looking. Inset from the
    // rounded corner so it reads as part of the card rather than as a crop of
    // it, and absent for a finished session because "exited" is not a status.
    Rectangle {
        id: stripe
        visible: badge.tone !== "idle"
        anchors.left: parent.left
        anchors.leftMargin: Theme.px(3)
        anchors.verticalCenter: parent.verticalCenter
        width: Theme.px(3)
        height: parent.height - Theme.px(16)
        radius: width / 2
        color: badge.toneColor
        Behavior on color { ColorAnimation { duration: 120 } }
    }

    Row {
        anchors.fill: parent
        anchors.leftMargin: Theme.px(12)
        anchors.rightMargin: Theme.px(8)
        spacing: Theme.px(10)

        // ── State ─────────────────────────────────────────────────────────────
        StateBadge {
            id: badge
            anchors.verticalCenter: parent.verticalCenter
            sessionState: row.session.state
            size: Theme.px(26)
        }

        // ── Identity ──────────────────────────────────────────────────────────
        Column {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - badge.width - controls.width - Theme.fs(40)
            spacing: Theme.px(2)

            Row {
                spacing: Theme.px(6)
                Text {
                    text: AgentState.agentName(row.session.agent)
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

            // project · STATE · elapsed, with the state word in its own tone.
            //
            // Three Texts rather than one joined string, because the state is
            // the only part that is coloured and QML has no way to tone a
            // substring without building markup out of a project name the user
            // controls. The project elides; the state and the tail never do,
            // so the two things that identify what is happening survive a
            // narrow window.
            Row {
                id: meta
                width: parent.width
                spacing: 0

                readonly property string where:
                    row.session.project_name
                    || AgentService._basename(row.session.cwd)
                    || ""
                readonly property string tail: {
                    var bits = []
                    var e = AgentService.elapsed(row.session)
                    if (e) bits.push(e)
                    if (!row.live && row.session.exit_code !== null
                        && row.session.exit_code !== 0)
                        bits.push("exit " + row.session.exit_code)
                    return bits.length ? "  ·  " + bits.join("  ·  ") : ""
                }

                Text {
                    text: meta.where === "" ? "" : meta.where + "  ·  "
                    color: Theme.subtext
                    font.pixelSize: Theme.fs(10)
                    elide: Text.ElideRight
                    width: Math.max(0, Math.min(implicitWidth,
                             meta.width - stateWord.implicitWidth - tailText.implicitWidth))
                }
                Text {
                    id: stateWord
                    text: AgentService.stateLabel(row.session.state)
                    color: badge.toneColor
                    font.pixelSize: Theme.fs(10)
                    font.bold: true
                }
                Text {
                    id: tailText
                    text: meta.tail
                    color: Theme.subtext
                    font.pixelSize: Theme.fs(10)
                }
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
