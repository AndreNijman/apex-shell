import QtQuick
import "../"
import "../components/controls"

// ChannelColumn — one vertical level control (volume, brightness, an external
// display's brightness): a percentage, a track with its fill and thumb, and a
// mute/icon button. Its own file so the keyboard suite can drive it (UI/UX
// roadmap v3 Phase 21; it was an inline component of QuickControl.qml, and a
// pointer-only copy of it lived in AudioControl.qml — the right panel's audio
// pane uses this one now, with its own sizes and a worded mute button).
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

    // The quick controls' sizes by default; the audio pane is shorter and
    // tighter, and words its mute button.
    property int  trackHeight: 180
    property int  gap:         12
    property bool muteText:    false
    readonly property int barW:   22
    readonly property int thumbD: barW - 6
    property int  labelWidth:  barW + 50
    // A level that cannot be muted (brightness) shows its icon as a label: no
    // Tab stop, no pointer target, nothing announced as a button that does
    // nothing — and at full strength, not dimmed as disabled.
    property bool muteable:    true

    signal volumeChanged(real value)
    signal muteToggled()

    implicitWidth:  inner.implicitWidth
    implicitHeight: inner.implicitHeight

    // No device to read: a dash, not a percentage of nothing (brief §F.7).
    readonly property string pctText: active ? Math.round(value * 100) + "%" : "—"

    Column {
        id: inner
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: col.gap

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
                    id: fill
                    anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                    height: fillH.value
                    SpringFollower { id: fillH; role: "valueFollow"
                                     target: Math.max(fill.radius * 2, fill.parent.height * col.value) }
                    radius: parent.radius
                    color:  col.muted ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.15) : Theme.active
                    Behavior on color  { MotionColor { role: "state" } }
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
                    // 22 px wide drawn, 32 px to grab (hitMin); the value is
                    // read off y alone, so the margins change nothing else.
                    anchors.fill: parent; anchors.leftMargin: -5; anchors.rightMargin: -5
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
            objectName: "channelMuteButton"
            anchors.horizontalCenter: parent.horizontalCenter
            width:  col.barW + (col.muteText ? 32 : 16)
            height: 28
            radius: theme.cornerRadius
            hitMargin: 2
            interactive: col.muteable
            opacity: 1
            Accessible.ignored: !col.muteable
            // A toggle: the name stays put and the state is its checked state.
            Accessible.name: "Mute " + col.accessibleName
            Accessible.checkable: true
            Accessible.checked: col.muted
            onActivated: col.muteToggled()
          Rectangle {
            anchors.fill: parent; radius: parent.radius
            color:  col.muted
                        ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.2)
                        : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.06)
            Behavior on color { MotionColor { role: "state" } }
          }

            Row {
                anchors.centerIn: parent
                spacing: 5
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text:           col.icon
                    font.pixelSize: theme.fs(col.muteText ? 13 : 14)
                    color:          col.muted ? Theme.active : Theme.textSecondary
                    Behavior on color { MotionColor { role: "state" } }
                }
                Text {
                    visible:        col.muteText
                    anchors.verticalCenter: parent.verticalCenter
                    text:           col.muted ? "Muted" : "Mute"
                    font.pixelSize: theme.fs(11)
                    color:          col.muted ? Theme.active : Theme.textSecondary
                    Behavior on color { MotionColor { role: "state" } }
                }
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
            width:           col.labelWidth
            horizontalAlignment: Text.AlignHCenter
        }
    }
}
