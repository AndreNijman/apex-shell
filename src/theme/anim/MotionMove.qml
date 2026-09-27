import QtQuick
import "../.."

// A spatial change — position, size, scale — on a semantic spatial token.
//
//     Behavior on x { MotionMove {} }                                   // a selection travelling
//     Behavior on height { MotionMove { role: "surfaceEnterSmall" } }   // an inline reveal
//     Behavior on width { MotionMove { role: "valueFollow"; curve: Motion.fastSpatial } }
//
// `role` is a Motion SPATIAL token name. Reduce Motion makes it 0: the thing is
// simply in its new place. Never use this for opacity or colour — a fade that
// vanishes under Reduce Motion takes the user's only cue with it.
NumberAnimation {
    property string role: "selection"
    property var curve: Motion.defaultSpatial
    duration: Motion[role]
    easing.type: Easing.BezierSpline
    easing.bezierCurve: curve
}
