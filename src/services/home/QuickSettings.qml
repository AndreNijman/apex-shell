import Quickshell
import QtQuick
import QtQuick.Controls
import Quickshell.Io
import "../../"
import "../../components"
import "../"

// Right column — brightness slider + scrollable quick-settings grid.

StatCard {
    id: root
    padding: 0
    focus: true

    // Set by DashHome: "these tiles are genuinely in front of a user". Gates the
    // nmcli/bluetoothctl/rfkill poll below.
    property bool onScreen: false

    // ── Compositor gating ─────────────────────────────────────────────────────
    // Three tiles here only work on some compositors, and every one of them now
    // asks CompositorService what the running one can do rather than what it is
    // called:
    //
    //   Night Light  can.nightLight    hyprsunset, Hyprland's CTM protocol
    //   Filter       can.screenShader  decoration:screen_shader
    //   Focus Mode   can.gaps          keeps the bar-shrink either way
    //
    // This card was the last consumer in the shell that spawned hyprctl itself
    // — two dialects of `hl.config`, a DPMS damage cycle and a `pgrep` — and
    // all of it is in HyprlandBackend.qml now. What is left here is the tile,
    // and the one genuinely compositor-neutral part: finding shader files on
    // the user's disk, which is a directory question and not an IPC one.

    // ─────────────────────────────────────────────────────────────────────────
    //  Brightness
    // ─────────────────────────────────────────────────────────────────────────
    // Backed by BrightnessService: one shared, inotify-driven source instead of
    // this card's own `brightnessctl -m` once a second for the whole session.
    readonly property real _brightVal: BrightnessService.value

    function _setBright(v) {
        BrightnessService.set(v)
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Wi-Fi
    // ─────────────────────────────────────────────────────────────────────────
    property bool   wifiOn:   false
    property string wifiSSID: ""

    Process { id: wifiRadioRead; command: ["bash", "-c", "nmcli radio wifi"]; running: false
        stdout: SplitParser { onRead: function(l) {
            root.wifiOn = l.trim() === "enabled"
            // Expose to ShellState — suppressed while hotspot owns the interface
            ShellState.wifiOn = root.wifiOn && !ShellState.hotspot
        } } }
    Process { id: wifiSSIDRead
        command: ["bash", "-c",
            "nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | grep '^yes:' | head -1 | cut -d: -f2"]
        running: false
        stdout: SplitParser { onRead: function(l) { root.wifiSSID = l.trim() } } }
    Process { id: wifiToggleProc; command: []; running: false
        onRunningChanged: if (!running) _wifiPoll() }
    function _wifiPoll() {
        wifiRadioRead.running = false; wifiRadioRead.running = true
        wifiSSIDRead.running  = false; wifiSSIDRead.running  = true
    }
    function _wifiToggle() {
        // Do not allow wifi toggle while hotspot is using the interface
        if (root.hotspotOn || root.hotspotBusy) return
        root.wifiOn = !root.wifiOn           // optimistic — tile updates now
        ShellState.wifiOn = root.wifiOn
        wifiToggleProc.command = ["bash", "-c",
            "nmcli radio wifi " + (root.wifiOn ? "on" : "off")]
        wifiToggleProc.running = false
        wifiToggleProc.running = true
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Bluetooth
    // ─────────────────────────────────────────────────────────────────────────
    property bool   btOn:     false
    property string btDevice: ""

    Process { id: btPowerRead
        command: ["bash", "-c",
            "bluetoothctl show 2>/dev/null | grep '^\\s*Powered:' | awk '{print $2}'"]
        running: false
        stdout: SplitParser { onRead: function(l) { root.btOn = l.trim() === "yes" } } }
    Process { id: btDeviceRead
        command: ["bash", "-c",
            "bluetoothctl devices Connected 2>/dev/null | head -1 | cut -d' ' -f3-"]
        running: false
        stdout: SplitParser { onRead: function(l) { root.btDevice = l.trim() } } }
    Process { id: btToggleProc; command: []; running: false
        onRunningChanged: if (!running) {
            _btPoll()
        }
    }        
    function _btPoll() {
        btPowerRead.running  = false; btPowerRead.running  = true
        btDeviceRead.running = false; btDeviceRead.running = true
    }
    function _btToggle() {
        var turningOn = !root.btOn
        root.btOn = turningOn                // optimistic

        btToggleProc.command = ["bash", "-c",
            "bluetoothctl power " + (turningOn ? "on" : "off")]
        btToggleProc.running = false
        btToggleProc.running = true
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Night Light
    // ─────────────────────────────────────────────────────────────────────────
    // The daemon, the process that adopts an already-running one, and the kill
    // all moved into HyprlandBackend. This tile owns no processes at all now.
    readonly property bool nightLightOn: CompositorService.nightLightActive

    function _nightLightToggle() {
        CompositorService.setNightLight(!root.nightLightOn)
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Caffeine
    //
    //  A plain bool. The mechanisms hang off it elsewhere — a logind `idle`
    //  block inhibitor in ShellState (the one that works everywhere) and a
    //  Wayland surface inhibitor per TopBar window — and BOTH are held on every
    //  compositor, so this tile is never conditional on the session. Unlike
    //  Night Light and Filter above, it therefore has no capability gate and no
    //  `visible:`: a tile that can disappear is how a feature quietly stops
    //  existing on the compositor nobody tested.
    // ─────────────────────────────────────────────────────────────────────────
    readonly property bool caffeineOn: ShellState.caffeine

    function _caffeineToggle() {
        ShellState.caffeine = !ShellState.caffeine
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Do Not Disturb
    // ─────────────────────────────────────────────────────────────────────────
    function _dndToggle() {
        ShellState.dnd = !ShellState.dnd
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Hotspot — direct toggle; requires ethernet connection
    // ─────────────────────────────────────────────────────────────────────────
    property bool   hotspotOn:     false
    property bool   hotspotBusy:   false
    property bool   _hsWifiWasOff: false  // wifi radio was off when hotspot started; restore on stop
    property string hotspotLabel:  ""    // sublabel: "Active" | "Not on ethernet" | ""
    property string _hsSSID:       "ApexShell"
    property string _hsPassword:   "changeme1"
    // Empty until hsIfaceProc resolves the real device. It used to default to
    // "wlan0", so the first hotspot toggle on a wlp*-named card (or on a machine
    // with no wireless at all) ran nmcli against a device that does not exist.
    property string _hsWifiIface:  ""

    readonly property string _hsCfgPath:
        Quickshell.env("HOME") + "/.config/apex-shell/src/user_data/hotspot.json"

    // Load config on startup
    Process {
        id: hsCfgLoadProc
        command: ["bash", "-c",
            "[ -f '" + root._hsCfgPath + "' ] || " +
            "(mkdir -p \"$(dirname '" + root._hsCfgPath + "')\" && " +
            "printf '%s' '{\"ssid\":\"ApexShell\",\"password\":\"changeme1\"}' > '" + root._hsCfgPath + "'); " +
            "cat '" + root._hsCfgPath + "'"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var o = JSON.parse(text.trim())
                    if (o.ssid)     root._hsSSID     = o.ssid
                    if (o.password) root._hsPassword = o.password
                } catch(e) {}
            }
        }
    }

    // Detect WiFi interface name
    Process {
        id: hsIfaceProc
        command: ["bash", "-c",
            "nmcli -g DEVICE,TYPE dev 2>/dev/null | awk -F: '$2==\"wifi\"{print $1; exit}'"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                var n = text.trim()
                if (n !== "") root._hsWifiIface = n
            }
        }
    }

    // Check if ethernet is connected
    Process {
        id: hsEthernetCheck
        command: ["bash", "-c",
            "nmcli -t -f TYPE,STATE dev 2>/dev/null | grep -c 'ethernet:connected'"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                var hasEth = parseInt(text.trim()) > 0
                if (!hasEth) {
                    root.hotspotLabel = "Not on ethernet"
                    root.hotspotBusy  = false
                    return
                }
                // Remember whether wifi radio was off so we can restore it on stop
                root._hsWifiWasOff = !root.wifiOn
                // Ethernet confirmed — start hotspot
                root._hsDoStart()
            }
        }
    }

    // Check hotspot status
    Process {
        id: hotspotCheck
        command: ["bash", "-c",
            "nmcli -t -f TYPE,STATE dev 2>/dev/null | grep -c 'wifi:connected'"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                // If WiFi device shows 'connected' in AP mode that's our hotspot
                // Cross-check with ap-like connection
                hsActiveCheckProc.running = false; hsActiveCheckProc.running = true
            }
        }
    }

    Process {
        id: hsActiveCheckProc
        command: ["bash", "-c",
            "nmcli -t -f NAME,STATE,DEVICE con show --active 2>/dev/null" +
            " | awk -F: '$1~/[Hh]otspot/{found=1} END{print found+0}'"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                root.hotspotOn     = parseInt(text.trim()) > 0
                ShellState.hotspot = root.hotspotOn
                root.hotspotLabel  = root.hotspotOn ? "Active" : ""
                // WiFi interface is owned by hotspot — suppress from ShellState
                if (root.hotspotOn) ShellState.wifiOn = false
            }
        }
    }

    // Start hotspot
    Process {
        id: hsStartProc
        command: []
        running: false
        stderr: StdioCollector { id: hsStartErr }
        onRunningChanged: if (!running) {
            root.hotspotBusy = false
            // Re-check actual state after nmcli exits
            hsActiveCheckProc.running = false; hsActiveCheckProc.running = true
        }
        onExited: function(code, status) {
            if (code === 0) {
                root.hotspotOn     = true
                root.hotspotLabel  = "Active"
                ShellState.hotspot = true
                // WiFi interface now owned by hotspot
                ShellState.wifiOn  = false
            } else {
                root.hotspotOn    = false
                // exit 2 = no wireless interface on this machine at all.
                root.hotspotLabel = (code === 2) ? "No Wi-Fi device" : "Failed"
                ShellState.hotspot = false
                hsLabelResetTimer.restart()
            }
        }
    }

    // Stop hotspot
    Process {
        id: hsStopProc
        // Disconnect by interface — works regardless of what nmcli named the connection
        command: ["bash", "-c",
            "nmcli device disconnect " + root._hsWifiIface + " 2>/dev/null; " +
            "nmcli con delete ApexShellHotspot 2>/dev/null; true"]
        running: false
        onRunningChanged: if (!running) {
            root.hotspotBusy   = false
            root.hotspotOn     = false
            ShellState.hotspot = false
            if (root._hsWifiWasOff) {
                // Wifi radio was off before hotspot started — restore that state.
                // Turn the radio back off so the interface cycle is clean.
                root.wifiOn       = false
                ShellState.wifiOn = false
                wifiToggleProc.command = ["bash", "-c", "nmcli radio wifi off"]
                wifiToggleProc.running = false
                wifiToggleProc.running = true
                root._hsWifiWasOff = false
            } else {
                // Radio was already on — just re-expose wifi state and re-poll for SSID
                ShellState.wifiOn = root.wifiOn
                _wifiPoll()
            }
        }
    }

    Timer { id: hsLabelResetTimer; interval: 3000; repeat: false
        onTriggered: { if (root.hotspotLabel === "Failed") root.hotspotLabel = "" } }

    // Ethernet disconnect watcher — runs during polling when hotspot is active
    Process {
        id: hsEthernetLiveCheck
        command: ["bash", "-c",
            "nmcli -t -f TYPE,STATE dev 2>/dev/null | grep -c 'ethernet:connected'"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                if (!root.hotspotOn || root.hotspotBusy) return
                var hasEth = parseInt(text.trim()) > 0
                if (!hasEth) {
                    // Ethernet lost — tear down hotspot automatically
                    root.hotspotLabel = "Ethernet lost"
                    root.hotspotBusy  = true
                    // Rebuild stop command with current iface before running
                    hsStopProc.command = ["bash", "-c",
                        "nmcli device disconnect " + root._hsWifiIface + " 2>/dev/null; " +
                        "nmcli con delete ApexShellHotspot 2>/dev/null; true"]
                    hsStopProc.running = false; hsStopProc.running = true
                    hsLabelResetTimer.restart()
                }
            }
        }
    }

    function _hsDoStart() {
        // SSID / password / interface go in as positional args so they are never
        // spliced into the script. The interface is re-resolved here if startup
        // detection has not landed yet, and a machine with no wireless device at
        // all now fails fast with "No Wi-Fi" instead of running nmcli against a
        // nonexistent "wlan0".
        hsStartProc.command = ["bash", "-c",
            "IFACE=\"$3\"; " +
            "[ -n \"$IFACE\" ] || IFACE=$(nmcli -g DEVICE,TYPE dev 2>/dev/null " +
            "| awk -F: '$2==\"wifi\"{print $1; exit}'); " +
            "[ -n \"$IFACE\" ] || exit 2; " +
            // Silently bring the wifi radio up if it was off (ethernet-only scenario).
            // nmcli needs the radio enabled before it can create an AP connection.
            "nmcli radio wifi on 2>/dev/null; " +
            "sleep 1; " +
            // Disconnect whatever is currently on the interface
            "nmcli device disconnect \"$IFACE\" 2>/dev/null; " +
            "nmcli con delete ApexShellHotspot 2>/dev/null; " +
            "nmcli device wifi hotspot " +
                "ifname \"$IFACE\" ssid \"$1\" password \"$2\" " +
                "con-name ApexShellHotspot 2>&1",
            "--", root._hsSSID, root._hsPassword, root._hsWifiIface]
        hsStartProc.running = false; hsStartProc.running = true
    }

    function _hotspotToggle() {
        if (root.hotspotBusy) return
        if (root.hotspotOn) {
            root.hotspotBusy  = true
            root.hotspotLabel = ""
            // Rebuild with current iface (detected after startup)
            hsStopProc.command = ["bash", "-c",
                "nmcli device disconnect \"" + root._hsWifiIface + "\" 2>/dev/null; " +
                "nmcli con delete ApexShellHotspot 2>/dev/null; true"]
            hsStopProc.running = false; hsStopProc.running = true
        } else {
            root.hotspotBusy  = true
            root.hotspotLabel = ""
            // Check ethernet first, then start
            hsEthernetCheck.running = false; hsEthernetCheck.running = true
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Airplane Mode  (rfkill)
    // ─────────────────────────────────────────────────────────────────────────
    property bool airplaneOn: false

    Process { id: airplaneCheck
        command: ["bash", "-c",
            // Airplane = ALL radios soft-blocked.
            // nmcli radio wifi off blocks only wifi via rfkill — not bluetooth/wwan.
            // So count devices that are NOT blocked; if zero, airplane mode is on.
            "notBlocked=$(rfkill list all 2>/dev/null | grep -c 'Soft blocked: no');" +
            " total=$(rfkill list all 2>/dev/null | grep -c 'Soft blocked:');" +
            " [ \"$total\" -gt 0 ] && [ \"$notBlocked\" -eq 0 ] && echo yes || echo no"]
        running: false
        stdout: SplitParser {
            onRead: function(l) { root.airplaneOn = l.trim() === "yes" }
        }
    }
    Process { id: airplaneOn_proc
        command: ["bash", "-c", "rfkill block all"]; running: false
        onRunningChanged: if (!running) root.airplaneOn = true }
    Process { id: airplaneOff_proc
        command: ["bash", "-c", "rfkill unblock all"]; running: false
        onRunningChanged: if (!running) root.airplaneOn = false }
    function _airplaneToggle() {
        if (root.airplaneOn) {
            airplaneOff_proc.running = false; airplaneOff_proc.running = true
        } else {
            airplaneOn_proc.running = false; airplaneOn_proc.running = true
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Focus Mode
    //
    //  Shrinks the bar, and on a compositor that has runtime gaps, closes those
    //  too. The gaps half used to be four chained Processes here — two python
    //  one-liners to read two integers, one to apply, one to restore, sequenced
    //  through onRunningChanged. All of it is now two calls on the adapter, and
    //  a compositor without runtime gaps refuses them and just flips the bar,
    //  which is what the old `!isHyprland` early return did by hand.
    // ─────────────────────────────────────────────────────────────────────────
    property int _savedGapsIn:  5
    property int _savedGapsOut: 10

    // Guards a double-toggle from racing its own restore. The old code flipped
    // focusMode from restoreGaps.onRunningChanged — i.e. only once the restore
    // subprocess had exited — and that sequencing is what made this impossible.
    // Flipping immediately let a second toggle inside the window take the READ
    // branch while `hyprctl keyword general:gaps_in 5 && …` was still running:
    // if the read won, the saved gaps were overwritten with the shrunken 0/6 and
    // the user's real gaps were gone for the rest of the session. A fast
    // double-press of SUPER+B is enough.
    property bool _gapsBusy: false

    property Timer _gapsSettled: Timer {
        interval: 250
        repeat:   false
        onTriggered: root._gapsBusy = false
    }

    function _focusToggle() {
        if (root._gapsBusy) return

        if (ShellState.focusMode) {
            if (CompositorService.setGaps(root._savedGapsIn, root._savedGapsOut)) {
                root._gapsBusy = true
                root._gapsSettled.restart()
            }
            ShellState.focusMode = false
            return
        }

        // Read before shrinking, so what gets restored is what the user had and
        // not the 5/10 default. If the read fails — or gaps are not a runtime
        // concept here — fall through to flipping the bar alone rather than
        // applying a shrink we could never undo.
        CompositorService.readGaps(function (ok, g) {
            if (ok) {
                root._savedGapsIn  = g.inner
                root._savedGapsOut = g.outer
                if (CompositorService.setGaps(0, 6)) {
                    root._gapsBusy = true
                    root._gapsSettled.restart()
                }
            }
            ShellState.focusMode = true
        })
    }
    
    Connections {
        target: IpcManager
        function onFocusToggleRequested() {
            root._focusToggle()
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Filter  (screen shader)
    //
    //  Tile click: runs bash `find`, opens picker popup above the tile.
    //  Picker has "Off" at top + all available shaders.
    //  Selecting a shader hands its ABSOLUTE PATH to the adapter; selecting the
    //  active one or "Off" hands it "".
    //
    //  What used to be here: two dialects of `hyprctl`, a DPMS damage cycle and
    //  a `python3 -c` JSON reader. All of that is HyprlandBackend's now. The
    //  split is deliberate — *which file* is a question about the user's shader
    //  directories, and *how to apply it* is a question about the compositor.
    // ─────────────────────────────────────────────────────────────────────────
    readonly property string currentFilter: CompositorService.screenShader
    property var    filterList:       []
    property bool   filterPickerOpen: false

    // name → absolute path, built from the same `find` that fills filterList.
    //
    // The old code re-ran `find` at apply time with the chosen name spliced
    // into a `-name` pattern, which meant the shader name reached a shell as
    // code. Resolving once at list time and passing the path as an argument
    // removes that entirely, and it removes the silent failure mode where the
    // second `find` came back empty and the apply did nothing.
    property var _filterPaths: ({})

    // Add your standard shader directories here (space-separated)
    // Shell-owned shaders are resolved from Quickshell.shellDir so they are found
    // wherever the shell is checked out, not only at ~/.local/src/apex-shell.
    property string shaderPaths: "~/.config/hypr/shaders ~/.local/share/hypr/shaders /usr/share/hyprshade/shaders "
                                 + "'" + Quickshell.shellDir + "/src/config/shaders'"

    function _filterApply(name) {
        // No compositor guard needed: setScreenShader refuses on a backend
        // without the capability and spawns nothing. This function used to have
        // no guard at all and fired hyprctl on niri and on any third compositor.
        var turningOff = (name === "" || name === root.currentFilter)
        if (turningOff) {
            CompositorService.setScreenShader("")
        } else {
            var path = root._filterPaths[name]
            // An entry with no resolved path cannot be applied. Nothing is
            // handed to the adapter, because "" means OFF and turning the
            // filter off is not what the user asked for.
            if (path === undefined || path === "") { root.filterPickerOpen = false; return }
            CompositorService.setScreenShader(path)
        }
        root.filterPickerOpen = false
    }

    Connections {
        target: WallpaperService
        // A wallpaper apply can reload the compositor's config, which resets
        // the shader to whatever the config file says. Re-read rather than keep
        // showing the value from before the reload.
        enabled: CompositorService.can.screenShader
        function onWallpaperApplied(path) {
            CompositorService.refreshScreenShader()
        }
    }

    Connections {
        target: Popups
        function onDashboardOpenChanged() {
            if (!Popups.dashboardOpen) root.filterPickerOpen = false
        }
    }

    Process {
        id: filterListProc
        // Replaces `hyprshade ls` by searching your directories. Full paths
        // now, not basenames: the picker needs a label AND something to apply.
        command: ["bash", "-c", "find " + root.shaderPaths + " -maxdepth 1 -type f \\( -name '*.glsl' -o -name '*.frag' \\) 2>/dev/null | sort"]
        running: false
        stdout: SplitParser {
            onRead: function(l) {
                var p = l.trim()
                if (p === "") return
                var n = p.replace(/^.*\//, "").replace(/\.[^.]*$/, "")
                if (n === "") return
                // First path wins, which is what the old `sort -u | head -n 1`
                // pair did: a shader in ~/.config shadows one in /usr/share.
                if (root._filterPaths[n] !== undefined) return
                var m = root._filterPaths
                m[n] = p
                root._filterPaths = m
                root.filterList = root.filterList.concat([n])
            }
        }
    }

    function _filterOpen() {
        root.filterList  = []
        root._filterPaths = ({})
        filterListProc.running = false
        filterListProc.running = true
        root.filterPickerOpen  = true
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Polling timer
    // ─────────────────────────────────────────────────────────────────────────
    // Roughly six forks every five seconds (two nmcli for wifi, two
    // bluetoothctl, a hotspot check and an rfkill check). None of it is
    // meaningful unless a human is looking at the tiles, so it runs only while
    // the card is actually on screen. It fires immediately on becoming visible,
    // so the tiles are never stale when the dashboard opens.
    Timer {
        interval: 5000; running: root.onScreen; repeat: true; triggeredOnStart: true
        onTriggered: {
            _wifiPoll(); _btPoll()
            hsActiveCheckProc.running = false; hsActiveCheckProc.running = true
            airplaneCheck.running = false; airplaneCheck.running = true
            // Monitor ethernet while hotspot is active
            if (root.hotspotOn && !root.hotspotBusy) {
                hsEthernetLiveCheck.running = false; hsEthernetLiveCheck.running = true
            }
        }
    }

    Component.onCompleted: {
        // Night-light and screen-shader state are no longer probed here: the
        // backend owns both and reads them once at startup, so the tiles are
        // correct the first time the dashboard opens instead of a fork later.
        _wifiPoll(); _btPoll()
        hotspotCheck.running    = true
        airplaneCheck.running   = true
        hsCfgLoadProc.running   = true
        hsIfaceProc.running     = true
        hsActiveCheckProc.running = true
    }

    // ── The quick-settings-tile extension point (roadmap §16) ─────────────────
    // Non-visual: it hosts one Loader per granted tile plugin and exposes the
    // sanitised descriptors the Repeater at the end of the grid draws. A plugin
    // tile cannot flip a system switch — that would be the `system` permission,
    // which is refused at load — so it surfaces information and acts inside
    // whatever it was granted. See PluginTiles.qml.
    PluginTiles { id: pluginTiles }

    // ─────────────────────────────────────────────────────────────────────────
    //  UI
    // ─────────────────────────────────────────────────────────────────────────
    Column {
        anchors { fill: parent; margins: 12 }
        spacing: 0

        // ── Brightness ────────────────────────────────────────────────────────
        Item {
            width: parent.width
            height: 52

            Text {
                id: brightLbl
                anchors { left: parent.left; top: parent.top }
                text: "BRIGHTNESS"; font.pixelSize: Theme.fs(9); font.weight: Font.Bold
                color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.55)
            }
            Text {
                anchors { right: parent.right; top: parent.top }
                text: Math.round(root._brightVal * 100) + "%"
                font.pixelSize: Theme.fs(9); font.family: "JetBrains Mono"; font.weight: Font.Bold
                color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.7)
            }

            Row {
                anchors { left: parent.left; right: parent.right; top: brightLbl.bottom; topMargin: 8 }
                spacing: 8

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰃞"; font.pixelSize: Theme.fs(13)
                    color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.35)
                }

                Item {
                    id: btw
                    width: parent.width - 13 - 13 - parent.spacing * 2
                    height: 30; anchors.verticalCenter: parent.verticalCenter
                    anchors.bottomMargin: 30
                    readonly property int thumbD: 14

                    Rectangle {
                        id: btrack
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width; height: 5; radius: height / 2
                        color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.12)
                        Rectangle {
                            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                            width: Math.max(parent.radius * 2, parent.width * root._brightVal)
                            radius: parent.radius; color: Theme.active
                            Behavior on width { NumberAnimation { duration: 80; easing.type: Easing.OutCubic } }
                        }
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            function _c(mx) {
                                return Math.max(0.0, Math.min(1.0,
                                    (mx - btw.thumbD/2) / (btrack.width - btw.thumbD)))
                            }
                            onPressed:         root._setBright(_c(mouseX))
                            onPositionChanged: if (pressed) root._setBright(_c(mouseX))
                        }
                        }

                     WheelHandler {
                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                        onWheel: function(e) {
                            root._setBright(root._brightVal + (e.angleDelta.y > 0 ? 0.05 : -0.05))
                        }
                    }
                    Rectangle {
                        width: btw.thumbD; height: btw.thumbD; radius: btw.thumbD / 2
                        color: Theme.fixedLight; anchors.verticalCenter: parent.verticalCenter
                        x: Math.max(0, Math.min(btw.width - width, root._brightVal * (btw.width - width)))
                        Behavior on x { NumberAnimation { duration: 80; easing.type: Easing.OutCubic } }
                    }
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰃠"; font.pixelSize: Theme.fs(13)
                    color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.75)
                }
            }
        }

        Rectangle {
            width: parent.width; height: 1
            color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.08)
        }
        Item { width: parent.width; height: 8 }

        Text {
            id: qsLbl; width: parent.width
            text: "QUICK SETTINGS"; font.pixelSize: Theme.fs(9); font.weight: Font.Bold
            color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.55)
        }
        Item { width: parent.width; height: 8 }

        // ── Tile grid ─────────────────────────────────────────────────────────
        Item {
            width:  parent.width
            height: root.height - 12 - 52 - 1 - 8 - qsLbl.height - 8

            Flickable {
                id: flick
                anchors.fill:   parent
                contentWidth:   width
                contentHeight:  tileGrid.implicitHeight + 8
                clip:           true
                boundsBehavior: Flickable.StopAtBounds

                component TglBtn: Rectangle {
                    id: btn
                    required property bool   on
                    required property string icon
                    required property string label
                    property  string sublabel: ""
                    signal toggled()

                    radius: 10
                    color: on
                        ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.14)
                        : bH.hovered
                            ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.08)
                            : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.04)
                    border.color: on
                        ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.30)
                        : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10)
                    border.width: 1
                    Behavior on color        { ColorAnimation { duration: 130 } }
                    Behavior on border.color { ColorAnimation { duration: 130 } }

                    Rectangle {
                        anchors { top: parent.top; right: parent.right; margins: 8 }
                        width: 6; height: 6; radius: 3
                        color: btn.on ? Theme.active : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.18)
                        Behavior on color { ColorAnimation { duration: 130 } }
                    }

                    Column {
                        anchors { left: parent.left; bottom: parent.bottom; margins: 9 }
                        spacing: 2
                        Text {
                            text: btn.icon; font.pixelSize: Theme.fs(17)
                            color: btn.on ? Theme.active : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.40)
                            Behavior on color { ColorAnimation { duration: 130 } }
                        }
                        Text {
                            text: btn.label; font.pixelSize: Theme.fs(9); font.weight: Font.Medium
                            color: btn.on ? Theme.text : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.45)
                            Behavior on color { ColorAnimation { duration: 130 } }
                        }
                        Text {
                            visible: btn.sublabel !== ""
                            text:    btn.sublabel
                            font.pixelSize: Theme.fs(8); font.family: "JetBrains Mono"
                            color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.65)
                            width: btn.width - 18; elide: Text.ElideRight
                        }
                    }
                    HoverHandler { id: bH; cursorShape: Qt.PointingHandCursor }
                    MouseArea    { anchors.fill: parent; onClicked: btn.toggled() }
                }

                Grid {
                    id: tileGrid
                    width: flick.width
                    columns: 2; spacing: 6

                    readonly property real btnW: (width - spacing) / 2
                    readonly property real btnH: btnW * 0.85

                    TglBtn {
                        width: tileGrid.btnW; height: tileGrid.btnH
                        on: root.wifiOn && !root.hotspotOn
                        icon: (root.wifiOn && !root.hotspotOn) ? "󰤨" : "󰤭"; label: "Wi-Fi"
                        sublabel: (root.wifiOn && !root.hotspotOn) && root.wifiSSID !== "" ? root.wifiSSID : (root.hotspotOn ? "Used by Hotspot" : "")
                        onToggled: root._wifiToggle()
                    }
                    TglBtn {
                        width: tileGrid.btnW; height: tileGrid.btnH
                        on: root.btOn; icon: root.btOn ? "󰂱" : "󰂲"; label: "Bluetooth"
                        sublabel: root.btOn && root.btDevice !== "" ? root.btDevice : ""
                        onToggled: root._btToggle()
                    }
                    TglBtn {
                        width: tileGrid.btnW; height: tileGrid.btnH
                        on: root.airplaneOn; icon: "󰀝"; label: "Airplane Mode"
                        onToggled: root._airplaneToggle()
                    }
                    TglBtn {
                        width: tileGrid.btnW; height: tileGrid.btnH
                        on: root.hotspotOn || root.hotspotBusy
                        icon: "󰀃"
                        label: "Hotspot"
                        sublabel: root.hotspotLabel
                        onToggled: root._hotspotToggle()
                    }
                    TglBtn {
                        // Hidden on a capability, not a compositor name.
                        // hyprsunset shifts colour temperature through a
                        // Hyprland-only protocol; wlsunset would be the wlroots
                        // equivalent and APEX does not ship it, so the backends
                        // that would use it declare false.
                        visible: CompositorService.can.nightLight
                        width: tileGrid.btnW; height: tileGrid.btnH
                        on: root.nightLightOn; icon: "󰖐"; label: "Night Light"
                        onToggled: root._nightLightToggle()
                    }
                    TglBtn {
                        width: tileGrid.btnW; height: tileGrid.btnH
                        on: root.caffeineOn; icon: "󰅶"; label: "Caffeine"
                        onToggled: root._caffeineToggle()
                    }
                    TglBtn {
                        width: tileGrid.btnW; height: tileGrid.btnH
                        on: ShellState.focusMode
                        icon: ShellState.focusMode ? "󱃕" : "󰍻"; label: "Focus Mode"
                        onToggled: root._focusToggle()
                    }
                    TglBtn {
                        width: tileGrid.btnW; height: tileGrid.btnH
                        on: ShellState.dnd; icon: ShellState.dnd ? "󰂛" : "󰂚"
                        label: "Do Not Disturb"
                        onToggled: root._dndToggle()
                    }
                    TglBtn {
                        width: tileGrid.btnW; height: tileGrid.btnH
                        on:    ShellState.screenRecord || ScreenRecService.recording
                        icon:  ScreenRecService.recording ? "⏹" : "󰻂"
                        label: ScreenRecService.recording ? "Recording" : "Screen Capture"
                        onToggled: {
                            if (ScreenRecService.recording) {
                                ScreenRecService.stopRecording()
                            } else if (ShellState.screenRecord) {
                                ScreenRecService.cancelSetup()
                            } else {
                                Popups.closeAll()
                                ShellState.screenRecord = true
                            }
                        }
                    }
                    // Filter tile — opens picker, does not toggle directly.
                    // Only Hyprland has a fullscreen-shader hook, which is what
                    // can.screenShader answers.
                    TglBtn {
                        visible: CompositorService.can.screenShader
                        width: tileGrid.btnW; height: tileGrid.btnH
                        on:       root.currentFilter !== ""
                        icon:     "󱡓"
                        label:    "Filter"
                        sublabel: root.currentFilter !== "" ? root.currentFilter : ""
                        onToggled: root._filterOpen()
                    }

                    // ── Plugin tiles (roadmap §16) ────────────────────────
                    // LAST, unconditionally, so the shell's own tiles keep the
                    // positions users have muscle memory for. A plugin
                    // appearing must not move Wi-Fi.
                    //
                    // The delegate is the same TglBtn every tile above uses,
                    // which is the point of the extension point: the plugin
                    // supplies four values and the shell draws its own tile.
                    // A plugin cannot paint here, so it cannot draw something
                    // that looks like the Airplane Mode switch. Every value
                    // below has been through Manifest.quickTile(); see
                    // PluginTiles.qml.
                    Repeater {
                        model: pluginTiles.tiles

                        delegate: TglBtn {
                            required property var modelData

                            width: tileGrid.btnW; height: tileGrid.btnH
                            on:       modelData.on
                            icon:     modelData.icon
                            label:    modelData.label
                            sublabel: modelData.sublabel
                            onToggled: pluginTiles.toggle(modelData.pluginId)
                        }
                    }
                }
            }
        }
    }

    // ── Filter picker popup ───────────────────────────────────────────────────
    // Floats above the bottom-right tile. z:20 renders it over the grid.
    // Anchored bottom-right of the StatCard's inner area.
    Rectangle {
        id: filterPicker
        visible:  root.filterPickerOpen
        z:        20
        
        onVisibleChanged: {
            if (visible) {
                forceActiveFocus()
            } else {
                root.forceActiveFocus()
            }
        }

        Keys.onEscapePressed: function(event) {
            root.filterPickerOpen = false
            event.accepted = true // <--- Prevents the dashboard from closing
        }

        anchors {
            right:        parent.right
            bottom:       parent.bottom
            rightMargin:  12
            bottomMargin: 12
        }

        width:  180
        // Height fits "Off" row + all shader rows, capped at 280
        height: Math.min(280, pickerCol.implicitHeight + 16)
        radius: Theme.cornerRadius

        color: Qt.rgba(
            Math.min(1, Theme.background.r + 0.05),
            Math.min(1, Theme.background.g + 0.05),
            Math.min(1, Theme.background.b + 0.05),
            0.98)
        border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10)
        border.width: 1

        // Subtle entrance scale + fade
        opacity: root.filterPickerOpen ? 1 : 0
        scale:   root.filterPickerOpen ? 1 : 0.95
        Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        Behavior on scale   { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        transformOrigin: Item.BottomRight

        // Dismiss when clicking outside the picker
        MouseArea {
            anchors.fill: parent
            // Swallow clicks so they don't fall through to tiles below
            onClicked: {} // intentionally empty — keeps picker open on internal clicks
        }

        Flickable {
            anchors { fill: parent; margins: 8 }
            contentWidth:   width
            contentHeight:  pickerCol.implicitHeight
            clip:           true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: pickerCol
                width: parent.width
                spacing: 2

                // Header label
                Text {
                    width: parent.width
                    text: "SHADER"
                    font.pixelSize: Theme.fs(9); font.weight: Font.Bold
                    color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.55)
                    leftPadding: 4
                    bottomPadding: 4
                }

                // "Off" row — always first
                Rectangle {
                    width:  parent.width
                    height: 28
                    radius: 6
                    property bool isActive: root.currentFilter === ""
                    color: isActive
                        ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.14)
                        : offH.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07) : "transparent"
                    Behavior on color { ColorAnimation { duration: 100 } }

                    Row {
                        anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                        spacing: 8
                        Text {
                            text:           parent.parent.isActive ? "●" : "○"
                            font.pixelSize: Theme.fs(9)
                            color: parent.parent.isActive ? Theme.active : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.30)
                            anchors.verticalCenter: parent.verticalCenter
                            Behavior on color { ColorAnimation { duration: 100 } }
                        }
                        Text {
                            text:           "Off"
                            font.pixelSize: Theme.fs(12)
                            color: parent.parent.isActive ? Theme.active : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.65)
                            anchors.verticalCenter: parent.verticalCenter
                            Behavior on color { ColorAnimation { duration: 100 } }
                        }
                    }
                    HoverHandler { id: offH; cursorShape: Qt.PointingHandCursor }
                    TapHandler   { onTapped: root._filterApply("") }
                }

                // Divider
                Rectangle {
                    width: parent.width; height: 1
                    color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07)
                }

                // Shader rows — populated by hyprshade ls
                Repeater {
                    model: root.filterList
                    delegate: Rectangle {
                        required property string modelData
                        property bool isActive: root.currentFilter === modelData

                        width:  pickerCol.width
                        height: 28
                        radius: 6
                        color: isActive
                            ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.14)
                            : itemH.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07) : "transparent"
                        Behavior on color { ColorAnimation { duration: 100 } }

                        Row {
                            anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                            spacing: 8
                            Text {
                                text:           parent.parent.isActive ? "●" : "○"
                                font.pixelSize: Theme.fs(9)
                                color: parent.parent.isActive ? Theme.active : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.30)
                                anchors.verticalCenter: parent.verticalCenter
                                Behavior on color { ColorAnimation { duration: 100 } }
                            }
                            Text {
                                text:           modelData
                                font.pixelSize: Theme.fs(12)
                                color: parent.parent.isActive ? Theme.active : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.65)
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                                width: pickerCol.width - 38
                                Behavior on color { ColorAnimation { duration: 100 } }
                            }
                        }
                        HoverHandler { id: itemH; cursorShape: Qt.PointingHandCursor }
                        TapHandler   { onTapped: root._filterApply(modelData) }
                    }
                }

                // Empty state — shown while hyprshade ls is still running
                Text {
                    width:   parent.width
                    visible: root.filterList.length === 0
                    text:    "Loading…"
                    font.pixelSize: Theme.fs(11)
                    color:   Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.25)
                    horizontalAlignment: Text.AlignHCenter
                    topPadding: 4
                }
            }
        }
    }

    // Tap outside the picker to close it
    TapHandler {
        enabled: root.filterPickerOpen
        onTapped: root.filterPickerOpen = false
    }
}
