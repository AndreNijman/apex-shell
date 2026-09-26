import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import "../"
import "../components"
import "../services/"
import "../components/controls"

// Unified confirmation modal — replaces GfxWarning.qml.
// Driven entirely by Popups.confirm* props.
// Call Popups.showConfirm() to open, Popups.cancelConfirm() to close.
//
// Supported confirmAction values — all routed through scripts/PowerControl.sh:
//   "shutdown"        → hyprshutdown --post-cmd "systemctl poweroff"
//   "reboot"          → hyprshutdown --post-cmd "systemctl reboot"
//   "logout"          → hyprshutdown
//   "lock"            → loginctl lock-session
//   "suspend"         → systemctl suspend
//   "gamingmode"      → PowerControl.sh gamingmode (record the greeter's next
//                       session as apex-gaming, then end this session)
//   "windows"         → PowerControl.sh windows (verify Windows, arm EFI BootNext,
//                       reboot). PowerMenu only offers this when its
//                       "windows-check" probe found a bootable Windows.
//   "gpu-switch-envy" → pkexec scripts/GfxSwitch.sh <mode>, then systemctl reboot
//                       GfxSwitch.sh prints "authenticated" after pkexec auth succeeds,
//                       which triggers the processing card before envycontrol runs.

PanelWindow {
    id: root

    color: "transparent"

    // ── This output's sizes (P1-040) ─────────────────────────────────────────
    // Not Theme's. Theme carries ONE factor for the whole shell — the reference
    // output's — so on a desk whose monitors have different densities it is
    // wrong for at least one of them. This modal is built per output (shell.qml
    // creates one from Quickshell.screens), it is anchored to nothing but its
    // own screen, and nothing outside it reads its size, so it can answer for
    // itself instead.
    //
    // `root.screen` is exact from construction — measured on quickshell 0.3.1
    // with two headless outputs of different densities, each PanelWindow's
    // screen.height is that output's height at t=0, before the surface is
    // mapped. No transient, so no first-frame resize.
    //
    // Colours stay on Theme deliberately: a palette belongs to the shell, not
    // to an output. Sizes come from `theme`, colours from `Theme`, and the
    // split is visible at every call site below.
    // The set is SHARED, not built here. theme/OutputScale keeps one ThemeSet
    // per factor the breakpoint table can answer — five objects for the whole
    // shell — because a token set is a pure function of its factor and a
    // hundred migrated files each constructing their own would build a hundred
    // copies of the same forty bindings onto SettingsService.
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForScreen(root.screen) }

    anchors { top: true; left: true; right: true; bottom: true }
    exclusionMode: ExclusionMode.Ignore

    // On the dialog lifecycle (UI/UX Phase 6): the window stays mapped until
    // the exit has finished; it used to vanish on the flag with no motion.
    DialogLifecycle { id: life; name: "confirm"; open: Popups.confirmOpen || Popups.confirmRunning }
    visible: life.mapped

    WlrLayershell.layer:         WlrLayer.Overlay
    // A modal holds the keyboard while it is up. OnDemand — which a compositor
    // may grant only on a click — left it opened from the keyboard with no
    // key reaching it, not even Escape (measured on labwc; UI/UX Phase 21).
    WlrLayershell.keyboardFocus: life.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    // ── Processes ─────────────────────────────────────────────────────────────
    Process {
        id: proc
        property var pendingCmd: []
        command: pendingCmd

        // Watch stdout for "authenticated" — printed by GfxSwitch.sh immediately
        // after pkexec grants root, before envycontrol starts doing its work.
        stdout: SplitParser {
            onRead: data => {
                if (data.trim() === "authenticated") Popups.confirmRunning = true
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (reboot.command.length > 0) {
                if (exitCode === 0) {
                    reboot.running = true
                } else {
                    // Auth cancelled or envycontrol failed — hide card, abort.
                    Popups.confirmRunning = false
                    reboot.command = []
                }
            }
        }
    }

    Process {
        id: reboot
        command: []   // only populated for gpu-switch-envy
    }

    // ── Action dispatch ───────────────────────────────────────────────────────
    function confirm() {
        const powerScript = Quickshell.shellDir + "/src/scripts/PowerControl.sh"
        const gfxScript   = Quickshell.shellDir + "/src/scripts/GfxSwitch.sh"

        switch (Popups.confirmAction) {
            case "shutdown":
                Popups.cancelConfirm()
                proc.pendingCmd = ["bash", powerScript, "shutdown"]
                proc.running = true
                break
            case "reboot":
                Popups.cancelConfirm()
                proc.pendingCmd = ["bash", powerScript, "reboot"]
                proc.running = true
                break
            case "logout":
                Popups.cancelConfirm()
                proc.pendingCmd = ["bash", powerScript, "logout"]
                proc.running = true
                break
            case "lock":
                Popups.cancelConfirm()
                proc.pendingCmd = ["bash", powerScript, "lock"]
                proc.running = true
                break
            case "suspend":
                Popups.cancelConfirm()
                proc.pendingCmd = ["bash", powerScript, "suspend"]
                proc.running = true
                break
            // Gaming Mode: records the greeter's next session, then ends this
            // one. Routed through PowerControl.sh like every other power action
            // so the privileged call lives in one place.
            case "gamingmode":
                Popups.cancelConfirm()
                proc.pendingCmd = ["bash", powerScript, "gamingmode"]
                proc.running = true
                break
            case "windows":
                Popups.cancelConfirm()
                proc.pendingCmd = ["bash", powerScript, "windows"]
                proc.running = true
                break
            case "gpu-switch-envy":
                // Capture mode BEFORE cancelConfirm() clears Popups state.
                const gfxMode   = Popups.confirmGfxMode
                reboot.command  = ["bash", powerScript, "reboot"]
                proc.pendingCmd = ["pkexec", "bash", gfxScript, gfxMode]
                Popups.cancelConfirm()
                proc.running    = true
                break
        }
    }

    function cancel() {
        if (!Popups.confirmRunning) Popups.cancelConfirm()
    }

    // ── Dim overlay ───────────────────────────────────────────────────────────
    // KEPT deliberately. A modal scrim has to darken whatever is behind it on
    // every wallpaper, so it must NOT follow the palette — a themed scrim over a
    // dark wallpaper stops reading as modal at all.
    Rectangle {
        anchors.fill: parent
        color: "#99000000"
        opacity: life.scrimK()

        MouseArea {
            anchors.fill: parent
            onClicked: if (!Popups.confirmRunning) root.cancel()
        }
    }

    // ── Confirm dialog ────────────────────────────────────────────────────────
    Elevation { target: confirmCard; level: "modal" }   // over its scrim (UI/UX Phase 18b)
    Rectangle {
        id: confirmCard
        // Named for the scaling suite; see the note on the DisplayConfirm card.
        objectName: "apex-confirm-dialog-card"

        anchors.centerIn: parent
        // These two are raw literals and were before this change. They are the
        // separate question check-scale-tokens.sh deliberately leaves alone —
        // "radius: 8" — and scaling them is a visible change to a dialog, not a
        // per-output one. What this file now gets from its own output is every
        // size it DOES scale: the radius below and every font size in the card.
        width:  360
        height: col.implicitHeight + 48
        radius: theme.notchRadius
        color:  Theme.background
        border.width: 1
        border.color: Theme.outlineSoft   // the surface rim; it had none (UI/UX Phase 18b)
        visible: Popups.confirmOpen && !Popups.confirmRunning
        opacity: life.content * life.alpha
        scale:   life.cardScale()

        MouseArea { anchors.fill: parent }

        Column {
            id: col
            anchors {
                top:         parent.top
                left:        parent.left
                right:       parent.right
                topMargin:   24
                leftMargin:  24
                rightMargin: 24
            }
            spacing: 16

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: {
                    switch (Popups.confirmAction) {
                        case "shutdown":        return "⏻"
                        case "reboot":          return "↺"
                        case "windows":         return "󰖳"
                        case "logout":          return "⎋"
                        case "gpu-switch-envy": return "⚠️"
                        default:                return "⚠️"
                    }
                }
                // Every other Text in this dialog sets a colour; this one did
                // not, so the glyph fell back to Qt's default black on the dark
                // card. The accent, like the rest of the shell's chrome.
                color:          Theme.active
                font.pixelSize: theme.fs(32)
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text:           Popups.confirmTitle
                color:          Theme.text
                font.pixelSize: theme.fs(15)
                font.bold:      true
            }

            Text {
                width:          parent.width
                text:           Popups.confirmMessage
                color:          Theme.textSecondary
                font.pixelSize: theme.fs(12)
                wrapMode:       Text.WordWrap
                textFormat:     Text.RichText
                lineHeight:     1.4
            }

            // Two real buttons (UI/UX roadmap v3 Phase 21). Return used to
            // confirm whatever had focus — it still confirms by default, since
            // the confirm button takes focus when the dialog opens, but the
            // focus is now shown, Tab and the arrows move it, and Return or
            // Space press the button that has it.
            Row {
                id: buttons
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 10
                Keys.onEscapePressed: root.cancel()

                ApexPressable {
                    id: cancelBtn
                    width:  130
                    height: 38
                    radius: theme.cornerRadius
                    Accessible.name: "Cancel"
                    KeyNavigation.right: confirmBtn
                    KeyNavigation.tab:   confirmBtn
                    onActivated: root.cancel()

                    Rectangle {
                        anchors.fill: parent
                        radius: parent.radius
                        color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b,
                                       cancelBtn.pressed ? 0.14 : cancelBtn.hovered ? 0.10 : 0.05)
                        Behavior on color { MotionColor {} }
                    }
                    Text {
                        anchors.centerIn: parent
                        text:           "Cancel"
                        color:          Theme.textPrimary
                        font.pixelSize: theme.fs(13)
                    }
                    ApexFocusRing { target: cancelBtn }
                }

                ApexPressable {
                    id: confirmBtn
                    width:  130
                    height: 38
                    radius: theme.cornerRadius
                    Accessible.name: Popups.confirmLabel
                    KeyNavigation.left:    cancelBtn
                    KeyNavigation.backtab: cancelBtn
                    onActivated: root.confirm()

                    Rectangle {
                        anchors.fill: parent
                        radius: parent.radius
                        color: confirmBtn.hovered || confirmBtn.pressed ? Theme.dangerFillHover : Theme.dangerFill
                        Behavior on color { MotionColor {} }
                    }
                    Text {
                        anchors.centerIn: parent
                        text:           Popups.confirmLabel
                        color:          Theme.fixedLight   // on a fixed surface (the danger fill)
                        font.pixelSize: theme.fs(13)
                        font.bold:      true
                    }
                    ApexFocusRing { target: confirmBtn }
                }
            }
        }
    }

    // ── Processing card ───────────────────────────────────────────────────────
    Elevation { target: processingCard; level: "modal" }
    Rectangle {
        id: processingCard
        anchors.centerIn: parent
        width:  300
        height: processingCol.implicitHeight + 56
        radius: theme.notchRadius
        color:  Theme.background
        border.width: 1
        border.color: Theme.outlineSoft
        visible: Popups.confirmRunning
        opacity: life.content * life.alpha
        scale:   life.cardScale()

        MouseArea { anchors.fill: parent }

        Column {
            id: processingCol
            anchors {
                top:         parent.top
                left:        parent.left
                right:       parent.right
                topMargin:   28
                leftMargin:  24
                rightMargin: 24
            }
            spacing: 18

            Canvas {
                id: spinnerCanvas
                anchors.horizontalCenter: parent.horizontalCenter
                width:  40
                height: 40
                transformOrigin: Item.Center

                RotationAnimator {
                    target:      spinnerCanvas
                    from:        0
                    to:          360
                    duration:    Motion.spinPeriod
                    loops:       Animation.Infinite
                    running:     Popups.confirmRunning && Motion.loops
                    easing.type: Easing.Linear
                }

                onPaint: {
                    var ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    var cx = width / 2, cy = height / 2, r = 16
                    ctx.beginPath()
                    ctx.arc(cx, cy, r, 0, 2 * Math.PI)
                    // Palette roles, not white: the card is Theme.background,
                    // which a light scheme makes light.
                    ctx.strokeStyle = Theme.outlineSoft
                    ctx.lineWidth   = 3
                    ctx.stroke()
                    ctx.beginPath()
                    ctx.arc(cx, cy, r, -Math.PI / 2, Math.PI)
                    ctx.strokeStyle = Theme.textPrimary
                    ctx.lineWidth   = 3
                    ctx.lineCap     = "round"
                    ctx.stroke()
                }

                Component.onCompleted: requestPaint()
                readonly property color _ink: Theme.textPrimary
                on_InkChanged: requestPaint()
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text:           "Applying Changes"
                color:          Theme.text
                font.pixelSize: theme.fs(15)
                font.bold:      true
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                width:          parent.width
                text:           "Switching to <b>" + Popups.confirmGfxMode + "</b> graphics mode.<br>"
                                + "Your system will reboot when finished."
                color:          Theme.textSecondary
                font.pixelSize: theme.fs(12)
                wrapMode:       Text.WordWrap
                textFormat:     Text.RichText
                lineHeight:     1.5
                horizontalAlignment: Text.AlignHCenter
            }

            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width:  parent.width
                height: 1
                color:  Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07)
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text:           "Do not turn off your computer."
                color:          Theme.textTertiary
                font.pixelSize: theme.fs(11)
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }

    // Escape, wherever focus is (the processing card has no buttons). The
    // buttons take focus when the dialog opens; Return belongs to them.
    // It takes focus only for the processing card: a `focus: root.visible` here
    // took it straight back from the confirm button (measured — no ring).
    Item {
        anchors.fill: parent
        focus: Popups.confirmRunning
        Keys.onEscapePressed: root.cancel()
    }
    onVisibleChanged: if (root.visible) Qt.callLater(function () { confirmBtn.forceActiveFocus() })
}
