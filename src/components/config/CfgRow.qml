import QtQuick
import "../../"

// A settings row: label (+ optional description) on the left, a control on the
// right. Put the control as a child — it is placed in the right-hand slot.
Item {
    id: root
    property string label:       ""
    property string description: ""
    property bool   hoverable:   true
    // Why the running compositor cannot do this. Non-empty means the control is
    // switched off and the reason is shown in place of the description — the
    // honest alternative to a switch that moves and changes nothing, which is
    // what UI-003 was reported about. The reason is a sentence for a user, not
    // an option name: see apex-input-apply's CAPABILITIES table, which is where
    // these strings come from rather than being written here.
    property string disabledReason: ""
    readonly property bool unavailable: disabledReason !== ""
    // Shown on the right where a control would be, when the row has none.
    property string status: ""
    default property alias control: slot.data

    width:          parent ? parent.width : 0
    implicitHeight: (description !== "" || root.unavailable) ? 56 : 44
    height:         implicitHeight

    Rectangle {
        anchors.fill: parent
        radius:       8
        color:        (root.hoverable && hov.hovered) ? Qt.rgba(1,1,1,0.03) : "transparent"
        Behavior on color { ColorAnimation { duration: 120 } }
    }
    HoverHandler { id: hov; enabled: root.hoverable }

    Column {
        anchors.left:           parent.left
        anchors.leftMargin:     10
        anchors.right:          slot.left
        anchors.rightMargin:    12
        anchors.verticalCenter: parent.verticalCenter
        spacing: 3

        Text {
            width:          parent.width
            text:           root.label
            font.pixelSize: Theme.fs(12)
            color:          root.unavailable ? Qt.rgba(1,1,1,0.42) : Qt.rgba(1,1,1,0.75)
            elide:          Text.ElideRight
        }
        Text {
            width:          parent.width
            visible:        text !== ""
            text:           root.unavailable ? root.disabledReason : root.description
            font.pixelSize: Theme.fs(10)
            color:          Qt.rgba(1,1,1,0.38)
            wrapMode:       Text.WordWrap
            maximumLineCount: 2
            elide:          Text.ElideRight
        }
    }

    Item {
        id: slot
        // `enabled` propagates to children, so one property switches off every
        // MouseArea and HoverHandler inside whatever control the caller put
        // here. A dimmed control that still responds is worse than none.
        enabled:                !root.unavailable
        opacity:                root.unavailable ? 0.32 : 1.0
        anchors.right:          parent.right
        anchors.rightMargin:    8
        anchors.verticalCenter: parent.verticalCenter
        width:  childrenRect.width
        height: childrenRect.height
        Behavior on opacity { NumberAnimation { duration: 120 } }
    }

    // The right-hand slot for a row that reports rather than sets: the value
    // the compositor says is in effect, or "unavailable" when it has none.
    Text {
        visible:                root.status !== "" && slot.children.length === 0
        text:                   root.status
        anchors.right:          parent.right
        anchors.rightMargin:    8
        anchors.verticalCenter: parent.verticalCenter
        font.pixelSize:         Theme.fs(11)
        font.family:            "JetBrains Mono"
        color:                  Qt.rgba(1,1,1,0.45)
    }
}
