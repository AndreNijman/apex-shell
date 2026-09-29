import QtQuick
import "../../"

// ─── LayoutGlyph ────────────────────────────────────────────────────────────
// A picture of a tiling layout: where the windows go.
//
// A layout IS an arrangement of windows, so it is drawn as one — tiles in the
// proportions the layout gives them (the bar showed `><`, `M`, `|3|`, `<3>`,
// which named nothing a person could see on their screen). The proportions are
// the ones measured in a nested Hyprland 0.56.2 (layouts.js says what each
// layout does):
//
//   dwindle    left half, then the right half split again and again
//   master     one wide window, three stacked beside it
//   monocle    one window in front, another behind it — the rest are there,
//              just not visible
//   scrolling  a column in view with the next ones cut off by the screen edge
//
// Tile edges land on whole pixels (the glyph is 18 px wide in the bar), so a
// 4 px tile is 4 px and not a blur across five.
// ────────────────────────────────────────────────────────────────────────────

Item {
    id: root

    property string layout: ""
    property color  ink:     Theme.iconDefault
    // The surface the glyph sits on: the front window of "monocle" is cut out
    // of the one behind it in this colour, which is what makes it read as two.
    property color  surface: Theme.background
    property int    gap:     1
    property real   tileRadius: 1

    // { x, y, w, h } in fractions of the box; `back` = behind or off screen.
    readonly property var tiles: {
        switch (String(root.layout).toLowerCase()) {
        case "dwindle":   return [{ x: 0,    y: 0,   w: 0.5,  h: 1   },
                                  { x: 0.5,  y: 0,   w: 0.5,  h: 0.5 },
                                  { x: 0.5,  y: 0.5, w: 0.25, h: 0.5 },
                                  { x: 0.75, y: 0.5, w: 0.25, h: 0.5 }]
        case "master":    return [{ x: 0,    y: 0,     w: 0.6, h: 1     },
                                  { x: 0.6,  y: 0,     w: 0.4, h: 1 / 3 },
                                  { x: 0.6,  y: 1 / 3, w: 0.4, h: 1 / 3 },
                                  { x: 0.6,  y: 2 / 3, w: 0.4, h: 1 / 3 }]
        case "monocle":   return [{ x: 0.24, y: 0,    w: 0.76, h: 0.76, back: true },
                                  { x: 0,    y: 0.24, w: 0.76, h: 0.76, front: true }]
        case "scrolling": return [{ x: -0.3, y: 0, w: 0.5,  h: 1, back: true },
                                  { x: 0.25, y: 0, w: 0.5,  h: 1 },
                                  { x: 0.8,  y: 0, w: 0.5,  h: 1, back: true }]
        default:          return [{ x: 0, y: 0, w: 1, h: 1 }]
        }
    }

    // A tile's two edges on one axis, in pixels. An inner edge gives up half
    // the gap to each neighbour; an edge on (or past) the box's own is left
    // where it is, so the outer tiles reach the box.
    function _lo(f, size) {
        const p = Math.round(f * size)
        return f <= 0 ? p : p + Math.ceil(root.gap / 2)
    }
    function _hi(f, size) {
        const p = Math.round(f * size)
        return f >= 1 ? p : p - Math.floor(root.gap / 2)
    }

    clip: true

    Repeater {
        model: root.tiles

        Rectangle {
            required property var modelData
            readonly property int x0: root._lo(modelData.x, root.width)
            readonly property int y0: root._lo(modelData.y, root.height)
            // The front window's cut-out is a border in the surface colour,
            // grown outward by the gap so the ink keeps the tile's own size.
            readonly property int grow: modelData.front ? root.gap : 0
            x: x0 - grow
            y: y0 - grow
            width:  Math.max(0, root._hi(modelData.x + modelData.w, root.width)  - x0) + 2 * grow
            height: Math.max(0, root._hi(modelData.y + modelData.h, root.height) - y0) + 2 * grow
            radius: root.tileRadius + grow
            color:  modelData.back ? Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.45) : root.ink
            border.width: grow
            border.color: root.surface
        }
    }
}
