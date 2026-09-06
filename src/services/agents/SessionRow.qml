import QtQuick
import "../"
import "../../"
import "../agentstate.js" as AgentState
import "../agentgraph.js" as Graph
import "../agentpolicy.js" as Policy

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
//
// ── THE SANDBOX CHIP, AND WHY IT IS READ FROM THE SESSION ───────────────────
//
// §42.1 criterion 8: a running session displays its actual mode, and changing
// the default does not lie about sessions already running. `sandboxMode` reads
// this session's own record — the daemon flattens the six dimensions it
// normalised at fork time onto `SessionInfo` — and AgentPolicyService, which
// knows what a NEW session would get, is deliberately not consulted here. A
// row that read the setting would relabel four running agents the instant
// somebody moved a toggle, and every one of those labels would be wrong.
//
// Only the unconfined mode gets a colour. `project` is the default and `strict`
// is tighter still, and a status list that shouts about its own normal state
// teaches people to stop reading it.
//
// ── DIMENSION 1, AND WHY THE OBVIOUS FIELD IS THE WRONG ONE ─────────────────
//
// §4.1 criterion 3 asks that the agent-native permission mode be visible here.
// The obvious field is `session.native`, and it is the wrong one: it says what
// APEX did, and for the case that matters APEX did nothing. Andre runs Claude
// in `bypassPermissions` as his profile default, §4.1 says APEX must not
// override that, so `native` reads `inherit` — and a chip showing "inherit"
// beside a session running with confirmations off satisfies the criterion's
// words and answers none of its question.
//
// So the agent's own report wins. Claude puts `permission_mode` on every hook
// payload, apex-agentd records it as `native_observed`, and
// `Policy.sessionNativeLabel` prefers it. The chip then reads
// `project · bypassPermissions`, which is Claude's own word for its own mode.
//
// ── THE BREAK-GLASS INDICATOR ───────────────────────────────────────────────
//
// §3.4 asks for a "prominent red Agent Center indicator" and for "revocation
// control always visible". Those are one thing here: an indicator that says
// what is happening and how long is left, and a control beside it that ends it.
// It is drawn only for §4.5 break-glass — the mode that clears no_new_privs —
// and NOT for §4.4's session grant, which keeps every kernel boundary and is
// not what the sentence is about. Two red things would make neither red.
//
// ── THE SECOND LAYER, AND THE ONE ANSWER IT REFUSES TO GIVE (P1-020) ────────
//
// A session is not one thing. It delegates to subagents and it forks MCP
// servers, language servers and whatever a tool call runs, and until the
// runtime grew `SessionInfo.children` this row could not tell an agent with
// six subagents working from one sitting idle.
//
// The summary sits in the meta line and the detail is one click away, because
// the page is a supervisor: "what is running" belongs on the surface and
// "which of them" belongs behind an expander.
//
// The refusal is `Graph.supported()`. A daemon that predates the graph writes
// no `children` key at all, and every daemon in the shipped image is one of
// those — so the row draws NOTHING rather than "0 subagents", which would be a
// confident answer on the only machine anybody is running. Absent is not
// empty, and this row is where the difference is visible.

