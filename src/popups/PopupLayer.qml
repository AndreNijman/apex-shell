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

    // Right notch — audio
    LazyPopup {
        wanted: Popups.audioOpen
        AudioPopup {
            anchorWindow: root.rightBorder
        }
    }

    LazyPopup {
        wanted: Popups.quickOpen
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

    // Right notch
    LazyPopup {
        wanted: Popups.notificationsOpen
        NotificationsPopup {
            anchorWindow: root.topBar
        }
    }

    // Standardised pill-popup: anchored to the top bar like NotificationsPopup,
    // so the card's flush top lands exactly at the pill's bottom edge.
    LazyPopup {
        wanted: Popups.notificationToastOpen
        NotificationToast {
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

    LazyPopup {
        wanted: Popups.networkOpen
        NetworkPopup {}
    }
}
