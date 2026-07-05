import QtQuick
import "../../"

// Single-line editable field. Bind `text`; handle `edited` (per keystroke) and
// `accepted` (Enter).
Item {
    id: root
    property alias  text: input.text
    property string placeholder: ""
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
        anchors.fill:        parent
        anchors.leftMargin:  10
        anchors.rightMargin: 10
        verticalAlignment:   TextInput.AlignVCenter
        font.pixelSize:      11
        font.family:         "JetBrains Mono"
        color:               Theme.text
        clip:                true
        selectByMouse:       true
        selectionColor:      Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.4)
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
