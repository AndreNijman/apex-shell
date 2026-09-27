import QtQuick
import "../.."

// An opacity (or other non-spatial number) change, on a semantic effect token.
//
//     Behavior on opacity { MotionFade {} }                 // state change
//     Behavior on opacity { MotionFade { role: "fadeIn" } }
//
// Same contract as MotionColor: an EFFECT, so Reduce Motion keeps it, short.
NumberAnimation {
    property string role: "state"
    duration: Motion[role]
    easing.type: Easing.BezierSpline
    easing.bezierCurve: Motion.effects
}
