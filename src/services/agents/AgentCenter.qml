import QtQuick
import QtQuick.Controls
import "../"
import "../../"
import "../../components"

// ─── AgentCenter ──────────────────────────────────────────────────────────────
// The dashboard's Agents page (roadmap §3, §7).
//
// A SUPERVISOR AND A NAVIGATOR — §3's own words — not a replacement for the
// terminal. Everything here answers "what is running, what needs me, and take
// me to it". Clicking a session focuses its real terminal; there is no output
// pane, no prompt box and no way to talk to an agent from the shell, because a
// second and worse terminal is not worth building.
//
// Four sections, ordered by what interrupts you:
//   1. privilege requests   — an agent is blocked waiting for a decision
//   2. sessions needing you — waiting_for_user / permission_request
//   3. everything else      — running, then finished
//   4. remote devices       — §20's trusted hosts, and their agents
//
// ── WHY REMOTE AGENT STATUS LIVES HERE AND NOT IN THE BAR ───────────────────
//
// §20 asks for remote agent status "in the local APEX Shell", and there were
// two candidate surfaces: this page, or an indicator in the top bar next to
// the tray. The bar was rejected, and the reason is worth writing down because
// it looks like a UX preference and is actually a hard constraint.
//
// The rule for a bar indicator is that it should appear when there is
// something to show and be absent otherwise — an always-visible icon that is
// empty 99% of the time is worse than no icon. But knowing whether there is
// something to show means asking the remote devices, and every ask is an ssh
// connection to another machine. So a bar indicator that honours "appears when
// there is something to show" must poll while nobody is looking, forever,
// which is precisely the defect RemoteAgentService is built to avoid. The two
// requirements are in direct tension and the polling one wins: a laptop that
// opens three ssh connections a minute for the life of the session, to draw an
// icon that is usually absent, is not a feature.
//
// Conditional appearance is still honoured — just at the level where it is
// free. `apex host list` is a local file read, so "is any device registered at
// all?" costs nothing, and on a machine with no trusted devices the section
// does not exist and this page looks exactly as it did before. The per-device
// ssh only ever happens while this page is genuinely in front of the user.
//
// It belongs on this page for a second reason: a remote agent is an agent. The
// question "what is running, what needs me, and take me to it" does not become
// a different question because the process is on the desktop instead of the
// laptop, and it would be odd to answer half of it here and half of it in the
// bar.
// ──────────────────────────────────────────────────────────────────────────────

