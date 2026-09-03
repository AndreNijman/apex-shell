import Quickshell
import Quickshell.Wayland
import QtQuick
import "../"

// Transparent fullscreen overlay that dismisses all popups when:
//   - The user clicks anywhere on screen
//   - The user presses Escape
//
// Also active when screen rec setup is showing (ShellState.screenRecord
// without recording) so ESC can cancel it even with no other popup open.

PanelWindow {
    id: root

    // The output this overlay belongs to, passed in by shell.qml.
    //
    // Deliberately NOT derived from the window's own `screen` property: reading
    // `screen` inside the `visible` binding below is a binding loop, because a
    // PanelWindow re-resolves `screen` as it maps and unmaps, and `visible` is
    // what decides whether it maps. That loop was firing on every popup open.
    required property string screenName

    color: "transparent"

    mask: Region {
        Region {
            x:      Theme.borderWidth
            y:      Theme.notchHeight - Theme.borderWidth
            width:  root.width - (Theme.borderWidth * 2)
            height: root.height - Theme.notchHeight - Theme.borderWidth
        }
        Region {
            x:      ShellState.topBarLWidth - Theme.borderWidth
            y:      0
            width:  (root.width / 2) - (ShellState.topBarCWidth / 2) - ShellState.topBarLWidth+ Theme.borderWidth
            height: Theme.notchHeight
        }
        Region{
            x:     (root.width / 2) + (ShellState.topBarCWidth / 2)
            y:     0
            width: (root.width / 2) - (ShellState.topBarCWidth / 2) - ShellState.topBarRWidth + Theme.borderWidth
            height: Theme.notchHeight
        }
    }

    // Span entire screen
    anchors {
        top:    true
        left:   true
        right:  true
        bottom: true
    }
    
    margins.top: Theme.borderWidth // Start below the notch so it doesn't interfere with TopBar popups
    margins.left: Theme.borderWidth
    margins.right: Theme.borderWidth
    margins.bottom: Theme.borderWidth
    // Don't push windows away
    exclusionMode: ExclusionMode.Ignore

    // Only grab input when a popup is actually open
    // When false, input passes through as if this window doesn't exist
    // labwc stacks this Top-layer surface above ArchMenu's anchored popup even
    // though PopupDismiss is instantiated first. Its fullscreen mask therefore
    // receives every button click before the visible power menu can. Leave the
    // dismiss surface unmapped for that one popup on labwc; the compositor's
    // focusMoved listener below still closes it when focus moves, and
    // the power key/button toggles it closed directly.
    visible: (Popups.anyOpen
              && !(Compositor.isLabwc && Popups.archMenuOpen)
              && (!Popups.dashboardOpen
                  || Popups.dashboardScreen === root.screenName))
             || (ShellState.screenRecord && !ScreenRecService.recording)

    // Sit below popups but above the desktop
    WlrLayershell.layer: WlrLayer.Top
    
    // Detech Keyboard events for Escape key to dismiss popups
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    // --- Click anywhere to dismiss ---
    MouseArea {
        anchors.fill: parent
        onClicked:    Popups.closeAll()
    }

    // --- Escape to dismiss ---
    // Item must be focused for Keys to fire
    Item {
        anchors.fill: parent
        focus:        root.visible

        Keys.onEscapePressed: {
            Popups.closeAll()
            ScreenRecService.cancelSetup()
        }
    }
    
    // Dismiss on "the user is now looking somewhere else". That was three
    // separate listener blocks — a Hyprland raw-event filter, a niri pair of
    // property watchers and a labwc foreign-toplevel hook — each with its own
    // conditional target, and each a place to get the guard subtly wrong. The
    // adapter emits one signal from whichever of those it has.
    //
    // Title changes deliberately do not count: a browser switching tabs is not
    // the user looking elsewhere, and a popup that vanishes when a background
    // tab finishes loading is worse than one that lingers.
    //
    // A monitor change DOES count, and on Hyprland with `follow_mouse` that
    // means a cursor crossing a monitor boundary closes whatever is open. If
    // that ever reads as a bug, it is not: HyprlandBackend._FOCUS_EVENTS says
    // why, and `closeAll()` here is global, so the alternative is a popup left
    // behind on a monitor the user has walked away from.
    Connections {
        target: CompositorService
        function onFocusMoved() { Popups.closeAll(); }
    }

}
