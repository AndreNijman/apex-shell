import QtQuick
import "../../"
import "../controls"

// Action button. variant: "default" | "accent" | "danger".
//
// Built on ApexPressable (UI/UX roadmap v3 Phase 3): it dips when pressed, by
// pointer or by Space/Return; its hover and press are a state layer over its
// own surface; its focus ring shows only for keyboard focus. Its colours are
// the palette's roles, not translucent whites, so it reads on either scheme.
ApexPressable {
    id: root

    property string label:   ""
    property string icon:    ""
    property string variant: "default"
    property bool   enabled: true
    signal clicked()

    implicitWidth:  rowc.implicitWidth + 24
    implicitHeight: theme.controlCompact
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
                return root.tint(Theme.surfaceRaised)
            var a = root._accent
            var k = root.pressed ? 0.34 : root.hovered ? 0.28 : 0.15
            return Qt.rgba(a.r, a.g, a.b, k)
        }
        border.width: 1
        border.color: root.variant === "default"
            ? Theme.outlineStrong
            : Qt.rgba(root._accent.r, root._accent.g, root._accent.b, 0.42)
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
            font.pixelSize: theme.fs(11)
            font.weight:    Font.Medium
            anchors.verticalCenter: parent.verticalCenter
            color: root.variant === "default" ? Theme.textPrimary : root._accent
        }
    }
    ApexFocusRing { target: root }
}
