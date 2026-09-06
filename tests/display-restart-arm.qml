import Quickshell
import QtQuick
import "./src/components"
import "./src/services"
import "./src/nexus"
import "./src/popups"
import "./src"

// Half of criterion 8's "shell restart during the transaction".
//
// This entry point stages one change, applies it, announces that the countdown
// is running, and then does nothing at all. The harness kills it — with SIGKILL,
// so no QML cleanup path can run — and then asks the compositor whether the
// layout came back.
//
// The point being made: the thing that restores the layout must not be inside
// the process that can die. Before P0-018 it was a QML Timer in DisplayService,
// and killing the shell here left the machine on the layout nobody confirmed.
ShellRoot {
    id: root

    readonly property string output: "HEADLESS-1"

    property bool armed: false
    property bool announced: false

    Component.onCompleted: DisplayService.refresh()

    Timer {
        interval: 200
        repeat: true
        running: true
        onTriggered: {
            if (root.armed) return
            if (!DisplayService.loaded || DisplayService.draft.length === 0) return
            root.armed = true
            DisplayService.stage(root.output, "scale", 2.0)
            DisplayService.apply()
        }
    }

    Connections {
        target: DisplayService
        function onConfirmSecondsChanged() {
            if (DisplayService.confirmSeconds > 0 && !root.announced) {
                root.announced = true
                console.log("RESTART-READY " + DisplayService.confirmSeconds)
            }
        }
        function onLastErrorChanged() {
            if (DisplayService.lastError !== "")
                console.log("RESTART-ERROR " + DisplayService.lastError)
        }
    }

    Timer {
        interval: 60000
        running: true
        onTriggered: {
            console.log("RESTART-TIMEOUT")
            Qt.exit(1)
        }
    }
}
