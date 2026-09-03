import QtQuick
import "../../"

// A single palette chip with an optional caption underneath.
Column {
    id: root
    // Not a design colour — an unset-property sentinel. Every caller passes a
    // real colour; a visible black chip means someone forgot to. Do not "fix"
    // this to a token: a token would make the mistake invisible.
    property color swatchColor: "#000000"
    property string label: ""
    property int   size:   34
    spacing: 5

    Rectangle {
        width:  root.size
        height: root.size
        radius: 9
        color:  root.swatchColor
        border.width: 1
        border.color: Qt.rgba(1,1,1,0.15)
    }
    Text {
        visible: root.label !== ""
        width:   root.size
        horizontalAlignment: Text.AlignHCenter
        text:           root.label
        font.pixelSize: Theme.fs(8)
        color:          Qt.rgba(1,1,1,0.4)
        elide:          Text.ElideRight
    }
}
