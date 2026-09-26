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
// `channels` — { w, d, n, fw, fd } from a liquid SurfaceLifecycle — drives the
// family by its springs instead of by `progress` (see geometry.js, Channels).
// `hole` — SVG for a sub-path inside the body — is cut out of it (odd-even
// fill): the Dashboard leaves the notch's content window open so the bar's
// own label is seen fading as the bloom grows, rather than covered at once.
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
    property var    channels: null
    property string hole: ""
    property color  color: Theme.background

    /// The family's full result: path, bounds, clip, bar (see geometry.js).
    readonly property var result: Geo[shape.family](shape.progress,
        shape.channels ? Object.assign({}, shape.geometry, { ch: shape.channels }) : shape.geometry)

    preferredRendererType: Shape.CurveRenderer

    ShapePath {
        fillColor:   shape.color
        fillRule:    ShapePath.OddEvenFill
        strokeWidth: -1
        strokeColor: "transparent"
        PathSvg { path: shape.hole !== "" ? shape.result.path + " " + shape.hole : shape.result.path }
    }
}
