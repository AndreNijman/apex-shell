import QtQuick
import "../../"
import "../controls"

// Action button. variant: "default" | "accent" | "danger".
//
// Built on ApexPressable (UI/UX roadmap v3 Phase 3): it dips when pressed, by
// pointer or by Space/Return; its hover and press are a state layer over its
// own surface; its focus ring shows only for keyboard focus. Its colours are
// the palette's roles, not translucent whites, so it reads on either scheme.
//
// One action shape across the shell (UI/UX Phase 17, visual roadmap §18/§21):
// the high surface, radiusS, no border, the token height for a button — the
// same button the network panes, the Hotspot form and the Agents card use.
// It was the raised surface (.05, near-invisible on the light sheet without
// the outline) inside an outlineStrong border, 28 px. A border is kept for
// the danger variant only: borders mean an input, the focus ring, or a
// confirmation that destroys something.
ApexPressable {
    id: root

    property string label:   ""
    property string icon:    ""
    property string variant: "default"
    property bool   enabled: true
    signal clicked()

    implicitWidth:  rowc.implicitWidth + 24
    implicitHeight: theme.controlStandard
    width:  implicitWidth
    height: implicitHeight
    radius: theme.radiusS
    interactive: root.enabled

    readonly property color _accent: variant === "danger" ? Theme.danger : Theme.accentText

    // A button that only a mouse can press is not a button for everyone. Tab
    // reaches it, Space and Return press it, and a reader is told it is a
    // button and what it says. CfgButton names ITSELF because its words are its
    // own label — CfgRow only supplies a name to controls that have none.
    Accessible.name:  root.label

    function press() { if (root.enabled) root.clicked() }
    onActivated: root.press()

    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: {
            if (root.variant === "default")
                return root.tint(Theme.surfaceHigh)
            var a = root._accent
            var k = root.pressed ? 0.34 : root.hovered ? 0.28 : 0.15
            return Qt.rgba(a.r, a.g, a.b, k)
        }
        border.width: root.variant === "danger" ? 1 : 0
        border.color: Qt.rgba(root._accent.r, root._accent.g, root._accent.b, 0.42)
        Behavior on color { MotionColor { role: "hover" } }
    }
    Row {
        id: rowc
        anchors.centerIn: parent
        spacing: 5
        Text {
            visible: root.icon !== ""
            text:    root.icon
            font.pixelSize: theme.fs(12)
            anchors.verticalCenter: parent.verticalCenter
            color: root.variant === "default" ? Theme.textPrimary : root._accent
        }
        Text {
            text: root.label
            font.pixelSize: theme.typeCaption
            font.weight:    Font.Medium
            anchors.verticalCenter: parent.verticalCenter
            color: root.variant === "default" ? Theme.textPrimary : root._accent
        }
    }
    ApexFocusRing { target: root }
}
