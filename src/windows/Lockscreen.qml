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
        sessionLock._release.interval = Math.max(1, Motion.surfaceExitSmall)
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
        readonly property string timeText: Time.format("hh:mm")
        readonly property string dateText: Time.format("dddd, d MMMM")

        // ── Arrival and departure (2026-09-26) ───────────────────────
        // The lock surface is opaque from its first frame — that is the
        // security property and nothing here touches it. What moves is on
        // top: the wallpaper starts sharp (the desktop's own) and blurs and
        // dims in, the clock drops into place, the field rises a beat after.
        // On a correct password it all plays back out (`leave`) before the
        // lock releases (sessionLock.release()).
        property real enter: 0
        property real leave: LockState.unlocking ? 1 : 0
        Behavior on leave {
            NumberAnimation {
                duration: Motion.surfaceExitSmall
                easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.standardAccel
            }
        }
        NumberAnimation {
            id: enterAnim
            target: surface; property: "enter"; from: 0; to: 1
            duration: Motion.reduced ? Motion.fadeIn : Motion.hero
            easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.springCurve
        }
        // The backdrop's strength, the clock's arrival, the card's arrival.
        readonly property real _veil:  surface.enter * (1 - surface.leave)
        readonly property real _clock: Math.min(1, surface.enter * 1.3)
        readonly property real _card:  Math.max(0, Math.min(1, (surface.enter - 0.18) / 0.82))

        // ── Content root ─────────────────────────────────────────────
        Item {
            id: content
            anchors.fill: parent
            focus: true

            // Any stray keystroke lands in the password field.
            Keys.forwardTo: [passwordInput]

            // ── Background: Colors-derived gradient fallback ─────────
            // Always present so an empty/broken wallpaper path can never
            // leave a blank (or transparent) surface.
            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    orientation: Gradient.Vertical
                    GradientStop { position: 0.0; color: Qt.darker(Theme.background, 1.15) }
                    GradientStop { position: 1.0; color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 1.0) }
                }
            }

            // Wallpaper texture source (hidden; fed into the blur effect).
            //
            // SettingsService.lockBackground overrides the desktop wallpaper so
            // the lock screen can show something else (or something the desktop
            // wallpaper rotation will not clobber). Empty means "follow the
            // desktop wallpaper", which is the historical behaviour. A path that
            // fails to load falls through to the gradient underneath, exactly as
            // a broken wallpaper path already did.
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

            // Blurred + dimmed wallpaper. Hidden automatically if the image
            // fails to load, revealing the gradient underneath.
            MultiEffect {
                anchors.fill: parent
                source:       wallImg
                visible:      wallImg.status === Image.Ready
                blurEnabled:  true
                blur:         1.0 * surface._veil
                blurMax:      48
                brightness:  -0.30 * surface._veil
                saturation:  -0.10 * surface._veil
            }

            // Extra scrim for legibility.
            Rectangle {
                anchors.fill: parent
                color: Qt.rgba(0, 0, 0, 0.35)
                opacity: surface._veil
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
                opacity: surface._clock * (1 - surface.leave)
                transform: Translate {
                    y: (1 - surface._clock) * -Motion.travel(theme.px(28))
                       - surface.leave * Motion.travel(theme.px(18))
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text:           surface.timeText
                    color:          Theme.text
                    font.family:    "JetBrainsMono Nerd Font"
                    font.pixelSize: theme.fs(120)
                    font.bold:      true
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
                opacity: surface._card * (1 - surface.leave)
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
                        size:                15
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
            passwordInput.forceActiveFocus()
            enterAnim.start()
        }
        // A surface Quickshell shows again for a later lock arrives again.
        onVisibleChanged: if (visible) {
            passwordInput.forceActiveFocus()
            surface.enter = 0
            enterAnim.restart()
        }
    }
}
