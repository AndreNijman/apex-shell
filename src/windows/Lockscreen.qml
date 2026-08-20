import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pam
import "../"
import "../services/"

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

    // ── Per-output lock surface ──────────────────────────────────────
    WlSessionLockSurface {
        id: surface

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
                    // The one and only unlock path.
                    surface.password = ""
                    LockState.locked = false
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
            surface.password  = ""
            surface.hasError  = true
            surface.errorText = msg
            shakeAnim.restart()
        }

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

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text:           surface.timeText
                    color:          Theme.text
                    font.family:    "JetBrainsMono Nerd Font"
                    font.pixelSize: 120
                    font.bold:      true
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text:           surface.dateText
                    color:          Theme.subtext
                    font.family:    "JetBrainsMono Nerd Font"
                    font.pixelSize: 22
                }
            }

            // ── Auth card ────────────────────────────────────────────
            Column {
                id: card
                anchors.centerIn: parent
                anchors.verticalCenterOffset: 90
                spacing: 14
                transform: Translate { x: surface.shakeOffset }

                // Username
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text:           surface.username !== "" ? surface.username : "Locked"
                    color:          Theme.text
                    font.family:    "JetBrainsMono Nerd Font"
                    font.pixelSize: 20
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
                                      ? "#ff5c5c"
                                      : (passwordInput.activeFocus ? Theme.active : Theme.border)
                    Behavior on border.color { ColorAnimation { duration: 140 } }

                    // Lock glyph
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left:           parent.left
                        anchors.leftMargin:     18
                        text:  "󰌾"
                        color: Theme.subtext
                        font.family:    "JetBrainsMono Nerd Font"
                        font.pixelSize: 18
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
                        color:                   Theme.text
                        selectionColor:          Theme.active
                        font.family:             "JetBrainsMono Nerd Font"
                        font.pixelSize:          18
                        echoMode:                TextInput.Password
                        passwordCharacter:       "●"
                        passwordMaskDelay:       0
                        activeFocusOnPress:      true

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

                        // Placeholder
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left:           parent.left
                            visible: passwordInput.text.length === 0 && !surface.checking
                            text:  "Enter password"
                            color: Theme.subtext
                            font.family:    passwordInput.font.family
                            font.pixelSize: passwordInput.font.pixelSize
                        }
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
                        RotationAnimator on rotation {
                            running: spinner.visible
                            loops:   Animation.Infinite
                            from: 0; to: 360
                            duration: 850
                        }
                    }
                }

                // Status line — error message or caps-lock warning.
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    height:  18
                    text: surface.hasError ? surface.errorText
                        : (surface.capsOn ? "󰪛  Caps Lock is on" : "")
                    color: surface.hasError ? "#ff5c5c" : Theme.subtext
                    font.family:    "JetBrainsMono Nerd Font"
                    font.pixelSize: 14
                }
            }

            // ── Error shake ──────────────────────────────────────────
            SequentialAnimation {
                id: shakeAnim
                NumberAnimation { target: surface; property: "shakeOffset"; from: 0; to:  14; duration: 45 }
                NumberAnimation { target: surface; property: "shakeOffset"; to: -14; duration: 45 }
                NumberAnimation { target: surface; property: "shakeOffset"; to:  10; duration: 45 }
                NumberAnimation { target: surface; property: "shakeOffset"; to: -10; duration: 45 }
                NumberAnimation { target: surface; property: "shakeOffset"; to:   6; duration: 45 }
                NumberAnimation { target: surface; property: "shakeOffset"; to:   0; duration: 45 }
            }
        }

        // Grab keyboard focus as soon as the surface appears.
        Component.onCompleted: passwordInput.forceActiveFocus()
        onVisibleChanged: if (visible) passwordInput.forceActiveFocus()
    }
}
