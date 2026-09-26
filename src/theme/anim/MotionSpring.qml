import QtQuick
import "../.."

// A spatial change on a SPRING — position, size, scale — for the values that
// get retargeted while they move: a tab pill chased across the bar, a nav
// highlight, a switch knob flipped twice, a surface's width changing page
// mid-open.
//
//     Behavior on x { MotionSpring {} }                       // selection
//     Behavior on width { MotionSpring { role: "page" } }
//     Behavior on scale { MotionSpring { role: "toggle"; epsilon: 0.0005 } }
//
// Why not MotionMove: a timed animation interrupted by a new target restarts
// from rest — the pill stops dead and sets off again, which is the mechanical
// feel Andre named (2026-09-26). A SpringAnimation in a Behavior keeps its
// velocity and bends toward the new target. The parameters come from the
// Motion spring table through Motion.qtSpring (motion.js: an exact mapping,
// measured against Qt's integrator), so `role` means the same response and
// damping as everywhere else.
//
// `epsilon` is in the property's own units: the default suits pixels; give a
// scale or an opacity-like value a far smaller one or it stops short.
// Reduce Motion makes it deadbeat — on the target in one 16 ms step — which is
// as good as no animation and never strands the value (spring 0 would).
SpringAnimation {
    property string role: "selection"
    readonly property var _p: Motion.qtSpring(role)
    spring:  _p.spring
    damping: _p.damping
    epsilon: 0.25
}
