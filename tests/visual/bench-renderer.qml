import Quickshell
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes

// bench-renderer.qml — frame cost of one animated connected shape.
//
// Animates a dashboard-sized notch-attached silhouette for 600 frames with one
// of four renderers (BENCH_VARIANT: idle | shape | geometry | canvas) and prints
// MARK-START / MARK-END. bench-renderer.sh samples the process tree's CPU time
// from /proc at those two marks — from OUTSIDE, because a FileView reading
// /proc/self/stat from in here returns stale text (reload is asynchronous) and
// reported numbers that a 2 ms busy-loop mutant did not move.
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: 1280; implicitHeight: 720
        color: "#202428"
        readonly property string variant: Quickshell.env("BENCH_VARIANT") || "shape"
        readonly property int total: 600
        property int frames: 0
        property real t0: 0
        property real p: 0
        function geo(p) {
            var w = 300 + 600 * p, h = 40 + 560 * p, cx = 640, r = 16 + 8 * p, b = 6
            return { l: cx - w / 2, rr: cx + w / 2, h: h, r: r, b: b, s: 15 + 10 * p }
        }
        function pathFor(p) {
            var g = geo(p), l = g.l, rr = g.rr, h = g.h, r = g.r, b = g.b, s = g.s
            return "M " + (l - s) + " " + b + " C " + (l - s * 0.45) + " " + b + " " + l + " " + (b + s * 0.55) + " " + l + " " + (b + s)
                 + " L " + l + " " + (h - r) + " C " + l + " " + (h - r * 0.45) + " " + (l + r * 0.45) + " " + h + " " + (l + r) + " " + h
                 + " L " + (rr - r) + " " + h + " C " + (rr - r * 0.45) + " " + h + " " + rr + " " + (h - r * 0.45) + " " + rr + " " + (h - r)
                 + " L " + rr + " " + (b + s) + " C " + rr + " " + (b + s * 0.55) + " " + (rr + s * 0.45) + " " + b + " " + (rr + s) + " " + b + " Z"
        }
        Loader {
            anchors.fill: parent
            sourceComponent: win.variant === "canvas" ? canvasC : win.variant === "idle" ? idleC : win.variant === "card" ? cardC : win.variant === "shadow" ? shadowC : (win.variant === "geometry" ? shapeGeoC : shapeC)
        }
        Component { id: idleC; Item { Rectangle { width: 10; height: 10; x: win.p * 100; color: "red" } } }
        // UI/UX Phase 18b: a floating card resizing every frame, without and with
        // Elevation's modal shadow (RectangularShadow, blur 40, 12 down, 4 in).
        // `shadow` minus `card` is what the shadow costs on this GPU.
        Component {
            id: cardC
            Item {
                Rectangle { id: c1; x: 300; y: 200; width: 500 + 300 * win.p; height: 360; radius: 20; color: "#fdfaf3"; border.width: 1; border.color: "#e2ddd3" }
            }
        }
        Component {
            id: shadowC
            Item {
                RectangularShadow { x: c2.x; y: c2.y; width: c2.width; height: c2.height; radius: 20; blur: 40; spread: -4; offset: Qt.vector2d(0, 12); color: Qt.rgba(0, 0, 0, 0.28); cached: false }
                Rectangle { id: c2; x: 300; y: 200; width: 500 + 300 * win.p; height: 360; radius: 20; color: "#fdfaf3"; border.width: 1; border.color: "#e2ddd3" }
            }
        }
        Component {
            id: shapeC
            Shape {
                preferredRendererType: Shape.CurveRenderer
                ShapePath { fillColor: "#1a282a"; strokeWidth: -1; PathSvg { path: win.pathFor(win.p) } }
            }
        }
        Component {
            id: shapeGeoC
            Shape {
                preferredRendererType: Shape.GeometryRenderer
                layer.enabled: true; layer.samples: 4
                ShapePath { fillColor: "#1a282a"; strokeWidth: -1; PathSvg { path: win.pathFor(win.p) } }
            }
        }
        Component {
            id: canvasC
            Canvas {
                layer.enabled: true; layer.samples: 8; layer.smooth: true
                property real pp: win.p
                onPpChanged: requestPaint()
                onPaint: {
                    var ctx = getContext("2d"); ctx.reset(); ctx.fillStyle = "#1a282a"
                    var g = win.geo(win.p), l = g.l, rr = g.rr, h = g.h, r = g.r, b = g.b, s = g.s
                    ctx.beginPath(); ctx.moveTo(l - s, b); ctx.quadraticCurveTo(l, b, l, b + s)
                    ctx.lineTo(l, h - r); ctx.arcTo(l, h, l + r, h, r); ctx.lineTo(rr - r, h); ctx.arcTo(rr, h, rr, h - r, r)
                    ctx.lineTo(rr, b + s); ctx.quadraticCurveTo(rr, b, rr + s, b); ctx.closePath(); ctx.fill()
                }
            }
        }
        Timer { id: quitT; interval: 400; onTriggered: Qt.quit() }
        FrameAnimation {
            running: true
            onTriggered: {
                win.frames++
                if (win.frames === 30) { console.warn("MARK-START"); win.t0 = Date.now() }
                win.p = (win.frames % 90) / 90
                if (win.variant === "busy") { var e = Date.now() + 2; while (Date.now() < e) {} }
                if (win.frames === 30 + win.total) {
                    console.warn("MARK-END variant=" + win.variant + " wall=" + (Date.now() - win.t0)); quitT.start()
                }
            }
        }
    }
}