Rectangle {
    id: row

    required property var session

    readonly property bool live:
        session.exit_code === null && session.exit_signal === null
    readonly property bool needsYou: AgentState.needsYou(session.state)

    // The graph, or the runtime's admission that it has none. Three-valued —
    // see the header, and agentgraph.js for the failure it prevents.
    readonly property string graphState: Graph.supported(row.session)
    readonly property var graphKids: Graph.subagents(row.session)
    readonly property var graphRoots: Graph.processRoots(row.session)
    readonly property bool hasGraph:
        row.graphState === "some"
        && (row.graphKids.length > 0 || row.graphRoots.length > 0)
    property bool expanded: false

    // This session's real sandbox, from this session's record.
    readonly property string sandboxMode: Policy.sessionSandbox(session)
    readonly property bool unconfined: row.sandboxMode === Policy.UNRESTRICTED

    // Dimension 1 as the agent reports it, or as APEX selected it, or "" when
    // neither has anything to say. See the header.
    readonly property string nativeLabel: Policy.sessionNativeLabel(session)

    // §4.5 break-glass, and how much of its window is left.
    //
    // `now` ticks rather than being read once: an indicator that said "12m"
    // for twelve minutes would be a countdown that never counted, and the
    // number is the part a person acts on. Only while this row is one — a
    // per-second timer on every session in the list would be a timer running
    // for nothing on almost all of them.
    readonly property bool breakGlass: Policy.isBreakGlass(session)
    property double nowMs: Date.now()
    readonly property string grantLabel: Policy.breakGlassLabel(row.session, row.nowMs)

    Timer {
        running: row.breakGlass && row.live
        interval: 1000
        repeat: true
        onTriggered: row.nowMs = Date.now()
    }

    height: header.height + (row.expanded ? kidsBlock.height + Theme.px(8) : 0)
    radius: Theme.px(8)
    color: hover.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07)
                         : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.03)
    // Bordered while the session is asking for something, in that state's own
    // tone rather than in one shared accent — "it went quiet" and "it asked for
    // root" arrive at the same place in the list and must not look alike.
    // Break-glass outranks every other reason to draw a border. A session that
    // can become root is the loudest thing in this list while it lasts, and a
    // row that borrowed the "waiting for you" tone for it would put the two
    // states at the same volume.
    border.width: (row.breakGlass && row.live) || row.needsYou
        ? Math.max(1, Theme.px(1)) : 0
    border.color: (row.breakGlass && row.live) ? Theme.danger : badge.toneColor

    Behavior on color { ColorAnimation { duration: 90 } }

    HoverHandler { id: hover }

    // The header is the row as it always was, and the clickable part. The
    // child list below is NOT inside it: a tap meant for a subagent row must
    // not also focus the terminal, and a TapHandler on the whole card would do
    // exactly that.
    Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: Theme.px(52)

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
        color: (row.breakGlass && row.live) ? Theme.danger : badge.toneColor
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

                // The session's own sandbox. Always drawn, so `project` is a
                // fact the reader has seen rather than an absence they have to
                // infer — an indicator that only ever appears when something is
                // wrong cannot be distinguished from one that is broken.
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    radius: Theme.px(3)
                    color: row.unconfined
                        ? Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.18)
                        : "transparent"
                    border.width: row.unconfined ? 0 : Math.max(1, Theme.px(1))
                    border.color: Qt.rgba(Theme.subtext.r, Theme.subtext.g,
                                          Theme.subtext.b, 0.28)
                    width:  sandboxLabel.implicitWidth + Theme.fs(8)
                    height: sandboxLabel.implicitHeight + Theme.fs(3)
                    Text {
                        id: sandboxLabel
                        anchors.centerIn: parent
                        // The sandbox, and dimension 1 beside it whenever
                        // anything is known about it — which for a managed
                        // Claude is the mode Claude itself reports. Empty only
                        // when APEX passed no flag AND the agent has said
                        // nothing, where naming a mode would claim knowledge of
                        // a settings file the runtime never read.
                        text: row.sandboxMode
                            + (row.nativeLabel === "" ? "" : " · " + row.nativeLabel)
                        color: row.unconfined ? Theme.danger : Theme.subtext
                        font.pixelSize: Theme.fs(9)
                        font.bold: row.unconfined
                    }
                }

                // §3.4's prominent red indicator. Its own chip rather than a
                // third field on the sandbox one: this is not a property of
                // the session's confinement, it is a window that is closing.
                Rectangle {
                    id: breakGlassChip
                    visible: row.breakGlass && row.live
                    anchors.verticalCenter: parent.verticalCenter
                    radius: Theme.px(3)
                    color: Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.28)
                    border.width: Math.max(1, Theme.px(1))
                    border.color: Theme.danger
                    width:  grantText.implicitWidth + Theme.fs(8)
                    height: grantText.implicitHeight + Theme.fs(3)
                    Text {
                        id: grantText
                        anchors.centerIn: parent
                        text: row.grantLabel
                        color: Theme.danger
                        font.pixelSize: Theme.fs(9)
                        font.bold: true
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
                // What this session started. Empty string for a runtime that
                // has no graph and for a session that has started nothing —
                // agentgraph.js decides which, and the row asks rather than
                // testing the array itself.
                readonly property string graph:
                    Graph.summary(row.session, Date.now() / 1000)

                Text {
                    text: meta.where === "" ? "" : meta.where + "  ·  "
                    color: Theme.subtext
                    font.pixelSize: Theme.fs(10)
                    elide: Text.ElideRight
                    width: Math.max(0, Math.min(implicitWidth,
                             meta.width - stateWord.implicitWidth
                             - tailText.implicitWidth - graphText.implicitWidth))
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
                // Last, and never elided, for the same reason the state word
                // is not: it is the answer to "is anything running under
                // this", and a truncated answer to that is no answer.
                Text {
                    id: graphText
                    text: meta.graph === "" ? "" : "  ·  " + meta.graph
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

            // The graph, when there is one. Absent — not disabled — when the
            // runtime cannot tell: a control that is permanently greyed out
            // teaches the reader that the feature is broken rather than that
            // their daemon predates it, and the row says nothing about the
            // graph in that case either.
            SmallIconButton {
                visible: row.hasGraph
                icon: row.expanded ? "󰅃" : "󰅀"
                tip: row.expanded ? "Hide what it started"
                                  : "Show what it started"
                onActivated: row.expanded = !row.expanded
            }

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
            // §3.4: "revocation control always visible". Beside the state it
            // is about, present for exactly as long as there is something to
            // revoke, and asking for nothing — giving up privilege is free.
            SmallIconButton {
                id: revokeButton
                visible: row.breakGlass && row.live
                icon: "󰌾"
                tip: "End break-glass now (" + row.grantLabel + ")"
                onActivated: AgentService.revokeGrant(Policy.sessionGrant(row.session))
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

    // ── What it started ───────────────────────────────────────────────────────
    //
    // Subagents by name, then the processes the AGENT forked — not the ones
    // the sandbox did. A confined session's pid is the `bwrap` wrapper, so the
    // agent's own binary is a child in the process tree; drawing it literally
    // would open the list with a row called "claude" underneath a row called
    // "Claude". agentgraph.js lifts that one node out of the way and folds its
    // subtree into the rows below it, so nothing is hidden and nothing is
    // drawn beneath itself.
    Column {
        id: kidsBlock
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Theme.px(30)
        anchors.rightMargin: Theme.px(12)
        visible: row.expanded
        spacing: Theme.px(1)

        Repeater {
            model: row.expanded ? row.graphKids : []
            delegate: SubagentRow {
                required property var modelData
                width: parent.width
                child: modelData
                session: row.session
            }
        }
        Repeater {
            model: row.expanded ? row.graphRoots : []
            delegate: SubagentRow {
                required property var modelData
                width: parent.width
                child: modelData
                session: row.session
                // The subtree this row stands for, asked once per root rather
                // than recomputed inside the delegate on every repaint.
                subtreeCount: Graph.processSummary(row.session, modelData).count
                subtreeRssKb: Graph.processSummary(row.session, modelData).rssKb
            }
        }
    }
}
