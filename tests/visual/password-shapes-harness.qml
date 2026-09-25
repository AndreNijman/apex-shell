import Quickshell
import QtQuick
import "./src/components/auth"

// ─────────────────────────────────────────────────────────────────────────────
// password-shapes-harness.qml — the password-shape indicator, driven through a
// scripted typing session and grabbed frame by frame for review. Staged at the
// repo root by tests/visual/password-shapes-harness.sh.
//
// Environment: HARNESS_OUT (dir), HARNESS_SCALE (motion scale; 3 = slow
// motion, so mid-animation frames are catchable), HARNESS_REDUCED (1/0).
// ─────────────────────────────────────────────────────────────────────────────
ShellRoot {
    id: h
    readonly property string outDir: Quickshell.env("HARNESS_OUT") || "/tmp"
    readonly property real motionScale: parseFloat(Quickshell.env("HARNESS_SCALE") || "1")
    readonly property bool reduced: Quickshell.env("HARNESS_REDUCED") === "1"

    FloatingWindow {
        implicitWidth: 460; implicitHeight: 150
        color: "#171210"

        Item {
            id: stage
            anchors.fill: parent

            // The lock screen's field, verbatim geometry.
            Rectangle {
                id: field
                anchors.centerIn: parent
                width: 340; height: 52; radius: height / 2
                color: Qt.rgba(0.09, 0.07, 0.063, 0.55)
                border.width: 2
                border.color: h.err ? "#f87171" : "#fab898"
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left; anchors.leftMargin: 18
                    text: "󰌾"; color: "#d6c2ba"
                    font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 18
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left; anchors.leftMargin: 46
                    visible: shapes.empty
                    text: "Enter password"; color: "#d6c2ba"
                    font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 18
                }
                PasswordShapes {
                    id: shapes
                    anchors.fill: parent
                    anchors.leftMargin: 46; anchors.rightMargin: 52
                    length: h.len
                    accent: "#fab898"; text: "#ece0dc"; background: "#171210"; danger: "#f87171"
                    error: h.err
                    motionScale: h.motionScale
                    speed: "balanced"
                    reduced: h.reduced
                    size: 14
                }
            }
            Text {
                x: 10; y: 6; color: "#888"; font.pixelSize: 11
                text: h.label
            }
        }
    }

    property int len: 0
    property bool err: false
    property string label: ""

    // Script: [action, value, grab-name]
    //   len N      set the length
    //   err B      set the error flag
    //   wait MS    advance time
    //   grab NAME  save a frame
    readonly property var script: {
        var s = []
        function type(n, name) {
            s.push(["len", n]); s.push(["label", name])
            s.push(["grab", name + "-t000"])
            s.push(["wait", 40 * h.motionScale]); s.push(["grab", name + "-t040"])
            s.push(["wait", 50 * h.motionScale]); s.push(["grab", name + "-t090"])
            s.push(["wait", 60 * h.motionScale]); s.push(["grab", name + "-t150"])
            s.push(["wait", 120 * h.motionScale]); s.push(["grab", name + "-t270"])
        }
        type(1, "a-type1"); type(2, "b-type2"); type(3, "c-type3")
        s.push(["len", 8]); s.push(["wait", 600 * h.motionScale]); s.push(["label", "d-eight"]); s.push(["grab", "d-eight"])
        type(7, "e-delete")
        s.push(["len", 12]); s.push(["wait", 600 * h.motionScale]); s.push(["label", "f-twelve"]); s.push(["grab", "f-twelve"])
        s.push(["err", true]); s.push(["len", 0]); s.push(["label", "g-refused"])
        s.push(["grab", "g-refused-t000"]); s.push(["wait", 45 * h.motionScale]); s.push(["grab", "g-refused-t045"])
        s.push(["wait", 45 * h.motionScale]); s.push(["grab", "g-refused-t090"])
        s.push(["wait", 90 * h.motionScale]); s.push(["grab", "g-refused-t180"])
        s.push(["err", false]); s.push(["len", 40]); s.push(["wait", 900 * h.motionScale]); s.push(["label", "h-overflow"]); s.push(["grab", "h-overflow"])
        return s
    }
    property int pc: 0
    Timer {
        id: tick; interval: 400; running: true
        onTriggered: h.step()
    }
    function step() {
        while (h.pc < h.script.length) {
            var op = h.script[h.pc++]
            if (op[0] === "len") h.len = op[1]
            else if (op[0] === "err") h.err = op[1]
            else if (op[0] === "label") h.label = op[1]
            else if (op[0] === "wait") { tick.interval = Math.max(1, op[1]); tick.start(); return }
            else if (op[0] === "grab") {
                var name = op[1]
                stage.grabToImage(function (r) {
                    r.saveToFile(h.outDir + "/" + name + ".png")
                    tick.interval = 1; tick.start()
                })
                return
            }
        }
        Qt.quit()
    }
}
