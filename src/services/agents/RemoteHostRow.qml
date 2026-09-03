import QtQuick
import "../"
import "../../"

// One trusted remote device, with whatever it said about its agents.
//
// ── Every state here is a legitimate one ────────────────────────────────────
//
// The status glyph and the line under the name come from RemoteAgentService,
// which gets them from remoteagents.js. Nothing in this row is styled as an
// error, because none of these ARE errors:
//
//   not probed    the device is registered and nobody has asked it anything.
//                 The honest display is "not probed" plus the command that
//                 fixes it — not a guess, and not a zero.
//   no agent      probed, and it does not have the runtime. Known, and final
//                 until the next probe.
//   checking…     the ssh is in flight. Shown BEFORE the first answer, because
//                 rendering "unreachable" before having asked is a lie that
//                 reads as a bug.
//   unreachable   the laptop is off the LAN, which is where a laptop usually
//                 is. Subdued, never accented, never a toast.
//
// The row does not grow a Refresh button of its own. Demand is per-page, so a
// per-host refresh would be one more way to open an ssh connection by clicking
// around; the section has a single Refresh that re-sweeps everything.

Item {
    id: hrow

    required property var host

    readonly property string status: RemoteAgentService.statusFor(hrow.host.name)
    readonly property var    result: RemoteAgentService.resultFor(hrow.host.name)

    // { shown, hidden } — the sessions to render and how many were left out.
    // Named with a leading underscore because `visible` is taken by Item.
    readonly property var _slice: RemoteAgentService.sessionsFor(hrow.host.name)

    // The count model is an INTEGER, not the array.
    //
    // `model: <JS array>` recreates every delegate whenever the array's
    // contents change — measured on Qt 6.10.3 in this repo: a 3-element model
    // reported created=6, destroyed=3 after one content change, which silently
    // killed the Behaviour animations in the workspace strip. See the long
    // comment in src/modules/Left/Workspaces.qml. A remote sweep rewrites this
    // host's session array every fifteen seconds, so the same trap applies: the
    // working-session pulse would restart from zero on every poll.
    readonly property int sessionCount: hrow._slice.shown.length

    width: parent ? parent.width : 0
    height: header.height + sessionColumn.height + Theme.fs(4)

    // ── The host itself ───────────────────────────────────────────────────────
    Rectangle {
        id: header
        width: parent.width
        height: Theme.fs(44)
        radius: Theme.fs(8)
        color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.03)

        Row {
            anchors.fill: parent
            anchors.leftMargin: Theme.fs(10)
            anchors.rightMargin: Theme.fs(10)
            spacing: Theme.fs(10)

            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.fs(22)
                horizontalAlignment: Text.AlignHCenter
                text: RemoteAgentService.statusIcon(hrow.status)
                font.pixelSize: Theme.fs(15)
                color: hrow.status === "ok"
                           ? (RemoteAgentService.resultFor(hrow.host.name).sessions.length > 0
                                  ? Theme.text : Theme.subtext)
                           : Theme.subtext

                // The only motion: a query actually in flight. Everything else
                // is a settled fact and holds still.
                SequentialAnimation on opacity {
                    running: hrow.status === "querying"
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutQuad }
                    NumberAnimation { to: 1.0;  duration: 700; easing.type: Easing.InOutQuad }
                }
                onOpacityChanged: if (hrow.status !== "querying") opacity = 1.0
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Theme.fs(60)
                spacing: Theme.fs(2)

                Row {
                    spacing: Theme.fs(6)

                    Text {
                        text: hrow.host.name
                        color: Theme.text
                        font.pixelSize: Theme.fs(12)
                        font.bold: true
                    }

                    // The ssh destination, but only when it is not simply the
                    // name. An entry whose destination IS its name — the normal
                    // case, an alias already in ~/.ssh/config — would otherwise
                    // print everything twice.
                    Text {
                        visible: hrow.host.ssh !== hrow.host.name
                        anchors.verticalCenter: parent.verticalCenter
                        text: hrow.host.ssh
                        color: Theme.subtext
                        font.pixelSize: Theme.fs(9)
                    }

                    // Variant badge, only for a host that reported one. A box
                    // that has never been probed gets no badge rather than an
                    // "unknown" badge — the absence is the information.
                    Rectangle {
                        visible: hrow.host.caps.variant !== null
                        anchors.verticalCenter: parent.verticalCenter
                        radius: Theme.fs(3)
                        color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.18)
                        width: variantLabel.implicitWidth + Theme.fs(8)
                        height: variantLabel.implicitHeight + Theme.fs(3)
                        Text {
                            id: variantLabel
                            anchors.centerIn: parent
                            text: hrow.host.caps.variant === null
                                      ? "" : String(hrow.host.caps.variant)
                            color: Theme.active
                            font.pixelSize: Theme.fs(9)
                        }
                    }
                }

                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    text: RemoteAgentService.summaryFor(hrow.host)
                    color: Theme.subtext
                    font.pixelSize: Theme.fs(10)
                }
            }
        }
    }

    // ── Its sessions ──────────────────────────────────────────────────────────
    Column {
        id: sessionColumn
        anchors.top: header.bottom
        anchors.topMargin: hrow.sessionCount > 0 || hrow._slice.hidden > 0
                               ? Theme.fs(2) : 0
        width: parent.width
        spacing: 0

        Repeater {
            model: hrow.sessionCount

            delegate: RemoteSessionRow {
                required property int index
                width: sessionColumn.width
                session: hrow._slice.shown[index]
            }
        }

        // A build box that has run forty agents this week is not a reason for
        // this page to become forty rows tall.
        Text {
            visible: hrow._slice.hidden > 0
            height: visible ? Theme.fs(20) : 0
            leftPadding: Theme.fs(46)
            text: "and " + hrow._slice.hidden + " more"
            color: Theme.subtext
            font.pixelSize: Theme.fs(9)
        }
    }
}
