import Quickshell
import Quickshell.Wayland
import QtQuick
import "../"
import Quickshell.Hyprland
import Quickshell.WindowManager

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
    visible: (Popups.anyOpen
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
    
    Connections {
        // Conditional target and a positive guard. `target: Hyprland` resolves
        // the singleton even when disabled, and constructing it off Hyprland
        // logs "cannot connect to hyprland"; `!isNiri` was also true on labwc,
        // which is neither.
        target: Compositor.isHyprland ? Hyprland : null
        enabled: Compositor.isHyprland

        // Quickshell emits (name, data) for raw events
        function onRawEvent(event) {
            if (event.name === "workspace" || event.name === "activemonitor" || event.name === "activespecial" || event.name === "openwindow") {
                Popups.closeAll();
            }
        }
    }

    // niri equivalent: dismiss popups when the focused workspace or window changes
    // (mirrors the workspace / openwindow / activemonitor auto-close above).
    Connections {
        target: NiriService
        enabled: Compositor.isNiri
        function onFocusedWorkspaceIdChanged() { Popups.closeAll(); }
        function onFocusedWindowIdChanged()    { Popups.closeAll(); }
    }

    // labwc equivalent. labwc publishes no IPC event stream at all, so the
    // signals come from Wayland protocols it does implement:
    // wlr-foreign-toplevel for focus changes, and ext-workspace for desktop
    // switches. Between them these cover what the Hyprland rawEvent branch
    // above reacts to.
    Connections {
        target: Compositor.isLabwc ? ToplevelManager : null
        enabled: Compositor.isLabwc
        function onActiveToplevelChanged() { Popups.closeAll(); }
    }

    Repeater {
        model: Compositor.isLabwc ? WindowManager.windowsets : 0

        Item {
            required property var modelData

            readonly property bool wsActive: modelData.active
            onWsActiveChanged: if (wsActive) Popups.closeAll()
        }
    }
}
