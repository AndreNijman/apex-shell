import Quickshell
import QtQuick
import "./src"
import "./src/shapes/fluid"

// ─────────────────────────────────────────────────────────────────────────────
// fluid-harness.qml — renders one fluid shape family at a list of progress
// values and saves each frame, so bad intermediate geometry is visible BEFORE a
// family goes anywhere near a real popup (Fluid roadmap §33).
//
// Staged at the repo root by tests/visual/fluid-harness.sh (so "./src" resolves)
// and run with `quickshell -p` inside the private headless compositor.
//
// Environment: HARNESS_FAMILY, HARNESS_OUT (directory), HARNESS_SCALE (the
// output factor the geometry is built at, default 1.0), HARNESS_STEPS (default
// 11 → 0.0, 0.1 … 1.0), HARNESS_BG (a wallpaper image, optional).
// ─────────────────────────────────────────────────────────────────────────────
ShellRoot {
    id: shellRoot
    readonly property string family: Quickshell.env("HARNESS_FAMILY") || "centerBloom"
    readonly property string outDir: Quickshell.env("HARNESS_OUT") || "/tmp"
    readonly property real   sc: parseFloat(Quickshell.env("HARNESS_SCALE") || "1.0")
    readonly property int    steps: parseInt(Quickshell.env("HARNESS_STEPS") || "11")
    readonly property string bg: Quickshell.env("HARNESS_BG") || ""

    FloatingWindow {
        id: win
        implicitWidth: 1400; implicitHeight: 760
        color: "#2a2a30"

        ThemeSet { id: t; scale: shellRoot.sc }

        Item {
            id: stage
            anchors.fill: parent

            Image {
                anchors.fill: parent
                source: shellRoot.bg !== "" ? "file://" + shellRoot.bg : ""
                fillMode: Image.PreserveAspectCrop
                visible: shellRoot.bg !== ""
            }

            // The bar as it is drawn today: a strip across the top and the
            // centre notch hanging from it, so the join can be judged.
            Rectangle { x: 0; y: 0; width: parent.width; height: t.borderWidth; color: Theme.background }
            FluidShape {
                anchors.fill: parent
                family: "centerBloom"
                progress: 0
                geometry: harnessGeo.centre
                opacity: 1
            }

            FluidShape {
                id: shp
                anchors.fill: parent
                family: shellRoot.family
                progress: 0
                geometry: harnessGeo[shellRoot.family] || harnessGeo.centre
            }

            // The content clip, outlined, so a clip that runs outside the body
            // (or lags inside it) is obvious.
            Rectangle {
                x: shp.result.clip.x; y: shp.result.clip.y
                width: shp.result.clip.w; height: shp.result.clip.h
                color: "transparent"; border.color: "#40ff66"; border.width: 1
                opacity: 0.5
            }
            Text {
                x: 12; y: parent.height - 30
                color: "white"; font.pixelSize: 14
                text: shellRoot.family + "  p=" + shp.progress.toFixed(2) + "  scale=" + shellRoot.sc
            }
        }

        QtObject {
            id: harnessGeo
            readonly property var centre: ({
                cx: stage.width / 2, strip: t.borderWidth,
                notchW: t.cNotchMinWidth, notchH: t.notchHeight,
                shoulder: t.notchRadius, notchR: t.notchRadius,
                w: t.px(900), h: t.px(520), r: t.cornerRadius + t.px(4), shoulder1: t.notchRadius
            })
            readonly property var centerBloom: centre
        }

        property int i: -1
        Timer {
            id: step
            interval: 250; running: true; repeat: false
            onTriggered: {
                win.i++
                if (win.i >= shellRoot.steps) { Qt.quit(); return }
                shp.progress = shellRoot.steps > 1 ? win.i / (shellRoot.steps - 1) : 1
                grab.start()
            }
        }
        Timer {
            id: grab
            interval: 120
            onTriggered: stage.grabToImage(function (r) {
                var n = String(Math.round(shp.progress * 100)).padStart(3, "0")
                r.saveToFile(shellRoot.outDir + "/" + shellRoot.family + "-s" + shellRoot.sc + "-p" + n + ".png")
                step.start()
            })
        }
    }
}
