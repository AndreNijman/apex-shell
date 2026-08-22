pragma Singleton
import Quickshell
import QtQuick
import Quickshell.Io
import Quickshell.Wayland
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

    // labwc forwards idle through ext-idle-notify, but the surface-scoped
    // Wayland inhibitor is not consistently reflected into hypridle there.
    // hypridle explicitly honours logind's `idle` block inhibitor, so hold one
    // for exactly as long as Caffeine is enabled. Keep this labwc-only: the
    // existing Wayland path remains unchanged on Hyprland and niri.
    readonly property Process caffeineInhibitor: Process {
        command: [
            "setpriv", "--pdeathsig", "TERM",
            "systemd-inhibit",
            "--what=idle",
            "--who=APEX Shell",
            "--why=Caffeine is enabled",
            "--mode=block",
            // systemd-inhibit forks the payload. Give that process the same
            // parent-death guarantee so neither side survives a shell crash.
            "setpriv", "--pdeathsig", "TERM", "sleep", "infinity"
        ]
        running: root.caffeine && Compositor.isLabwc
    }

    // VPN state must be alive with the bar, not owned by VPNTab: that tab is
    // lazy-loaded, so a connection established before opening it otherwise has
    // no indicator. VPNTab writes changes immediately; this low-frequency probe
    // catches connections made externally without leaving a monitor process
    // behind across Quickshell reloads.
    readonly property Process vpnRefresh: Process {
        // Resolve NetworkManager and sing-box in one process so an older
        // fallback result cannot overwrite a newer NetworkManager result.
        command: ["sh", "-c",
            "name=$(nmcli -t -f TYPE,NAME con show --active 2>/dev/null" +
            " | awk -F: '$1==\"wireguard\" || $1==\"vpn\" {sub(/^[^:]*:/, \"\"); print; exit}'); " +
            "if [ -z \"$name\" ] && systemctl is-active --quiet sing-box.service 2>/dev/null; then name=sing-box; fi; " +
            "printf '%s' \"$name\""]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                const name = text.trim()
                root.vpnActive = name !== ""
                if (name !== "") {
                    root.vpnName = name
                    root.vpnConnecting = false
                } else if (!root.vpnConnecting) {
                    root.vpnName = ""
                }
            }
        }
    }

    readonly property Timer vpnRefreshTimer: Timer {
        interval: 30000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: if (!root.vpnRefresh.running) root.vpnRefresh.running = true
    }

    // ── Fullscreen window tracking (bar + borders unmap for it) ──────────────
    // The bar and the three border strips are layer-shell surfaces on layer
    // `top`, which the compositor draws ABOVE a fullscreen window. So a game
    // paid for compositing four extra surfaces on every single frame, forever,
    // and anything that repainted one of them (the cava visualiser, a clock
    // tick) forced a recomposite between the game's own frames.
    //
    // Setting `visible: false` on a Quickshell PanelWindow genuinely UNMAPS the
    // layer surface — verified on hardware by watching `hyprctl layers` while
    // toggling a popup (4 -> 5 -> 4) — so there is nothing left for the
    // compositor to draw.
    //
    // ToplevelManager is wlr-foreign-toplevel-management, NOT a Hyprland
    // interface: this has to keep working under niri, which the base ships as a
    // selectable session.
    //
    // Exposed as the toplevel itself rather than a bool so each bar can check
    // whether the fullscreen window is on ITS screen; a fullscreen game on one
    // monitor should not blank the bar on another.
    readonly property var activeFullscreenToplevel: {
        var t = ToplevelManager.activeToplevel
        return (t && t.fullscreen) ? t : null
    }

    /// Whether the bar on `screenName` should unmap. Popups are separate windows
    /// anchored to the bar, so never unmap it while one is open — that would
    /// leave a popup parented to a surface that no longer exists.
    function fullscreenCovers(screenName) {
        var t = root.activeFullscreenToplevel
        if (!t)             return false
        if (Popups.anyOpen) return false
        var ss = t.screens
        // An empty/unknown screen list means the compositor did not tell us; the
        // safe reading is "it covers this output", because the alternative is
        // leaving the bar over a fullscreen game.
        if (!ss || ss.length === 0) return true
        for (var i = 0; i < ss.length; i++)
            if (ss[i] && ss[i].name === screenName) return true
        return false
    }

    // WiFi — false when radio is off OR hotspot is using the interface
    property bool wifiOn:       false

    // VPN — set by VPNTab and the low-frequency state probe, read by Network.qml
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
