import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pam
import "../"
import "../services/"
import "../components/auth"

// ─────────────────────────────────────────────────────────────
// Lockscreen — native Wayland session lock, replaces hyprlock.
//
// Instantiated ONCE at the ShellRoot top level (NOT per-screen): the
// WlSessionLock manages one WlSessionLockSurface per output itself via
// its surface delegate.
//
// Engages when LockState.locked === true (set by the "lockscreen" IPC
// handler, PowerMenu, or hypridle → loginctl lock-session). The ONLY
// path back to unlocked is a successful PAM authentication inside the
// surface — IPC unlock() is a guarded no-op by design.
//
// Safety: every surface delegate guards against undefined access. A
// missing wallpaper falls back to a Colors-derived gradient; a missing
// or broken PAM service surfaces as on-screen error text rather than an
// unhandled exception that could take the whole shell down while locked.
// ─────────────────────────────────────────────────────────────

WlSessionLock {
    id: sessionLock

    // Bind to the global flag. Success inside the surface sets
    // LockState.locked = false, which unwinds this binding and releases
    // the compositor lock.
    locked: LockState.locked

    // Mirror the compositor-ACKNOWLEDGED lock state to logind, so
    // `loginctl show-session -p LockedHint` means something — P0-015's
    // lock-state policy for autonomous sessions keys off exactly that
    // property, and until now nothing ever set it. Bound to `secure`, not to
    // `locked` above: `secure` only flips once ext-session-lock has actually
    // engaged (or been released), so a lock that fails to engage is never
    // reported to logind as engaged. See LockedHintService for why this has
    // to be the shell's job and not apexd's.
    onSecureStateChanged: {
        LockedHintService.setLocked(sessionLock.secure)
        LockState.lockSecure = sessionLock.secure
        if (Motion.pacingLog) console.info("APEX pacing: lock secure=" + sessionLock.secure)
    }

    // The initial sync, and the reason it cannot live in the service itself.
    //
    // `onSecureStateChanged` only fires on a CHANGE, so a shell that starts up
    // while logind still believes the session locked — a crash, a restart, a
    // `quickshell` reload mid-lock — would leave the hint reading `yes` until
    // somebody locked and unlocked the screen by hand. apex-agentd polls that
    // property, so the stale value is not cosmetic: it holds Remote Control
    // sessions and revokes root grants while the owner is sitting in front of
    // the machine.
    //
    // A fresh shell has no lock surface up, so `secure` is false here by
    // construction — ext-session-lock only sets it once the compositor has
    // acknowledged THIS client's lock. Pushing it anyway is what clears a
    // stale `yes`, and `_confirmed` starts undefined so the first call always
    // reaches logind rather than being suppressed as a no-op.
    //
    // This is also the only thing that brings the singleton into existence at
    // startup: Quickshell creates a Singleton on first reference, not when the
    // configuration loads — measured, not assumed, in
    // tests/run-locked-hint-test.sh. A `Component.onCompleted` inside
    // LockedHintService would therefore not run until something else had
    // already used it, which on this path is the lock it exists to report.
    Component.onCompleted: LockedHintService.setLocked(sessionLock.secure)

    // ── Release, after the exit has played ──────────────────────────────
    // Called ONLY from a surface's PAM success. The lock UI plays its exit
    // (clock lifting, field fading, the wallpaper sharpening back into the
    // desktop's) over UnlockCurtain, which has held the desktop wallpaper
    // behind the lock since it engaged; then the lock lets go and the curtain
    // fades the desktop in. The
    // timer IS the release, unconditionally: nothing it waits on can hold the
    // session locked after a correct password (under Reduce Motion it is one
    // millisecond).
    function release() {
        if (!LockState.locked || LockState.unlocking) return
        LockState.unlocking = true
        sessionLock._release.interval = Math.max(1, Motion.morphExit)
        sessionLock._release.restart()
    }
    property Timer _release: Timer {
        repeat: false
        onTriggered: {
            // A lock asked for since the password (LockState.lock()) cancelled
            // the release: stay locked.
            if (!LockState.unlocking) return
            LockState.unlocking = false
            LockState.locked = false
        }
    }

    // ── Per-output lock surface ──────────────────────────────────────
    WlSessionLockSurface {
        id: surface

        // One surface per output, so the sizes are that output's (P1-040). The
        // declaration is here rather than on the WlSessionLock above because
        // the lock object is not a window and has no screen; the surface is and
        // does. A lock screen is the one surface where a mixed-DPI desk is
        // guaranteed to be showing all of them at once.
        readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForScreen(surface.screen) }

        // Opaque base so there is never a transparent flash before the
        // wallpaper/gradient paints.
        color: "black"

        // ── Per-surface auth state ───────────────────────────────────
        property string password:   ""
        property bool   checking:    false   // PAM conversation in flight
        property bool   hasError:    false   // last attempt failed
        property string errorText:   ""
        property bool   capsOn:      false
        property real   shakeOffset: 0

        // Username for display only (PAM resolves the auth user itself).
        property string username: ""

        // ── PAM authentication ───────────────────────────────────────
        // config "system-auth" → /etc/pam.d/system-auth on Void, whose auth
        // stack is a bare `pam_unix.so` password check — the correct locker
        // semantics. (The alternative, "login", gates auth behind
        // pam_securetty + pam_nologin, which a screen locker must not depend
        // on.) `user` is left default so PamContext resolves the current
        // session user itself.
        PamContext {
            id: pam
            config: "system-auth"

            // PAM asks for the password via a hidden-response prompt; reply
            // with the buffered text as soon as a response is required.
            onResponseRequiredChanged: {
                if (responseRequired && surface.checking)
                    respond(surface.password)
            }

            onCompleted: function(result) {
                surface.checking = false
                if (result === PamResult.Success) {
                    // The one and only unlock path (release() is the flip).
                    surface.password = ""
                    sessionLock.release()
                } else if (result === PamResult.MaxTries) {
                    surface.fail("Too many attempts — wait and retry")
                } else {
                    surface.fail("Wrong password")
                }
            }

            onError: function(err) {
                surface.checking = false
                surface.fail("Auth unavailable: " + PamError.toString(err))
            }
        }

        function tryAuth() {
            if (surface.checking) return
            if (surface.password.length === 0) return
            surface.hasError  = false
            surface.errorText = ""
            surface.checking  = true
            // start() returns false if the PAM conversation can't begin
            // (e.g. service file missing) — surface that instead of hanging.
            if (!pam.start()) {
                surface.checking = false
                surface.fail("PAM failed to start")
            }
        }

        function fail(msg) {
            // Clear the FIELD, not only the buffer. This used to empty
            // surface.password and leave the TextInput holding the rejected
            // attempt: the dots stayed, Enter did nothing (the buffer was
            // empty), and the next key appended to the wrong password. Cleared
            // before hasError is set, because clearing runs onTextChanged,
            // which drops hasError as soon as the user types.
            passwordInput.text = ""
            surface.password  = ""
            surface.hasError  = true
            surface.errorText = msg
            shakeAnim.restart()
            // Last, deliberately: see say() below.
            surface.say(msg)
        }

        // Say it out loud, rather than merely publishing it.
        //
        // `Accessible.description` on the field puts the live state in the
        // accessibility tree. It does not make a screen reader SPEAK it: a
        // reader does not generally announce a description change on the object
        // that already holds focus, so a blind user who typed a wrong password
        // got the red border, the shake, a line of red text — and silence. Qt
        // 6.8 added Accessible.announce() for exactly this case; the image
        // ships Qt 6.10.3, measured by the probe in
        // tests/check-lockscreen-a11y.sh rather than assumed.
        //
        // Guarded with a typeof, and called LAST in fail(), because this is the
        // lock screen: if a future Qt renames or drops the method, a user must
        // still get the border, the shake and the text. It is a no-op while
        // accessibility is not running — QAccessible::updateAccessibility
        // returns early — so it costs a sighted user nothing.
        function say(msg) {
            if (msg === "")
                return
            if (typeof passwordInput.Accessible.announce === "function")
                passwordInput.Accessible.announce(msg)
        }

        // Caps Lock is the single most common reason a correct password is
        // refused, and this screen reported it with a glyph and a colour — both
        // invisible to a reader. Announced on the TRANSITION, so it is said
        // once rather than on every keystroke.
        onCapsOnChanged: if (surface.capsOn) surface.say("Caps Lock is on")

        // ── Resolve username for display (best-effort, non-fatal) ─────
        Process {
            id: userProc
            command: ["bash", "-c", "echo \"$USER\""]
            running: true
            stdout: SplitParser {
                onRead: function(line) {
                    var t = line.trim()
                    if (t !== "") surface.username = t
                }
            }
        }

        // ── Live clock ───────────────────────────────────────────────
        // Bound to the shared Time singleton (ClockState is island
        // timer/alarm state, not wall-clock time). Neither field shows
        // seconds, so minute precision is all that is required — this
        // used to be a 1 Hz Timer that ran for the whole session even
        // though the lock surface only exists while locked, and it woke
        // the process 59 times a minute to redraw nothing.
        // 12 or 24 h (SettingsService.clockFormat); a 12-hour AM/PM is drawn
        // beside the digits, small, not at the clock's 120 px.
        readonly property string timeText: Time.clock(false, false)
        readonly property string dateText: Time.format("dddd, d MMMM")

        // ── Arrival and departure: the notch pours down (2026-09-27) ────
        // The lock surface is opaque from its first frame — that is the
        // security property and nothing here touches it. What moves is drawn
        // on it.
        //
        // Andre, twice: "make the transition to lock screen actually cleaner
        // and sleek not just fading", then, of a desktop that drew back and
        // dissolved: "It's still just fading. I want a real animation." So
        // nothing here dissolves the desktop. The shell's surfaces pour out
        // of the notch, and so does the lock: its first frame is the notch
        // itself — a notch-coloured shape exactly over the bar's notch — which
        // spreads into a band, then falls down the screen, its lower corners
        // rounding into a drop and flattening as it lands, carrying the lock's
        // blurred backdrop in with it. Underneath, the desktop as it was
        // (windows/LockCapture.qml's picture, or the bare wallpaper without
        // one) sinks and darkens and is COVERED, never faded. The clock and
        // the card ride in once the shade is most of the way down.
        //
        // A correct password plays it backwards (`leave`): the shade retracts
        // up into the notch over the sharp wallpaper, which is exactly what
        // UnlockCurtain holds behind the lock, and the lock lets go.
        //
        // `enter` and `leave` are plain time; each part shapes its share of
        // it. Under Reduce Motion nothing travels: the shade is whole and
        // fades in and out.
        property real enter: 0
        property real leave: LockState.unlocking ? 1 : 0
        Behavior on leave {
            NumberAnimation { duration: Motion.morphExit; easing.type: Easing.Linear }
        }
        NumberAnimation {
            id: enterAnim
            target: surface; property: "enter"; from: 0; to: 1
            duration: Motion.reduced ? Motion.fadeIn : Motion.hero
            easing.type: Easing.Linear
        }
        // APEX_PACING_LOG: the arrival's own frames (count, worst gap), the
        // measurement a recording of a nested session cannot make.
        property var _pace: ({ n: 0, worst: 0, last: 0 })
        property Connections _paceFrames: Connections {
            target: (Motion.pacingLog && enterAnim.running) ? content.Window.window : null
            ignoreUnknownSignals: true
            function onFrameSwapped() {
                const now = Date.now(), p = surface._pace
                if (p.last > 0) { p.worst = Math.max(p.worst, now - p.last); p.gaps = (p.gaps || "") + (now - p.last) + "," }
                p.last = now; p.n += 1
            }
        }
        property Connections _paceEnd: Connections {
            target: Motion.pacingLog ? enterAnim : null
            function onRunningChanged() {
                if (enterAnim.running) { surface._pace = { n: 0, worst: 0, last: 0 }; return }
                console.info("APEX pacing: lock arrival frames=" + surface._pace.n + " worst="
                             + surface._pace.worst + "ms over " + enterAnim.duration + "ms gaps=" + (surface._pace.gaps || ""))
            }
        }
        // Started once the surface is on screen, not at its creation: the
        // frames before that are never seen, and a clock started at creation
        // spent the start of the arrival in them (measured in a nested
        // Hyprland: the picture was half gone in the first frame shown). On
        // screen means both: this window has swapped a frame, and the
        // compositor has engaged the lock (`secure`) — a lock surface's first
        // frame is drawn before the compositor shows it, and it shows it only
        // once the lock holds. SurfaceLifecycle's guard covers a compositor
        // that reports neither.
        property bool _swapped: false
        property bool _presented: false
        property real _createdAt: 0
        property Connections _firstFrame: Connections {
            target: surface._swapped ? null : content.Window.window
            ignoreUnknownSignals: true
            function onFrameSwapped() { surface._swapped = true; surface._maybeArrive() }
        }
        property Connections _engaged: Connections {
            target: sessionLock
            function onSecureStateChanged() { surface._maybeArrive() }
        }
        property Timer _presentGuard: Timer { interval: 250; onTriggered: surface._arrive() }
        function _maybeArrive() { if (surface._swapped && sessionLock.secure) surface._arrive() }
        function _arrive() {
            if (surface._presented) return
            surface._presented = true
            surface._presentGuard.stop()
            if (Motion.pacingLog)
                console.info("APEX pacing: lock arrival start ms=" + (Date.now() - surface._createdAt)
                             + " picture=" + surface._fromCapture)
            enterAnim.restart()
        }

        // The desktop as it was: LockCapture's picture of this output, taken
        // just before the lock engaged. Read once per arrival; dropped the
        // frame the shade has covered it.
        property string capture: ""
        function _takeCapture() {
            const shots = LockState.captures
            const name = surface.screen ? surface.screen.name : ""
            surface.capture = (shots && name !== "" && shots[name]) ? String(shots[name]) : ""
        }
        readonly property bool _fromCapture: surface.capture !== "" && capImg.status === Image.Ready
        on_ShadeHChanged: if (surface._shadeH >= 0.999 && surface.leave === 0 && surface.capture !== "") surface.capture = ""

        function _clamp01(v) { return Math.max(0, Math.min(1, v)) }
        readonly property bool _still: Motion.reduced || Motion.hero <= 0
        // The shade's spread (width) and fall (height), 0 = the notch, 1 = the
        // screen. Width leads: a band first, then down. Leaving, the fall
        // retracts first and the band draws in last.
        readonly property real _shadeW: surface._still ? 1
            : surface.leave > 0 ? 1 - Motion.ease(Motion.emphasizedAccel, surface._clamp01((surface.leave - 0.45) / 0.55))
            : Motion.ease(Motion.emphasizedDecel, surface._clamp01(surface.enter / 0.5))
        readonly property real _shadeH: surface._still ? 1
            : surface.leave > 0 ? 1 - Motion.ease(Motion.emphasizedAccel, surface._clamp01(surface.leave / 0.75))
            : Motion.ease(Motion.emphasized, surface._clamp01((surface.enter - 0.08) / 0.92))
        // Under Reduce Motion the whole shade fades instead. Leaving, the
        // notch it has become fades in the last fifth: the lock's last frame
        // is then the sharp wallpaper, which is what UnlockCurtain shows the
        // moment the lock lets go — no shape left to pop out.
        readonly property real _shadeAlpha: surface._still ? surface.enter * (1 - surface.leave)
            : 1 - surface._clamp01((surface.leave - 0.8) / 0.2)
        // The notch colour it starts as, dissolving into the backdrop as it spreads.
        readonly property real _notchInk: surface._still ? 0
            : 1 - Motion.ease(Motion.standard, surface._clamp01(Math.min(surface._shadeW, surface._shadeH * 4)))
        // The shade's rectangle, in this surface's pixels.
        readonly property real _sw: theme.cNotchMinWidth + (surface.width - theme.cNotchMinWidth) * surface._shadeW
        readonly property real _sh: theme.notchHeight + (surface.height - theme.notchHeight) * surface._shadeH
        // Lower corners: the notch's own, a drop's while it falls, square as it lands.
        readonly property real _sr: (theme.notchBottom + (theme.px(64) - theme.notchBottom) * surface._shadeW)
                                    * (1 - surface._shadeH)

        // The clock and the card, once the shade is most of the way down.
        readonly property real _clock: surface._still ? surface.enter
            : Motion.ease(Motion.emphasizedDecel, surface._clamp01((surface.enter - 0.45) / 0.55))
        readonly property real _card:  surface._still ? surface.enter
            : Motion.ease(Motion.emphasizedDecel, surface._clamp01((surface.enter - 0.55) / 0.45))

        // ── Content root ─────────────────────────────────────────────
        Item {
            id: content
            anchors.fill: parent
            focus: true

            // Any stray keystroke lands in the password field.
            Keys.forwardTo: [passwordInput]

            // Wallpaper texture source (hidden; fed into the blur effect).
            //
            // SettingsService.lockBackground overrides the desktop wallpaper so
            // the lock screen can show something else (or something the desktop
            // wallpaper rotation will not clobber). Empty means "follow the
            // desktop wallpaper", which is the historical behaviour. A path that
            // fails to load falls through to the gradient in the shade, exactly
            // as a broken wallpaper path already did.
            Image {
                id: wallImg
                anchors.fill: parent
                source: {
                    const override = SettingsService.lockBackground
                    if (override && override !== "")
                        return override.startsWith("/") ? "file://" + override : override
                    const wall = WallpaperService.currentWall
                    return wall && wall !== "" ? "file://" + wall : ""
                }
                fillMode:     Image.PreserveAspectCrop
                asynchronous: true
                cache:        true
                visible:      false
            }

            // ── Under the shade: the desktop as it was ───────────────
            // Synchronous: the picture is already decoded in the pixmap cache
            // (LockCapture) and the first frame has to have it. Same URL and
            // default fill mode as the preload, or the cache misses and the
            // file is already gone.
            Item {
                id: under
                anchors.fill: parent
                visible: surface._shadeH < 0.999 || surface._shadeW < 0.999 || surface._shadeAlpha < 1
                // Sinks as the shade falls over it.
                scale: surface._still ? 1 : 1 - 0.06 * surface._shadeH * (surface.leave > 0 ? 0 : 1)

                Image {
                    id: capImg
                    anchors.fill: parent
                    source:       surface.capture
                    asynchronous: false
                    cache:        true
                }
                // Without a picture, and on the way out: the wallpaper, sharp —
                // the desktop's own, and what UnlockCurtain holds behind the lock.
                Image {
                    anchors.fill: parent
                    visible:      !surface._fromCapture
                    source:       wallImg.source
                    fillMode:     Image.PreserveAspectCrop
                    asynchronous: true
                    cache:        true
                }
                // A scrim, like the shade's own (not a theme colour).
                Rectangle {
                    anchors.fill: parent
                    color: Qt.rgba(0, 0, 0, 1)
                    opacity: surface._still ? 0 : 0.5 * surface._shadeH * (surface.leave > 0 ? 0 : 1)
                }
            }

            // The shade's edge throws a shadow on what it is falling over.
            Rectangle {
                visible: !surface._still && surface._shadeH < 0.999
                x: (surface.width - surface._sw) / 2
                y: surface._sh - theme.px(8)
                width: surface._sw
                height: theme.px(72)
                opacity: 0.55 * Math.min(1, surface._shadeH * 6)
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.6) }
                    GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0) }
                }
            }

            // ── The shade: the lock's own backdrop, masked to its shape ──
            // Nothing inside this layer changes while the shade moves, so the
            // full-screen blur is rendered once and every frame of the pour is
            // one masked composite. (A parallax shift on the wallpaper in here
            // re-rendered the blur each frame: the shade moved at 20-30 fps in
            // the nested measurement. The shift now moves the whole effect.)
            Item {
                id: shade
                anchors.fill: parent
                visible: false
                layer.enabled: true

                // Colors-derived gradient: always present, so an empty or broken
                // wallpaper can never leave a blank (or transparent) lock.
                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        orientation: Gradient.Vertical
                        GradientStop { position: 0.0; color: Qt.darker(Theme.background, 1.15) }
                        GradientStop { position: 1.0; color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 1.0) }
                    }
                }
                // Blurred + dimmed wallpaper.
                MultiEffect {
                    anchors.fill: parent
                    source:       wallImg
                    visible:      wallImg.status === Image.Ready
                    blurEnabled:  true
                    blur:         1.0
                    blurMax:      48
                    brightness:  -0.30
                    saturation:  -0.10
                }
                // Extra scrim for legibility.
                Rectangle {
                    anchors.fill: parent
                    color: Qt.rgba(0, 0, 0, 0.35)
                }
            }
            // Its shape: top-anchored (the rectangle reaches above the screen by
            // its radius, so only the lower corners round), centred.
            // The backdrop rides down with the shade a little (a sheet being
            // drawn down, not a window onto a still picture): the whole effect
            // is shifted up by _drift and the mask down by as much, so the
            // shape stays where it is and only what is inside it moves.
            readonly property real _drift: surface._still ? 0 : theme.px(90) * (1 - surface._shadeH)
            Item {
                id: shadeMask
                anchors.fill: parent
                visible: false
                layer.enabled: true
                Rectangle {
                    x: (surface.width - surface._sw) / 2
                    y: -surface._sr + content._drift
                    width: surface._sw
                    height: surface._sh + surface._sr
                    radius: surface._sr
                    color: Theme.background   // the mask reads only its coverage
                    antialiasing: true
                }
            }
            MultiEffect {
                anchors.fill: parent
                source:      shade
                opacity:     surface._shadeAlpha
                maskEnabled: true
                maskSource:  shadeMask
                transform: Translate { y: -content._drift }
            }
            // The notch it starts as: the same shape in the bar's colour,
            // dissolving as it spreads.
            Rectangle {
                visible: surface._notchInk > 0.001
                x: (surface.width - surface._sw) / 2
                y: -surface._sr
                width: surface._sw
                height: surface._sh + surface._sr
                radius: surface._sr
                color: Theme.background
                opacity: surface._notchInk * surface._shadeAlpha
                antialiasing: true
            }

            // Clicking anywhere re-focuses the password field.
            MouseArea {
                anchors.fill: parent
                onClicked: passwordInput.forceActiveFocus()
            }

            // ── Clock + date ─────────────────────────────────────────
            Column {
                id: clockBlock
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom:           card.top
                anchors.bottomMargin:     56
                spacing: 4
                // Gone in the first part of the retract, before the shade lifts past them.
                opacity: surface._clock * (1 - surface._clamp01(surface.leave * 2.5))
                transform: Translate {
                    y: (1 - surface._clock) * -Motion.travel(theme.px(28))
                       - surface.leave * Motion.travel(theme.px(18))
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: theme.px(10)
                    Text {
                        id: bigTime
                        text:           surface.timeText
                        color:          Theme.text
                        font.family:    "JetBrainsMono Nerd Font"
                        font.pixelSize: theme.fs(120)
                        font.bold:      true
                    }
                    Text {
                        visible:        Time.meridiem !== ""
                        text:           Time.meridiem
                        color:          Theme.subtext
                        font.family:    "JetBrainsMono Nerd Font"
                        font.pixelSize: theme.fs(28)
                        font.bold:      true
                        anchors.baseline: bigTime.baseline
                    }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text:           surface.dateText
                    color:          Theme.subtext
                    font.family:    "JetBrainsMono Nerd Font"
                    font.pixelSize: theme.fs(22)
                }
            }

            // ── Auth card ────────────────────────────────────────────
            Column {
                id: card
                anchors.centerIn: parent
                anchors.verticalCenterOffset: 90
                spacing: 14
                opacity: surface._card * (1 - surface._clamp01(surface.leave * 2.5))
                scale: Motion.reduced ? 1 : 0.97 + 0.03 * surface._card - 0.02 * surface.leave
                transform: Translate {
                    x: surface.shakeOffset
                    y: (1 - surface._card) * Motion.travel(theme.px(28))
                }

                // Username
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text:           surface.username !== "" ? surface.username : "Locked"
                    color:          Theme.text
                    font.family:    "JetBrainsMono Nerd Font"
                    font.pixelSize: theme.fs(20)
                    font.bold:      true
                }

                // Password field
                Rectangle {
                    id: field
                    anchors.horizontalCenter: parent.horizontalCenter
                    width:  340
                    height: 52
                    radius: height / 2
                    color:  Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.55)
                    border.width: 2
                    border.color: surface.hasError
                                      ? Theme.danger
                                      : (passwordInput.activeFocus ? Theme.active : Theme.border)
                    Behavior on border.color { MotionColor { role: "state" } }

                    // Lock glyph
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left:           parent.left
                        anchors.leftMargin:     18
                        text:  "󰌾"
                        color: Theme.subtext
                        font.family:    "JetBrainsMono Nerd Font"
                        font.pixelSize: theme.fs(18)

                        // A drawing, not a word. This is a private-use
                        // codepoint: a reader that reaches it says "private use
                        // character F033E", or whatever its font calls it,
                        // before the field it decorates. Qt Quick gives a bare
                        // Text the StaticText role and its own text as its name,
                        // so silence here has to be asked for.
                        Accessible.ignored: true
                    }

                    TextInput {
                        id: passwordInput
                        anchors.fill:            parent
                        anchors.leftMargin:      46
                        anchors.rightMargin:     52
                        verticalAlignment:       TextInput.AlignVCenter
                        clip:                    true
                        enabled:                 !surface.checking
                        focus:                   true
                        // The field draws nothing of its own: what it holds is
                        // shown by PasswordShapes below, which is given its
                        // LENGTH and nothing else. Still a masked field with no
                        // echo delay, so no character exists on screen even for
                        // the frame before the shapes hide it; transparent so
                        // the mask characters, the cursor and a selection are
                        // not painted on top of the shapes.
                        color:                   "transparent"
                        selectionColor:          "transparent"
                        selectedTextColor:       "transparent"
                        // The caret is NOT painted in `color` — it would sit
                        // where the invisible mask characters end, a bar
                        // floating left of the shapes. The shapes are the
                        // position; the caret is drawn by nothing.
                        cursorDelegate:          Item {}
                        font.family:             "JetBrainsMono Nerd Font"
                        font.pixelSize:          theme.fs(18)
                        echoMode:                TextInput.Password
                        passwordCharacter:       "●"
                        passwordMaskDelay:       0
                        activeFocusOnPress:      true

                        // ── What a screen reader is told about this field ──
                        //
                        // `passwordEdit` is the load-bearing one: it is what
                        // tells an assistive technology that this box holds a
                        // secret, so it must not echo, log or braille what is
                        // typed into it. `echoMode` hides the text from the
                        // screen; it says nothing to the tree.
                        //
                        // The description carries the LIVE state, in the order
                        // a user needs it: in-flight first, because that is the
                        // state in which the field refuses input; then why the
                        // last attempt was refused; then Caps Lock, which was
                        // reported on this screen by a red glyph alone. It is
                        // deliberately never the field's contents — see the
                        // "must never be told" section of
                        // tests/check-lockscreen-a11y.sh.
                        Accessible.role:         Accessible.EditableText
                        Accessible.passwordEdit: true
                        Accessible.name:         "Password"
                        Accessible.description:  surface.checking ? "Checking your password."
                                               : surface.hasError ? surface.errorText
                                               : surface.capsOn   ? "Caps Lock is on."
                                               : "Type your password and press Enter to unlock."

                        // Mirror the buffer into surface state (used by PAM).
                        onTextChanged: {
                            surface.password = text
                            if (surface.hasError) surface.hasError = false
                        }

                        // Enter submits.
                        onAccepted: surface.tryAuth()

                        Keys.onPressed: function(event) {
                            if (event.key === Qt.Key_Escape) {
                                text = ""
                                event.accepted = true
                                return
                            }
                            if (event.key === Qt.Key_CapsLock) {
                                // Best-effort toggle tracking (initial state
                                // isn't queryable; the case heuristic below
                                // corrects it as soon as a letter is typed).
                                surface.capsOn = !surface.capsOn
                                return
                            }
                            // Caps-Lock detection via typed-character case:
                            // an unshifted letter arriving uppercase (or a
                            // shifted letter arriving lowercase) means Caps is on.
                            if (event.text.length === 1) {
                                var c = event.text
                                var isLower = (c >= "a" && c <= "z")
                                var isUpper = (c >= "A" && c <= "Z")
                                var shift   = (event.modifiers & Qt.ShiftModifier) !== 0
                                if (isLower || isUpper)
                                    surface.capsOn = shift ? isLower : isUpper
                            }
                        }

                        // Placeholder. Waits for the shapes to have actually
                        // gone, so it never draws over a row that is leaving.
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left:           parent.left
                            visible: shapes.empty && !surface.checking
                            text:  "Enter password"
                            color: Theme.subtext
                            font.family:    passwordInput.font.family
                            font.pixelSize: passwordInput.font.pixelSize

                            // A hint drawn INSIDE the field, not a second label
                            // for it. Left alone, Qt Quick would announce this
                            // as its own StaticText immediately after the
                            // field's own name — two labels for one box, one of
                            // which disappears the moment a key is pressed.
                            Accessible.ignored: true
                        }
                    }

                    // What the field holds, as shapes — one per character,
                    // chosen by position, never by what was typed. Same
                    // component the login screen loads (apex-greet).
                    PasswordShapes {
                        id: shapes
                        anchors.fill:        passwordInput
                        length:              passwordInput.length
                        accent:              Theme.active
                        text:                Theme.text
                        background:          Theme.background
                        danger:              Theme.danger
                        error:               surface.hasError
                        busy:                surface.checking
                        // The raw settings, resolved inside by the motion
                        // table — the same three the login screen is handed.
                        speed:               SettingsService.motionSpeed
                        motionScale:         SettingsService.motionScale
                        reduced:             SettingsService.reduceMotion
                        size:                18
                    }

                    // Spinner (shown while PAM is checking).
                    Item {
                        id: spinner
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.right:          parent.right
                        anchors.rightMargin:    16
                        width:  22
                        height: 22
                        visible: surface.checking

                        Rectangle {
                            anchors.fill: parent
                            radius: width / 2
                            color: "transparent"
                            border.width: 3
                            border.color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.25)
                        }
                        Rectangle {
                            width: 6; height: 6; radius: 3
                            color: Theme.active
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: -1
                        }
                        // A busy spinner, not decoration: it is the only sign
                        // the password is being checked, so it keeps turning
                        // under Reduce Motion and stops only with motion off.
                        RotationAnimator on rotation {
                            running: spinner.visible && Motion.loops
                            loops:   Animation.Infinite
                            from: 0; to: 360
                            duration: Motion.spinPeriod
                        }
                    }
                }

                // Status line — error message or caps-lock warning.
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    height:  18
                    text: surface.hasError ? surface.errorText
                        : (surface.capsOn ? "󰪛  Caps Lock is on" : "")
                    color: surface.hasError ? Theme.danger : Theme.subtext
                    font.family:    "JetBrainsMono Nerd Font"
                    font.pixelSize: theme.fs(14)

                    // The same line, spoken. Two differences from what is drawn,
                    // and both matter: the warning icon is a private-use
                    // codepoint and is dropped rather than spelled out, and the
                    // role is declared so this reaches the tree as text a reader
                    // will read instead of an unnamed item it may skip.
                    Accessible.role: Accessible.StaticText
                    Accessible.name: surface.hasError ? surface.errorText
                                   : (surface.capsOn ? "Caps Lock is on" : "")
                }
            }

            // ── Error shake ──────────────────────────────────────────
            SequentialAnimation {
                id: shakeAnim
                NumberAnimation { target: surface; property: "shakeOffset"; from: 0; to:  14; duration: Motion.errorShake }
                NumberAnimation { target: surface; property: "shakeOffset"; to: -14; duration: Motion.errorShake }
                NumberAnimation { target: surface; property: "shakeOffset"; to:  10; duration: Motion.errorShake }
                NumberAnimation { target: surface; property: "shakeOffset"; to: -10; duration: Motion.errorShake }
                NumberAnimation { target: surface; property: "shakeOffset"; to:   6; duration: Motion.errorShake }
                NumberAnimation { target: surface; property: "shakeOffset"; to:   0; duration: Motion.errorShake }
            }
        }

        // Grab keyboard focus as soon as the surface appears, and arrive.
        Component.onCompleted: {
            surface._createdAt = Date.now()
            surface._takeCapture()
            passwordInput.forceActiveFocus()
            surface._presentGuard.restart()
        }
        // A surface Quickshell shows again for a later lock arrives again.
        onVisibleChanged: if (visible) {
            surface._takeCapture()
            passwordInput.forceActiveFocus()
            enterAnim.stop()
            surface.enter = 0
            surface._createdAt = Date.now()
            surface._swapped = false
            surface._presented = false
            surface._presentGuard.restart()
        }
    }
}
