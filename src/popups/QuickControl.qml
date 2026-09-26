import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pipewire
import "../shapes/fluid"
import "../shapes/fluid/geometry.js" as Geo
import "../components"
import "../components/controls"
import "../services"
import "../"

// ─────────────────────────────────────────────────────────────────────────────
// QuickControl — volume and brightness, out of the right screen strip
// (UI/UX roadmap v3 Phase 9b, EDGE_SPILL).
//
// It opens on hovering the middle of the right strip and closes a moment after
// the pointer has left both the strip and the panel. The body is geometry.js
// edgeSpillRight: extruded out of the strip on standardDecel, its top settling
// early and its bottom late — it arrives from the edge and drips down, which
// is what keeps it from being LEFT_SPILL mirrored.
//
// ── It was unreachable ───────────────────────────────────────────────────────
// Since the lazy-popup change (cea90b5, #2) this window was built only by
// `Popups.quickOpen`, which nothing sets: the strip's hover wrote
// `quickTriggerHovered`, read only inside the window that was never built. It
// is now built by the hover itself, and its lifecycle opens from
// construction, so the hover that builds it also shows it.
//
// A PanelWindow with the right strip's own extent (bar bottom to one corner
// radius above the screen bottom), so the spill centres on the strip's hover
// zone by construction instead of through a popup anchor rectangle.
// ─────────────────────────────────────────────────────────────────────────────
PanelWindow {
    id: root

    // The bar of this screen; it is only asked which screen that is.
    required property var anchorWindow
    screen: root.anchorWindow.screen
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForScreen(root.screen) }   // P1-040: this output's sizes

    // ── Config ────────────────────────────────────────────────────────────────
    readonly property int popupWidth:  theme.px(180)
    readonly property int popupHeight: theme.px(300)

    anchors.top:    true
    anchors.bottom: true
    anchors.right:  true
    margins.top:    theme.notchHeight
    margins.bottom: theme.cornerRadius
    implicitWidth:  root.popupWidth + theme.radiusL + theme.borderWidth

    exclusionMode: ExclusionMode.Ignore
    color:         "transparent"
    WlrLayershell.layer:         WlrLayer.Overlay
    // The keyboard only when its keybind opened it (Popups.quickOpen): opened
    // by the pointer resting on the edge it must never take the keys from the
    // window being typed into (UI/UX Phase 21).
    WlrLayershell.keyboardFocus: Popups.quickOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    // ── Open state: the flag, or the pointer on the strip or on the panel ────
    property bool _selfHovered: false
    readonly property bool _wanted: Popups.quickOpen || Popups.quickTriggerHovered || root._selfHovered
    property bool _held: root._wanted
    on_WantedChanged: {
        if (root._wanted) { closeDelay.stop(); root._held = true }
        else closeDelay.restart()
    }
    // Closing by the flag (the toggle, closeAll) is immediate. Only the
    // pointer leaving gets the grace below — which is Popups.hoverCloseDelay,
    // animDuration + 200, and made every keyboard close wait for it.
    Connections {
        target: Popups
        function onQuickOpenChanged() {
            // Opened by its keybind, the arrows adjust the volume at once.
            if (Popups.quickOpen) Qt.callLater(function () { volCol.focusSlider() })
            if (!Popups.quickOpen && !Popups.quickTriggerHovered && !root._selfHovered) {
                closeDelay.stop()
                root._held = false
            }
        }
    }
    // A moment's grace, so the pointer can cross from the strip to the panel.
    Timer {
        id: closeDelay
        interval: Popups.hoverCloseDelay
        onTriggered: if (!root._wanted) { root._held = false; Popups.quickOpen = false }
    }

    SurfaceLifecycle {
        name: "quick"
        id: life
        open:          root._held
        enterDuration: Motion.surfaceEnterSmall
        exitDuration:  Motion.surfaceExitSmall
        // Liquid: the width extrudes first, the height unfolds after it and
        // swells a hair past its mark, the fillets trail; it waits for this
        // window's first frame, so it grows out of the strip.
        liquid:  true
        surface: body
    }
    visible: life.mapped

    // ── Audio State ───────────────────────────────────────────────────────────
    readonly property var sink: Pipewire.defaultAudioSink
    PwObjectTracker {
        objects: root.sink ? [root.sink] : []
    }

    // ── Brightness State ──────────────────────────────────────────────────────
    // Backed by BrightnessService: one shared, inotify-driven source instead of
    // this popup's own `brightnessctl -m` once a second for the whole session.
    readonly property real _bVal: BrightnessService.value

    function setBrightness(v) {
        BrightnessService.set(v)
    }

    // Make sure the slider is accurate the instant the panel appears, in case
    // the level moved while it was closed.
    onVisibleChanged: if (visible)
        BrightnessService.refresh()

    // ── Body ──────────────────────────────────────────────────────────────────
    Item {
        id: bodyFade
        anchors.fill: parent
        // The ridge a spill starts from (16 px wide, geometry.js) is already a
        // shape: it fades in over the next 24 px of width, so it neither appears
        // nor vanishes on one frame — keyed to WIDTH, because the extrusion is
        // so steep that by 8 % progress the body is already ~140 px wide, and a
        // fade over progress left a translucent box at the end of every close.
        // Both ways since the springs wait for the first frame: that frame IS
        // the ridge (it used to be far wider than the ramp). And on a wrapper, not on the shape: read
        // from the shape's own opacity, its `result` was a binding loop (logged)
        // that left the opacity a frame stale — a translucent first frame. It
        // reads `closing`, not `open`, for the same reason (SurfaceLifecycle).
        opacity:  life.alpha * Math.min(1, Math.max(0,
                      (Geo.edgeSpillWidth(life.progress, body.chGeometry) - Geo.spillRidge(body.geometry)) / 24))

        FluidShape {
            id: body
            anchors.fill: parent
            family:   "edgeSpillRight"
            progress: life.progress
            channels: ({ w: life.lead, d: life.body, n: life.trail, fw: life.leadFlow, fd: life.bodyFlow })
            readonly property var chGeometry: Object.assign({}, geometry, { ch: channels })
            color:    Theme.background
            geometry: ({
                x1:    root.width - theme.borderWidth,
                edgeW: theme.borderWidth,
                cy:    Math.round(root.height / 2),
                w:     root.popupWidth,
                h:     root.popupHeight,
                r:     theme.radiusL,
                rm:    theme.radiusM
            })
        }
    }

    mask: Region { item: hit }
    Item {
        id: hit
        x: life.open ? body.result.bounds.x : 0
        y: life.open ? body.result.bounds.y : 0
        width:  life.open ? body.result.bounds.w : 0
        height: life.open ? body.result.bounds.h : 0
        HoverHandler { onHoveredChanged: root._selfHovered = hovered }
    }

    // ── Content, at its finished layout, revealed by the body's clip ─────────
    Item {
        id: reveal
        x: body.result.clip.x; y: body.result.clip.y
        width: body.result.clip.w; height: body.result.clip.h
        clip: true
        // An ancestor of every slider, so Escape reaches it from whichever has focus.
        Keys.onEscapePressed: Popups.quickOpen = false

        Item {
            id: sizer
            // Window coordinates: the finished body.
            x: root.width - theme.borderWidth - root.popupWidth - reveal.x
            y: Math.round(root.height / 2 - root.popupHeight / 2) - reveal.y
            width:  root.popupWidth
            height: root.popupHeight

            opacity: life.content
            transform: Translate { x: (1 - life.content) * Motion.travel(theme.px(8)) }

            // ── Sliders Layout ────────────────────────────────────────────────
            Row {
                anchors {
                    fill:         parent
                    topMargin:    theme.px(24)
                    leftMargin:   8
                    rightMargin:  8
                }
                spacing: 8 
                anchors.horizontalCenter: parent.horizontalCenter

                // Audio Slider
                ChannelColumn {
                    id: volCol
                    label: ""
                    accessibleName: "Volume"
                    icon: {
                        if (!root.sink?.ready)            return "󰕾"
                        if (root.sink.audio.muted)        return "󰖁"
                        if (root.sink.audio.volume > 0.6) return "󰕾"
                        if (root.sink.audio.volume > 0.2) return "󰖀"
                        return "󰕿"
                    }
                    value:  root.sink?.ready ? root.sink.audio.volume : 0
                    muted:  root.sink?.audio.muted ?? false
                    active: root.sink?.ready ?? false
                    
                    onVolumeChanged: function(v) {
                        if (root.sink?.ready) root.sink.audio.volume = v
                    }
                    onMuteToggled: {
                        if (root.sink?.ready) root.sink.audio.muted = !root.sink.audio.muted
                    }
                }

                // Brightness Slider — the internal panel. Hidden on a desktop
                // with no backlight, where the DDC columns below are the only
                // brightness controls that exist.
                ChannelColumn {
                    accessibleName: "Brightness"
                    muteable: false
                    icon:    "󰃠"
                    value:   root._bVal
                    muted:   false
                    active:  true
                    visible: BrightnessService.max > 0

                    onVolumeChanged: function(v) {
                        root.setBrightness(v)
                    }
                }

                // One column per DDC/CI external display. The list is empty
                // until `ddcutil detect` has run, which happens on this popup
                // becoming visible (see refresh() above) rather than at startup
                // — the probe walks every I2C bus and takes seconds.
                Repeater {
                    model: BrightnessService.ddcMonitors

                    ChannelColumn {
                        required property var modelData

                        icon:   "󰍹"
                        accessibleName: "External display brightness"
                        muteable: false
                        value:  modelData.value >= 0 ? modelData.value : 0
                        muted:  false
                        // A monitor whose level has not been read yet cannot be
                        // driven sensibly; grey it until the first read lands.
                        active: modelData.value >= 0

                        onVolumeChanged: function(v) {
                            BrightnessService.setDdc(modelData.bus, v)
                        }
                    }
                }
            }
        }
    }

}
