import QtQuick
import Quickshell
import "../"

// Low battery warning — FloatingWindow, centered by the WM (Hyprland floats center).
// Auto-dismisses after `timeout` ms. Click anywhere to dismiss early.

FloatingWindow {
    id: root

    property int warnLevel: 30
    property int timeout:   8000

    minimumSize: Qt.size(320, 100)
    maximumSize: Qt.size(320, 100)

    color: "transparent"
    
    // Auto-dismiss timer
    Timer {
        id: autoClose
        interval: root.timeout
        running:  root.visible
        onTriggered: root.visible = false
    }

    onVisibleChanged: if (visible) autoClose.restart()

    // ── Severity helpers ─────────────────────────────────────────────────────
    // Two colours for three titles on purpose: the title carries the third step.
    // Matches BatteryStatus's icon, which reports the same fact in the bar.
    readonly property color accentColor: warnLevel <= 10 ? Theme.danger : Theme.warning
    readonly property string title:      warnLevel <= 5  ? "Critical Battery" :
                                         warnLevel <= 10 ? "Very Low Battery"  : "Low Battery"
    readonly property string message:    warnLevel <= 5
                                             ? "Battery at " + warnLevel + "% — plug in now!"
                                             : "Battery at " + warnLevel + "% — consider charging." // for testing visuals without changing actual battery level

    // ── Visuals ───────────────────────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        radius:       Theme.cornerRadius + 4
        color:        Theme.background

        // Left accent bar
        Rectangle {
            width:                  4
            height:                 parent.height - 20
            radius:                 2
            anchors.left:           parent.left
            anchors.leftMargin:     8
            anchors.verticalCenter: parent.verticalCenter
            color:                  root.accentColor
        }

        Column {
            anchors {
                left:           parent.left
                leftMargin:     22
                right:          parent.right
                rightMargin:    12
                verticalCenter: parent.verticalCenter
            }
            spacing: 5

            Text {
                text:           "⚠  " + root.title
                color:          root.accentColor
                font.pixelSize: Theme.fs(13)
                font.bold:      true
            }

            Text {
                text:           root.message
                color:          Theme.text
                font.pixelSize: Theme.fs(12)
                width:          parent.width
                wrapMode:       Text.WordWrap
            }
        }

        // Countdown progress bar
        Rectangle {
            anchors.bottom:      parent.bottom
            anchors.left:        parent.left
            anchors.right:       parent.right
            height:              3
            radius:              2
            color:               Qt.rgba(1, 1, 1, 0.08)

            Rectangle {
                id:       countdown
                height:   parent.height
                radius:   parent.radius
                color:    root.accentColor
                width:    parent.width

                NumberAnimation on width {
                    running:  root.visible
                    from:     countdown.parent.width
                    to:       0
                    duration: root.timeout
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape:  Qt.PointingHandCursor
            onClicked:    root.visible = false
        }
        Item {
            anchors.fill: parent
            Keys.onEscapePressed: root.visible = false
        }
    }
}
