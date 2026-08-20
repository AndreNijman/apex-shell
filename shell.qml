import Quickshell
import QtQuick
import "./src/windows"
import "./src/popups"
import "./src/services"
import "./src/"

ShellRoot {
    // Force-instantiate lazy singletons that need startup behavior.
    //
    // Note what is deliberately NOT here: the telemetry services (Cpu, Mem,
    // Net, Disk, Gpu, CpuFreq, PowerProfile). They are refcounted and must stay
    // lazy — force-loading one would start its poll timer for the whole session,
    // which is the exact behaviour the perf work removed.
    property var _compositor: Compositor
    property var _niri:       NiriService
    property var _keybinds:   KeybindService
    property var _updater:    UpdateService
    property var _ipc:        IpcManager

    // Must exist without anything referencing it: it is what raises the
    // low-battery warning, and nothing on screen "uses" it.
    property var _batteryAlert: BatteryAlert

    Variants {
        model: Quickshell.screens

        delegate: Component {
            Scope {
                required property var modelData

                // ── Windows ──────────────────────────────────────
                TopBar    { id: topBar;        screen: modelData }

                Border    { id: leftBorder;    screen: modelData; edge: "left"   }
                Border    { id: rightBorder;   screen: modelData; edge: "right"  }
                Border    { id: bottomBorder;  screen: modelData; edge: "bottom" }

                // ── Overlays ─────────────────────────────────────
                // Dismisses all popups on click-outside or Escape
                PopupDismiss { screen: modelData; screenName: modelData.name }

                // GPU mode change confirmation modal
                ConfirmDialog { screen: modelData }

                // Shell update notification
                UpdatePopup { screen: modelData }

                // ── All popups ───────────────────────────────────
                // Add new popups in src/popups/PopupLayer.qml only
                PopupLayer {
                    topBar:       topBar
                    leftBorder:   leftBorder
                    rightBorder:  rightBorder
                    bottomBorder: bottomBorder
                }

                // Volume / brightness / mic OSD — transient top-centre pill
                Osd { screen: modelData }
            }
        }
    }

    // ── Native session lock ──────────────────────────────────
    // Top-level (NOT per-screen): WlSessionLock manages one surface per
    // output itself. Engages when LockState.locked is set.
    Lockscreen {}
}
