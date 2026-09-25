import QtQuick
import QtQuick.Shapes
import "../.."
import "geometry.js" as Geo

// ─────────────────────────────────────────────────────────────────────────────
// FluidShape — one fluid surface silhouette, drawn from parameters.
//
// `family` names a function in geometry.js (centerBloom, rightPour, …),
// `progress` is the surface's lifecycle progress, `geometry` the record of
// sizes it connects to. The path is rebuilt from those every time one changes;
// nothing here tweens a path.
//
// Rendered by QtQuick.Shapes' CurveRenderer, which anti-aliases on the GPU by
// itself. Do NOT wrap this in `layer.samples` — the 8x MSAA layer the Canvas
// shapes needed is most of what made them cost 1.65 ms a frame against this
// renderer's 0.17 (roadmaps/baseline/BASELINE.md §3).
// ─────────────────────────────────────────────────────────────────────────────
Shape {
    id: shape

    property string family: "centerBloom"
    property real   progress: 0
    property var    geometry: ({})
    property color  color: Theme.background

    /// The family's full result: path, bounds, clip, bar (see geometry.js).
    readonly property var result: Geo[shape.family](shape.progress, shape.geometry)

    preferredRendererType: Shape.CurveRenderer

    ShapePath {
        fillColor:   shape.color
        strokeWidth: -1
        strokeColor: "transparent"
        PathSvg { path: shape.result.path }
    }
}
