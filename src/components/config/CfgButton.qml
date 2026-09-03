import QtQuick
import "../../"

// Action button. variant: "default" | "accent" | "danger".
Item {
    id: root
    property string label:   ""
    property string icon:    ""
    property string variant: "default"
    property bool   enabled: true
    signal clicked()

    implicitWidth:  rowc.implicitWidth + 24
    implicitHeight: 28
    width:  implicitWidth
    height: implicitHeight
    opacity: enabled ? 1 : 0.4
    Behavior on opacity { NumberAnimation { duration: 120 } }

    readonly property color _accent: variant === "danger" ? Theme.danger : Theme.active

    Rectangle {
        anchors.fill: parent
        radius: 7
        color: {
            if (root.variant === "default")
                return hov.hovered ? Qt.rgba(1,1,1,0.09) : Qt.rgba(1,1,1,0.05)
            var a = root._accent
            return hov.hovered ? Qt.rgba(a.r, a.g, a.b, 0.28) : Qt.rgba(a.r, a.g, a.b, 0.15)
        }
        border.width: 1
        border.color: root.variant === "default"
            ? Qt.rgba(1,1,1,0.13)
            : Qt.rgba(root._accent.r, root._accent.g, root._accent.b, 0.42)
        Behavior on color { ColorAnimation { duration: 110 } }
    }
    Row {
        id: rowc
        anchors.centerIn: parent
        spacing: 5
        Text {
            visible: root.icon !== ""
            text:    root.icon
            font.pixelSize: Theme.fs(12)
            anchors.verticalCenter: parent.verticalCenter
            color: root.variant === "default" ? Qt.rgba(1,1,1,0.7) : root._accent
        }
        Text {
            text: root.label
            font.pixelSize: Theme.fs(11)
            font.weight:    Font.Medium
            anchors.verticalCenter: parent.verticalCenter
            color: root.variant === "default" ? Qt.rgba(1,1,1,0.7) : root._accent
        }
    }
    HoverHandler { id: hov; enabled: root.enabled; cursorShape: Qt.PointingHandCursor }
    MouseArea { anchors.fill: parent; enabled: root.enabled; onClicked: root.clicked() }
}
