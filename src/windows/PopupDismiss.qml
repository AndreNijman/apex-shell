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

    // THIS output's bar, handed over by shell.qml from the same per-screen
    // Scope that built both of them (P1-040).
    //
    // The three notch widths used to arrive through ShellState.topBar{L,C,R}Width
    // — one singleton field per width, one bar per output, and every bar bound
    // into it. Last writer won. That was harmless only for as long as every bar
    // computed the SAME number, which is exactly what stops being true the
    // moment a bar sizes itself from its own output's density: two bars would
    // write two different widths into one field and this mask would carve its
    // click-through gaps out of the other monitor's geometry, non-
    // deterministically, depending on which bar re-evaluated last.
    //
    // There is no per-screen map here either. The bar object itself is the
    // per-screen state, shell.qml already holds it, and PopupLayer already takes
    // it the same way.
    required property var topBar

    color: "transparent"

    mask: Region {
        Region {
            x:      Theme.borderWidth
            y:      Theme.notchHeight - Theme.borderWidth
            width:  root.width - (Theme.borderWidth * 2)
            height: root.height - Theme.notchHeight - Theme.borderWidth
        }
        Region {
            x:      root.barLWidth - Theme.borderWidth
            y:      0
            width:  (root.width / 2) - (root.barCWidth / 2) - root.barLWidth + Theme.borderWidth
            height: Theme.notchHeight
        }
        Region{
            x:     (root.width / 2) + (root.barCWidth / 2)
            y:     0
            width: (root.width / 2) - (root.barCWidth / 2) - root.barRWidth + Theme.borderWidth
            height: Theme.notchHeight
        }
    }

    // Named so the mask above reads as geometry rather than as null-guards, and
    // so a suite can assert what this overlay carved without reaching into a
    // Region's children. A bar is always present in the shell; the fallbacks are
    // for a window built before its bar has finished constructing.
    readonly property int barLWidth: root.topBar ? root.topBar.lWidth : 0
    readonly property int barCWidth: root.topBar ? root.topBar.cWidth : 0
    readonly property int barRWidth: root.topBar ? root.topBar.rWidth : 0

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
