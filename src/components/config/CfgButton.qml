import QtQuick
import "../../"

// Action button. variant: "default" | "accent" | "danger".
Item {
    id: root
    readonly property ThemeSet theme: Theme.setForHeight(Screen.height)   // P1-040: this output's sizes

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

    // A button that only a mouse can press is not a button for everyone. Tab
    // reaches it, Space and Return press it, and a reader is told it is a
    // button and what it says. CfgButton names ITSELF because its words are its
    // own label — CfgRow only supplies a name to controls that have none.
    activeFocusOnTab: root.enabled
    Accessible.role:  Accessible.Button
    Accessible.name:  root.label
    Accessible.onPressAction: root.press()

    function press() { if (root.enabled) root.clicked() }

    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Space || event.key === Qt.Key_Return
            || event.key === Qt.Key_Enter) {
            root.press()
            event.accepted = true
        }
    }

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
            font.pixelSize: theme.fs(12)
            anchors.verticalCenter: parent.verticalCenter
            color: root.variant === "default" ? Qt.rgba(1,1,1,0.7) : root._accent
        }
        Text {
            text: root.label
            font.pixelSize: theme.fs(11)
            font.weight:    Font.Medium
            anchors.verticalCenter: parent.verticalCenter
            color: root.variant === "default" ? Qt.rgba(1,1,1,0.7) : root._accent
        }
    }
    // The hover tint is the only "you are here" signal this control had, and a
    // keyboard user never triggers it. Focus needs a mark of its own.
    Rectangle {
        anchors.fill: parent
        anchors.margins: -2
        radius: 9
        color: "transparent"
        border.width: 2
        border.color: Theme.active
        visible: root.activeFocus
    }
    HoverHandler { id: hov; enabled: root.enabled; cursorShape: Qt.PointingHandCursor }
    MouseArea {
        anchors.fill: parent
        enabled: root.enabled
        onClicked: { root.forceActiveFocus(); root.press() }
    }
}
