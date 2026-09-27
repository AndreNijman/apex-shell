import QtQuick
import Quickshell
import "../"
import "../components"
import "../services"

// ============================================================
// PopupLayer — the only file that instantiates popup windows.
//
// shell.qml creates the anchor windows and passes them in.
// To add a new popup:
//   1. Create the .qml file in src/popups/
//   2. Add its anchor window as a property here (if new)
//   3. Instantiate it below under the right section, wrapped in a
//      LazyPopup whose `wanted` is that popup's own open flag
//
// Every popup here is built on first open rather than at login. See
// components/LazyPopup.qml for why the instance is then kept rather than
// unloaded on close.
// ============================================================

Scope {
    id: root

    // ── Anchor windows (set by shell.qml) ───────────────────
    required property var topBar       // TopBar PanelWindow
    required property var leftBorder   // left Border PanelWindow
    required property var rightBorder  // right Border PanelWindow
    required property var bottomBorder // bottom Border PanelWindow

    // ── Border-anchored popups ───────────────────────────────

    // Left border → center
    LazyPopup {
        wanted: Popups.archMenuOpen
        ArchMenu {
            anchorWindow: root.leftBorder
        }
    }

    // Bottom border → slides up
    LazyPopup {
        wanted: Popups.wallpaperOpen
        WallpaperPopup {}
    }

    // Bottom-right corner → clipboard history + emoji
    LazyPopup {
        wanted: Popups.clipboardOpen
        ClipboardPopup {}
    }

    // ── TopBar-anchored popups ───────────────────────────────

    // Right strip — quick controls, opened by hovering the strip. The hover
    // itself builds it: gated on `quickOpen` alone it was never built at all,
    // because nothing sets that flag (see QuickControl.qml).
    LazyPopup {
        wanted: Popups.quickOpen || Popups.quickTriggerHovered
        QuickControl {
            anchorWindow: root.topBar
        }
    }

    // Center notch — dashboard (expands below the center notch)
    LazyPopup {
        wanted: Popups.dashboardOpen
        Dashboard {
            anchorWindow: root.topBar
        }
    }

    // Right notch — the network panel, the notification centre, audio and the
    // toast, as panes of one surface that pours out of the notch (RightPanel.qml).
    //
    // The toast's trigger is NOT Popups.notificationToastOpen: that flag is
    // written ONLY by the toast itself, so gating construction on it alone was
    // a deadlock — no window, so no listener, so nothing ever set the flag, so
    // toasts never appeared at all. The service's own record of the last
    // announced notification is the real trigger.
    LazyPopup {
        wanted: Popups.networkOpen || Popups.notificationsOpen || Popups.audioOpen
                || Popups.notificationToastOpen || NotificationService.lastToast !== null
        RightPanel {
            anchorWindow: root.topBar
        }
    }

    // Screen recorder strip options — appears below center notch on hover.
    // Driven by ScreenRecService rather than a Popups flag.
    LazyPopup {
        wanted: ScreenRecService.openStrip !== ""
        ScreenRecOptionsPopup {
            anchorWindow: root.topBar
        }
    }

    // Desktop right-click menu. Full-screen overlay rather than an anchored
    // popup: it places itself at the pointer, so it has no anchor window.
    LazyPopup {
        wanted: Popups.contextMenuOpen
        ContextMenu {}
    }
}
