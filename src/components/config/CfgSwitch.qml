import QtQuick
import "../../"

// iOS-style toggle. Bind `checked`; handle `toggled(value)` to persist.
Item {
    id: root
    property bool checked: false
    signal toggled(bool value)

    implicitWidth:  42
    implicitHeight: 24
    width:  implicitWidth
    height: implicitHeight

    Rectangle {
        id: track
        anchors.fill: parent
        radius:       height / 2
        color:        root.checked ? Theme.active : Qt.rgba(1,1,1,0.13)
        opacity:      hov.hovered ? 1.0 : 0.92
        Behavior on color { ColorAnimation { duration: 150 } }
    }
    Rectangle {
        width:  parent.height - 6
        height: parent.height - 6
        radius: height / 2
        y:      3
        x:      root.checked ? parent.width - width - 3 : 3
        color:  root.checked ? Theme.background : "#ffffff"
        Behavior on x     { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation  { duration: 150 } }
    }
    HoverHandler { id: hov; cursorShape: Qt.PointingHandCursor }
    MouseArea {
        anchors.fill: parent
        cursorShape:  Qt.PointingHandCursor
        onClicked:    root.toggled(!root.checked)
    }
}
