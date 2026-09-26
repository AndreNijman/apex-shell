import QtQuick
import "../"

// ─────────────────────────────────────────────────────────────────────────────
// OpenPill — a bar control's open state.
//
// While the surface a control opened is up, its glyph sits on a small
// full-radius pill in the selection tint (brief §D.5). It replaces the right
// notch's old open state, which faded every status icon out and drew a ▾ in
// their place: the readout vanished exactly while the panel it opened was
// showing the same thing. Now every other icon stays where it is.
//
// Put it inside the glyph's own item; it centres on it and draws beneath it.
// ─────────────────────────────────────────────────────────────────────────────
Rectangle {
    id: pill
    property bool shown: false
    property real size: 24

    anchors.centerIn: parent
    z: -1
    width: pill.size; height: pill.size
    radius: height / 2
    // The one selected tint the shell uses (the nav pill's too).
    color: Theme.surfaceSelected

    visible: pill.opacity > 0
    opacity: pill.shown ? 1 : 0
    scale:   pill.shown ? 1 : 0.9
    // The state beat. The scale is the spatial half and goes with Reduce
    // Motion; the fade stays.
    Behavior on opacity { MotionFade { role: "state" } }
    Behavior on scale   { MotionMove { role: "selection"; curve: Motion.standardDecel } }
}
