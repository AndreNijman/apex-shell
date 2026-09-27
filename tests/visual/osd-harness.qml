import QtQuick
import Quickshell
import "./src/services"
import "./src/popups"
import "./src"

// OSD harness (tests/visual/osd-harness.sh): the REAL Osd capsule on the first
// output, driven through OsdState._trigger — the headless session has no
// PipeWire and no backlight to do it — so its CAPSULE motion can be captured.
// Since 2026-09-27 the level shows in the centre notch and the capsule is the
// fallback for a screen without one; focus mode is set here to take that path.
// Prints a "TRIGGER <name> <epoch ms>" line at each step; the runner bursts
// frames from it.
ShellRoot {
    id: r
    Osd { id: osd; screen: Quickshell.screens[0] }
    Component.onCompleted: ShellState.focusMode = true

    property int step: 0
    Timer {
        interval: 1500; running: true
        onTriggered: {                    // past the OSD's 900 ms boot guard
            console.warn("TRIGGER show " + Date.now())
            OsdState._trigger("volume", 0.42, false, "󰕾", "42%")
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
            OsdState._trigger("volume", v, false, "󰕾", Math.round(v * 100) + "%")
            if (r.step >= 16) { tick.stop(); console.warn("TRIGGER release " + Date.now()); quit.start() }
        }
    }
    Timer { id: quit; interval: 2600; onTriggered: Qt.quit() }
}
