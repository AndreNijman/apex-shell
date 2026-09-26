import QtQuick
import QtQuick.Shapes
import "../"
import "fluid/geometry.js" as Geo

// ─────────────────────────────────────────────────────────────────────────────
// SeamlessBarShape — the top strip and its three notches, one silhouette.
//
// Drawn by the same renderer as every fluid surface (QtQuick.Shapes
// CurveRenderer, path from geometry.js barSilhouette). It was a Canvas with an
// 8x multisampled layer; measured under the first RIGHT_POUR, that repainted a
// frame or more behind its inputs, so the notch visibly trailed the body
// hanging from it — up to 77 px mid-pour — and cost almost three times as much
// a frame. Same geometry, same corners, same whole-pixel rounding.
// ─────────────────────────────────────────────────────────────────────────────
Shape {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes

    anchors.fill: parent

    // These are set by TopBar.qml with the real clamped widths.
    // They default to the Theme constraints so the shape is never empty.
    property int leftWidth:   theme.lNotchMinWidth
    property int centerWidth: theme.cNotchMinWidth
    property int rightWidth:  theme.rNotchMinWidth

    property int notchHeight:     theme.notchHeight
    // The two radii of a notch are two tokens (ThemeSet): the concave
    // SHOULDER out of the strip and the convex BOTTOM corner. Surfaces that
    // grow out of a notch read the same pair, so at progress 0 they are this
    // shape exactly.
    property int radius:          theme.notchShoulder
    property int bottomRadius:    theme.notchBottom
    property int topBorderWidth:  theme.borderWidth
    property color color:         Theme.background

    // Right notch bottom-left corner radius. The right panel covers this
    // corner itself while it is attached (geometry.js rightPour), so TopBar
    // leaves it at the notch's own; it stays a property for a surface that
    // cannot.
    property real rightBottomRadius: bottomRadius

    // A pane hangs under the right notch (TopBar.rightLife): the hairline stops
    // short of that notch rather than running along the seam.
    property bool rightAttached: false

    readonly property var result: Geo.barSilhouette({
        w:            root.width,
        strip:        root.topBorderWidth,
        h:            root.notchHeight,
        shoulder:     root.radius,
        bottom:       root.bottomRadius,
        leftW:        root.leftWidth,
        centerW:      root.centerWidth,
        rightW:       root.rightWidth,
        rightBottomL: root.rightBottomRadius
    })

    preferredRendererType: Shape.CurveRenderer

    ShapePath {
        fillColor:   root.color
        strokeWidth: -1
        strokeColor: "transparent"
        PathSvg { path: root.result.path }
    }

    // The depth cue (brief §C.6, §D.7): one 1 px line along the edge the
    // wallpaper meets, inset so it never touches the wallpaper — no shadow,
    // no blur. On a light wallpaper it disappears; on a dark one it is the
    // separation.
    readonly property var hairline: Geo.barHairline({
        w:             root.width,
        strip:         root.topBorderWidth,
        h:             root.notchHeight,
        shoulder:      root.radius,
        bottom:        root.bottomRadius,
        leftW:         root.leftWidth,
        centerW:       root.centerWidth,
        rightW:        root.rightWidth,
        rightBottomL:  root.rightBottomRadius,
        rightAttached: root.rightAttached
    })
    ShapePath {
        fillColor:   "transparent"
        strokeWidth: 1
        strokeColor: Theme.hairline
        capStyle:    ShapePath.FlatCap
        joinStyle:   ShapePath.RoundJoin
        PathSvg { path: root.hairline.path }
    }
}
