import QtQuick
import "../../"
import "../controls"

// A toggle. Bind `checked`; handle `toggled(value)` to persist.
//
// Built on ApexPressable (UI/UX roadmap v3 Phase 16; brief §E "Toggle"):
// the track is the palette's high surface off and the accent on; the thumb
// travels on the selection beat (emphasizedDecel) and squeezes to .94 while
// pressed, instead of the whole switch dipping; the ring is for keyboard focus
// only.
ApexPressable {
    id: root
    property bool checked: false
    signal toggled(bool value)

    implicitWidth:  36
    implicitHeight: 20
    width:  implicitWidth
    height: implicitHeight
    radius: height / 2
    pressedScale: 1        // the thumb answers the press, not the whole switch

    // A switch carries no words of its own — they are in the CfgRow beside it,
    // which supplies the name. What the switch must say for itself is that it
    // is a checkbox and which way it is set: checkable without checked would
    // announce every toggle in the shell as "off".
    Accessible.role:      Accessible.CheckBox
    Accessible.checkable: true
    Accessible.checked:   root.checked
    Accessible.onToggleAction: root.toggle()

    function toggle() { root.toggled(!root.checked) }
    onActivated: root.toggle()

    Rectangle {
        id: track
        anchors.fill: parent
        radius:       height / 2
        color:        root.checked ? Theme.active : root.tint(Theme.surfaceHigh)
        Behavior on color { MotionColor { role: "state" } }
    }
    Rectangle {
        width:  parent.height - 4
        height: parent.height - 4
        radius: height / 2
        y:      2
        x:      root.checked ? parent.width - width - 2 : 2
        scale:  root.pressed ? 0.94 : 1
        color:  root.checked ? Theme.onAccent : Theme.textSecondary
        Behavior on x     { MotionSpring { role: "toggle" } }
        Behavior on scale { MotionMove { role: "pressIn" } }
        Behavior on color { MotionColor { role: "state" } }
    }
    ApexFocusRing { target: root }
}
