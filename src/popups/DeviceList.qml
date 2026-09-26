import QtQuick
import "../"

// DeviceList — one section of the audio pane's devices (outputs or inputs), a
// row per PipeWire node with the default marked. One Tab stop (UI/UX roadmap
// v3 Phase 21, the network panes' template): Up/Down move a highlight kept by
// the node's name, Return or Space make it the default, and focus lands on the
// current default. Its own file so the keyboard suite can drive it.
Column {
    id: list
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }
    function nameOf(node) {
        if (!node) return "Unknown"
        return node.nickname || node.description || node.name || "Unknown"
    }
    property string listName: ""
    property var    nodes:    []
    property string current:  ""
    signal chosen(var node)

    property string _cur: ""
    function _names() { return list.nodes.map(function (n) { return n.name }) }
    function _step(d) {
        const names = list._names()
        if (names.length === 0) return
        const i = names.indexOf(list._cur)
        list._cur = i < 0 ? names[0] : names[Math.max(0, Math.min(names.length - 1, i + d))]
    }

    activeFocusOnTab: list.nodes.length > 0
    Accessible.role: Accessible.List
    Accessible.name: list.listName
    onActiveFocusChanged: if (activeFocus && list._names().indexOf(list._cur) < 0)
        list._cur = list._names().indexOf(list.current) >= 0 ? list.current : (list._names()[0] || "")
    Keys.onPressed: function (event) {
        if      (event.key === Qt.Key_Down) list._step(1)
        else if (event.key === Qt.Key_Up)   list._step(-1)
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            const i = list._names().indexOf(list._cur)
            if (i >= 0) list.chosen(list.nodes[i])
        } else return
        event.accepted = true
    }

    Repeater {
        model: list.nodes
        delegate: DeviceRow {
            required property var modelData
            width:     list.width
            label:     list.nameOf(modelData)
            isDefault: modelData.name === list.current
            keyed:     list.activeFocus && modelData.name === list._cur
            onClicked: list.chosen(modelData)
        }
    }

    component DeviceRow: Item {
        id: row
        implicitHeight: 28

        property string label:     ""
        property bool   isDefault: false
        property bool   keyed:     false
        signal clicked()

        Accessible.role: Accessible.ListItem
        Accessible.name: row.label
        Accessible.selected: row.isDefault

        Rectangle {
            anchors.fill: parent
            radius: theme.cornerRadius - 4
            color:  row.isDefault
                        ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.12)
                        : (rowHov.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.05) : "transparent")
            Behavior on color { MotionColor { role: "state" } }
        }

        Row {
            anchors { left: parent.left; leftMargin: 8; right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
            spacing: 6

            Rectangle {
                width: 6; height: 6; radius: 3
                anchors.verticalCenter: parent.verticalCenter
                color: row.isDefault ? Theme.active : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.2)
                Behavior on color { MotionColor { role: "state" } }
            }

            Text {
                text:           row.label
                color:          row.isDefault ? Theme.text : Theme.textSecondary
                font.pixelSize: theme.fs(11)
                elide:          Text.ElideRight
                width:          parent.width - 14 - parent.spacing
                anchors.verticalCenter: parent.verticalCenter
                Behavior on color { MotionColor { role: "state" } }
            }
        }

        // The keyboard highlight, inset: the page clips at the row's edges.
        Rectangle {
            anchors.fill: parent; anchors.margins: 1
            radius: theme.cornerRadius - 5
            color: "transparent"; border.width: 2; border.color: Theme.accentText
            visible: row.keyed
        }

        HoverHandler { id: rowHov; cursorShape: Qt.PointingHandCursor }
        MouseArea { anchors.fill: parent; onClicked: row.clicked() }
    }
}
