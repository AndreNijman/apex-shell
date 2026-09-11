import QtQuick
import "../"
import "../services/qr.js" as QR

// ─────────────────────────────────────────────────────────────────────────────
//  A QR code, drawn from a payload (roadmap P1-051, criterion 1).
//
//  ── Canvas rather than a Repeater ───────────────────────────────────────────
//
//  A pairing offer naming a relay is a version 13 symbol: 69 x 69 = 4761
//  modules, and 4761 Rectangles is a scene graph node per module for something
//  that is one bitmap and never animates. One Canvas and one repaint is the
//  whole of it.
//
//  ── Fixed contrast, on purpose ──────────────────────────────────────────────
//
//  The palette here is wallpaper-derived and can land anywhere, including two
//  mid-tones a camera cannot separate. A QR code that follows the theme is a
//  QR code that stops scanning on somebody's wallpaper. So the modules are
//  Theme.fixedDark on Theme.fixedLight -- the two tokens Colors.qml declares
//  for exactly this, "a foreground sitting on something whose colour is NOT
//  the themed background" -- and they stay put whatever the scheme does.
//
//  Not "black" and "white", which would be two new colour literals and would
//  fail tests/check-color-tokens.sh's exact count. fixedDark is #1e1e2e rather
//  than #000000; against #ffffff that is about 15.9:1, where a scanner needs
//  roughly 3:1.
//
//  ── The quiet zone is not optional ──────────────────────────────────────────
//
//  ISO/IEC 18004 requires four modules of light on every side, and a decoder
//  that cannot find it does not find the symbol. qr.js returns the matrix with
//  no quiet zone and says in its own header that "a caller that draws it owes
//  it four modules of light on every side" -- this is the caller, and this is
//  where that debt is paid. Drawing the code hard against a dark settings
//  background without it is the classic way to ship a QR nothing scans.
//
//  ── What is exposed, and why ────────────────────────────────────────────────
//
//  `modules`, `moduleCount` and `version` are readable properties rather than
//  private state, because that is what the headless suite asserts on. Reading
//  pixels back out of a Canvas under pixman is fragile and would be testing
//  the renderer; reading the matrix tests what this component was given and
//  what it decided to draw, which is the part that can be wrong.
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: root

    // The `apex-remote:` payload. Empty draws nothing at all -- deliberately
    // not a placeholder pattern, because a QR-shaped thing that is not a QR
    // code is the failure `apex remote pair` refuses to risk.
    property string payload: ""

    // Error correction level. `m` rather than the encoder's default `l`: a
    // phone photographs this off a screen at an angle, under whatever lighting
    // the room has, and m tolerates about 15% damage against l's 7% for four
    // more modules on a side at this payload size.
    property string level: "m"

    // Four, as the specification requires. A property so the test can assert
    // the drawn extent accounts for it rather than trusting the arithmetic.
    readonly property int quietZone: 4

    // The encode result, or null when there is no payload or it could not be
    // encoded. Never a partial matrix: a half-drawn QR is a wrong QR.
    readonly property var encoded: {
        if (!root.payload) return null
        try {
            return QR.encode(root.payload, { level: root.level })
        } catch (e) {
            // A payload no version holds. The page shows the failure; this
            // draws nothing rather than something misleading.
            return null
        }
    }

    readonly property var modules: root.encoded ? root.encoded.modules : []
    readonly property int moduleCount: root.encoded ? root.encoded.size : 0
    readonly property int version: root.encoded ? root.encoded.version : 0

    // Total modules across, quiet zone included. The drawn symbol is square,
    // so this is what the side length divides by.
    readonly property int span: root.moduleCount > 0
        ? root.moduleCount + root.quietZone * 2 : 0

    implicitWidth: Theme.px(220)
    implicitHeight: root.implicitWidth

    onEncodedChanged: canvas.requestPaint()
    onWidthChanged: canvas.requestPaint()
    onHeightChanged: canvas.requestPaint()

    Canvas {
        id: canvas
        anchors.fill: parent
        // Repainting on a scale change rather than stretching a cached bitmap:
        // a resampled QR is a blurred QR, and blur is what a camera fails on.
        renderStrategy: Canvas.Immediate

        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            if (root.span <= 0) return

            var side = Math.min(width, height)
            // Whole pixels per module. A fractional module size puts a seam of
            // half-lit pixels between neighbours, which is the other way a
            // screen-displayed code stops scanning. Losing a pixel or two off
            // the edge is cheaper than losing the edges of every module.
            var px = Math.max(1, Math.floor(side / root.span))
            var drawn = px * root.span
            var ox = Math.floor((width - drawn) / 2)
            var oy = Math.floor((height - drawn) / 2)

            // The quiet zone is part of the symbol, so it is painted, not left
            // to whatever is behind the component.
            ctx.fillStyle = Theme.fixedLight
            ctx.fillRect(ox, oy, drawn, drawn)

            ctx.fillStyle = Theme.fixedDark
            var q = root.quietZone
            for (var y = 0; y < root.moduleCount; y++) {
                var row = root.modules[y]
                for (var x = 0; x < root.moduleCount; x++) {
                    if (row[x]) {
                        ctx.fillRect(ox + (x + q) * px, oy + (y + q) * px, px, px)
                    }
                }
            }
        }
    }
}
