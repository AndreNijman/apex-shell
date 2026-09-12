import QtQuick
import "../../"
import "settings-semantics.js" as Semantics

// A settings row: label (+ optional description) on the left, a control on the
// right. Put the control as a child — it is placed in the right-hand slot.
Item {
    id: root
    readonly property ThemeSet theme: Theme.setForHeight(Screen.height)   // P1-040: this output's sizes

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

    // ── What a screen reader is told about this row ──────────────────────────
    //
    // The problem this solves is structural, not a missing property. A row's
    // words — the label, the description, the reason it is switched off, the
    // effective value read back from the machine — are sibling Text items. The
    // CONTROL is a separate object with none of them, so a reader that lands on
    // the switch announces an unnamed checkbox and the user is toggling
    // something anonymous. Naming the control at each call site would mean
    // touching 294 rows across eleven pages and would rot the first time
    // somebody changed a label and not its twin.
    //
    // So the row hands its own words to whatever control was put in it. An
    // attached Accessible object is a real QObject property, so it can be
    // written from here — verified, not assumed — and a control that already
    // names itself (CfgButton carries its own label) is left alone.
    //
    // `status` is in the description on purpose: it is what the machine reports
    // is ACTUALLY in effect, and a sighted user reads it beside the control. A
    // reader that omitted it would be missing the one thing distinguishing a
    // setting that worked from one whose backend stopped listening.
    readonly property string a11yDescription: {
        var parts = []
        if (root.unavailable)             parts.push(root.disabledReason)
        else if (root.description !== "") parts.push(root.description)
        if (root.status !== "")           parts.push("Currently " + root.status)
        if (root._effectNote !== "")      parts.push(root._effectNote)
        return parts.join(". ")
    }

    // The controls this row supplies accessible text for: the ones that had no
    // name of their own when they were placed. Decided once, so a row cannot
    // start overwriting a control that names itself later.
    property var _adopted: []

    function _adoptControls() {
        var kids = slot.data
        var out  = []
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            // A non-Item child (a Timer, a Connections) has no Accessible
            // attachment worth writing to; `visible` is the cheap Item test
            // that does not itself create an attachment on everything.
            if (!c || c.visible === undefined) continue
            if (c.Accessible.name === "") out.push(c)
        }
        root._adopted = out
        root._pushA11y()
    }

    function _pushA11y() {
        for (var i = 0; i < root._adopted.length; i++) {
            var c = root._adopted[i]
            if (root.label !== "") c.Accessible.name = root.label
            c.Accessible.description = root.a11yDescription
        }
    }

    Component.onCompleted:     root._adoptControls()
    onLabelChanged:            root._pushA11y()
    onA11yDescriptionChanged:  root._pushA11y()
    Connections {
        target: slot
        function onChildrenChanged() { root._adoptControls() }
    }

    width: parent ? parent.width : 0

    // As tall as what it holds, with a floor.
    //
    // This used to be two constants — 56 with a description, 44 without —
    // chosen for how tall two lines are at scale 1.0. The text inside is sized
    // with Theme.fs(), which scales; the row was not, so from 1.5x upward every
    // row with a description drew its second line outside itself. Nothing
    // noticed, because a clipped line is not an error: the row's own rectangle
    // is right, its neighbours are right, and the sentence is simply gone.
    // tests/nav-geometry-test.qml's page block found 34 of them on the first
    // run that graded a page.
    //
    // The control and the readout are in the maximum too: either one taller
    // than the text beside it would have hung out of the bottom the same way.
    implicitHeight: Math.max(44, texts.implicitHeight + 14,
                             slot.height + 12, readout.height + 12)
    height:         implicitHeight

    Rectangle {
        anchors.fill: parent
        radius:       8
        color:        (root.hoverable && hov.hovered) ? Qt.rgba(1,1,1,0.03) : "transparent"
        Behavior on color { ColorAnimation { duration: 120 } }
    }
    HoverHandler { id: hov; enabled: root.hoverable }

    Column {
        id: texts
        anchors.left:           parent.left
        anchors.leftMargin:     10
        anchors.right:          readout.visible ? readout.left : slot.left
        anchors.rightMargin:    12
        anchors.verticalCenter: parent.verticalCenter
        spacing: 3

        Text {
            width:          parent.width
            text:           root.label
            font.pixelSize: theme.fs(12)
            color:          root.unavailable ? Qt.rgba(1,1,1,0.42) : Qt.rgba(1,1,1,0.75)
            elide:          Text.ElideRight
        }
        Text {
            width:          parent.width
            visible:        text !== ""
            text:           root.unavailable ? root.disabledReason : root.description
            font.pixelSize: theme.fs(10)
            color:          Qt.rgba(1,1,1,0.38)
            wrapMode:       Text.WordWrap
            maximumLineCount: 2
            elide:          Text.ElideRight
        }
        Text {
            width:          parent.width
            visible:        root._effectNote !== ""
            text:           root._effectNote
            font.pixelSize: theme.fs(10)
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
        font.pixelSize:         theme.fs(10)
        font.family:            "JetBrains Mono"
        color:                  root.statusWarns ? Theme.attention : Qt.rgba(1,1,1,0.38)
    }
}
