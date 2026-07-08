import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pipewire
import "../"

// ============================================================
// Osd — transient on-screen-display pill for volume / brightness
// (and mic-mute). Floats top-centre just below the notch, shows
// briefly on a hardware-key change, then auto-hides.
//
// One instance per screen (created in shell.qml's Variants delegate).
//
// Change detection
//   • volume / mute → Pipewire.defaultAudioSink.audio {volume,muted}
//   • brightness    → FileView(watchChanges) on the backlight sysfs
//                     `brightness` file → inotify fires on every write
//                     (incl. hardware keys via brightnessctl). Value is
//                     read back with `brightnessctl -m` for parity with
//                     the rest of the shell. No polling.
//   • mic-mute      → Pipewire.defaultAudioSource.audio.muted
//
// Startup is suppressed two ways: a short boot-grace timer AND a
// per-channel "primed" step that swallows the first settled value.
// ============================================================

PanelWindow {
    id: root

    // ── Layer / geometry ──────────────────────────────────────
    // Overlay layer, no focus, click-through (empty input mask), no
    // exclusive zone. Full-width strip at the top; the pill is centred
    // inside and floats a little below the notch.
    color: "transparent"
    anchors { top: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    margins.top:   Theme.notchHeight + 14

    WlrLayershell.layer:         WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    mask: Region {}   // no input region → never blocks clicks

    implicitHeight: pillH + slideRoom
    visible:        windowVisible

    // ── Config ────────────────────────────────────────────────
    readonly property int pillW:     264
    readonly property int pillH:     46
    readonly property int slideRoom: 14

    // Reduce-motion collapses every OSD animation to an instant cut.
    readonly property int showAnim: SettingsService.reduceMotion ? 0 : 220
    readonly property int valAnim:  SettingsService.reduceMotion ? 0 : 200

    // ── Live display state ────────────────────────────────────
    property string kind:    "volume"   // "volume" | "brightness" | "mic"
    property real   value:   0.0         // 0..1 bar fill
    property bool   muted:   false
    property string glyph:   ""
    property string label:   ""
    property bool   showing: false

    property bool windowVisible: false

    // ── Startup suppression ───────────────────────────────────
    property bool _booting: true
    Timer { id: bootGuard; interval: 900; onTriggered: root._booting = false }

    function _blocked() {
        // Don't show during startup, or while the audio / quick-control
        // popups are open — they already give live feedback.
        return root._booting || Popups.audioOpen || Popups.quickOpen
    }

    // ── Show / hide ───────────────────────────────────────────
    function _trigger(k, v, mut, g, lbl) {
        root.kind    = k
        root.value   = Math.max(0.0, Math.min(1.0, v))
        root.muted   = mut
        root.glyph   = g
        root.label   = lbl
        root.windowVisible = true
        root.showing = true
        hideTimer.restart()
    }

    Timer { id: hideTimer; interval: 1300; onTriggered: root.showing = false }
    Timer { id: goneTimer; interval: root.showAnim + 60
            onTriggered: if (!root.showing) root.windowVisible = false }
    onShowingChanged: if (!showing) goneTimer.restart()

    Component.onCompleted: {
        bootGuard.start()
        brightRead.running = true   // startup prime + backlight discovery
    }

    // ── Audio: default sink (volume + mute) ───────────────────
    readonly property var sink: Pipewire.defaultAudioSink
    PwObjectTracker { objects: root.sink ? [root.sink] : [] }

    property var  _primedSink: null
    property real _lastVol:    -1
    property bool _lastMuted:  false

    Connections {
        target:               root.sink?.audio ?? null
        ignoreUnknownSignals: true
        // PwNodeAudio.volume notifies via `volumesChanged` (per-channel signal).
        function onVolumesChanged() { root._onVol() }
        function onMutedChanged()   { root._onMute() }
    }

    // Prime the sink's baseline as soon as it's ready (and on any sink swap),
    // so the user's first real change isn't swallowed by the "new sink" guard.
    onSinkChanged: root._primeSink()
    Connections {
        target:               root.sink ?? null
        ignoreUnknownSignals: true
        function onReadyChanged() { root._primeSink() }
    }
    function _primeSink() {
        var s = root.sink
        if (!s || !s.ready || !s.audio || s === root._primedSink) return
        root._primedSink = s
        root._lastVol    = s.audio.volume
        root._lastMuted  = s.audio.muted
    }

    function _volGlyph(v, m) {
        if (m)         return "󰝟"
        if (v > 0.6)   return "󰕾"
        if (v > 0.2)   return "󰖀"
        return "󰕿"
    }

    function _onVol() {
        var s = root.sink
        if (!s || !s.ready || !s.audio) return
        var v = s.audio.volume
        // A changed/new default sink primes silently (no OSD on switch).
        if (s !== root._primedSink) {
            root._primedSink = s
            root._lastVol    = v
            root._lastMuted  = s.audio.muted
            return
        }
        if (Math.abs(v - root._lastVol) < 0.0005) return
        root._lastVol = v
        if (root._blocked()) return
        root._trigger("volume", v, s.audio.muted,
                      root._volGlyph(v, s.audio.muted),
                      Math.round(v * 100) + "%")
    }

    function _onMute() {
        var s = root.sink
        if (!s || !s.ready || !s.audio) return
        if (s !== root._primedSink) {
            root._primedSink = s
            root._lastVol    = s.audio.volume
            root._lastMuted  = s.audio.muted
            return
        }
        if (root._lastMuted === s.audio.muted) return
        root._lastMuted = s.audio.muted
        if (root._blocked()) return
        root._trigger("volume", s.audio.volume, s.audio.muted,
                      root._volGlyph(s.audio.volume, s.audio.muted),
                      Math.round(s.audio.volume * 100) + "%")
    }

    // ── Audio: default source (mic-mute) ──────────────────────
    readonly property var source: Pipewire.defaultAudioSource
    PwObjectTracker { objects: root.source ? [root.source] : [] }

    property var  _primedSource: null
    property bool _lastMicMuted: false

    Connections {
        target:               root.source?.audio ?? null
        ignoreUnknownSignals: true
        function onMutedChanged() { root._onMicMute() }
    }

    onSourceChanged: root._primeSource()
    Connections {
        target:               root.source ?? null
        ignoreUnknownSignals: true
        function onReadyChanged() { root._primeSource() }
    }
    function _primeSource() {
        var s = root.source
        if (!s || !s.ready || !s.audio || s === root._primedSource) return
        root._primedSource = s
        root._lastMicMuted = s.audio.muted
    }

    function _onMicMute() {
        var s = root.source
        if (!s || !s.ready || !s.audio) return
        if (s !== root._primedSource) {
            root._primedSource = s
            root._lastMicMuted = s.audio.muted
            return
        }
        if (root._lastMicMuted === s.audio.muted) return
        root._lastMicMuted = s.audio.muted
        if (root._blocked()) return
        var m = s.audio.muted
        root._trigger("mic", m ? 0.0 : 1.0, m,
                      m ? "󰍭" : "󰍬", m ? "Muted" : "On")
    }

    // ── Brightness: backlight sysfs watch ─────────────────────
    // brightnessctl -m → "name,class,current,percent,max"; p[0] also gives
    // us the backlight device name so the FileView can watch its sysfs
    // `brightness` file. inotify fires on every write (hardware keys too).
    property string backlightDevice: ""
    readonly property string brightnessPath:
        backlightDevice !== ""
            ? "/sys/class/backlight/" + backlightDevice + "/brightness"
            : ""
    property bool _brightPrimed: false

    Process {
        id: brightRead
        command: ["bash", "-c", "brightnessctl -m"]
        running: false
        stdout: SplitParser {
            onRead: function(line) {
                var p = line.split(",")
                if (p.length < 5) return
                if (root.backlightDevice === "") root.backlightDevice = p[0].trim()
                var cur = parseInt(p[2])
                var max = parseInt(p[4])
                if (max > 0 && !isNaN(cur)) root._applyBright(cur / max)
            }
        }
    }

    FileView {
        id: brightWatch
        path:          root.brightnessPath
        watchChanges:  true
        // Change notifier only — the value is (re)read via brightnessctl.
        onFileChanged: { brightRead.running = false; brightRead.running = true }
    }

    function _applyBright(v) {
        // First (startup) read primes silently; later ones show the OSD.
        if (!root._brightPrimed) { root._brightPrimed = true; return }
        if (root._blocked()) return
        root._trigger("brightness", v, false, "󰃠", Math.round(v * 100) + "%")
    }

    // ── Pill ──────────────────────────────────────────────────
    Item {
        id: pill
        width:  root.pillW
        height: root.pillH
        anchors.horizontalCenter: parent.horizontalCenter

        y:       root.showing ? root.slideRoom : 0
        opacity: root.showing ? 1 : 0
        Behavior on y       { NumberAnimation { duration: root.showAnim; easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: root.showAnim; easing.type: Easing.OutCubic } }

        Rectangle {
            id: bg
            anchors.fill: parent
            radius:       Theme.cornerRadius
            color:        Theme.background
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.06)
        }

        // Icon
        Text {
            id: iconText
            anchors.left:           parent.left
            anchors.leftMargin:     16
            anchors.verticalCenter: parent.verticalCenter
            text:           root.glyph
            font.pixelSize: 18
            color:          root.muted ? Theme.subtext : Theme.text
            Behavior on color { ColorAnimation { duration: 150 } }
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
            font.pixelSize: 13
            font.bold:      true
            color:          root.muted ? Theme.subtext : Theme.text
            Behavior on color { ColorAnimation { duration: 150 } }
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
                color:        Qt.rgba(1, 1, 1, 0.10)

                Rectangle {
                    anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                    width:  Math.max(parent.height, parent.width * root.value)
                    radius: parent.radius
                    color:  root.muted ? Qt.rgba(1, 1, 1, 0.20) : Theme.active
                    Behavior on width { NumberAnimation { duration: root.valAnim; easing.type: Easing.OutCubic } }
                    Behavior on color { ColorAnimation  { duration: 150 } }
                }
            }
        }
    }
}
