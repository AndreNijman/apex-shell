import QtQuick
import "../"
import "../../"
import "../../components/controls"
import "../agentstate.js" as AgentState

// One pending privilege request in the Agent Center (roadmap §4's prompt).
//
// It shows what is being asked and why, and offers Review — which opens a
// terminal on it. It does NOT offer Allow.
//
// That is not an omission. Approving performs the operation with the reviewing
// human's own root (see docs/agent-runtime.md), so it belongs somewhere sudo
// can authenticate and where the full prompt and the resulting output are
// visible. An [Allow] button in a status list would be one unconfirmed click
// away from an OS change, judged from a two-line summary.
//
// ── IT IS TONED LIKE A BLOCKED SESSION, BECAUSE IT IS ONE ───────────────────
//
// A pending request and a session in `permission_request` are the same event
// seen from two sides, and this page shows both — the card up top, the session
// further down. They were coloured differently, the card in the wallpaper's
// primary and the session in whatever the state ternary landed on, so nothing
// connected them. Both now carry the `attention` tone, which is what makes the
// pair legible as one thing that is waiting on you.

Rectangle {
    id: row
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    required property var request

    // Set by AgentCenter's flat keyboard list (UI/UX roadmap v3 Phase 21):
    // `keyed` is true while the list's highlight sits on this row, and gates
    // the Review button's Tab stop the same way the Wi-Fi/Clipboard template
    // does. `listFocused` additionally requires the LIST ITSELF to hold
    // keyboard focus, so the ring goes dark the moment focus moves onto
    // Review's own button, exactly like the other two list panes.
    property bool keyed: false
    property bool listFocused: false

    readonly property string operation: {
        var v = request.verb
        if (v === "install" || v === "remove")
            return "apex " + v + " " + (request.packages || []).join(" ")
        return "apex " + String(v).replace("pkg-", "pkg ")
    }

    // What Return does on the list, and what Review's own tap does — one
    // definition so the two can never disagree.
    function primary() { AgentService.reviewRequest(row.request.id) }

    Accessible.role: Accessible.ListItem
    Accessible.name: (row.request.agent ? AgentState.agentName(row.request.agent) : "An agent")
                     + " requests privilege: " + row.operation

    height: body.implicitHeight + theme.fs(20)
    radius: theme.px(8)
    color: Qt.rgba(Theme.attention.r, Theme.attention.g, Theme.attention.b, 0.10)
    border.width: Math.max(1, theme.px(1))
    border.color: Theme.attention

    // Keyboard highlight ring — inset rather than outset like WifiTab's
    // NetworkRow, because this row sits flush at x=0 inside AgentCenter's
    // ScrollView (`clip: true`, no per-row inset): an outward ring's left edge
    // would land outside the clip and never draw. Same fix as HistoryTab's
    // ClipRow, for a different reason (its own `clip: true` there).
    Rectangle {
        anchors.fill: parent; anchors.margins: 2
        radius: Math.max(row.radius - 2, 0)
        color: "transparent"; border.width: 2; border.color: Theme.accentText
        visible: row.keyed && row.listFocused
    }

    Row {
        id: body
        anchors.fill: parent
        anchors.margins: theme.px(10)
        spacing: theme.px(10)

        // The badge a blocked session wears, drawn at the same weight — filled,
        // because this is the one card on the page that will not clear itself.
        StateBadge {
            id: badge
            anchors.top: parent.top
            sessionState: "permission_request"
            size: theme.px(26)
        }

        Column {
            // Measured off the badge rather than repeating its size. The line
            // this replaces subtracted Theme.fs(22) from a 22px-wide glyph —
            // right at scale 1.0 and wrong at every other scale, because fs()
            // and px() are different scalers.
            width: parent.width - badge.width - reviewBtn.width - theme.fs(30)
            spacing: theme.px(3)

            Text {
                text: (row.request.agent
                       ? AgentState.agentName(row.request.agent)
                       : "An agent") + " requests privilege"
                color: Theme.text
                font.pixelSize: theme.fs(12)
                font.bold: true
            }

            // The operation, verbatim and monospaced. This is the line a person
            // reads to decide, so it is not summarised or prettified.
            Text {
                width: parent.width
                elide: Text.ElideRight
                text: row.operation
                color: Theme.attention
                font.family: "monospace"
                font.pixelSize: theme.fs(11)
            }

            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                maximumLineCount: 3
                elide: Text.ElideRight
                text: row.request.reason || ""
                color: Theme.subtext
                font.pixelSize: theme.fs(10)
            }

            Text {
                visible: !!row.request.project
                width: parent.width
                elide: Text.ElideMiddle
                text: row.request.project || ""
                color: Theme.subtext
                font.pixelSize: theme.fs(9)
                opacity: 0.75
            }
        }

        // ApexPressable (UI/UX roadmap v3 Phase 21): was a bare
        // Rectangle/HoverHandler/TapHandler with no keyboard path. A Tab stop
        // only while the list's highlight is on this row (`row.keyed`), same
        // as every other row-level button in the template.
        ApexPressable {
            id: reviewBtn
            anchors.verticalCenter: parent.verticalCenter
            width: reviewLabel.implicitWidth + theme.fs(18)
            height: reviewLabel.implicitHeight + theme.fs(10)
            radius: theme.px(6)
            activeFocusOnTab: row.keyed
            Accessible.name: "Review " + row.operation
            onActivated: row.primary()

            Rectangle {
                anchors.fill: parent; radius: parent.radius
                color: reviewBtn.hovered
                    ? Qt.rgba(Theme.attention.r, Theme.attention.g, Theme.attention.b, 0.35)
                    : Qt.rgba(Theme.attention.r, Theme.attention.g, Theme.attention.b, 0.20)

                Behavior on color { MotionColor {} }
            }

            Text {
                id: reviewLabel
                anchors.centerIn: parent
                text: "Review"
                color: Theme.text
                font.pixelSize: theme.fs(11)
            }

            ApexFocusRing { target: reviewBtn }
        }
    }
}
