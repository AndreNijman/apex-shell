import QtQuick
import "../../"

// Horizontal slider with a monospace readout on the right.
// Bind `value`; handle `moved(value)` live (fires on click, drag and keys).
//
// There is deliberately no wheel handler here. This control sits in a settings
// page the user scrolls, and a wheel event over it is someone reading the page,
// not editing it — the handler that used to live here turned every scroll past
// a slider into a settings change nobody asked for. tests/check-wheel-value.sh
// fails if one comes back.
//
// Keyboard: Tab to focus, Left/Right or Down/Up for one step, Page keys for
// ten, Home/End for the ends.
Item {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes

    property real   value:  0
    property real   from:   0
    property real   to:     100
    property real   step:   1
    property string suffix: ""
    property int    readoutWidth: 48
    signal moved(real value)

    implicitWidth:  212
    implicitHeight: 24
    width:  implicitWidth
    height: implicitHeight

    activeFocusOnTab: true

    // Focus a pointer gave lights no ring; the next key does (ApexPressable's
    // rule — Qt Quick 6.10 has no Item.focusReason, so it is tracked).
    property bool _pointerFocus: false
    onActiveFocusChanged: if (!activeFocus) _pointerFocus = false

    // The one control in this library that was already keyboard-operable, and
    // still announced nothing: no role, so a reader called it a plain element,
    // and no value, so the arrow keys moved something unreportable. The name
    // comes from the CfgRow around it.
    Accessible.role: Accessible.Slider
    Accessible.description: root.value + (root.suffix !== "" ? " " + root.suffix : "")
    Accessible.onIncreaseAction: root._nudge(1)
    Accessible.onDecreaseAction: root._nudge(-1)

    readonly property real _frac: (to > from) ? Math.max(0, Math.min(1, (value - from) / (to - from))) : 0

    // The one place a new value leaves this component. Clamped to the range and
    // never emitted for a no-op, so a key held at either end stays quiet.
    function _emit(v) {
        var clamped = Math.max(from, Math.min(to, v))
        if (clamped !== root.value) root.moved(clamped)
    }

    function _apply(frac) {
        var raw = from + Math.max(0, Math.min(1, frac)) * (to - from)
        root._emit(Math.round(raw / step) * step)
    }

    // Move `n` steps from where the value is now, keeping it on the step grid.
    function _nudge(n) {
        root._emit(Math.round((root.value + n * step) / step) * step)
    }

    Keys.onPressed: function(event) {
        root._pointerFocus = false
        switch (event.key) {
        case Qt.Key_Left:
        case Qt.Key_Down:     root._nudge(-1);        break
        case Qt.Key_Right:
        case Qt.Key_Up:       root._nudge(1);         break
        case Qt.Key_PageDown: root._nudge(-10);       break
        case Qt.Key_PageUp:   root._nudge(10);        break
        case Qt.Key_Home:     root._emit(root.from);  break
        case Qt.Key_End:      root._emit(root.to);    break
        default: return
        }
        event.accepted = true
    }

    Text {
        id: readout
        anchors.right:          parent.right
        anchors.verticalCenter: parent.verticalCenter
        width:               root.readoutWidth
        horizontalAlignment: Text.AlignRight
        text:           Math.round(root.value) + root.suffix
        // A value: the readout treatment (UI/UX Phase 17, P2.17).
        font.pixelSize: theme.typeMono
        font.family:    Theme.fontMono
        color:          Theme.textSecondary
    }

    Item {
        id: bar
        anchors.left:           parent.left
        anchors.right:          readout.left
        anchors.rightMargin:    10
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        readonly property int thumbD: 14

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width:  parent.width
            height: 4
            radius: 2
            color:  Theme.outlineStrong
            Rectangle {
                anchors.left:   parent.left
                anchors.top:    parent.top
                anchors.bottom: parent.bottom
                width:  Math.max(parent.radius * 2, parent.width * root._frac)
                radius: parent.radius
                color:  Theme.active
                // No easing while the thumb is being dragged (brief §E): it is
                // under the pointer. A value that changes by itself follows
                // smoothly, by velocity, instead of restarting a tween.
                Behavior on width {
                    enabled: !drag.pressed && Motion.valueFollow > 0
                    SmoothedAnimation { velocity: Math.max(1, bar.width * 4) }
                }
            }
        }
        Rectangle {
            // 14, and 16 under the pointer or held (brief §E "Slider"): the
            // accent with a ring of the surface it sits on.
            readonly property int d: drag.pressed || drag.containsMouse ? bar.thumbD + 2 : bar.thumbD
            width:  d
            height: d
            radius: d / 2
            color:  Theme.active
            border.width: 2
            border.color: Theme.surfaceBase
            anchors.verticalCenter: parent.verticalCenter
            x: Math.max(0, Math.min(bar.width - bar.thumbD, root._frac * (bar.width - bar.thumbD))) - (d - bar.thumbD) / 2
            Behavior on width  { MotionMove { role: "pressOut" } }
            Behavior on height { MotionMove { role: "pressOut" } }
            Behavior on x {
                enabled: !drag.pressed && Motion.valueFollow > 0
                SmoothedAnimation { velocity: Math.max(1, bar.width * 4) }
            }
        }
        // Focus ring. Keyboard access is worth nothing if you cannot see which
        // control has the keys.
        Rectangle {
            anchors.fill:    parent
            anchors.margins: -4
            radius:          8
            color:           "transparent"
            // The one ring every control draws: 2 px of accentText, 3:1 or better
            // on every surface of every shipped palette (color-roles-test). It was
            // 1 px of the raw accent at 60 %, the faintest ring in the shell.
            border.width:    2
            border.color:    Theme.accentText
            // Keyboard focus only: a drag that takes focus lights no ring.
            visible:         root.activeFocus && !root._pointerFocus
        }
        MouseArea {
            id: drag
            anchors.fill: parent
            hoverEnabled: true
            cursorShape:  Qt.PointingHandCursor
            function _c(mx) { return (mx - bar.thumbD / 2) / (bar.width - bar.thumbD) }
            onPressed:         function(mouse) { root._pointerFocus = true; root.forceActiveFocus(); root._apply(_c(mouse.x)) }
            onPositionChanged: function(mouse) { if (pressed) root._apply(_c(mouse.x)) }
        }
    }
}
