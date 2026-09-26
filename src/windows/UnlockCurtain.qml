import QtQuick
import Quickshell
import Quickshell.Wayland
import "../"
import "../services/"

// ─────────────────────────────────────────────────────────────────────────────
// UnlockCurtain — the desktop fading in after an unlock, instead of popping.
//
// When ext-session-lock lets go, the compositor shows the desktop at once:
// windows, bar and wallpaper all in the same frame, straight after a lock UI
// that had been drawing a blurred, dimmed wallpaper. Lockscreen now plays its
// UI out first and sharpens its wallpaper back into the desktop's; this is
// the other half. Per output, the desktop wallpaper is mapped on the Overlay
// layer as the lock engages (hidden behind the lock surface from then on, so
// its first frame is long ready), and the moment the lock releases it covers
// everything with exactly what the lock surface had just become — then fades,
// and the windows and the bar arrive from under it.
//
// Presentation only: it maps on LockState.curtain (raised with the lock),
// takes no input (an empty mask) and no keyboard, and drops itself when the
// fade has finished. A wallpaper the shell does not know leaves it empty and
// transparent: the desktop simply appears, as it did before.
// ─────────────────────────────────────────────────────────────────────────────
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: win
        required property var modelData
        screen: modelData

        anchors { top: true; left: true; right: true; bottom: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        color: "transparent"
        mask: Region {}

        // Armed only once the compositor has engaged the lock (LockState).
        visible: LockState.curtainArmed
        property real fade: 1
        onVisibleChanged: if (visible) { fadeOut.stop(); win.fade = 1 }

        Image {
            anchors.fill: parent
            source: WallpaperService.currentWall !== "" ? "file://" + WallpaperService.currentWall : ""
            fillMode: Image.PreserveAspectCrop
            // Decoded before the first frame: the frame the lock hands over to
            // must already be the wallpaper, not transparent.
            asynchronous: false
            cache: true
            opacity: win.fade
        }

        Connections {
            target: LockState
            function onLockedChanged() {
                if (!LockState.locked && LockState.curtain) fadeOut.restart()
            }
        }
        NumberAnimation {
            id: fadeOut
            target: win; property: "fade"; from: 1; to: 0
            duration: Motion.fadeIn
            easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.effects
            onFinished: LockState.curtain = false
        }
    }
}
