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
// Three sections, ordered by what interrupts you:
//   1. privilege requests   — an agent is blocked waiting for a decision
//   2. sessions needing you — waiting_for_user / permission_request
//   3. everything else      — running, then finished
// ──────────────────────────────────────────────────────────────────────────────

Item {
    id: root

    // Set by the dashboard: true only when this page is genuinely in front of
    // the user. Drives the poll rate through the refcount.
    property bool onScreen: false

    ServiceRef { service: AgentService; active: root.onScreen }

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

    // ── The runtime is not running ────────────────────────────────────────────
    // Distinguished from "no sessions", because the fixes are different and
    // telling someone "no agents" when the daemon is off sends them looking in
    // the wrong place.
    Column {
        anchors.centerIn: parent
        width: parent.width * 0.8
        spacing: Theme.fs(10)
        visible: AgentService.everChecked && !AgentService.daemonUp

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
        visible: AgentService.daemonUp && root._empty

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
        visible: AgentService.daemonUp && !root._empty
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
            SectionHeading {
                visible: root._others.length > 0
                text: (root._needsYou.length > 0 || root._requests.length > 0)
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
        }
    }
}
