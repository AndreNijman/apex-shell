import QtQuick
import "../../"

// Horizontal slider with a monospace readout on the right.
// Bind `value`; handle `moved(value)` live (fires on drag / wheel).
Item {
    id: root
    property real   value:  0
    property real   from:   0
    property real   to:     100
    property real   step:   1
    property string suffix: ""
    property int    readoutWidth: 48
    signal moved(real value)

    implicitWidth:  212
    implicitHeight: 24
    width:  implicitWidth
    height: implicitHeight

    readonly property real _frac: (to > from) ? Math.max(0, Math.min(1, (value - from) / (to - from))) : 0

    function _apply(frac) {
        var raw     = from + Math.max(0, Math.min(1, frac)) * (to - from)
        var snapped = Math.round(raw / step) * step
        snapped     = Math.max(from, Math.min(to, snapped))
        if (snapped !== root.value) root.moved(snapped)
    }

    Text {
        id: readout
        anchors.right:          parent.right
        anchors.verticalCenter: parent.verticalCenter
        width:               root.readoutWidth
        horizontalAlignment: Text.AlignRight
        text:           Math.round(root.value) + root.suffix
        font.pixelSize: Theme.fs(11)
        font.family:    "JetBrains Mono"
        color:          Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.9)
    }

    Item {
        id: bar
        anchors.left:           parent.left
        anchors.right:          readout.left
        anchors.rightMargin:    10
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        readonly property int thumbD: 14

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width:  parent.width
            height: 5
            radius: 2.5
            color:  Qt.rgba(1,1,1,0.12)
            Rectangle {
                anchors.left:   parent.left
                anchors.top:    parent.top
                anchors.bottom: parent.bottom
                width:  Math.max(parent.radius * 2, parent.width * root._frac)
                radius: parent.radius
                color:  Theme.active
                Behavior on width { NumberAnimation { duration: 60; easing.type: Easing.OutCubic } }
            }
        }
        Rectangle {
            width:  bar.thumbD
            height: bar.thumbD
            radius: bar.thumbD / 2
            color:  "#ffffff"
            anchors.verticalCenter: parent.verticalCenter
            x: Math.max(0, Math.min(bar.width - width, root._frac * (bar.width - width)))
            Behavior on x { NumberAnimation { duration: 60; easing.type: Easing.OutCubic } }
        }
        MouseArea {
            anchors.fill: parent
            cursorShape:  Qt.PointingHandCursor
            function _c(mx) { return (mx - bar.thumbD / 2) / (bar.width - bar.thumbD) }
            onPressed:         function(mouse) { root._apply(_c(mouse.x)) }
            onPositionChanged: function(mouse) { if (pressed) root._apply(_c(mouse.x)) }
        }
        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: function(e) {
                var d = root.step / Math.max(1, (root.to - root.from))
                root._apply(root._frac + (e.angleDelta.y > 0 ? d : -d))
            }
        }
    }
}
