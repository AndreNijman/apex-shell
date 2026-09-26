import QtQuick
import Quickshell
import "./src/services"
import "./src/popups"
import "./src"

// OSD harness (tests/visual/osd-harness.sh): the REAL Osd on the first output,
// driven through its own _trigger — the headless session has no PipeWire and no
// backlight to do it — so its CAPSULE motion can be captured. Prints a
// "TRIGGER <name> <epoch ms>" line at each step; the runner bursts frames from it.
ShellRoot {
    id: r
    Osd { id: osd; screen: Quickshell.screens[0] }

    property int step: 0
    Timer {
        interval: 1500; running: true
        onTriggered: {                    // past the OSD's 900 ms boot guard
            console.warn("TRIGGER show " + Date.now())
            osd._trigger("volume", 0.42, false, "󰕾", "42%")
            held.start()
        }
    }
    // A held key: a step every 60 ms for a second, after the entrance.
    Timer {
        id: held; interval: 700
        onTriggered: { console.warn("TRIGGER held " + Date.now()); tick.start() }
    }
    Timer {
        id: tick; interval: 60; repeat: true
        onTriggered: {
            r.step++
            const v = Math.min(1, 0.42 + r.step * 0.03)
            osd._trigger("volume", v, false, "󰕾", Math.round(v * 100) + "%")
            if (r.step >= 16) { tick.stop(); console.warn("TRIGGER release " + Date.now()); quit.start() }
        }
    }
    Timer { id: quit; interval: 2600; onTriggered: Qt.quit() }
}
