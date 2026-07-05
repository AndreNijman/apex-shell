import QtQuick
import "../"

// Draws a popup background that "melts" into whichever edge(s) it's attached to.
Canvas {
    id: root

    // Multisample so the "melt" curves render crisp, not stair-stepped.
    layer.enabled: true
    layer.samples:  8
    layer.smooth:   true

    property string attachedEdge: "top"
    property color color: Theme.background

    // Normal corner radius for the edges away from the notch
    property int radius: Theme.cornerRadius

    // Custom dimensions for the outward "melt" (concave corners)
    // Increase flareHeight to make the corners "higher" / stretch further
    property int flareWidth: Theme.cornerRadius
    property int flareHeight: Theme.cornerRadius

    // Inset of the flare start from the attached edge. Set this to the border
    // strip thickness (Theme.borderWidth) when the popup melts into one of the
    // screen-edge strips: the flare then starts at the strip's INNER edge with
    // a matching tangent, so the junction blends smoothly instead of kinking
    // out of the strip at a steep angle. The uncovered sliver between the
    // window edge and the flare start shows the strip behind (same colour).
    property int edgeOffset: 0

    onWidthChanged:        requestPaint()
    onHeightChanged:       requestPaint()
    onAttachedEdgeChanged: requestPaint()
    onColorChanged:        requestPaint()
    onFlareWidthChanged:   requestPaint()
    onFlareHeightChanged:  requestPaint()
    onEdgeOffsetChanged:   requestPaint()

    onPaint: {
        var ctx = getContext("2d")
        ctx.reset()

        var w = width
        var h = height
        var r = radius
        var fw = flareWidth
        var fh = flareHeight
        var off = edgeOffset

        ctx.beginPath()
        ctx.fillStyle = root.color

        // We use quadraticCurveTo(cpx, cpy, x, y) for the flares to allow
        // asymmetric stretching (making them higher/wider than a perfect circle).
        switch (root.attachedEdge) {

        case "left":
            // Body inset by fw on the Left. Flare stretches vertically by fh.
            ctx.moveTo(0, 0)
            ctx.quadraticCurveTo(0, fh, fw, fh)       // outward flare top-left
            ctx.lineTo(w - r, fh)
            ctx.arcTo(w, fh, w, fh + r, r)            // normal top-right
            ctx.lineTo(w, h - fh - r)
            ctx.arcTo(w, h - fh, w - r, h - fh, r)    // normal bottom-right
            ctx.lineTo(fw, h - fh)
            ctx.quadraticCurveTo(0, h - fh, 0, h)     // outward flare bottom-left
            ctx.closePath()
            break

        case "right":
            // Body inset by fw on the Right. Flare stretches vertically by fh.
            ctx.moveTo(w, 0)
            ctx.quadraticCurveTo(w, fh, w - fw, fh)   // outward flare top-right
            ctx.lineTo(r, fh)
            ctx.arcTo(0, fh, 0, fh + r, r)            // normal top-left
            ctx.lineTo(0, h - fh - r)
            ctx.arcTo(0, h - fh, r, h - fh, r)        // normal bottom-left
            ctx.lineTo(w - fw, h - fh)
            ctx.quadraticCurveTo(w, h - fh, w, h)     // outward flare bottom-right
            ctx.closePath()
            break

        case "top":
            // Body inset by fw on Left/Right. Flare stretches horizontally by fw, vertically by fh.
            // Flares start `off` below the window top, tangent to the bar
            // strip's bottom edge, so the melt blends smoothly out of it.
            ctx.moveTo(0, off)
            ctx.quadraticCurveTo(fw, off, fw, off + fh)   // outward flare top-left
            ctx.lineTo(fw, h - r)
            ctx.arcTo(fw, h, fw + r, h, r)                // normal bottom-left
            ctx.lineTo(w - fw - r, h)
            ctx.arcTo(w - fw, h, w - fw, h - r, r)        // normal bottom-right
            ctx.lineTo(w - fw, off + fh)
            ctx.quadraticCurveTo(w - fw, off, w, off)     // outward flare top-right
            ctx.closePath()
            break

        case "pill-right":
            // Card hanging directly below the top-right notch pill, same width
            // as the expanded pill. The top edge is flush with the pill bottom
            // and the top-left corner is SQUARE: the pill un-rounds its
            // bottom-left corner while a popup is open (SeamlessBarShape),
            // so pill + card share one continuous straight left edge — a true
            // single-shape merge with nothing peeking through. The right edge
            // runs flush with the screen edge; bottom corners are rounded.
            ctx.moveTo(0, 0)                   // square top-left, straight into the pill
            ctx.lineTo(w, 0)                   // flush under the pill
            ctx.lineTo(w, h - r)               // right edge, flush with screen
            ctx.arcTo(w, h, w - r, h, r)       // bottom-right corner
            ctx.lineTo(r, h)
            ctx.arcTo(0, h, 0, h - r, r)       // bottom-left corner
            ctx.closePath()
            break

        case "bottom":
            // Body inset by fw on Left/Right. Flare stretches horizontally by fw, vertically by fh.
            ctx.moveTo(0, h)
            ctx.quadraticCurveTo(fw, h, fw, h - fh)   // outward flare bottom-left
            ctx.lineTo(fw, r)
            ctx.arcTo(fw, 0, fw + r, 0, r)            // normal top-left
            ctx.lineTo(w - fw - r, 0)
            ctx.arcTo(w - fw, 0, w - fw, r, r)        // normal top-right
            ctx.lineTo(w - fw, h - fh)
            ctx.quadraticCurveTo(w - fw, h, w, h)     // outward flare bottom-right
            ctx.closePath()
            break

        case "bottom-right":
            // Popup sits in the bottom-right screen corner.
            // Canvas: (popupWidth + fw) × (popupHeight + fh)
            //
            // Body top edge at y=fh, body left edge at x=fw.
            // Right and bottom edges are flush with screen borders.
            //
            // fw pixels on LEFT  → bottom-left flare zone
            // fh pixels on TOP   → top-right flare zone
            //
            // Flares:
            //   top-right:   concave melt into right border
            //   bottom-left: concave melt into bottom border
            //   top-left:    normal convex rounded corner
            //   bottom-right: square — both border strips physically cover it
            //
            // Content safe zone: x ≥ fw, y ≥ fh  (margins handle both flare corners)

            // 1. Start top edge just after top-left radius
            ctx.moveTo(fw + r, fh)
            // 2. Top edge rightward to the flare start
            ctx.lineTo(w - fw, fh)
            // 3. Top-right flare: concave melt into the right border
            ctx.quadraticCurveTo(w, fh, w, 0)
            // 4. Right edge straight down (flush with right screen border)
            ctx.lineTo(w, h)
            // 5. Bottom edge straight left (flush with bottom screen border)
            ctx.lineTo(0, h)
            // 6. Bottom-left flare: concave melt into the bottom border
            ctx.quadraticCurveTo(fw, h, fw, h - fh)
            // 7. Left edge straight up to the top-left corner
            ctx.lineTo(fw, fh + r)
            // 8. Top-left: standard convex rounded corner
            ctx.arcTo(fw, fh, fw + r, fh, r)
            ctx.closePath()
            break
        }

        ctx.fill()
    }
}