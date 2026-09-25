import QtQuick
import Quickshell
import "../"

// ============================================================
// BarTooltip — hover label for an item in the bar.
//
// Drawn in its own popup surface below the bar, not as a Controls
// ToolTip. A ToolTip is a Popup inside the bar window, which is only
// as tall as the bar, so Qt pushed the label back down over the item
// it described. A Popup takes every press inside its bounds, so once
// the label appeared, clicks on that item hit the label and the item
// never got its right-click. This surface has an empty input mask and
// sits outside the bar, so it cannot take a click from anything.
//
//     BarTooltip { target: someMouseArea; text: "…"; shown: someMouseArea.containsMouse }
// ============================================================

PopupWindow {
    id: tip

    required property Item target
    property string text: ""
    property bool shown: false
    property int delay: 500

    property bool _armed: false

    anchor.item: target
    anchor.edges: Edges.Bottom
    anchor.gravity: Edges.Bottom
    anchor.margins.top: 6

    color: "transparent"
    mask: Region {}   // no input region → never blocks clicks

    implicitWidth: label.implicitWidth + 16
    implicitHeight: label.implicitHeight + 10
    visible: _armed && shown && text !== ""

    onShownChanged: {
        if (shown) armTimer.restart()
        else { armTimer.stop(); _armed = false }
    }

    Timer {
        id: armTimer
        interval: tip.delay
        onTriggered: tip._armed = true
    }

    Rectangle {
        anchors.fill: parent
        radius: 6
        color: Theme.background
        border.color: Theme.border
        border.width: 1

        Text {
            id: label
            anchors.centerIn: parent
            text: tip.text
            color: Theme.text
            font.pixelSize: Theme.fs(12)
        }
    }
}
