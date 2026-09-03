import QtQuick
import "../"
import "../../"

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

Rectangle {
    id: row

    required property var request

    readonly property string operation: {
        var v = request.verb
        if (v === "install" || v === "remove")
            return "apex " + v + " " + (request.packages || []).join(" ")
        return "apex " + String(v).replace("pkg-", "pkg ")
    }

    height: body.implicitHeight + Theme.fs(20)
    radius: Theme.px(8)
    color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.10)
    border.width: 1
    border.color: Theme.active

    Row {
        id: body
        anchors.fill: parent
        anchors.margins: Theme.px(10)
        spacing: Theme.px(10)

        Text {
            anchors.top: parent.top
            width: Theme.px(22)
            horizontalAlignment: Text.AlignHCenter
            text: "󰌾"
            font.pixelSize: Theme.fs(17)
            color: Theme.active
        }

        Column {
            width: parent.width - Theme.fs(22) - reviewBtn.width - Theme.fs(30)
            spacing: Theme.px(3)

            Text {
                text: (row.request.agent
                        ? row.request.agent.charAt(0).toUpperCase()
                          + row.request.agent.slice(1)
                        : "An agent") + " requests privilege"
                color: Theme.text
                font.pixelSize: Theme.fs(12)
                font.bold: true
            }

            // The operation, verbatim and monospaced. This is the line a person
            // reads to decide, so it is not summarised or prettified.
            Text {
                width: parent.width
                elide: Text.ElideRight
                text: row.operation
                color: Theme.active
                font.family: "monospace"
                font.pixelSize: Theme.fs(11)
            }

            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                maximumLineCount: 3
                elide: Text.ElideRight
                text: row.request.reason || ""
                color: Theme.subtext
                font.pixelSize: Theme.fs(10)
            }

            Text {
                visible: !!row.request.project
                width: parent.width
                elide: Text.ElideMiddle
                text: row.request.project || ""
                color: Theme.subtext
                font.pixelSize: Theme.fs(9)
                opacity: 0.75
            }
        }

        Rectangle {
            id: reviewBtn
            anchors.verticalCenter: parent.verticalCenter
            width: reviewLabel.implicitWidth + Theme.fs(18)
            height: reviewLabel.implicitHeight + Theme.fs(10)
            radius: Theme.px(6)
            color: reviewHover.hovered
                ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.35)
                : Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.20)

            Behavior on color { ColorAnimation { duration: 90 } }

            Text {
                id: reviewLabel
                anchors.centerIn: parent
                text: "Review"
                color: Theme.text
                font.pixelSize: Theme.fs(11)
            }

            HoverHandler { id: reviewHover }
            TapHandler { onTapped: AgentService.reviewRequest(row.request.id) }
        }
    }
}
