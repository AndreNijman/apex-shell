import Quickshell
import QtQuick
import QtQuick.Shapes
import "./src/services"
import "./src"
import "./src/shapes/fluid"
import "./src/shapes/fluid/geometry.js" as Geo

// ─────────────────────────────────────────────────────────────────────────────
// fluid-harness.qml — one fluid shape family at a list of progress values, with
// the bar it grows out of drawn around it, so bad intermediate geometry — and a
// bad JOIN — is visible before a family goes anywhere near a real popup
// (Fluid roadmap §33). Staged at the repo root by tests/visual/fluid-harness.sh.
//
// Env: HARNESS_FAMILY (centerBloom | rightPour | leftSpill | edgeSpillRight),
// HARNESS_OUT, HARNESS_SCALE (output factor), HARNESS_STEPS, HARNESS_BG.
// ─────────────────────────────────────────────────────────────────────────────
ShellRoot {
    id: h
    readonly property string family: Quickshell.env("HARNESS_FAMILY") || "centerBloom"
    readonly property string outDir: Quickshell.env("HARNESS_OUT") || "/tmp"
    readonly property real   sc: parseFloat(Quickshell.env("HARNESS_SCALE") || "1.0")
    readonly property int    steps: parseInt(Quickshell.env("HARNESS_STEPS") || "11")
    readonly property string bg: Quickshell.env("HARNESS_BG") || ""
    property real p: 0

    FloatingWindow {
        id: win
        // Room for the largest family at the largest scale: at 1500x800 the
        // bloom and both spills ran off the viewport past p = 0.3-0.5 at 1.5x.
        implicitWidth: 1920; implicitHeight: 1080
        color: "#2a2a30"
        ThemeSet { id: t; scale: h.sc }

        Item {
            id: stage
            anchors.fill: parent
            readonly property color fill: Theme.background

            Image {
                anchors.fill: parent
                source: h.bg !== "" ? "file://" + h.bg : ""
                fillMode: Image.PreserveAspectCrop
                visible: h.bg !== ""
            }

            // ── geometry records per family ─────────────────────────────────
            readonly property int cNotchW: t.cNotchMinWidth
            readonly property int rNotchW: t.px(213)
            readonly property var bloomG: ({
                cx: stage.width / 2, strip: t.borderWidth, notchW: stage.cNotchW, notchH: t.notchHeight,
                shoulder: t.notchShoulder, notchBottom: t.notchBottom,
                w: t.px(900), h: t.notchHeight + t.px(520), r: t.radiusXL,
                shoulderW1: t.px(28), shoulderH1: t.px(22)
            })
            readonly property int pourWinW: t.networkPopupWidth + t.notchRadius
            // RightPanel's record, field for field: the pour reads the seam, the
            // notch's shoulder and its bottom corner, and draws from the window's
            // top (the band over the strip is part of it). Without those three the
            // path was built from NaN and the body never drew (Phase 23 review).
            readonly property var pourG: ({
                winW: stage.pourWinW, strip: t.borderWidth, seam: t.notchHeight,
                shoulder: t.notchShoulder, notchBottom: t.notchBottom, notchW: stage.rNotchW,
                w: stage.pourWinW, h: t.px(560), r: t.radiusL
            })
            readonly property var spillG: ({
                x0: t.borderWidth, cy: t.px(400), w: t.px(220), h: t.px(270), r: t.radiusL, rm: t.radiusM
            })
            readonly property var edgeG: ({
                x1: t.px(200), edgeW: t.borderWidth, cy: t.px(400), w: t.px(200), h: t.px(340),
                r: t.radiusL, rm: t.radiusM
            })

            // ── the bar: strip + notches, as the bar would draw them ────────
            Rectangle { x: 0; y: 0; width: parent.width; height: t.borderWidth; color: stage.fill }
            // left + right screen strips, under the bar
            Rectangle { x: 0; y: t.notchHeight; width: t.borderWidth; height: parent.height; color: stage.fill }
            Rectangle { x: parent.width - t.borderWidth; y: t.notchHeight; width: t.borderWidth; height: parent.height; color: stage.fill }

            Shape {   // centre notch (under the bloom)
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    fillColor: stage.fill; strokeWidth: -1
                    PathSvg { path: Geo.barNotch({ x: Math.round(stage.width / 2) - Math.round(stage.cNotchW / 2), w: stage.cNotchW,
                                                   strip: t.borderWidth, h: t.notchHeight, shoulder: t.notchShoulder,
                                                   bottomL: t.notchBottom, bottomR: t.notchBottom }).path }
                }
            }
            Shape {   // right notch, widening in step with RIGHT_POUR
                id: rNotch
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                readonly property int nw: h.family === "rightPour"
                                          ? Geo.rightPourWidth(h.p, stage.rNotchW, stage.pourWinW) : stage.rNotchW
                ShapePath {
                    fillColor: stage.fill; strokeWidth: -1
                    PathSvg { path: Geo.barNotch({ x: stage.width - rNotch.nw, w: rNotch.nw,
                                                   strip: t.borderWidth, h: t.notchHeight, shoulder: t.notchShoulder,
                                                   bottomL: (h.family === "rightPour" && h.p > 0) ? 0 : t.notchBottom,
                                                   bottomR: 0, edgeR: true }).path }
                }
            }

            // ── the family ──────────────────────────────────────────────────
            Item {
                id: host
                // Each family draws in its own window's coordinates; place that
                // window where the real one sits on screen.
                x: h.family === "rightPour" ? stage.width - stage.pourWinW
                 : h.family === "edgeSpillRight" ? stage.width - stage.edgeG.x1 - t.borderWidth
                 : 0
                y: 0
                width: stage.width; height: stage.height

                FluidShape {
                    id: shp
                    anchors.fill: parent
                    family: h.family
                    progress: h.p
                    color: stage.fill
                    geometry: h.family === "centerBloom" ? stage.bloomG
                            : h.family === "rightPour"   ? stage.pourG
                            : h.family === "leftSpill"   ? stage.spillG
                            : stage.edgeG
                }
                Rectangle {   // the content clip, outlined
                    x: shp.result.clip.x; y: shp.result.clip.y
                    width: shp.result.clip.w; height: shp.result.clip.h
                    color: "transparent"; border.color: "#40ff66"; border.width: 1; opacity: 0.45
                }
            }
            Text {
                x: 12; y: parent.height - 28; color: "white"; font.pixelSize: 14
                text: h.family + "  p=" + h.p.toFixed(2) + "  scale=" + h.sc
            }
        }

        property int i: -1
        Timer {
            id: step; interval: 300; running: true
            onTriggered: {
                win.i++
                if (win.i >= h.steps) { Qt.quit(); return }
                h.p = h.steps > 1 ? win.i / (h.steps - 1) : 1
                grab.start()
            }
        }
        Timer {
            id: grab; interval: 120
            onTriggered: stage.grabToImage(function (r) {
                var n = String(Math.round(h.p * 100)).padStart(3, "0")
                r.saveToFile(h.outDir + "/" + h.family + "-s" + h.sc + "-p" + n + ".png")
                step.start()
            })
        }
    }
}
