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

    // A switch carries no words of its own — they are in the CfgRow beside it,
    // which supplies the name. What the switch must say for itself is that it
    // is a checkbox and which way it is set: checkable without checked would
    // announce every toggle in the shell as "off".
    activeFocusOnTab:     true
    Accessible.role:      Accessible.CheckBox
    Accessible.checkable: true
    Accessible.checked:   root.checked
    Accessible.onToggleAction: root.toggle()
    Accessible.onPressAction:  root.toggle()

    function toggle() { root.toggled(!root.checked) }

    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Space || event.key === Qt.Key_Return
            || event.key === Qt.Key_Enter) {
            root.toggle()
            event.accepted = true
        }
    }

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
        color:  root.checked ? Theme.background : Theme.fixedLight
        Behavior on x     { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation  { duration: 150 } }
    }
    Rectangle {
        anchors.fill: parent
        anchors.margins: -3
        radius: height / 2
        color: "transparent"
        border.width: 2
        border.color: Theme.active
        visible: root.activeFocus
    }
    HoverHandler { id: hov; cursorShape: Qt.PointingHandCursor }
    MouseArea {
        anchors.fill: parent
        cursorShape:  Qt.PointingHandCursor
        onClicked:    { root.forceActiveFocus(); root.toggle() }
    }
}
