import QtQuick
import QtQuick.Controls
import "../../"

// Scroll container matching the Keybinds page — flick + thin 3px scrollbar.
// Drop a stack of CfgSection children inside; they lay out top-to-bottom.
Item {
    id: root
    default property alias content: col.data
    property int contentSpacing: 2

    Flickable {
        id: flick
        anchors.fill:        parent
        anchors.leftMargin:  12
        anchors.rightMargin: 12
        anchors.topMargin:   6
        anchors.bottomMargin: 12
        contentWidth:  width
        contentHeight: col.implicitHeight + 16
        clip:          true
        boundsBehavior: Flickable.StopAtBounds

        ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
            contentItem: Rectangle { implicitWidth: 3; implicitHeight: 40; radius: 1.5; color: Qt.rgba(1,1,1,0.22) }
            background: Item {}
        }

        Column {
            id: col
            width:   flick.width - 12
            spacing: root.contentSpacing
        }
    }
}
