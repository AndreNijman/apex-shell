import QtQuick
import "../.."

// A colour change, on a semantic duration and the effects curve.
//
//     Behavior on color { MotionColor {} }                 // hover tint
//     Behavior on color { MotionColor { role: "state" } }  // status / selection colour
//
// `role` is a Motion effect token name: micro, hover, state, fadeIn, fadeOut.
// Effects survive Reduce Motion (shortened), because a colour that changes
// instantly and one that changes in 80 ms are equally calm.
ColorAnimation {
    property string role: "hover"
    duration: Motion[role]
    easing.type: Easing.BezierSpline
    easing.bezierCurve: Motion.effects
}
