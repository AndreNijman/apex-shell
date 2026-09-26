import QtQuick
import "../../"

// ApexFocusRing — the keyboard-focus mark (UI/UX roadmap v3 Phase 3, brief §E).
//
// A 2 px accent stroke drawn 2 px outside the control, at the control's radius
// + 2 so it follows its shape. Shown only while the target's focus came from
// the keyboard (ApexPressable.focusVisible): a pointer never leaves one behind.
// Place it inside the control it marks.
Rectangle {
    id: ring
    required property Item target
    property real targetRadius: ring.target && ring.target.radius !== undefined ? ring.target.radius : 0

    anchors.fill: parent
    anchors.margins: -4
    radius: ring.targetRadius + 4
    color: "transparent"
    border.width: 2
    border.color: Theme.accentText
    visible: ring.target && ring.target.focusVisible === true
    z: 100
}