Item {
    id: root

    // Set by the dashboard: true only when this page is genuinely in front of
    // the user. Drives the poll rate through the refcount.
    property bool onScreen: false

    ServiceRef { service: AgentService; active: root.onScreen }

    // The remote service's refcount is the ONLY thing that lets it open an ssh
    // connection. Handing this ref back stops the sweep timer and kills the
    // query in flight — see RemoteAgentService.
    ServiceRef { service: RemoteAgentService; active: root.onScreen }

    readonly property var _requests: AgentService.requests
    readonly property var _needsYou: AgentService.sessions.filter(function(s) {
        return s.state === "waiting_for_user" || s.state === "permission_request"
    })
    readonly property var _others: AgentService.sessions.filter(function(s) {
        return s.state !== "waiting_for_user" && s.state !== "permission_request"
    }).slice().sort(function(a, b) {
        // Live first, then most recently active. A finished session sinking
        // below a running one is what makes the list readable at a glance.
        var aLive = a.exit_code === null && a.exit_signal === null
        var bLive = b.exit_code === null && b.exit_signal === null
        if (aLive !== bLive) return aLive ? -1 : 1
        return (b.last_activity || 0) - (a.last_activity || 0)
    })

    readonly property bool _empty:
        _requests.length === 0 && AgentService.sessions.length === 0

    // Whether §20's remote section has anything at all to draw. This is a
    // local file read (`apex host list`), never an ssh, so it is safe to ask
    // it in a binding.
    readonly property bool _hasRemote: RemoteAgentService.hosts.length > 0

    // ── The runtime is not running ────────────────────────────────────────────
    // Distinguished from "no sessions", because the fixes are different and
    // telling someone "no agents" when the daemon is off sends them looking in
    // the wrong place.
    //
    // Suppressed when there are remote devices to show: a laptop with no local
    // runtime and a desktop full of agents is a real configuration, and a
    // full-page "the agent runtime is not running" would hide the answer the
    // user came for. The list says the same thing in one line instead.
    Column {
        anchors.centerIn: parent
        width: parent.width * 0.8
        spacing: Theme.fs(10)
        visible: AgentService.everChecked && !AgentService.daemonUp
                 && !root._hasRemote

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "󰒲"
            font.pixelSize: Theme.fs(42)
            color: Theme.subtext
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "The agent runtime is not running"
            color: Theme.text
            font.pixelSize: Theme.fs(14)
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: "systemctl --user enable --now apex-agentd\n\n" +
                  "It is opt-in. Running claude, opencode or codex directly " +
                  "works exactly as it always did."
            color: Theme.subtext
            font.pixelSize: Theme.fs(11)
        }
    }

    // ── Nothing to show ──────────────────────────────────────────────────────
    Column {
        anchors.centerIn: parent
        width: parent.width * 0.8
        spacing: Theme.fs(8)
        visible: AgentService.daemonUp && root._empty && !root._hasRemote

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "󰚩"
            font.pixelSize: Theme.fs(42)
            color: Theme.subtext
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "No agent sessions"
            color: Theme.text
            font.pixelSize: Theme.fs(14)
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: "Start one with  a  or  apex agent run"
            color: Theme.subtext
            font.pixelSize: Theme.fs(11)
        }
    }

    // ── The list ─────────────────────────────────────────────────────────────
    ScrollView {
        anchors.fill: parent
        anchors.margins: Theme.fs(6)
        clip: true
        visible: (AgentService.daemonUp && !root._empty) || root._hasRemote
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        Column {
            width: root.width - Theme.fs(20)
            spacing: Theme.fs(6)

            // ── 1. Privilege requests ────────────────────────────────────────
            SectionHeading {
                visible: root._requests.length > 0
                text: "Waiting for your decision"
                accent: true
            }
            Repeater {
                model: root._requests
                delegate: RequestRow {
                    // Declared required rather than reached for implicitly:
                    // QML 6 flags the unqualified access, and an injected
                    // `modelData` silently becomes undefined the moment this
                    // delegate is used anywhere but a Repeater.
                    required property var modelData
                    width: parent.width
                    request: modelData
                }
            }

            // ── 2. Sessions that need you ────────────────────────────────────
            SectionHeading {
                visible: root._needsYou.length > 0
                text: "Needs you"
                accent: true
            }
            Repeater {
                model: root._needsYou
                delegate: SessionRow {
                    required property var modelData
                    width: parent.width
                    session: modelData
                }
            }

            // ── 3. Everything else ───────────────────────────────────────────
            // The heading says "This machine" once there is a remote section
            // below it, because "Sessions" stops being unambiguous the moment
            // some of the sessions on the page are on a different computer.
            SectionHeading {
                visible: root._others.length > 0
                text: root._hasRemote
                      ? "This machine"
                      : (root._needsYou.length > 0 || root._requests.length > 0)
                        ? "Other sessions" : "Sessions"
            }
            Repeater {
                model: root._others
                delegate: SessionRow {
                    required property var modelData
                    width: parent.width
                    session: modelData
                }
            }

            // The local runtime being off, said in one line rather than as a
            // full-page state, for the case where the remote section is
            // carrying the page.
            //
            // Wrapped in an Item, like SectionHeading, for two reasons. A
            // Column reserves space for an invisible child, so the collapse has
            // to be a height of 0; and `height: visible ? implicitHeight : 0`
            // ON THE TEXT ITSELF is a binding loop — Qt warned about exactly
            // that here — because a Text's implicitHeight is derived from its
            // own geometry. The wrapper's height is not an input to the child's
            // implicitHeight, so the cycle does not exist.
            Item {
                width: parent.width
                visible: root._hasRemote && AgentService.everChecked
                         && !AgentService.daemonUp
                height: visible ? localOffLabel.implicitHeight + Theme.fs(12) : 0

                Text {
                    id: localOffLabel
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.fs(4)
                    anchors.bottom: parent.bottom
                    text: "This machine's agent runtime is not running  ·  "
                          + "systemctl --user enable --now apex-agentd"
                    color: Theme.subtext
                    font.pixelSize: Theme.fs(10)
                }
            }

            // ── 4. Remote devices (§20) ──────────────────────────────────────
            // Present only when a device is actually registered. See the header
            // for why this is where remote agent status lives.
            Item {
                id: remoteHeading
                visible: root._hasRemote
                width: parent.width
                height: visible ? Theme.fs(28) : 0

                SectionHeading {
                    anchors.fill: parent
                    text: RemoteAgentService.overviewLabel === ""
                              ? "Remote devices"
                              : "Remote devices  ·  " + RemoteAgentService.overviewLabel
                    accent: RemoteAgentService.overview.live > 0
                }

                // Ask now. The only caller that bypasses the anti-churn clamp,
                // because a person clicking Refresh is not churn.
                SmallIconButton {
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.fs(6)
                    anchors.verticalCenter: parent.verticalCenter
                    icon: "󰑐"
                    tip: RemoteAgentService.busy ? "Checking devices…"
                                                 : "Check the devices again"
                    onActivated: RemoteAgentService.refresh()

                    RotationAnimation on rotation {
                        running: RemoteAgentService.busy
                        loops: Animation.Infinite
                        from: 0; to: 360; duration: 1400
                    }
                    onRotationChanged: if (!RemoteAgentService.busy) rotation = 0
                }
            }

            Repeater {
                // An integer count model, looked up by index — the same reason
                // as in RemoteHostRow and Workspaces.qml. A sweep rewrites the
                // host array wholesale, so an array model would rebuild every
                // row (and restart every animation) on every poll.
                model: RemoteAgentService.hosts.length

                delegate: RemoteHostRow {
                    required property int index
                    width: parent.width
                    host: RemoteAgentService.hosts[index]
                }
            }

            // How to actually get to a remote session. One line, once, rather
            // than a button per row: the row cannot act on a remote session
            // without handing a foreign id to the local daemon, and attaching
            // means a terminal on the far side of an ssh. §3 keeps this page a
            // supervisor and a navigator.
            //
            // Wrapped for the same reason as the note above: binding a Text's
            // own height to its own implicitHeight is a cycle.
            Item {
                width: parent.width
                visible: root._hasRemote
                height: visible ? attachHint.implicitHeight + Theme.fs(14) : 0

                Text {
                    id: attachHint
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.fs(4)
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    wrapMode: Text.WordWrap
                    text: "Attach with  apex host run -t <device> -- apex agent attach <id>"
                    color: Theme.subtext
                    font.pixelSize: Theme.fs(9)
                }
            }
        }
    }
}
