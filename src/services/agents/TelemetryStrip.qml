import QtQuick
import "../"
import "../../"
import "../agenttelemetry.js" as Telemetry

// The account's rate-limit windows, said once (roadmap P1-021).
//
// ── WHY THIS IS NOT ON THE SESSION ROWS ─────────────────────────────────────
//
// A five-hour or seven-day window belongs to the LOGIN, not to a session. Six
// agents running against this repository all report the same 62%, and putting
// it on six rows is not six pieces of information — it is one, repeated until
// the reader stops seeing it. That is precisely the failure P1-022 exists for,
// one surface over, and the same answer applies: say it once, in the place a
// person looks for a fact about the whole machine.
//
// So the rows carry the model, the context window and the branch, which
// genuinely differ per session, and this strip carries the two windows, which
// do not.
//
// ── AND WHY IT SAYS WHEN IT LAST HEARD ──────────────────────────────────────
//
// Claude's status line runs on a timer and on events. A fleet where every
// agent has been idle for an hour last reported an hour ago, and "62% used"
// drawn from that with no qualification is a number the shell cannot stand
// behind. agenttelemetry.js takes the reading from the FRESHEST session — not
// the first in the list, not the highest — and this says how old it is as soon
// as it stops being current.
//
// ── AND WHY IT IS ABSENT RATHER THAN EMPTY ──────────────────────────────────
//
// `rate_limits` reaches the status line only for a Pro or Max account, and
// only after the first API response. A strip that showed 0% for everyone else
// would be inventing a measurement; one that showed an empty frame would be a
// permanent reminder of a feature they do not have. It simply is not there.

Item {
    id: strip

    // Recomputed on every poll, which is what makes the age below tick rather
    // than freeze at whatever it was when the page opened.
    readonly property real now: Date.now() / 1000
    readonly property var reading: Telemetry.fleet(AgentService.sessions, strip.now)

    visible: !!strip.reading
    height: visible ? content.implicitHeight + Theme.px(12) : 0

    Rectangle {
        anchors.fill: parent
        radius: Theme.px(8)
        color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.03)
    }

    Row {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Theme.px(12)
        anchors.rightMargin: Theme.px(12)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.px(14)

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "󰄉"
            color: Theme.subtext
            font.pixelSize: Theme.fs(12)
        }

        // One window each. `windowLine` returns an empty string for a window
        // nobody reported, and an empty Text is zero-width, so a plan with only
        // one of the two draws only that one.
        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: text !== ""
            text: Telemetry.windowLine("5h", strip.reading ? strip.reading.fiveHour : null,
                                       strip.reading ? strip.reading.fiveHourReset : null,
                                       strip.now)
            color: Theme[Telemetry.tokenFor(strip.reading ? strip.reading.fiveHour : null)]
            font.pixelSize: Theme.fs(11)
            font.bold: true
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: text !== ""
            text: Telemetry.windowLine("7d", strip.reading ? strip.reading.sevenDay : null,
                                       strip.reading ? strip.reading.sevenDayReset : null,
                                       strip.now)
            color: Theme[Telemetry.tokenFor(strip.reading ? strip.reading.sevenDay : null)]
            font.pixelSize: Theme.fs(11)
            font.bold: true
        }

        // Only once it stops being current. A reading under one refresh
        // interval old is simply the reading, and stamping every one of those
        // with "just now" would add a word to the line that never changes.
        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: !!strip.reading && strip.reading.freshness !== "fresh"
            text: strip.reading ? Telemetry.agoLabel(strip.reading.ageSecs) : ""
            color: Theme.subtext
            font.pixelSize: Theme.fs(10)
        }
    }
}
