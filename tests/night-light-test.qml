import Quickshell
import QtQuick
import "./src"
import "./src/services"

// ─────────────────────────────────────────────────────────────────────────────
// Night light, driven against a REAL compositor. Run via
// tests/run-night-light-test.sh, which brings its own headless one and its own
// PID namespace, and which decides what each phase should have produced.
//
// This file makes no assertions of its own. It prints what the facade did — the
// mechanism it chose, the argv it ran, whether the tool stayed up and what it
// said when it did not — and the runner grades that against the phase it set
// up. The split is deliberate: the interesting facts are "gammastep exited 1 on
// niri" and "hyprsunset was spawned on Hyprland", and both are properties of the
// machine rather than of the QML, so the QML has no business deciding whether
// they are right.
//
// The tool is spawned for real in every phase. That is safe here and nowhere
// else: the runner re-execs itself inside a private PID namespace, so the
// `pkill -x` the facade uses to stop the tool can see the test's own processes
// and nothing else on the machine.
// ─────────────────────────────────────────────────────────────────────────────

ShellRoot {
    id: root

    function say(k, v) { console.log("[nl] " + k + "=" + v) }

    // Long enough for the backend Loader to settle and for a doomed gammastep to
    // fail: it connects, binds, discovers there is no gamma control and exits.
    // Measured at well under a second; 1200 ms is slack, not a guess dressed up
    // as one.
    property int step: 0

    Timer {
        interval: 1200
        repeat:   true
        running:  true
        onTriggered: {
            root.step++
            switch (root.step) {
            case 1:
                root.say("compositor",  Compositor.name)
                root.say("mechanism",   CompositorService.nightLightMechanism)
                root.say("supported",   CompositorService.nightLightSupported)
                root.say("capability",  CompositorService.can.nightLight)
                root.say("temperature", CompositorService.nightLightTemperature)
                // Nothing has been asked for yet, so nothing may claim to be on.
                root.say("active-before", CompositorService.nightLightActive)
                root.say("returned", CompositorService.setNightLight(true))
                break
            case 2:
                root.say("active-on", CompositorService.nightLightActive)
                root.say("error-on",  CompositorService.nightLightError)
                CompositorService.setNightLightTemperature(3200)
                break
            case 3:
                root.say("temperature-after", CompositorService.nightLightTemperature)
                root.say("active-after",      CompositorService.nightLightActive)
                root.say("error-after",       CompositorService.nightLightError)
                CompositorService.setNightLight(false)
                break
            case 4:
                root.say("active-off", CompositorService.nightLightActive)
                root.say("error-off",  CompositorService.nightLightError)
                console.log("[nl] done")
                Qt.exit(0)
                break
            }
        }
    }
}
