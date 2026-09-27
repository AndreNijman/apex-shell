pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Services.Pipewire
import "../"
import "../services"
import "../nexus"

// ─────────────────────────────────────────────────────────────────────────────
// OsdState — what the volume / brightness / mic-mute display is showing, and
// whether it is showing at all. One for the whole shell.
//
// It used to be a floating capsule (popups/Osd.qml) that detected changes and
// drew itself below the notch. Andre, 2026-09-27: "make it actually part of
// the top notch, like clean and part of the top notch, following the proper
// design of apex." So the detection lives here and the NOTCH draws it
// (modules/Center/NotchOsd.qml inside TopBar: the island widens and the level
// scrolls in like any other island item). The capsule is kept only for where
// there is no notch to draw in — a fullscreen window unmaps the bar, focus
// mode empties it — and for when the Dashboard or the Nexus is pouring out of
// the centre notch, whose width they read live (`inNotch` below).
//
// Change detection (unchanged from the capsule):
//   • volume / mute → Pipewire.defaultAudioSink.audio {volume,muted}
//   • brightness    → BrightnessService.changedExternally (inotify on the
//                     backlight's sysfs file; the shell's own slider writes do
//                     not raise it)
//   • mic-mute      → Pipewire.defaultAudioSource.audio.muted
// Startup is suppressed two ways: a boot-grace timer AND a per-channel
// "primed" step that swallows the first settled value. Nothing shows while the
// audio panel or the quick controls are open: they already give live feedback.
// ─────────────────────────────────────────────────────────────────────────────
Singleton {
    id: root

    // ── What is on display ───────────────────────────────────
    property string kind:    "volume"   // "volume" | "brightness" | "mic"
    property real   value:   0.0         // 0..1 bar fill
    property bool   muted:   false
    property string glyph:   ""
    property string label:   ""
    property bool   showing: false

    // Where: in the centre notch, unless something is pouring out of it. A
    // screen whose bar is unmapped (fullscreen) or empty (focus mode) uses the
    // capsule regardless — that part is per screen (popups/Osd.qml, TopBar).
    readonly property bool inNotch: !Popups.dashboardOpen && !NexusState.open

    // ── Startup suppression ───────────────────────────────────
    property bool _booting: true
    property Timer _bootGuard: Timer { interval: 900; running: true; onTriggered: root._booting = false }

    function _blocked() {
        return root._booting || Popups.audioOpen || Popups.quickOpen
    }

    // ── Show / hide ───────────────────────────────────────────
    function _trigger(k, v, mut, g, lbl) {
        root.kind    = k
        root.value   = Math.max(0.0, Math.min(1.0, v))
        root.muted   = mut
        root.glyph   = g
        root.label   = lbl
        root.showing = true
        root._hide.restart()
    }
    property Timer _hide: Timer { interval: 1300; onTriggered: root.showing = false }

    // ── Audio: default sink (volume + mute) ───────────────────
    readonly property var sink: Pipewire.defaultAudioSink
    property PwObjectTracker _sinkTracker: PwObjectTracker { objects: root.sink ? [root.sink] : [] }

    property var  _primedSink: null
    property real _lastVol:    -1
    property bool _lastMuted:  false

    property Connections _sinkAudio: Connections {
        target:               root.sink?.audio ?? null
        ignoreUnknownSignals: true
        // PwNodeAudio.volume notifies via `volumesChanged` (per-channel signal).
        function onVolumesChanged() { root._onVol() }
        function onMutedChanged()   { root._onMute() }
    }
    // Prime the sink's baseline as soon as it's ready (and on any sink swap),
    // so the user's first real change isn't swallowed by the "new sink" guard.
    onSinkChanged: root._primeSink()
    property Connections _sinkReady: Connections {
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

    function volGlyph(v, m) {
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
        root._trigger("volume", v, s.audio.muted, root.volGlyph(v, s.audio.muted), Math.round(v * 100) + "%")
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
                      root.volGlyph(s.audio.volume, s.audio.muted),
                      Math.round(s.audio.volume * 100) + "%")
    }

    // ── Audio: default source (mic-mute) ──────────────────────
    readonly property var source: Pipewire.defaultAudioSource
    property PwObjectTracker _sourceTracker: PwObjectTracker { objects: root.source ? [root.source] : [] }

    property var  _primedSource: null
    property bool _lastMicMuted: false

    property Connections _sourceAudio: Connections {
        target:               root.source?.audio ?? null
        ignoreUnknownSignals: true
        function onMutedChanged() { root._onMicMute() }
    }
    onSourceChanged: root._primeSource()
    property Connections _sourceReady: Connections {
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
        root._trigger("mic", m ? 0.0 : 1.0, m, m ? "󰍭" : "󰍬", m ? "Muted" : "On")
    }

    // ── Brightness ────────────────────────────────────────────
    property Connections _brightness: Connections {
        target: BrightnessService
        function onChangedExternally(value) {
            if (root._blocked()) return
            root._trigger("brightness", value, false, "󰃠", Math.round(value * 100) + "%")
        }
    }
}
