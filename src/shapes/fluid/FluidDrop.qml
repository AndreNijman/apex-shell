import QtQuick
import "geometry.js" as Geo

// ─────────────────────────────────────────────────────────────────────────────
// FluidDrop — the Nexus's extrusion, drawn as a field (geometry.js
// notchExtrudeField).
//
// The notch sags, a short thick neck comes down with a bulb on it, the bulb
// spreads into a sheet and the sheet into the window; the neck thins and
// draws back into the notch. Every part is round and every join is a
// meniscus, because the shape is a smooth union of round primitives
// evaluated per pixel (fluiddrop.frag) rather than curves joined by hand —
// the curves made a pipe with a lollipop and needle tips (Andre,
// 2026-09-27: "it's ugly").
//
//   geometry   notchExtrudeField's g: cx, notchW, notchH, notchBottom, card, r
//   channels   { w: lead, d: body, n: trail } — SurfaceLifecycle's springs
//   color      the fill
//
// `result` is the field's frame: its clip (where content may show) and bounds.
// The shader item covers only the bounds, not the whole screen.
//
// Where shaders do not run (the software scene graph), the same result is
// drawn plainly — the sheet as a rounded rectangle and the neck as a bar
// from the seam — rougher, never blank, and never a different trajectory.
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: drop

    property var geometry: ({})
    property var channels: ({ w: 0, d: 0, n: 0 })
    property color color

    readonly property var result: Geo.notchExtrudeField(0, Object.assign({}, drop.geometry, { ch: drop.channels }))
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
        property vector4d blends: Qt.vector4d(_r.card.r, _r.kN, _r.kC, _r.kW || 0)
        property vector4d upperA: _r.upper ? Qt.vector4d(_r.upper.ax, _r.upper.ay, _r.upper.ra, 1) : Qt.vector4d(0, 0, 0, 0)
        property vector4d upperB: _r.upper ? Qt.vector4d(_r.upper.bx, _r.upper.by, _r.upper.rb, 0) : Qt.vector4d(0, 0, 0, 0)
        property vector4d lowerA: _r.lower ? Qt.vector4d(_r.lower.ax, _r.lower.ay, _r.lower.ra, 1) : Qt.vector4d(0, 0, 0, 0)
        property vector4d lowerB: _r.lower ? Qt.vector4d(_r.lower.bx, _r.lower.by, _r.lower.rb, 0) : Qt.vector4d(0, 0, 0, 0)
        property color fillColor: drop.color
    }

    Item {
        anchors.fill: parent
        visible: !drop.shaded
        Rectangle {
            readonly property var _c: drop.result.card
            x: _c.cx - _c.hw; y: _c.cy - _c.hh
            width: 2 * _c.hw; height: 2 * _c.hh
            radius: _c.r
            color: drop.color
        }
        Rectangle {
            readonly property var _u: drop.result.upper
            readonly property var _l: drop.result.lower
            readonly property real _w: (_u && _l) ? 2 * Math.min(_u.ra, _u.rb, _l.rb) : 0
            visible: _w > 0
            x: drop.result.card.cx - _w / 2
            y: drop.result.notch.y
            width: _w
            height: _l ? Math.max(0, _l.by - drop.result.notch.y) : 0
            radius: _w / 2
            color: drop.color
        }
    }
}
