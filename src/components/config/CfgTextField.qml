import QtQuick
import "../../"

// Single-line editable field. Bind `text`; handle `edited` (per keystroke) and
// `accepted` (Enter).
Item {
    id: root
    property alias  text: input.text
    property string placeholder: ""

    // CfgRow writes the row's label onto the control it was given, which is
    // this Item — but the object a reader lands on is the TextInput inside it,
    // and an accessible name on a wrapper the focus never reaches helps nobody.
    // So the inner field BINDS to the outer name (see input.Accessible.name
    // below) and this wrapper deliberately declares no role of its own, so the
    // reader is not offered two overlapping editable texts.
    //
    // The forwarding is a binding rather than an `onAccessibleNameChanged`
    // handler: attached properties have no such handler, and QML accepts the
    // line at lint time and then fails to build the component at runtime with
    // "Cannot assign to non-existent property". tests/run-a11y-controls-test.sh
    // caught exactly that.
    property int    fieldWidth: 210
    signal edited(string text)
    signal accepted(string text)

    implicitWidth:  fieldWidth
    implicitHeight: 28
    width:  implicitWidth
    height: implicitHeight

    Rectangle {
        anchors.fill: parent
        radius: 7
        color:  input.activeFocus ? Qt.rgba(1,1,1,0.07) : Qt.rgba(1,1,1,0.04)
        border.width: 1
        border.color: input.activeFocus
            ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.5)
            : Qt.rgba(1,1,1,0.10)
        Behavior on border.color { ColorAnimation { duration: 120 } }
    }
    TextInput {
        id: input
        objectName:          "cfgTextFieldInput"
        anchors.fill:        parent
        anchors.leftMargin:  10
        anchors.rightMargin: 10
        verticalAlignment:   TextInput.AlignVCenter
        font.pixelSize:      Theme.fs(11)
        font.family:         "JetBrains Mono"
        color:               Theme.text
        clip:                true
        selectByMouse:       true
        selectionColor:      Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.4)

        // TextInput does not take Tab focus by default, so this field was
        // mouse-only: a keyboard user could not reach it to type in it at all.
        // The placeholder is a sibling Text that disappears on the first
        // keystroke, so it is not a label — the name comes from the CfgRow.
        activeFocusOnTab:    true
        Accessible.role:     Accessible.EditableText
        Accessible.name:     root.Accessible.name
        Accessible.description: root.placeholder
        onTextEdited: root.edited(text)
        onAccepted:   root.accepted(text)

        Text {
            anchors.fill:       parent
            verticalAlignment:  Text.AlignVCenter
            visible:            input.text === "" && !input.activeFocus
            text:               root.placeholder
            font:               input.font
            color:              Qt.rgba(1,1,1,0.3)
            elide:              Text.ElideRight
        }
    }
}
