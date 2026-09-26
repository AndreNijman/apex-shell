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
            // What the lock surface sharpens into: the lock's own background
            // when one is set (so the hand-over is not a cut from that image to
            // the desktop's), else the desktop wallpaper.
            source: {
                const o = SettingsService.lockBackground
                if (o && o !== "") return o.startsWith("/") ? "file://" + o : o
                return WallpaperService.currentWall !== "" ? "file://" + WallpaperService.currentWall : ""
            }
            fillMode: Image.PreserveAspectCrop
            // Asynchronous: this window exists (unmapped) from startup, so the
            // image is decoded long before any lock, off the GUI thread — and
            // the lock surface's own wallpaper (same URL, same cache) finds it
            // warm on the first lock of a session instead of popping in over
            // the gradient. A synchronous decode here would run exactly as
            // the lock surface is being built.
            asynchronous: true
            cache: true
            opacity: win.fade
        }

        Connections {
            target: LockState
            function onLockedChanged() {
                if (!LockState.locked && LockState.curtain) fadeOut.restart()
                // Locked again mid-fade: the curtain is whole again for the
                // next unlock, and the fade must not take it down under the lock.
                else if (LockState.locked) { fadeOut.stop(); win.fade = 1 }
            }
        }
        NumberAnimation {
            id: fadeOut
            target: win; property: "fade"; from: 1; to: 0
            duration: Motion.fadeIn
            easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.effects
            onFinished: if (!LockState.locked) LockState.curtain = false
        }
    }
}
