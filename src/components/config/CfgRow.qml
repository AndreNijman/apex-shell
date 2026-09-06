import QtQuick
import "../../"
import "settings-semantics.js" as Semantics

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
    // What is actually in effect, shown beside the control rather than in place
    // of it. A control that writes and never reads cannot tell a working
    // setting from one whose backend stopped listening, and a readout the user
    // has to open a terminal to see is not a read-back.
    property string status: ""
    // The readout disagrees with what this page asked for. Coloured rather than
    // worded, because the row already has a label and a description and a third
    // sentence would bury it.
    property bool   statusWarns: false

    // When this particular control reaches the machine, if it is not now. One
    // of settings-semantics.js's EFFECTS: "relogin", "reboot", "apply",
    // "reload". The default "now" renders nothing on purpose — a page that
    // stamps "takes effect immediately" on every row has taught the reader to
    // skip the one line that matters (roadmap P0-023, criterion 1).
    //
    // Distinct from `status`, which is what the machine reports back NOW.
    // `effect` is about a value that has not reached it yet.
    property string effect: ""

    readonly property string _effectNote: Semantics.effectNote(root.effect)

    default property alias control: slot.data

    width:          parent ? parent.width : 0
    implicitHeight: ((description !== "" || root.unavailable) ? 56 : 44)
                    + (root._effectNote !== "" ? 14 : 0)
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
        anchors.right:          readout.visible ? readout.left : slot.left
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
        Text {
            width:          parent.width
            visible:        root._effectNote !== ""
            text:           root._effectNote
            font.pixelSize: Theme.fs(10)
            color:          Theme.info
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

    // The effective value. Sits to the LEFT of the control when there is one,
    // so a row can both set and report — which is the whole of "controls read
    // back actual effective state rather than assuming a write succeeded".
    // Hidden while the row is disabled: a reason and a stale readout together
    // say two different things about the same control.
    Text {
        id: readout
        visible:                root.status !== "" && !root.unavailable
        text:                   root.status
        anchors.right:          slot.children.length > 0 ? slot.left : parent.right
        anchors.rightMargin:    slot.children.length > 0 ? 10 : 8
        anchors.verticalCenter: parent.verticalCenter
        font.pixelSize:         Theme.fs(10)
        font.family:            "JetBrains Mono"
        color:                  root.statusWarns ? Theme.attention : Qt.rgba(1,1,1,0.38)
    }
}
