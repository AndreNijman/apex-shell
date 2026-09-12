import QtQuick
import "../"

Rectangle {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes

    width: 24
    height: 24
    radius: 4
    
    // 1. Correct: referencing the ID 'hover' directly works here
    color: hover.hovered ? Theme.active : "transparent"
    
    property string text: "" 
    property color textColor: Theme.text
    signal clicked()

    Text {
        anchors.centerIn: parent
        text: root.text
        
        // 2. FIX: Changed 'root.hoverHandler.hovered' to 'hover.hovered'
        color: hover.hovered ? Theme.background : root.textColor
        
        font.pixelSize: theme.fs(14)
    }

    HoverHandler {
        id: hover
        cursorShape: Qt.PointingHandCursor
    }
    
    MouseArea {
        anchors.fill: parent
        onClicked: root.clicked()
    }
}
