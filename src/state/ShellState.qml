pragma Singleton
import Quickshell
import QtQuick
import Quickshell.Io
import Quickshell.Services.UPower
import "../."

// Global shell state.
//
// WiFi / Bluetooth  — owned by QuickSettings (nmcli / bluetoothctl)
// Night Light       — owned by QuickSettings (hyprsunset)
// Caffeine          — toggled by QuickSettings; TopBar holds the Wayland idle inhibitors
// Hotspot           — owned by QuickSettings (nmcli hotspot)
// Airplane Mode     — owned by QuickSettings (rfkill)
// Focus Mode        — owned by QuickSettings; TopBar reacts to hide + zero gaps
// DND               — read by NotificationService to suppress incoming notifications
// VPN               — written by VPNTab; read by Network.qml for bar icon

QtObject {
    id: root

    property int topBarLWidth: 0
    property int topBarCWidth: 0
    property int topBarRWidth: 0
    
    
    property bool focusMode:    false
    property bool dnd:          false
    property bool screenRecord: false
    property bool hotspot:      false
    property bool airplane:     false

    // Caffeine — while true, IdleInhibitors in each TopBar window keep the
    // compositor's idle timers (hypridle: dim/lock/dpms/suspend) from firing.
    property bool caffeine:     false

    // WiFi — false when radio is off OR hotspot is using the interface
    property bool wifiOn:       false

    // VPN — set by VPNTab, read by Network.qml bar indicator
    property bool   vpnActive:     false
    property bool   vpnConnecting: false
    property string vpnName:       ""

    // Bluetooth — written by BluetoothTab immediately on action, read by Network.qml
    // This avoids the 5s poll lag when a device disconnects or adapter toggles.
    property bool btPowered:   false   // adapter is on
    property bool btConnected: false   // at least one device connected

    // ── Hardware Detection ──────────────────────────────────────────
    property bool hasBattery: false
    
    function _checkBattery() {
        if (UPower.displayDevice && UPower.displayDevice.ready) {
            hasBattery = UPower.displayDevice.isLaptopBattery
        }
    }
    
    Component.onCompleted: {
        _checkBattery()
        providerProbe.running = true
    }
    
    property var _batConn: Connections {
        target: UPower.displayDevice
        function onReadyChanged() {
            _checkBattery()
        }
    }

    // ── Keybind Interception / Hyprland Submap Controller ─────────────────────
    
    property Process submapProcess: Process {}

    property Connections keybindListener: Connections {
        target: KeybindService 
        
        function onIsCapturingChanged() {
            // Submaps are a Hyprland concept; niri has no passthrough mode and
            // key capture is disabled there. Positive guard, so this also stays
            // off on compositors that are neither Hyprland nor niri.
            if (!Compositor.isHyprland) return

            if (KeybindService.isCapturing) {
                // Enter passthrough mode (disables Hyprland binds)
                if (configProvider === "lua") {
                    submapProcess.command = ["hyprctl", "dispatch", "hl.dsp.submap('ApexShell_clean')"]
                } else {
                    submapProcess.command = ["hyprctl", "dispatch", "submap", "ApexShell_clean"]
                }
            } else {
                // Exit passthrough mode (re-enables Hyprland binds)
                if (configProvider === "lua") {
                    submapProcess.command = ["hyprctl", "dispatch", "hl.dsp.submap('reset')"]
                } else {
                    submapProcess.command = ["hyprctl", "dispatch", "submap", "reset"]
                }
            }
            
            submapProcess.running = true
        }
    }
    
    // Which Hyprland config dialect the shell writes and dispatches.
    //
    // Defaults to "conf" — Hyprland's own default format. This used to default
    // to "lua", which silently broke everyone who did not run install-arch.sh:
    // config_Provider.json is written ONLY by that script, so a manual clone, a
    // non-Arch install, or a wiped ~/.config left the value at "lua" while the
    // user's config was stock text. KeybindService._ensureInclude() then took
    // the lua branch, found no ~/.config/hypr/hyprland.lua, appended nothing,
    // and the user got a working-looking Keybinds page with zero live shortcuts
    // and no error anywhere. Workspace clicks, layout cycling, the Filter tile
    // and keybind-capture passthrough all failed the same way.
    property string configProvider: "conf"

    // Set once config_Provider.json supplies a value, so the filesystem probe
    // below never overrides an explicit installer/user choice.
    property bool _providerFromFile: false

    // Fallback detection for every install path that writes no JSON.
    property var _providerProbe: Process {
        id: providerProbe
        command: ["bash", "-c",
            "[ -f \"$HOME/.config/hypr/hyprland.lua\" ] && echo lua || echo conf"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                if (root._providerFromFile) return
                var v = text.trim()
                if (v === "lua" || v === "conf") root.configProvider = v
            }
        }
    }

    // Watch the JSON file written by the installer
    property var _providerFile: FileView {
        id: providerFile
        path: Quickshell.env("HOME") + "/.config/apex-shell/src/user_data/config_Provider.json"
        watchChanges: true
        
        onFileChanged: {
            reload()
        }
        
        onLoaded: {
            _parse(providerFile.text())
        }
    }
    
    function _parse(jsonString) {
        if (!jsonString || jsonString === "") return;
        try {
            let data = JSON.parse(jsonString)
            if (data.configProvider) {
                root.configProvider     = data.configProvider
                root._providerFromFile  = true
            }
        } catch (e) {
            console.error("APEX Shell: Failed to parse config_Provider.json")
        }
    }
}