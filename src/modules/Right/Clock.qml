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
    color: clockHov.hovered ? Theme.active : Theme.text
    Behavior on color { ColorAnimation { duration: 120 } }
    font.bold: true
    anchors.verticalCenter: parent.verticalCenter
    font.pixelSize: Theme.fs(16)

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
