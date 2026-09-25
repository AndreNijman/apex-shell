import QtQuick
import "../../"

// ─────────────────────────────────────────────────────────────────────────────
// ApexPressable — the one press, hover and focus language every control shares
// (UI/UX roadmap v3 Phase 3).
//
//   * Press: the control dips to Motion.pressScale (0.975) on pressIn and comes
//     back on pressOut — visible the moment the pointer goes down, no bounce.
//     Space and Return replay the same dip, so the keyboard gets the feedback
//     the pointer does. Under Reduce Motion the dip goes; the state layer stays.
//   * Hover and press as a STATE LAYER: `tint(base)` is the control's own
//     surface mixed toward the palette's text colour — 6 % hovered, 10 %
//     pressed (roles.js) — so it reads on any surface and either scheme, where
//     a translucent white only ever read on dark.
//   * Focus: `focusVisible` is true only for focus a keyboard gave. A pointer
//     press that takes focus does not light a ring; the next key does.
//     (Item has no focusReason in Qt Quick 6.10 — measured — so it is tracked.)
//   * Hit size and visual size are separate: `hitMargin` grows the pointer
//     target past the drawn control (a 20 px glyph with a 24 px target).
//   * Disabled: `interactive: false` — opacity .38, no press, no cursor, not a
//     tab stop.
//
// Use it as a control's root, so the dip carries the whole control:
//
//     ApexPressable {
//         id: btn
//         onActivated: …
//         Rectangle { anchors.fill: parent; radius: btn.radius; color: btn.tint(Theme.surfaceRaised) }
//         ApexFocusRing { target: btn }
//     }
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes

    property bool interactive: true
    property real radius: theme.radiusS
    property real pressedScale: Motion.pressScale
    property real hitMargin: 0

    readonly property bool hovered: hov.hovered && root.interactive
    readonly property bool pressed: root._pressed
    readonly property bool focusVisible: root.activeFocus && !root._pointerFocus

    signal activated()

    // The surface a control is on, under this control's state layer.
    function tint(base) {
        const k = root.pressed ? 0.10 : root.hovered ? 0.06 : 0
        if (k === 0) return base
        const t = Theme.textPrimary
        return Qt.rgba(base.r * (1 - k) + t.r * k, base.g * (1 - k) + t.g * k,
                       base.b * (1 - k) + t.b * k, base.a)
    }

    // For a control with no surface of its own: the state layer by itself —
    // the palette's text colour at the same 6 % / 10 %, over whatever is behind.
    // (Not `layer()`: that name is Item's own `layer` group, and a function
    // declared under it is shadowed — measured, calling it threw.)
    function stateLayer() {
        const k = root.pressed ? 0.10 : root.hovered ? 0.06 : 0
        const t = Theme.textPrimary
        return Qt.rgba(t.r, t.g, t.b, k)
    }

    property bool _pressed: false
    property bool _pointerFocus: false
    onActiveFocusChanged: if (!root.activeFocus) root._pointerFocus = false

    activeFocusOnTab: root.interactive
    opacity: root.interactive ? 1 : 0.38
    Behavior on opacity { MotionFade {} }

    Accessible.role: Accessible.Button
    Accessible.onPressAction: if (root.interactive) root.activated()

    // ── The dip ──────────────────────────────────────────────────────────────
    scale: 1
    onPressedChanged: {
        dip.stop()
        dip.to = root.pressed ? root.pressedScale : 1
        dip.duration = root.pressed ? Motion.pressIn : Motion.pressOut
        dip.easing.bezierCurve = root.pressed ? Motion.standardAccel : Motion.standardDecel
        if (dip.duration <= 0) root.scale = dip.to
        else dip.start()
    }
    NumberAnimation { id: dip; target: root; property: "scale"; easing.type: Easing.BezierSpline }

    // Space / Return: the same dip, then the action — never a delayed one.
    Keys.onPressed: function (event) {
        if (!root.interactive) return
        if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root._pointerFocus = false
            if (!event.isAutoRepeat) { root._pressed = true; keyRelease.restart() }
            root.activated()
            event.accepted = true
        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
            root._pointerFocus = false
        }
    }
    Timer { id: keyRelease; interval: Motion.pressIn; onTriggered: root._pressed = false }

    HoverHandler {
        id: hov
        enabled: root.interactive
        cursorShape: Qt.PointingHandCursor
        margin: root.hitMargin
    }
    MouseArea {
        anchors.fill: parent
        anchors.margins: -root.hitMargin
        enabled: root.interactive
        onPressed: {
            root._pointerFocus = true
            root.forceActiveFocus()
            root._pressed = true
        }
        onReleased: root._pressed = false
        onCanceled: root._pressed = false
        onClicked: root.activated()
    }
}
