import QtQuick
import "../"

Canvas {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes

    anchors.fill: parent

    // Multisample the canvas so the notch curves are crisp, not stair-stepped.
    layer.enabled: true
    layer.samples:  8
    layer.smooth:   true

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

    // Right notch bottom-left corner radius. TopBar animates this to 0 while a
    // pill-popup hangs under the right notch, so the pill's left edge runs
    // straight into the popup's square top-left corner — one merged shape.
    property real rightBottomRadius: bottomRadius

    onWidthChanged:             requestPaint()
    onHeightChanged:            requestPaint()
    onLeftWidthChanged:         requestPaint()
    onCenterWidthChanged:       requestPaint()
    onRightWidthChanged:        requestPaint()
    onColorChanged:             requestPaint()
    onRightBottomRadiusChanged: requestPaint()

    onPaint: {
        var ctx = getContext("2d");
        ctx.reset();

        var leftW   = root.leftWidth
        var centerW = root.centerWidth
        var rightW  = root.rightWidth

        var r  = root.radius         // shoulders (concave, out of the strip)
        var rb = root.bottomRadius   // bottom corners (convex)
        var h = root.notchHeight
        var b = root.topBorderWidth
        var w = width

        // Calculated positions — whole pixels, the same rounding CENTER_BLOOM
        // applies, so an odd width never leaves a half-pixel seam between the
        // bar's notch and the surface drawn over it.
        var centerStart = Math.round(w / 2) - Math.round(centerW / 2)
        var centerEnd   = centerStart + Math.round(centerW)
        var rightStart  = w - rightW

        ctx.beginPath();
        ctx.fillStyle = root.color;

        // ============================
        // 1. LEFT NOTCH
        // ============================
        ctx.moveTo(0, h);
        ctx.lineTo(leftW - rb, h);
        ctx.arcTo(leftW, h, leftW, h - rb, rb);
        ctx.lineTo(leftW, b + r);
        ctx.arcTo(leftW, b, leftW + r, b, r);

        // ============================
        // 2. GAP 1 (Left → Center)
        // ============================
        ctx.lineTo(centerStart - r, b);

        // ============================
        // 3. CENTER NOTCH
        // ============================
        ctx.arcTo(centerStart, b, centerStart, b + r, r);
        ctx.lineTo(centerStart, h - rb);
        ctx.arcTo(centerStart, h, centerStart + rb, h, rb);
        ctx.lineTo(centerEnd - rb, h);
        ctx.arcTo(centerEnd, h, centerEnd, h - rb, rb);
        ctx.lineTo(centerEnd, b + r);
        ctx.arcTo(centerEnd, b, centerEnd + r, b, r);

        // ============================
        // 4. GAP 2 (Center → Right)
        // ============================
        ctx.lineTo(rightStart - r, b);

        // ============================
        // 5. RIGHT NOTCH
        // ============================
        var rb = root.rightBottomRadius
        ctx.arcTo(rightStart, b, rightStart, b + r, r);
        ctx.lineTo(rightStart, h - rb);
        ctx.arcTo(rightStart, h, rightStart + rb, h, rb);
        ctx.lineTo(w, h);

        // ============================
        // 6. CLOSE LOOP
        // ============================
        ctx.lineTo(w, 0);
        ctx.lineTo(0, 0);
        ctx.lineTo(0, h);

        ctx.fill();
    }
}
