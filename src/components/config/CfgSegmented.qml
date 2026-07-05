import QtQuick
import "../../"

// Wrapping set of selectable pills. `options` accepts either an array of strings
// or an array of { value, label }. Bind `value`; handle `selected(value)`.
Flow {
    id: root
    property var options: []
    property var value:   ""
    signal selected(var value)
    spacing: 6

    Repeater {
        model: root.options
        delegate: Rectangle {
            id: pill
            required property var modelData
            readonly property var    _val: (modelData && modelData.value !== undefined) ? modelData.value : modelData
            readonly property string _lbl: (modelData && modelData.label !== undefined) ? modelData.label : modelData
            readonly property bool   active: root.value === _val

            height: 26
            width:  t.implicitWidth + 20
            radius: 7
            color: active
                ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.16)
                : (h.hovered ? Qt.rgba(1,1,1,0.08) : Qt.rgba(1,1,1,0.04))
            border.width: 1
            border.color: active
                ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.42)
                : Qt.rgba(1,1,1,0.10)
            Behavior on color        { ColorAnimation { duration: 110 } }
            Behavior on border.color { ColorAnimation { duration: 110 } }

            Text {
                id: t
                anchors.centerIn: parent
                text:           pill._lbl
                font.pixelSize: 11
                font.weight:    pill.active ? Font.Medium : Font.Normal
                color:          pill.active ? Theme.active : Qt.rgba(1,1,1,0.62)
            }
            HoverHandler { id: h; cursorShape: Qt.PointingHandCursor }
            MouseArea { anchors.fill: parent; onClicked: root.selected(pill._val) }
        }
    }
}
