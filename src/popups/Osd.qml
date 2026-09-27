import QtQuick
import Quickshell
import Quickshell.Wayland
import "../"
import "../components"
import "../services"

// ============================================================
// Osd — the volume / brightness / mic level as a floating capsule, for where
// the centre notch cannot show it (2026-09-27). The notch is where it lives
// now (modules/Center/NotchOsd.qml in TopBar); OsdState decides what shows.
// This one opens only on a screen whose notch is gone or empty — a fullscreen
// window unmaps the bar, focus mode empties it — or while the Dashboard or
// the Nexus is pouring out of the centre notch (OsdState.inNotch false).
//
// One instance per screen (created in shell.qml's Variants delegate).
// ============================================================

PanelWindow {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForScreen(root.screen) }   // P1-040: this output's sizes


    // ── Layer / geometry ──────────────────────────────────────
    // Overlay layer, no focus, click-through (empty input mask), no
    // exclusive zone. Full-width strip at the top; the pill is centred
    // inside and floats a little below the notch.
    color: "transparent"
    anchors { top: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    margins.top:   theme.notchHeight + 14

    WlrLayershell.layer:         WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    mask: Region {}   // no input region → never blocks clicks

    implicitHeight: pillH + slideRoom
    visible:        life.mapped

    // ── Config ────────────────────────────────────────────────
    readonly property int pillW:     264
    readonly property int pillH:     46
    readonly property int slideRoom: 14

    // ── CAPSULE (UI/UX roadmap v3 Phase 14, brief B.7) ──────────────────────
    // In: a fade on the state beat while it drops 10 px into place on the
    // selection beat, both standardDecel. Out: the fade, rising 6 px. A value
    // changing while it is up never replays the entrance — only the hide timer
    // restarts — and the bar follows the value with a SmoothedAnimation, so a
    // held key tracks a moving target instead of restarting a tween per step.
    // Under Reduce Motion nothing travels and the fade stays.
    SurfaceLifecycle {
        resetsFocusRing: false   // arrives unasked (a volume key), takes no focus
        name: "osd"
        id: life
        open:          root.showing
        enterDuration: Motion.selection
        exitDuration:  Motion.state
        contentDelay:  0
        contentIn:     Motion.state
        contentOut:    Motion.state
    }

    // ── What it shows: OsdState's; where: here only without a notch ──────
    readonly property string kind:  OsdState.kind
    readonly property real   value: OsdState.value
    readonly property bool   muted: OsdState.muted
    readonly property string glyph: OsdState.glyph
    readonly property string label: OsdState.label
    readonly property string _screenName: root.screen ? root.screen.name : ""
    readonly property bool showing: OsdState.showing
        && (!OsdState.inNotch || ShellState.focusMode || ShellState.fullscreenCovers(root._screenName))

    // ── Pill ──────────────────────────────────────────────────
    Item {
        id: pill
        width:  root.pillW
        height: root.pillH
        anchors.horizontalCenter: parent.horizontalCenter

        // Settled at slideRoom; 10 px above it arriving, 6 px above leaving.
        y: root.slideRoom - (1 - life.progress)
                          * Motion.travel(theme.px(life.closing ? 6 : 10))
        opacity: life.content * life.alpha

        Rectangle {
            id: bg
            anchors.fill: parent
            // A capsule: fully round ends.
            radius:       height / 2
            color:        Theme.background
            border.width: 1
            border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.06)
        }

        // Icon
        Text {
            id: iconText
            anchors.left:           parent.left
            anchors.leftMargin:     16
            anchors.verticalCenter: parent.verticalCenter
            text:           root.glyph
            font.pixelSize: theme.fs(18)
            color:          root.muted ? Theme.subtext : Theme.text
            Behavior on color { MotionColor { role: "state" } }
        }

        // Value / label text (fixed width so the bar doesn't jump)
        Text {
            id: pctText
            anchors.right:          parent.right
            anchors.rightMargin:    16
            anchors.verticalCenter: parent.verticalCenter
            width:                  46
            horizontalAlignment:    Text.AlignRight
            text:           root.label
            font.pixelSize: theme.fs(13)
            font.bold:      true
            color:          root.muted ? Theme.subtext : Theme.text
            Behavior on color { MotionColor { role: "state" } }
        }

        // Filled progress bar
        Item {
            anchors.left:           iconText.right
            anchors.leftMargin:     12
            anchors.right:          pctText.left
            anchors.rightMargin:    12
            anchors.verticalCenter: parent.verticalCenter
            height: 6

            Rectangle {
                id: track
                anchors.fill: parent
                radius:       height / 2
                color:        Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10)

                Rectangle {
                    anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                    width:  Math.max(parent.height, parent.width * root.value)
                    radius: parent.radius
                    color:  root.muted ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.20) : Theme.active
                    // About three track-widths a second: fast enough to keep up
                    // with a held key, smooth enough not to jump per step. Only
                    // while the capsule is up — arriving, it shows the value it
                    // has instead of growing from wherever the last one left it
                    // (which read as the volume rising from 0) — and off with
                    // spatial motion (valueFollow is 0 under Reduce Motion).
                    Behavior on width {
                        enabled: Motion.valueFollow > 0 && life.progress >= 1 && !life.closing
                        SmoothedAnimation { velocity: Math.max(1, track.width * 3) }
                    }
                    Behavior on color { MotionColor { role: "state" } }
                }
            }
        }
    }
}
