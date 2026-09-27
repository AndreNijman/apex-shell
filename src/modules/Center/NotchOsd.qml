import QtQuick
import "../../"
import "../../components"

// ─────────────────────────────────────────────────────────────────────────────
// NotchOsd — the volume / brightness / mic level, drawn IN the centre notch.
//
// Andre, 2026-09-27: the OSD was a separate capsule floating below the notch;
// "make it actually part of the top notch, like clean and part of the top
// notch, following the proper design of apex, and the proper animations from
// apex". TopBar places this in the centre notch and moves it the way the
// island moves anything: the notch widens on its page spring, the island's
// current item scrolls up out of it and this scrolls in from below (the
// island carousel's own direction and spring), and back when it hides. What
// it shows is OsdState's; it only draws.
//
//   glyph · level bar (as long as the notch is wide) · value
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes

    // Fully in place: the bar follows a held key smoothly only then, so it
    // arrives showing the value it has rather than growing from the last one.
    property bool settled: false
    // A switch between volume and brightness is a different quantity, not a
    // move: it cuts. (OsdState sets the kind before the value.)
    property bool _cut: false
    readonly property string _kind: OsdState.kind
    on_KindChanged: { root._cut = true; Qt.callLater(function () { root._cut = false }) }

    Text {
        id: glyph
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: theme.px(22)
        text: OsdState.glyph
        color: OsdState.muted ? Theme.subtext : Theme.text
        font.family: Theme.fontIcon
        font.pixelSize: theme.typeIcon
        horizontalAlignment: Text.AlignHCenter
        Behavior on color { MotionColor { role: "state" } }
    }

    Text {
        id: value
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        // Wide enough for "100%" and "Muted", so the bar does not jump.
        width: theme.px(44)
        horizontalAlignment: Text.AlignRight
        text: OsdState.label
        color: OsdState.muted ? Theme.subtext : Theme.text
        font.family: Theme.fontUi
        font.pixelSize: theme.fs(13)
        font.weight: Font.DemiBold
        font.features: { "tnum": 1 }
        Behavior on color { MotionColor { role: "state" } }
    }

    Item {
        id: track
        anchors.left: glyph.right
        anchors.leftMargin: theme.px(10)
        anchors.right: value.left
        anchors.rightMargin: theme.px(10)
        anchors.verticalCenter: parent.verticalCenter
        height: theme.px(6)

        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10)
        }
        Rectangle {
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
            width: Math.max(parent.height, parent.width * OsdState.value)
            radius: height / 2
            color: OsdState.muted ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.20) : Theme.active
            // About three track-widths a second: keeps up with a held key
            // without jumping per step. Off with spatial motion (valueFollow
            // is 0 under Reduce Motion).
            Behavior on width {
                enabled: Motion.valueFollow > 0 && root.settled && !root._cut
                SmoothedAnimation { velocity: Math.max(1, track.width * 3) }
            }
            Behavior on color { MotionColor { role: "state" } }
        }
    }
}
