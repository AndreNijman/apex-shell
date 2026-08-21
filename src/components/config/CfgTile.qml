import QtQuick
import "../../"

// Compact toggle/action tile (mirrors the QuickSettings tiles). Use in a Grid.
Rectangle {
    id: root
    property bool   on:       false
    property string icon:     ""
    property string label:    ""
    property string sublabel: ""
    signal toggled()

    radius: 10
    color: on
        ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.14)
        : (bH.hovered ? Qt.rgba(1,1,1,0.08) : Qt.rgba(1,1,1,0.04))
    border.width: 1
    border.color: on
        ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.30)
        : Qt.rgba(1,1,1,0.10)
    Behavior on color        { ColorAnimation { duration: 130 } }
    Behavior on border.color { ColorAnimation { duration: 130 } }

    Rectangle {
        anchors { top: parent.top; right: parent.right; margins: 8 }
        width: 6; height: 6; radius: 3
        color: root.on ? Theme.active : Qt.rgba(1,1,1,0.18)
        Behavior on color { ColorAnimation { duration: 130 } }
    }
    Column {
        anchors { left: parent.left; bottom: parent.bottom; margins: 9 }
        spacing: 2
        Text {
            text: root.icon; font.pixelSize: Theme.fs(17)
            color: root.on ? Theme.active : Qt.rgba(1,1,1,0.40)
        }
        Text {
            text: root.label; font.pixelSize: Theme.fs(9); font.weight: Font.Medium
            color: root.on ? Theme.text : Qt.rgba(1,1,1,0.45)
        }
        Text {
            visible: root.sublabel !== ""
            text:    root.sublabel
            font.pixelSize: Theme.fs(8); font.family: "JetBrains Mono"
            color:   Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.65)
            width:   root.width - 18; elide: Text.ElideRight
        }
    }
    HoverHandler { id: bH; cursorShape: Qt.PointingHandCursor }
    MouseArea { anchors.fill: parent; onClicked: root.toggled() }
}
