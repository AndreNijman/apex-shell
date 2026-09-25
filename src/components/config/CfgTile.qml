import QtQuick
import "../../"
import "../controls"

// Compact toggle/action tile (mirrors the QuickSettings tiles). Use in a Grid.
//
// Built on ApexPressable (UI/UX roadmap v3 Phase 3): the tile dips when
// pressed, by pointer or Space/Return, hovers and presses as a state layer
// over its own surface, and shows a focus ring only for keyboard focus. On,
// it fills with the accent container and its glyph turns to the accent.
ApexPressable {
    id: root

    property bool   on:       false
    property string icon:     ""
    property string label:    ""
    property string sublabel: ""
    signal toggled()

    radius: theme.radiusM
    // Through a function: emitting `toggled` straight from the inherited
    // `activated` handler failed in this Qt ("Unknown method return type").
    function toggle() { root.toggled() }
    onActivated: root.toggle()

    // A tile is a labelled on/off control, so it names itself and reports its
    // state. The sublabel is the live readout ("Wi-Fi: MyNetwork"); it belongs
    // in the description, where a reader gives it after the name and the state.
    Accessible.checkable: true
    Accessible.checked:   root.on
    Accessible.name:      root.label
    Accessible.description: root.sublabel

    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: root.tint(root.on ? Theme.accentContainer : Theme.surfaceRaised)
        border.width: 1
        border.color: root.on
            ? Qt.rgba(Theme.accentText.r, Theme.accentText.g, Theme.accentText.b, 0.30)
            : Theme.outlineSoft
        Behavior on color        { MotionColor { role: "state" } }
        Behavior on border.color { MotionColor { role: "state" } }
    }

    Rectangle {
        anchors { top: parent.top; right: parent.right; margins: 8 }
        width: 6; height: 6; radius: 3
        color: root.on ? Theme.accentText : Theme.outlineStrong
        Behavior on color { MotionColor { role: "state" } }
    }
    Column {
        anchors { left: parent.left; bottom: parent.bottom; margins: 9 }
        spacing: 2
        Text {
            text: root.icon; font.pixelSize: theme.fs(17)
            color: root.on ? Theme.accentText : Theme.iconDefault
            Behavior on color { MotionColor { role: "state" } }
        }
        Text {
            text: root.label; font.pixelSize: theme.fs(9); font.weight: Font.Medium
            color: root.on ? Theme.textPrimary : Theme.textSecondary
            Behavior on color { MotionColor { role: "state" } }
        }
        Text {
            visible: root.sublabel !== ""
            text:    root.sublabel
            font.pixelSize: theme.fs(8); font.family: Theme.fontMono
            color:   Theme.accentText
            opacity: 0.8
            width:   root.width - 18; elide: Text.ElideRight
        }
    }
    ApexFocusRing { target: root }
}
