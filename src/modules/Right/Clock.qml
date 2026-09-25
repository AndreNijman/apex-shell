import QtQuick
import "../../"
import "../../components"

// Bar clock. Left-click cycles seconds on/off, right-click swaps to the date.
//
// The text is a plain binding on the shared Time singleton rather than a local
// 1 Hz Timer writing into `text`. Seconds mode is the only mode that needs a
// per-second tick, so it is the only mode that holds a ref on Time's
// second-precision clock; in the other two modes the whole shell wakes once a
// minute, on the minute, instead of once a second forever.
Text {
    id: clock
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    // Only the hh:mm:ss mode needs second-precision ticks.
    ServiceRef {
        service: Time
        active: clock.formatMode === 1
    }

    text: {
        switch (clock.formatMode) {
        case 1:
            return Time.formatSeconds("hh:mm:ss")
        case 2:
            return Time.format("dd-MM-yyyy")
        default:
            return Time.format("hh:mm")
        }
    }
    // 14 / 600 / tabular figures in the UI face (brief §C.4, §D.4): the bar's
    // anchor, calm — not mono (mono is for telemetry inside panels), and no
    // accent on hover (the accent in the bar means "open").
    color: Theme.textPrimary
    font.family: Theme.fontUi
    font.weight: Font.DemiBold
    font.features: { "tnum": 1 }
    anchors.verticalCenter: parent.verticalCenter
    font.pixelSize: theme.fs(14)
    // The gap between groups is 12 (cluster | clock | bell); the row's is 8.
    leftPadding: theme.px(2)
    rightPadding: theme.px(2)

    property int formatMode: 0

    state: "time"
    states: [
        State {
            name: "time"
            PropertyChanges { target: clock; formatMode: 0 }
        },
        State {
            name: "timeSeconds"
            PropertyChanges { target: clock; formatMode: 1 }
        },
        State {
            name: "date"
            PropertyChanges { target: clock; formatMode: 2 }
        }
    ]

    HoverHandler { id: clockHov }
    MouseArea {
        anchors.fill: parent
        acceptedButtons:     Qt.LeftButton | Qt.RightButton
        onClicked: (mouse) => {
            if (mouse.button === Qt.RightButton) {
                if (clock.state === "time" || clock.state === "timeSeconds") {
                    clock.state = "date"
                } else if (clock.state === "date" || clock.state === "timeSeconds") {
                    clock.state = "time"
                }
            } else {
                if (clock.state === "time"|| clock.state === "date") {
                    clock.state = "timeSeconds"
                } else if (clock.state === "timeSeconds" || clock.state === "date") {
                    clock.state = "time"
                }
            }
        }
    }
}
