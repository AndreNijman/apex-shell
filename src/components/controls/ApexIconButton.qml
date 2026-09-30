import QtQuick
import "../../"

// ─────────────────────────────────────────────────────────────────────────────
// ApexIconButton — a glyph that is a button (UI/UX roadmap v3 Phase 3; brief
// §E "Icon button", §D.6 for the bar).
//
// Anywhere but the bar: transparent at rest, the surface's state layer on
// hover and press, dipping to .96; `selected` fills it with surfaceSelected and
// turns the glyph to the accent. In the bar (`bar: true`): no fill at all — the
// glyph alone answers, textPrimary on hover and the accent while pressed — and
// the target is 24 px however small the glyph.
// ─────────────────────────────────────────────────────────────────────────────
ApexPressable {
    id: root

    property string glyph: ""
    // What a screen reader says. Never the glyph: every icon here is a
    // private-use codepoint, which reads as nothing or as noise
    // (tests/run-lockscreen-atspi-shim.sh fails on one reaching the bus).
    property string label: ""
    property bool   selected: false
    property bool   bar: false
    property real   size: root.bar ? theme.px(20) : theme.hitMin
    property color  glyphColor: root.selected || (root.bar && root.pressed) ? Theme.accentText
                              : root.hovered ? Theme.textPrimary : Theme.iconDefault
    property int    glyphSize: theme.typeIcon

    implicitWidth: root.size
    implicitHeight: root.size
    radius: root.bar ? height / 2 : theme.radiusM
    pressedScale: 0.96
    hitMargin: root.bar ? Math.max(0, (theme.hitBar - root.size) / 2) : 0
    Accessible.name: root.label

    Rectangle {
        anchors.fill: parent
        radius: root.radius
        visible: !root.bar
        color: root.selected ? root.tint(Theme.surfaceSelected) : root.stateLayer()
        Behavior on color { MotionColor { role: "hover" } }
    }
    Text {
        anchors.centerIn: parent
        text: root.glyph
        font.family: Theme.fontIcon
        font.pixelSize: root.glyphSize
        color: root.glyphColor
        Behavior on color { MotionColor { role: "hover" } }
    }
    ApexFocusRing { target: root }
}
