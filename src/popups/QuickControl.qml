import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import "../shapes"
import "../components"
import "../services"
import "../"

PopupWindow {
    id: root

    required property var anchorWindow

    // ── Config ────────────────────────────────────────────────────────────────
    readonly property int fw: Theme.cornerRadius
    readonly property int fh: Theme.cornerRadius
    readonly property int popupHeight: 340
    readonly property int popupWidth:  180 // Thinner than the 300px AudioPopup

    color:   "transparent"
    visible: slide.windowVisible
    mask:    Region { item: maskProxy }

    // ── Position: Right Center ────────────────────────────────────────────────
    anchor.window:  anchorWindow
    anchor.rect: Qt.rect(
        anchorWindow.width - root.fw,
        (root.screen.height + root.fh + 5)/2,
        0,
        0
    )
    anchor.gravity: Edges.Right
    
    Item {
        id:      maskProxy
        x:       root.popupWidth - sizer.width
        y:       ((root.popupHeight - sizer.height) / 2)
        width:   sizer.width
        height:  sizer.height
    }

    implicitWidth:  popupWidth
    implicitHeight: popupHeight

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

    // ── Layout ────────────────────────────────────────────────────────────────
    PopupSlide {
        id: slide
        anchors.fill:     parent
        edge:             "right"
        open:             Popups.quickOpen 
        hoverEnabled:     true
        triggerHovered:   Popups.quickTriggerHovered 
        onCloseRequested: Popups.quickOpen = false

        Item {
            id: sizer
            anchors.right:          parent.right
            anchors.verticalCenter: parent.verticalCenter
            clip: true

            width:  root.popupWidth
            height: root.popupHeight

            Behavior on width { NumberAnimation { duration: Theme.animDuration; easing.type: Easing.InOutCubic } }

            PopupShape {
                id: bg
                anchors.fill: parent
                attachedEdge: "right"
                color:        Theme.background
                radius:       Theme.cornerRadius
                flareWidth:   root.fw
                flareHeight:  root.fh
            }

            // ── Sliders Layout ────────────────────────────────────────────────
            Row {
                anchors {
                    fill:         parent
                    topMargin:    root.fh + 30
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

        readonly property string pctText: active ? Math.round(value * 100) + "%" : "--%"

        Column {
            id: inner
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 12

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text:           col.pctText
                color:          col.muted ? Qt.rgba(1,1,1,0.25) : Theme.text
                font.pixelSize: Theme.fs(13)
                font.bold:      true
                Behavior on color { ColorAnimation { duration: 150 } }
            }

            Item {
                anchors.horizontalCenter: parent.horizontalCenter
                width:  col.barW
                height: col.trackHeight

                Rectangle {
                    id: track
                    anchors.fill: parent
                    radius: width / 2
                    color:  Qt.rgba(1,1,1,0.08)

                    // Fill bar
                    Rectangle {
                        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                        height: Math.max(radius * 2, parent.height * col.value)
                        radius: parent.radius
                        color:  col.muted ? Qt.rgba(1,1,1,0.15) : Theme.active
                        Behavior on color  { ColorAnimation  { duration: 150 } }
                        Behavior on height { NumberAnimation { duration: 80; easing.type: Easing.OutCubic } }
                    }

                    // Thumb
                    Rectangle {
                        id: thumb
                        anchors.horizontalCenter: parent.horizontalCenter
                        width:  col.thumbD
                        height: width
                        radius: width / 2
                        color:  col.muted ? Qt.rgba(1,1,1,0.3) : Theme.fixedLight
                        y: {
                            var travel = track.height - height
                            return Math.max(0, Math.min(travel, (1.0 - col.value) * travel))
                        }
                        Behavior on color { ColorAnimation { duration: 150 } }
                    }

                    // Drag to change value
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

                    // Scroll wheel to change value
                    WheelHandler {
                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                        onWheel: function(event) {
                            var step = 0.05
                            var delta = event.angleDelta.y > 0 ? step : -step
                            col.volumeChanged(Math.max(0.0, Math.min(1.0, col.value + delta)))
                        }
                    }
                }
            }

            // Icon & Mute Toggle
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width:  col.barW + 16
                height: 28
                radius: Theme.cornerRadius
                color:  col.muted
                            ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.2)
                            : Qt.rgba(1,1,1,0.06)
                Behavior on color { ColorAnimation { duration: 150 } }

                Text {
                    anchors.centerIn: parent
                    text:           col.icon
                    font.pixelSize: Theme.fs(14)
                    color:          col.muted ? Theme.active : Qt.rgba(1,1,1,0.55)
                    Behavior on color { ColorAnimation { duration: 150 } }
                }

                Rectangle {
                    anchors.fill: parent; radius: parent.radius
                    color: muteHov.hovered ? Qt.rgba(1,1,1,0.05) : "transparent"
                    Behavior on color { ColorAnimation { duration: 100 } }
                }
                HoverHandler { id: muteHov; cursorShape: Qt.PointingHandCursor }
                MouseArea { anchors.fill: parent; onClicked: col.muteToggled()}
            }

            // Label
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text:            col.label
                color:           Qt.rgba(1,1,1,0.3)
                font.pixelSize:  Theme.fs(10)
                font.capitalization: Font.AllUppercase
                font.letterSpacing: 1
                elide:           Text.ElideRight
                width:           col.barW + 50
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }
}