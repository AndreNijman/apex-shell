import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pipewire
import "../shapes/fluid"
import "../shapes/fluid/geometry.js" as Geo
import "../components"
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
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

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
        id: life
        open:          root._held
        enterDuration: Motion.surfaceEnterSmall
        exitDuration:  Motion.surfaceExitSmall
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
        // On the way out only: on the way in the first mapped frame is already
        // far wider than the ramp. And on a wrapper, not on the shape: read
        // from the shape's own opacity, its `result` was a binding loop (logged)
        // that left the opacity a frame stale — a translucent first frame. It
        // reads `closing`, not `open`, for the same reason (SurfaceLifecycle).
        opacity:  life.alpha * (!life.closing ? 1 : Math.min(1, Math.max(0,
                      (Geo.edgeSpillWidth(life.progress, body.geometry) - Geo.spillRidge(body.geometry)) / 24)))

        FluidShape {
            id: body
            anchors.fill: parent
            family:   "edgeSpillRight"
            progress: life.progress
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

    // ── Reusable ChannelColumn Component ──────────────────────────────────────
    component ChannelColumn: Item {
        id: col

        property string label:  ""
        property string icon:   ""
        property real   value:  0.0
        property bool   muted:  false
        property bool   active: false

        readonly property int trackHeight: 180
        readonly property int barW:        22
        readonly property int thumbD:      barW - 6

        signal volumeChanged(real value)
        signal muteToggled()

        implicitWidth:  inner.implicitWidth
        implicitHeight: inner.implicitHeight

        // No device to read: a dash, not a percentage of nothing (brief §F.7).
        readonly property string pctText: active ? Math.round(value * 100) + "%" : "—"

        Column {
            id: inner
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 12

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text:           col.pctText
                color:          col.muted ? Theme.textTertiary : Theme.text
                font.pixelSize: theme.fs(13)
                font.bold:      true
                Behavior on color { MotionColor { role: "state" } }
            }

            Item {
                anchors.horizontalCenter: parent.horizontalCenter
                width:  col.barW
                height: col.trackHeight

                Rectangle {
                    id: track
                    anchors.fill: parent
                    radius: width / 2
                    color:  Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.08)

                    // Fill bar
                    Rectangle {
                        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                        height: Math.max(radius * 2, parent.height * col.value)
                        radius: parent.radius
                        color:  col.muted ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.15) : Theme.active
                        Behavior on color  { MotionColor { role: "state" } }
                        Behavior on height { MotionMove { role: "valueFollow"; curve: Motion.fastSpatial } }
                    }

                    // Thumb
                    Rectangle {
                        id: thumb
                        anchors.horizontalCenter: parent.horizontalCenter
                        width:  col.thumbD
                        height: width
                        radius: width / 2
                        color:  col.muted ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.3) : Theme.fixedLight
                        y: {
                            var travel = track.height - height
                            return Math.max(0, Math.min(travel, (1.0 - col.value) * travel))
                        }
                        Behavior on color { MotionColor { role: "state" } }
                    }

                    // Drag to change value. No wheel handler: a value bar in this
                    // shell never reads the wheel, so scrolling stays scrolling.
                    MouseArea {
                        anchors.fill: parent
                        cursorShape:  Qt.SizeVerCursor
                        function calc(my) {
                            var travel = track.height - thumb.height
                            return Math.max(0.0, Math.min(1.0, 1.0 - (my - thumb.height / 2) / travel))
                        }
                        onPressed:         col.volumeChanged(calc(mouseY))
                        onPositionChanged: if (pressed) col.volumeChanged(calc(mouseY))
                    }
                }
            }

            // Icon & Mute Toggle
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width:  col.barW + 16
                height: 28
                radius: theme.cornerRadius
                color:  col.muted
                            ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.2)
                            : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.06)
                Behavior on color { MotionColor { role: "state" } }

                Text {
                    anchors.centerIn: parent
                    text:           col.icon
                    font.pixelSize: theme.fs(14)
                    color:          col.muted ? Theme.active : Theme.textSecondary
                    Behavior on color { MotionColor { role: "state" } }
                }

                Rectangle {
                    anchors.fill: parent; radius: parent.radius
                    color: muteHov.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.05) : "transparent"
                    Behavior on color { MotionColor {} }
                }
                HoverHandler { id: muteHov; cursorShape: Qt.PointingHandCursor }
                MouseArea { anchors.fill: parent; onClicked: col.muteToggled()}
            }

            // Label
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text:            col.label
                color:           Theme.textTertiary
                font.pixelSize:  theme.fs(10)
                font.capitalization: Font.AllUppercase
                font.letterSpacing: 1
                elide:           Text.ElideRight
                width:           col.barW + 50
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }
}