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

            // Each pill is its own control: it has its own words, its own
            // selected state, and a keyboard user has to be able to reach and
            // choose each one. The group's meaning ("Scaling mode") comes from
            // the CfgRow around it; what a pill must say for itself is which
            // option it is and whether it is the chosen one.
            objectName: "cfgSegmentedPill"
            activeFocusOnTab:     true
            Accessible.role:      Accessible.RadioButton
            Accessible.checkable: true
            Accessible.checked:   pill.active
            Accessible.name:      String(pill._lbl)
            Accessible.onPressAction: root.selected(pill._val)

            Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Space || event.key === Qt.Key_Return
                    || event.key === Qt.Key_Enter) {
                    root.selected(pill._val)
                    event.accepted = true
                }
            }

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
                font.pixelSize: Theme.fs(11)
                font.weight:    pill.active ? Font.Medium : Font.Normal
                color:          pill.active ? Theme.active : Qt.rgba(1,1,1,0.62)
            }
            Rectangle {
                anchors.fill: parent
                anchors.margins: -2
                radius: 9
                color: "transparent"
                border.width: 2
                border.color: Theme.active
                visible: pill.activeFocus
            }
            HoverHandler { id: h; cursorShape: Qt.PointingHandCursor }
            MouseArea {
                anchors.fill: parent
                onClicked: { pill.forceActiveFocus(); root.selected(pill._val) }
            }
        }
    }
}
