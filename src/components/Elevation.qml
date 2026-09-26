import QtQuick
import QtQuick.Effects
import "../"

// ─────────────────────────────────────────────────────────────────────────────
// Elevation — the one shadow a floating surface casts (UI/UX roadmap v3 Phase
// 18b; visual roadmap §13, "restrained depth").
//
// Floating means free of the bar: the context menu, the window switcher, the
// dialogs and the settings sheet. The Dashboard, the right panel, the toasts,
// the OSD and the power menu grow out of the bar and cast nothing — a shadow
// on one of them would stop at its join with the bar and show the seam, since
// the bar has none (Fable, 18b). One shadow per surface, never on its rows.
//
// Two levels, by what is behind the surface:
//   "popup"  over the bare desktop (the context menu): blur 20, 4 down
//   "modal"  over a scrim (the dialogs, the switcher, the sheet): blur 40,
//            12 down, drawn 4 in so the halo does not read as a glow above it
// Black at an alpha per scheme — deeper on a dark palette, where a shadow has
// less to darken — not a palette role: a shadow is the absence of light. The
// surface keeps its 1 px outlineSoft rim: on a dark card over a dark wallpaper
// a black shadow separates nothing, and the rim is the only edge there.
//
// RectangularShadow is analytic — one quad, no offscreen layer — so it costs
// nothing measurable on a surface that animates. It follows its target's
// geometry, radius, visibility and opacity; declare it BEFORE the target, as a
// sibling, so it draws underneath:
//
//     Elevation { target: card; level: "modal" }
//     Rectangle { id: card; … }
// ─────────────────────────────────────────────────────────────────────────────
RectangularShadow {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }

    required property Item target
    property string level: "modal"
    // The target's corner radius when it is not a Rectangle (an Item holding one).
    property real targetRadius: (root.target && root.target.radius !== undefined) ? root.target.radius : 0

    readonly property bool _modal: root.level === "modal"

    x: root.target ? root.target.x : 0
    y: root.target ? root.target.y : 0
    width:  root.target ? root.target.width : 0
    height: root.target ? root.target.height : 0
    scale:  root.target ? root.target.scale : 1
    transformOrigin: root.target ? root.target.transformOrigin : Item.Center
    visible: !!root.target && root.target.visible && root.target.opacity > 0
    opacity: root.target ? root.target.opacity : 0

    radius: root.targetRadius
    blur:   theme.px(root._modal ? 40 : 20)
    spread: root._modal ? -theme.px(4) : 0
    offset: Qt.vector2d(0, theme.px(root._modal ? 12 : 4))
    color:  Qt.rgba(0, 0, 0, Theme.darkSurface ? (root._modal ? 0.45 : 0.40)
                                                : (root._modal ? 0.28 : 0.22))
    cached: false
}
