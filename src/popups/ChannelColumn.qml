import QtQuick
import "../"
import "../components/controls"

// ChannelColumn — one vertical level control in the quick controls (volume,
// brightness, an external display's brightness): a percentage, a track with
// its fill and thumb, and a mute/icon button. Its own file so the keyboard
// suite can drive it (UI/UX roadmap v3 Phase 21; it was an inline component
// of QuickControl.qml).
Item {
    id: col
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }

    property string label:  ""
    property string icon:   ""
    property real   value:  0.0
    property bool   muted:  false
    property bool   active: false
    property string accessibleName: "Level"
    function focusSlider() { track.forceActiveFocus() }

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

                // A slider on the keyboard (UI/UX roadmap v3 Phase 21): a Tab
                // stop; Up/Right and Down/Left step 5 %, Page Up/Down 20 %,
                // Home and End the ends. It took no key at all.
                activeFocusOnTab: col.active
                Accessible.role: Accessible.Slider
                Accessible.name: col.accessibleName
                Accessible.description: col.pctText
                function _nudge(d) { col.volumeChanged(Math.max(0, Math.min(1, col.value + d))) }
                Keys.onPressed: function (event) {
                    if (!col.active) return
                    if      (event.key === Qt.Key_Up    || event.key === Qt.Key_Right)    track._nudge(0.05)
                    else if (event.key === Qt.Key_Down  || event.key === Qt.Key_Left)     track._nudge(-0.05)
                    else if (event.key === Qt.Key_PageUp)   track._nudge(0.2)
                    else if (event.key === Qt.Key_PageDown) track._nudge(-0.2)
                    else if (event.key === Qt.Key_Home)     col.volumeChanged(0)
                    else if (event.key === Qt.Key_End)      col.volumeChanged(1)
                    else return
                    event.accepted = true
                }
                Rectangle {
                    anchors.fill: parent; anchors.margins: -4
                    radius: width / 2
                    color: "transparent"; border.width: 2; border.color: Theme.accentText
                    visible: track.activeFocus
                }

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

        // Icon & Mute Toggle — a real button (it was pointer-only).
        ApexPressable {
            id: muteBtn
            anchors.horizontalCenter: parent.horizontalCenter
            width:  col.barW + 16
            height: 28
            radius: theme.cornerRadius
            hitMargin: 2
            Accessible.name: col.muted ? "Unmute" : "Mute"
            onActivated: col.muteToggled()
          Rectangle {
            anchors.fill: parent; radius: parent.radius
            color:  col.muted
                        ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.2)
                        : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.06)
            Behavior on color { MotionColor { role: "state" } }
          }

            Text {
                anchors.centerIn: parent
                text:           col.icon
                font.pixelSize: theme.fs(14)
                color:          col.muted ? Theme.active : Theme.textSecondary
                Behavior on color { MotionColor { role: "state" } }
            }

            Rectangle {
                anchors.fill: parent; radius: parent.radius
                color: muteBtn.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.05) : "transparent"
                Behavior on color { MotionColor {} }
            }
            ApexFocusRing { target: muteBtn }
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
