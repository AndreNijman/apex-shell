import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../shapes"
import "../shapes/fluid"
import "../components"
import "../shapes/fluid/geometry.js" as Geo
import "../"

PanelWindow {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForScreen(root.screen) }   // P1-040: this output's sizes


    readonly property int popupWidth:  420
    readonly property int popupHeight: 560
    readonly property int fw: theme.cornerRadius
    readonly property int fh: theme.cornerRadius

    anchors.right:  true
    anchors.bottom: true

    // The finished sheet, its fillets into both strips, and a few pixels for
    // the swell a liquid open passes through before it settles.
    implicitWidth:  popupWidth  + fw + theme.borderWidth + 6
    implicitHeight: popupHeight + fh + theme.borderWidth + 6

    exclusionMode: ExclusionMode.Ignore
    color:         "transparent"

    WlrLayershell.layer:         WlrLayer.Overlay
    // The keyboard while it is open (UI/UX Phase 21): it was OnDemand, which a
    // compositor may grant only on a click — measured, typed keys reached
    // nothing — and it had no Escape of its own.
    WlrLayershell.keyboardFocus: Popups.clipboardOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    mask: Region { item: maskProxy }
    Item {
        id: maskProxy
        x:      body.result.bounds.x
        y:      body.result.bounds.y
        width:  body.result.bounds.w
        height: body.result.bounds.h
    }

    // On the shared lifecycle (UI/UX roadmap v3 Phase 21): the sheet grows out
    // of its corner on the progress, its content arrives on its own channel,
    // and the window is mapped until the close has finished — not for a guessed
    // `animDuration + 20`. It ran on the legacy duration, which is 0 under
    // Reduce Motion, so there it popped in and out with no fade at all
    // (measured); now the shape holds while alpha fades, as every surface does.
    // Liquid since 2026-09-26 (CORNER_RISE): it rises up the right strip, then
    // pours left along the bottom one, and waits for its first frame — it used
    // to be a rectangle scaled out of the corner on a Canvas.
    SurfaceLifecycle {
        name: "clipboard"
        id: life
        open:          Popups.clipboardOpen
        enterDuration: Motion.morphEnter
        exitDuration:  Motion.morphExit
        liquid:        true
        surface:       body
    }
    readonly property bool windowVisible: life.mapped
    visible: life.mapped

    // LazyPopup calls this right after building the window; the lifecycle is
    // born open and opens itself, so there is nothing left to apply.
    function applyOpenState() {}
    
    readonly property var riseGeometry: ({
        x1:    root.width  - theme.borderWidth,
        y1:    root.height - theme.borderWidth,
        edgeW: theme.borderWidth,
        edgeH: theme.borderWidth,
        w:     root.popupWidth,
        h:     root.popupHeight,
        r:     theme.cornerRadius,
        rm:    theme.radiusM
    })

    // ── Body ──────────────────────────────────────────────────────────────────
    // The ridge it starts from fades in over the first 24 px of height, both
    // ways, as the spills' does over their width.
    FluidShape {
        id: body
        anchors.fill: parent
        family:   "cornerRise"
        progress: life.progress
        channels: ({ d: life.lead, w: life.body, n: life.trail, fd: life.leadFlow, fw: life.bodyFlow })
        readonly property var chGeometry: Object.assign({}, geometry, { ch: channels })
        geometry: root.riseGeometry
        color:    Theme.background
        opacity:  life.alpha * Math.min(1, Math.max(0,
                      (Geo.cornerRiseHeight(life.progress, body.chGeometry) - Geo.riseRidge(root.riseGeometry)) / 24))
    }

    // ── Content, at its finished layout, revealed by the body's clip ────────
    Item {
        id: reveal
        x: body.result.clip.x; y: body.result.clip.y
        width: body.result.clip.w; height: body.result.clip.h
        clip: true

        Item {
            id: content
            // Escape from anywhere inside (keys travel up from the focused item),
            // and before any Tab: it holds focus itself when the popup opens.
            focus: true
            Keys.onEscapePressed: Popups.clipboardOpen = false
            // Window coordinates, whatever the clip is doing.
            x: root.riseGeometry.x1 - root.popupWidth + 10 - reveal.x
            y: root.riseGeometry.y1 - root.popupHeight + 8 - reveal.y
            width:  root.popupWidth - 10
            height: root.popupHeight - 16

            opacity: life.content
            transform: Translate { y: (1 - life.content) * Motion.travel(theme.px(10)) }

            HistoryTab { anchors.fill: parent }
        }
    }
}
