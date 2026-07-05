import QtQuick
import "../../"

// A single palette chip with an optional caption underneath.
Column {
    id: root
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
        font.pixelSize: 8
        color:          Qt.rgba(1,1,1,0.4)
        elide:          Text.ElideRight
    }
}
