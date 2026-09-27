import QtQuick
import QtQuick.Shapes
import "geometry.js" as Geo

// ─────────────────────────────────────────────────────────────────────────────
// FluidDrop — the Nexus drip, drawn as a field (geometry.js notchDropField).
//
// A drop gathers at the notch and falls on a thread, the window swells out of
// it, the thread pinches and each tail draws back into its own side. Every
// part is round and every join is a meniscus, because the shape is a smooth
// union of round primitives evaluated per pixel (fluiddrop.frag) rather than
// curves joined by hand — the curves made a pipe with a lollipop and needle
// tips (Andre, 2026-09-27: "it's ugly … after letting go the drops become
// big").
//
//   geometry   notchDropField's g: cx, notchW, notchH, notchBottom, card, r
//   channels   { w: lead, d: body, n: trail } — SurfaceLifecycle's springs
//   color      the fill
//
// `result` is the field's frame: its clip (where content may show) and bounds.
// The shader item covers only the bounds, not the whole screen.
//
// Where shaders do not run (the software scene graph), the same drip is drawn
// with curves (geometry.js notchDrop): rougher, never blank.
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: drop

    property var geometry: ({})
    property var channels: ({ w: 0, d: 0, n: 0 })
    property color color

    readonly property var result: Geo.notchDropField(0, Object.assign({}, drop.geometry, { ch: drop.channels }))
    readonly property bool shaded: GraphicsInfo.api !== GraphicsInfo.Software
                                   && field.status !== ShaderEffect.Error
    // For tests: the shader item itself.
    readonly property alias shader: field

    ShaderEffect {
        id: field
        visible: drop.shaded && width > 0 && height > 0
        x: drop.result.bounds.x
        y: drop.result.bounds.y
        width: drop.result.bounds.w
        height: drop.result.bounds.h
        fragmentShader: "fluiddrop.frag.qsb"

        readonly property var _r: drop.result
        property point fieldOrigin: Qt.point(x, y)
        property size fieldSize: Qt.size(width, height)
        property real pixelRatio: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1
        property vector4d notchBox: Qt.vector4d(_r.notch.x0, _r.notch.x1, _r.notch.y, _r.notch.r)
        property vector4d bodyBox: Qt.vector4d(_r.card.cx, _r.card.cy, _r.card.hw, _r.card.hh)
        property vector4d blends: Qt.vector4d(_r.card.r, _r.kN, _r.kC, 0)
        property vector4d upperA: _r.upper ? Qt.vector4d(_r.upper.ax, _r.upper.ay, _r.upper.ra, 1) : Qt.vector4d(0, 0, 0, 0)
        property vector4d upperB: _r.upper ? Qt.vector4d(_r.upper.bx, _r.upper.by, _r.upper.rb, 0) : Qt.vector4d(0, 0, 0, 0)
        property vector4d lowerA: _r.lower ? Qt.vector4d(_r.lower.ax, _r.lower.ay, _r.lower.ra, 1) : Qt.vector4d(0, 0, 0, 0)
        property vector4d lowerB: _r.lower ? Qt.vector4d(_r.lower.bx, _r.lower.by, _r.lower.rb, 0) : Qt.vector4d(0, 0, 0, 0)
        property color fillColor: drop.color
    }

    Loader {
        anchors.fill: parent
        active: !drop.shaded
        sourceComponent: FluidShape {
            family:   "notchDrop"
            progress: 0
            channels: drop.channels
            geometry: drop.geometry
            fillRule: ShapePath.WindingFill
            color:    drop.color
        }
    }
}
