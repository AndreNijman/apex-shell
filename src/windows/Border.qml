import Quickshell
import QtQuick
import "../"
import "../services/"

PanelWindow {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForScreen(root.screen) }   // P1-040: this output's sizes


    property string edge: "bottom"
    property bool isBarEnabled: Theme.barEnabled
    property int thickness: theme.borderWidth      
    property int radius: theme.cornerRadius        
    property color fillColor: Theme.background 
    // The frame's rim: the bar's hairline, carried on along the strips and
    // round their fillets (SeamlessBarShape stops its own where a strip
    // attaches), so bar and frame read as one silhouette with one edge.
    property color rimColor: Theme.hairline
    // A strip starts one row inside the bar, so its flare meets the bar's
    // bottom edge (and its hairline) exactly rather than a row below it.
    readonly property int overlap: 1

    // Wide / tall enough for the whole fillet: a strip's flare reaches
    // thickness + radius along the notch's bottom, and the bottom strip's
    // fillets rise thickness + radius from the screen's bottom. Sized to the
    // radius alone (as they were), every fillet was cut off short of its
    // tangent and met the straight edge with a step (Andre, 2026-09-27: "the
    // corners fillets dont merge properly").
    implicitWidth: (edge === "left" || edge === "right") ? thickness + radius : 0
    implicitHeight: (edge === "bottom") ? thickness + radius : 0

    color: "transparent"
    exclusionMode: ExclusionMode.Ignore

    // Input: the footprint the strips always had — a radius wide (or tall) at
    // the screen's edge. The surface grew to hold its whole fillet, but that
    // extra room is drawing only; it lies over the edges of the windows beside
    // it, whose clicks it must not take (nor move where the edge hovers and
    // taps open their menus).
    mask: Region { item: inputArea }
    Item {
        id: inputArea
        x: root.edge === "right" ? parent.width - root.radius : 0
        y: root.edge === "bottom" ? parent.height - root.radius : 0
        width:  root.edge === "bottom" ? parent.width : root.radius
        height: root.edge === "bottom" ? root.radius : parent.height
    }

    // The three border strips are layer-shell surfaces on `top` too — three MORE
    // surfaces the compositor draws over a fullscreen game, purely decorative.
    // Unmap them with the bar. See ShellState.fullscreenCovers.
    property string screenName: screen ? screen.name : ""
    visible: !ShellState.fullscreenCovers(root.screenName)

    anchors {
        left: (edge === "left" || edge === "bottom")
        right: (edge === "right" || edge === "bottom")
        bottom: true
        top: (edge !== "bottom")
    }

    margins {
        top: (edge !== "bottom") ? (ShellState.focusMode ? theme.borderWidth : theme.notchHeight) - root.overlap : 0
        Behavior on top { NumberAnimation { duration: Theme.animDuration; easing.type: Easing.InOutCubic }}
        
        // A side strip ends exactly where the bottom strip (and its fillet) begins.
        bottom: (edge !== "bottom") ? thickness + radius : 0
    }

    Item {
        anchors.fill: parent

        Canvas {
            id: shape
            anchors.fill: parent

            // Multisample so the rounded frame corners are crisp, not pixelly.
            layer.enabled: true
            layer.samples:  8
            layer.smooth:   true

            onWidthChanged:  requestPaint()
            onHeightChanged: requestPaint()

            Connections {
                target: root
                function onFillColorChanged() { shape.requestPaint() }
                function onRimColorChanged()  { shape.requestPaint() }
            }

            onPaint: {
                var ctx = getContext("2d");
                ctx.reset();

                var w = width;
                var h = height;
                var t = root.thickness;
                var r = root.radius;
                var o = root.overlap;          // the side strips' first row is the bar's last
                var i = 0.5;                   // the rim lies wholly inside the fill

                // ── Fill ──
                ctx.fillStyle = root.fillColor;
                ctx.beginPath();
                if (root.edge === "left") {
                    // The flare out of the notch's bottom (tangent to it at
                    // x = t + r), then straight down the strip.
                    ctx.moveTo(0, 0);
                    ctx.lineTo(t + r, 0);
                    ctx.lineTo(t + r, o);
                    ctx.arcTo(t, o, t, o + r, r);
                    ctx.lineTo(t, h);
                    ctx.lineTo(0, h);
                    ctx.closePath();
                } else if (root.edge === "right") {
                    ctx.moveTo(w, 0);
                    ctx.lineTo(w - (t + r), 0);
                    ctx.lineTo(w - (t + r), o);
                    ctx.arcTo(w - t, o, w - t, o + r, r);
                    ctx.lineTo(w - t, h);
                    ctx.lineTo(w, h);
                    ctx.closePath();
                } else if (root.edge === "bottom") {
                    // Square outside, a fillet at each inner corner that ends
                    // vertical at this surface's top, where the side strip
                    // carries straight on (h = t + r).
                    ctx.moveTo(0, 0);
                    ctx.lineTo(0, h);
                    ctx.lineTo(w, h);
                    ctx.lineTo(w, 0);
                    ctx.lineTo(w - t, 0);
                    ctx.arcTo(w - t, h - t, w - t - r, h - t, r);
                    ctx.lineTo(t + r, h - t);
                    ctx.arcTo(t, h - t, t, 0, r);
                    ctx.closePath();
                }
                ctx.fill();

                // ── Rim ──
                // The same 1 px hairline as the bar's edge, inset half a pixel:
                // round each fillet at r + ½ from the same centre, so it meets
                // the bar's line at the flare's tangent and the next strip's
                // line where this surface ends.
                ctx.strokeStyle = root.rimColor;
                ctx.lineWidth = 1;
                ctx.beginPath();
                if (root.edge === "left") {
                    ctx.arc(t + r, o + r, r + i, -Math.PI / 2, Math.PI, true);
                    ctx.lineTo(t - i, h);
                } else if (root.edge === "right") {
                    ctx.arc(w - t - r, o + r, r + i, -Math.PI / 2, 0, false);
                    ctx.lineTo(w - t + i, h);
                } else if (root.edge === "bottom") {
                    ctx.moveTo(t - i, 0);
                    ctx.arc(t + r, 0, r + i, Math.PI, Math.PI / 2, true);
                    ctx.lineTo(w - t - r, h - t + i);
                    ctx.arc(w - t - r, 0, r + i, Math.PI / 2, 0, true);
                }
                ctx.stroke();
            }
        }

        // ── Left border — hover opens ArchMenu ────────────────────────────────
        Item {
            visible: root.edge === "left"
            anchors{
                verticalCenter: parent.verticalCenter
                left: parent.left
                right: parent.right
            }
            height: 300
            HoverHandler {
                enabled: root.edge === "left"
                onHoveredChanged: Popups.archMenuTriggerHovered = hovered
            }
        }

        // ── Right border — hover opens the quick controls (QuickControl) ──────
        Item {
            visible: root.edge === "right"
            anchors{
                verticalCenter: parent.verticalCenter
                left: parent.left
                right: parent.right
            }
            height: 300
            HoverHandler {
                enabled: root.edge === "right"
                onHoveredChanged: Popups.quickTriggerHovered = hovered
            }
        }

        // ── Bottom border — centered 420px zone: wallpaper hover + tap ────────
        Item {
            visible:                  root.edge === "bottom"
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top:              parent.top
            anchors.bottom:           parent.bottom
            width:                    420

            HoverHandler {
                onHoveredChanged: Popups.wallpaperTriggerHovered = hovered
            }

            TapHandler {
                onTapped: {
                    var next = !Popups.wallpaperOpen
                    Popups.closeAll()
                    Popups.wallpaperOpen = next
                }
            }
        }

        // ── Bottom border — right corner 80px zone: clipboard tap ─────────────
        Item {
            visible:        root.edge === "bottom"
            anchors.right:  parent.right
            anchors.top:    parent.top
            anchors.bottom: parent.bottom
            width:          80

            TapHandler {
                onTapped: {
                    var next = !Popups.clipboardOpen
                    Popups.closeAll()
                    Popups.clipboardOpen = next
                }
            }
        }
    }
}
