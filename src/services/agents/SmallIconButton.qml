import QtQuick
import QtQuick.Controls
import "../../"
import "../../components/controls"

// A small glyph button with a tooltip (the Agent Center's row actions).
//
// ApexIconButton (UI/UX roadmap v3 Phase 16): transparent at rest, the state
// layer on hover and press, a .96 dip, a ring for keyboard focus only, and
// reachable with Tab and operable with Space/Return — it was pointer-only. A
// press does not take focus, so it never takes the keys from a field beside it.
ApexIconButton {
    id: btn

    property string icon: ""
    property string tip: ""

    glyph: btn.icon
    size: theme.px(26)
    // A 32 px target (hitMin) around the 26 px glyph; the rows that hold these
    // leave 6 px between them, so a margin meets a margin, never a glyph.
    hitMargin: theme.px(3)
    glyphSize: theme.fs(12)
    focusOnPress: false
    label: btn.tip

    ToolTip.visible: btn.hovered && btn.tip !== ""
    ToolTip.text: btn.tip
}
