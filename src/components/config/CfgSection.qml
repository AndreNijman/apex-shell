import QtQuick
import "../../"

// A titled group of rows. Matches the Keybinds tab's group headers — bare rows,
// no card, so every Config tab reads as one consistent surface.
Column {
    id: root
    property string title: ""
    property bool   first: false
    default property alias content: inner.data

    width:   parent ? parent.width : 0
    spacing: 2

    Item {
        width:  parent.width
        height: root.first ? 14 : 28
        Text {
            anchors.bottom:       parent.bottom
            anchors.bottomMargin: 4
            text:           root.title
            font.pixelSize: 9
            font.weight:    Font.Bold
            color:          Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.55)
        }
    }

    Column {
        id: inner
        width:   parent.width
        spacing: 2
    }
}
