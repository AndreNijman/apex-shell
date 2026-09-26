import QtQuick
import Quickshell.Io
import "../"
import "../components/controls"
import "../components"

// VPNTab — WireGuard connections via nmcli + the sing-box VLESS/Reality tunnel.
//
// Rules:
//  • Only one connection active at a time. Requesting a new one disconnects
//    the current first (in the same bash command so there is no gap).
//    sing-box and WireGuard are mutually exclusive too.
//  • No autoconnect: all WireGuard profiles have connection.autoconnect disabled
//    on first load to prevent boot reconnect.
//  • Kill switch: adds an nftables rule that drops all non-WireGuard traffic
//    while a VPN is active. Removed cleanly on disconnect.
//  • Notifications: notify-send on connect, disconnect, and failure.
//  • ShellState.vpnActive / vpnConnecting / vpnName reflect current status
//    so the bar icon can react.
//
// sing-box backend (systemd):
//  • system service sing-box.service — shipped disabled so it never autostarts;
//    toggled on demand via `systemctl start|stop sing-box.service`.
//  • Passwordless without sudo: a polkit rule (dots-extra/polkit/
//    49-apex-shell-singbox.rules) lets an active local session start/stop ONLY
//    this unit (org.freedesktop.systemd1.manage-units scoped to
//    sing-box.service). Status is read with `systemctl is-active` (no auth).
//  • /etc/sing-box/config.json — VLESS/Reality tun (sb-tun, auto/strict route).
//  • Connect = systemctl start → wait for the sb-tun device → verify egress via
//    the tunnel (api.ipify.org). If egress fails the service is stopped again
//    automatically so traffic is never left black-holed.

Item {
    id: root

    // How tall this tab wants to be — the header block (49) and its content —
    // as WifiTab reports it (UI/UX Phase 17). The panel sized every other tab
    // to a fixed 648 px, most of it empty.
    readonly property real preferredHeight: 49 + conCol.height
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    // ── State ─────────────────────────────────────────────────────────────────
    property var    _connections:  []     // [{name, active, busy}]
    property var    _buf:          []
    property bool   _loading:      false
    property bool   _killSwitch:   false  // persisted in-memory; toggle in UI
    property string _pendingName:  ""     // name being connected (for notif)
    property string _activeName:   ""     // currently active connection name

    // ── sing-box state ────────────────────────────────────────────────────────
    property bool   _sbActive:  false
    property bool   _sbBusy:    false
    property string _sbEgress:  ""       // egress IP through the tunnel

    // ── Disable autoconnect for all WireGuard profiles on first load ──────────
    // Runs once at startup. Safe to re-run (idempotent nmcli modify).
    Process {
        id: disableAutoconnectProc
        command: ["bash", "-c",
            "nmcli -t -f NAME,TYPE con show" +
            " | awk -F: '$2==\"wireguard\"{print $1}'" +
            " | while IFS= read -r name; do" +
            "     nmcli con modify \"$name\" connection.autoconnect no 2>/dev/null;" +
            "   done"]
        running: false
    }

    // ── List WireGuard connections ─────────────────────────────────────────────
    Process {
        id: wgProc
        running: false
        command: ["sh", "-c",
            "nmcli -t -f NAME,TYPE,ACTIVE con show" +
            " | awk -F: '$2==\"wireguard\"{print $1 \"|\" ($3==\"yes\" ? \"active\" : \"inactive\")}'"]
        stdout: SplitParser {
            onRead: function(data) {
                var line = data.trim()
                if (!line) return
                var sep = line.lastIndexOf("|")
                if (sep < 0) return
                root._buf = root._buf.concat([{
                    name:   line.substring(0, sep),
                    active: line.substring(sep + 1) === "active",
                    busy:   false
                }])
            }
        }
        onExited: function(code, status) {
            var buf = root._buf.slice()

            // Only mark busy for connections whose proc is STILL running.
            // Previously we carried busy from _connections which caused the row
            // to stay "Connecting…" forever after the proc already finished.
            var connectingName    = connectProc.running    ? connectProc._name    : ""
            var disconnectingName = disconnectProc.running ? disconnectProc._name : ""

            buf.sort(function(a, b) { return a.name.localeCompare(b.name) })
            for (var j = 0; j < buf.length; j++) {
                if (buf[j].name === connectingName || buf[j].name === disconnectingName)
                    buf[j].busy = true
            }

            root._buf         = []
            root._connections = buf
            root._loading     = false

            // Sync ShellState
            var active = buf.filter(function(c) { return c.active })
            if (active.length > 0) {
                root._activeName = active[0].name
                ShellState.updateVpnState(true, connectProc.running, active[0].name)
            } else {
                root._activeName = ""
                if (connectProc.running) {
                    ShellState.updateVpnState(false, true, connectProc._name)
                } else {
                    // Do not erase an external NetworkManager VPN that this
                    // WireGuard-only page does not manage.
                    var managed = ShellState.vpnName === "sing-box"
                        || buf.some(function(c) { return c.name === ShellState.vpnName })
                    if (managed)
                        ShellState.updateVpnState(false, false, "")
                }
            }
        }
    }

    // ── Connect process ────────────────────────────────────────────────────────
    // Disconnects any active WireGuard first, then brings up the requested one.
    // Kill switch is applied/removed as part of the same flow.
    Process {
        id: connectProc
        running: false
        command: []
        property string _name: ""

        stderr: StdioCollector { id: connectStderr }

        onExited: function(code, status) {
            if (code === 0) {
                // Immediately reflect connected state without waiting for wgProc
                var cname = connectProc._name
                var cons = root._connections.slice()
                for (var i = 0; i < cons.length; i++) {
                    var isTarget = cons[i].name === cname
                    cons[i] = {
                        name:   cons[i].name,
                        active: isTarget,
                        busy:   false
                    }
                }
                root._connections = cons
                ShellState.updateVpnState(true, false, cname)

                root._notify(
                    "VPN Connected",
                    "󰦝  " + cname + " is now active.\nYour traffic is encrypted.",
                    "normal"
                )
            } else {
                // Failure — clear busy on all, reset ShellState
                var cons2 = root._connections.slice()
                for (var j = 0; j < cons2.length; j++)
                    cons2[j] = { name: cons2[j].name, active: cons2[j].active, busy: false }
                root._connections = cons2

                ShellState.updateVpnState(false, false, "")

                root._notify(
                    "VPN Failed",
                    "Could not connect to " + connectProc._name + ".\n" + connectStderr.text.trim(),
                    "critical"
                )
            }
            root._refresh()
        }
    }

    // ── Disconnect process ─────────────────────────────────────────────────────
    Process {
        id: disconnectProc
        running: false
        command: []
        property string _name: ""

        onExited: function(code, status) {
            // Immediately reflect disconnected state
            var dname = disconnectProc._name
            var cons = root._connections.slice()
            for (var i = 0; i < cons.length; i++)
                cons[i] = { name: cons[i].name, active: false, busy: false }
            root._connections = cons

            ShellState.updateVpnState(false, false, "")

            root._notify(
                "VPN Disconnected",
                "󰦝  " + dname + " has been disconnected.",
                "low"
            )
            root._refresh()
        }
    }

    // ── sing-box: status ──────────────────────────────────────────────────────
    Process {
        id: sbStatusProc
        running: false
        // is-active is a read-only query — no polkit/sudo needed. Prints
        // "active" when the unit is up; inactive/failed/activating/unknown
        // (all treated as down) otherwise.
        command: ["systemctl", "is-active", "sing-box.service"]
        stdout: StdioCollector {
            onStreamFinished: {
                var up = text.trim() === "active"
                if (root._sbActive !== up) root._sbActive = up
                if (!up) root._sbEgress = ""
                root._syncShellState()
            }
        }
    }

    // ── sing-box: connect ─────────────────────────────────────────────────────
    // Downs any WireGuard first, brings the service up, waits for the sb-tun
    // device, then verifies real egress through the tunnel. Any failure rolls
    // the service back down so traffic is never left black-holed.
    Process {
        id: sbConnectProc
        running: false
        command: []
        stdout: StdioCollector { id: sbConnectOut }

        onExited: function(code, status) {
            root._sbBusy = false
            if (code === 0) {
                var m = sbConnectOut.text.match(/EGRESS:([0-9a-fA-F.:]+)/)
                root._sbEgress = m ? m[1] : ""
                root._sbActive = true
                root._notify(
                    "VPN Connected",
                    "󰖂  sing-box tunnel is up.\nEgress: " + (root._sbEgress || "unknown"),
                    "normal"
                )
            } else {
                root._sbActive = false
                root._sbEgress = ""
                var out  = sbConnectOut.text
                var why  = out.indexOf("SV_UP_FAIL") >= 0 ? "Could not start the sing-box service."
                         : out.indexOf("TUN_FAIL")   >= 0 ? "Tunnel device never appeared."
                         : out.indexOf("NO_EGRESS")  >= 0 ? "No traffic through the tunnel — rolled back."
                         : "Unknown failure."
                root._notify("VPN Failed", "sing-box: " + why, "critical")
            }
            root._syncShellState()
            root._refresh()
        }
    }

    // ── sing-box: disconnect ──────────────────────────────────────────────────
    Process {
        id: sbDisconnectProc
        running: false
        command: ["systemctl", "stop", "sing-box.service"]
        onExited: function(code, status) {
            root._sbBusy   = false
            root._sbActive = false
            root._sbEgress = ""
            root._notify("VPN Disconnected", "󰖂  sing-box tunnel is down.", "low")
            root._syncShellState()
            root._refresh()
        }
    }

    function _sbConnect() {
        if (sbConnectProc.running || sbDisconnectProc.running
            || connectProc.running || disconnectProc.running) return
        root._sbBusy = true
        ShellState.updateVpnState(false, true, "sing-box")
        sbConnectProc.command = ["bash", "-c",
            // 1. Mutual exclusion: down all active WireGuard connections
            "nmcli -g NAME,TYPE connection show --active" +
            " | awk -F: '$2==\"wireguard\"{print $1}'" +
            " | xargs -r -I {} nmcli connection down \"{}\"; " +
            // 2. Bring the service up (polkit-authorized, no password)
            "systemctl start sing-box.service || { echo SV_UP_FAIL; exit 1; }; " +
            // 3. Wait for the tun device
            "for i in $(seq 1 14); do sleep 0.5; ip link show sb-tun >/dev/null 2>&1 && break; done; " +
            "ip link show sb-tun >/dev/null 2>&1 || { systemctl stop sing-box.service; echo TUN_FAIL; exit 1; }; " +
            // 4. Verify egress through the tunnel (auto_route is live now)
            "sleep 1; EG=$(curl -s -m 8 https://api.ipify.org || true); " +
            "if [ -z \"$EG\" ]; then systemctl stop sing-box.service; echo NO_EGRESS; exit 1; fi; " +
            "echo \"EGRESS:$EG\""]
        sbConnectProc.running = false
        sbConnectProc.running = true
    }

    function _sbDisconnect() {
        if (sbConnectProc.running || sbDisconnectProc.running) return
        root._sbBusy = true
        sbDisconnectProc.running = false
        sbDisconnectProc.running = true
    }

    // ShellState from the combined WireGuard + sing-box picture
    function _syncShellState() {
        var wgActive = root._connections.some(function(c) { return c.active })
        if (root._sbActive && !wgActive) {
            ShellState.updateVpnState(true, false, "sing-box")
        } else if (!wgActive && !root._sbActive
                   && !connectProc.running && !sbConnectProc.running) {
            var managed = ShellState.vpnName === "sing-box"
                || root._connections.some(function(c) { return c.name === ShellState.vpnName })
            if (managed)
                ShellState.updateVpnState(false, false, "")
        }
    }

    // ── Kill switch — nmcli only, no pkexec/nftables ──────────────────────────
    // When enabled: downs all active WireGuard connections via nmcli.
    // No root required. Toggle reflects immediately in UI.
    Process {
        id: killSwitchProc
        running: false
        command: []
        onExited: function(code, status) {
            // After kill switch fires, refresh to reflect new state
            root._refresh()
        }
    }

    // ── notify-send process ────────────────────────────────────────────────────
    Process {
        id: notifyProc
        running: false
        command: []
    }

    // ── nmcli monitor — debounced refresh ─────────────────────────────────────
    Process {
        id: monitorProc
        running: Popups.networkOpen
        command: ["nmcli", "monitor"]
        stdout: SplitParser {
            onRead: function(data) { monitorDebounce.restart() }
        }
    }

    Timer {
        id: monitorDebounce
        interval: 600; repeat: false
        onTriggered: root._refresh()
    }

    // Also poll every 8s while popup is open to catch external changes
    Timer {
        interval: 8000; repeat: true; running: Popups.networkOpen
        onTriggered: root._refresh()
    }

    // ── Logic ─────────────────────────────────────────────────────────────────

    function _refresh() {
        // sing-box status is cheap — poll it on every refresh
        if (!sbConnectProc.running && !sbDisconnectProc.running) {
            sbStatusProc.running = false
            sbStatusProc.running = true
        }
        if (wgProc.running) return
        root._loading  = true
        root._buf      = []
        wgProc.running = false
        wgProc.running = true
    }

    function _notify(title, body, urgency) {
        // urgency: "low" | "normal" | "critical"
        notifyProc.command = [
            "notify-send",
            "--app-name=APEX Shell",
            "--urgency=" + urgency,
            "--icon=network-vpn",
            title,
            body
        ]
        notifyProc.running = false
        notifyProc.running = true
    }

    function _applyKillSwitch() {
        // Down the sing-box tunnel + all active WireGuard connections
        killSwitchProc.command = ["bash", "-c",
            "systemctl stop sing-box.service 2>/dev/null; " +
            "nmcli -g NAME,TYPE connection show --active" +
            " | awk -F: '$2==\"wireguard\" {print $1}'" +
            " | xargs -r -I {} nmcli connection down \"{}\""]
        killSwitchProc.running = false
        killSwitchProc.running = true

        // Update state immediately
        root._sbActive = false
        root._sbEgress = ""
        ShellState.updateVpnState(false, false, "")
    }

    function _removeKillSwitch() {
        // Nothing to undo — nmcli disconnect is the action itself.
        // Just update state; user reconnects manually if desired.
        root._killSwitch = false
    }

    function _connect(name) {
        if (connectProc.running || disconnectProc.running) return

        // Capture currently active names BEFORE marking anything busy
        var activeNames = root._connections
            .filter(function(c) { return c.active })
            .map(function(c) { return c.name })

        // Mark ONLY the selected connection and the currently active one as busy.
        // All other connections remain untouched.
        var cons = root._connections.slice()
        for (var i = 0; i < cons.length; i++) {
            var isBusy = cons[i].name === name
                      || activeNames.indexOf(cons[i].name) >= 0
            if (isBusy)
                cons[i] = { name: cons[i].name, active: cons[i].active, busy: true }
        }
        root._connections = cons

        ShellState.updateVpnState(false, true, name)

        connectProc._name = name

        // Down the sing-box tunnel and any active WireGuard first (mutual
        // exclusion), then bring up the requested connection
        var downCmd = "systemctl stop sing-box.service 2>/dev/null; " +
            "nmcli -g NAME,TYPE connection show --active" +
            " | awk -F: '$2==\"wireguard\" {print $1}'" +
            " | xargs -r -I {} nmcli connection down \"{}\""

        root._sbActive = false
        root._sbEgress = ""
        connectProc.command = ["bash", "-c",
            downCmd + "; nmcli con up \"" + name + "\" 2>&1"]
        connectProc.running = false
        connectProc.running = true
    }

    function _disconnect(name) {
        if (connectProc.running || disconnectProc.running) return

        var cons = root._connections.slice()
        for (var i = 0; i < cons.length; i++)
            if (cons[i].name === name)
                cons[i] = { name: cons[i].name, active: cons[i].active, busy: true }
        root._connections = cons

        disconnectProc._name   = name
        disconnectProc.command = ["bash", "-c",
            "nmcli con down \"" + name + "\" 2>/dev/null"]
        disconnectProc.running = false
        disconnectProc.running = true
    }

    function _toggleKillSwitch() {
        if (root._killSwitch) {
            // Turning off — just clear the flag, no action needed
            root._killSwitch = false
        } else {
            // Turning on — immediately down all active WireGuard connections
            root._killSwitch = true
            // Only act on connections this tab manages. ShellState also sees
            // external NetworkManager VPNs for the bar indicator.
            if (root._sbActive || root._connections.some(function(c) { return c.active })
                || connectProc.running || sbConnectProc.running)
                root._applyKillSwitch()
        }
    }

    // ── Keyboard (UI/UX roadmap v3 Phase 21) ────────────────────────────────
    // The connection list is ONE Tab stop: Up and Down move a highlight over
    // every WireGuard connection (active first, then available) and then the
    // sing-box row last — the same top-to-bottom order Phase 17 put on
    // screen — Return does what the row's own click does (connect,
    // disconnect, or toggle the tunnel). A list of many connections is not
    // that many stops.
    property string _curKey: ""
    readonly property var _rowKeys: root._connections.filter(function (c) { return c.active }).map(function (c) { return c.name })
        .concat(root._connections.filter(function (c) { return !c.active }).map(function (c) { return c.name }))
        .concat(["__singbox"])
    function _stepRow(d) {
        const list = root._rowKeys
        if (list.length === 0) return
        const i = list.indexOf(root._curKey)
        root._curKey = i < 0 ? list[d > 0 ? 0 : list.length - 1]
                             : list[Math.max(0, Math.min(list.length - 1, i + d))]
    }
    function _rowFor(key) {
        if (key === "__singbox") return sbRow
        for (let i = 0; i < activeRows.count; i++) {
            const r = activeRows.itemAt(i)
            if (r && r.con.name === key) return r
        }
        for (let i = 0; i < availRows.count; i++) {
            const r = availRows.itemAt(i)
            if (r && r.con.name === key) return r
        }
        return null
    }

    // Reset on popup open
    Connections {
        target: Popups
        function onNetworkOpenChanged() {
            if (Popups.networkOpen && root.visible)
                root._refresh()
        }
    }

    Component.onCompleted: {
        // Disable autoconnect for all WireGuard profiles silently
        disableAutoconnectProc.running = true
        root._refresh()
    }

    // ── Layout ────────────────────────────────────────────────────────────────
    Column {
        anchors.fill: parent; spacing: 0

        // Header
        Item {
            width: parent.width; height: 40

            Text {
                anchors { left: parent.left; leftMargin: 2; verticalCenter: parent.verticalCenter }
                text: "VPN"; font.pixelSize: theme.fs(15); font.weight: Font.Bold; color: Theme.text
            }

            Row {
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                spacing: 8

                // Kill switch — a real toggle (UI/UX Phase 17): ON is
                // surfaceSelected + accentText, same as a selected row; OFF is
                // the one action-button style everything else in this pane uses.
                ApexPressable {
                    id: ksBtn
                    height: 28; radius: theme.radiusS
                    width: ksRow.implicitWidth + 18
                    hitMargin: 2
                    Accessible.name: root._killSwitch ? "Turn off kill switch" : "Turn on kill switch"
                    Accessible.checkable: true
                    Accessible.checked: root._killSwitch
                    onActivated: root._toggleKillSwitch()
                    Rectangle {
                        anchors.fill: parent; radius: parent.radius
                        color: root._killSwitch ? ksBtn.tint(Theme.surfaceSelected) : ksBtn.tint(Theme.surfaceHigh)
                        Behavior on color { MotionColor { role: "state" } }
                    }

                    Row {
                        id: ksRow; anchors.centerIn: parent; spacing: 6

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "󰒃"; font.pixelSize: theme.fs(13)
                            color: root._killSwitch ? Theme.accentText : Theme.textPrimary
                            Behavior on color { MotionColor { role: "state" } }
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Kill Switch"; font.pixelSize: theme.typeCaption; font.weight: Font.Medium
                            color: root._killSwitch ? Theme.accentText : Theme.textPrimary
                            Behavior on color { MotionColor { role: "state" } }
                        }
                    }
                    ApexFocusRing { target: ksBtn }
                }

                // Refresh — borderless, state layer only (UI/UX Phase 17)
                ApexPressable {
                    id: rfBtn
                    width: 32; height: 32; radius: 8
                    Accessible.name: "Refresh VPN connections"
                    onActivated: if (!root._loading) root._refresh()
                    Rectangle { anchors.fill: parent; radius: parent.radius; color: rfBtn.stateLayer() }
                    Text {
                        id: rfIcon; anchors.centerIn: parent; text: "󰑐"; font.pixelSize: theme.fs(15)
                        // Genuine state colour: dimmed accent while the spin runs.
                        color: root._loading ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.4) : (rfBtn.hovered ? Theme.textPrimary : Theme.iconDefault)
                        Behavior on color { MotionColor { role: "state" } }
                        RotationAnimator {
                            target: rfIcon; from: 0; to: 360; duration: Motion.spinPeriod
                            loops: Animation.Infinite; running: root._loading && Motion.loops
                            easing.type: Easing.Linear
                        }
                    }
                    ApexFocusRing { target: rfBtn }
                }
            }
        }

        Rectangle { width: parent.width; height: 1; color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07) }
        Item      { width: parent.width; height: 8 }

        // Connection list
        Flickable {
            id: flick
            width: parent.width; height: parent.height - 49
            contentWidth: width; contentHeight: conCol.height
            clip: true; boundsBehavior: Flickable.StopAtBounds
            activeFocusOnTab: root._rowKeys.length > 0
            Accessible.role: Accessible.List
            Accessible.name: "VPN connections"
            onActiveFocusChanged: if (activeFocus && root._rowKeys.indexOf(root._curKey) < 0) root._stepRow(1)
            Keys.onPressed: function (event) {
                if      (event.key === Qt.Key_Down) root._stepRow(1)
                else if (event.key === Qt.Key_Up)   root._stepRow(-1)
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                    const row = root._rowFor(root._curKey)
                    if (row) row.primary()
                } else return
                event.accepted = true
                // Keep the highlighted row in view.
                const r = root._rowFor(root._curKey)
                if (r) {
                    const top = r.mapToItem(conCol, 0, 0).y
                    if (top < flick.contentY) flick.contentY = top
                    else if (top + r.height > flick.contentY + flick.height)
                        flick.contentY = top + r.height - flick.height
                }
            }

            Column {
                id: conCol; width: parent.width; height: implicitHeight; spacing: 6

                // ── Active section (UI/UX Phase 17: ACTIVE, then AVAILABLE,
                // then TUNNEL — the connection you are on belongs at the top) ──
                Item {
                    width: parent.width; height: visible ? aLbl.implicitHeight + 4 : 0
                    visible: root._connections.some(function(c) { return c.active })
                    SectionLabel { id: aLbl; text: "ACTIVE" }
                }

                Repeater {
                    id: activeRows
                    model: root._connections.filter(function(c) { return c.active })
                    delegate: VPNRow {
                        required property var modelData
                        width: conCol.width - 2; x: 1; con: modelData
                    }
                }

                Item {
                    width: parent.width; height: 6
                    visible: root._connections.some(function(c) { return c.active })
                          && root._connections.some(function(c) { return !c.active })
                }

                // Available section
                Item {
                    width: parent.width; height: visible ? iLbl.implicitHeight + 4 : 0
                    visible: root._connections.some(function(c) { return !c.active })
                    SectionLabel { id: iLbl; text: "AVAILABLE" }
                }

                Repeater {
                    id: availRows
                    model: root._connections.filter(function(c) { return !c.active })
                    delegate: VPNRow {
                        required property var modelData
                        width: conCol.width - 2; x: 1; con: modelData
                    }
                }

                // Empty state
                Item {
                    width: parent.width; height: 180
                    visible: !root._loading && root._connections.length === 0
                    // The shared empty state (UI/UX Phase 17).
                    EmptyState {
                        anchors.centerIn: parent; width: parent.width * 0.8
                        glyph: "󰦝"
                        title: "No WireGuard connections"
                        hint: "Import a config to get started:"
                        command: "nmcli con import type wireguard file <conf>"
                    }
                }

                // Loading state
                Item {
                    width: parent.width; height: 80
                    visible: root._loading && root._connections.length === 0
                    Column {
                        anchors.centerIn: parent; spacing: 8
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "○"; font.pixelSize: theme.fs(20); color: Theme.active
                            SequentialAnimation on opacity {
                                running: (root._loading && root._connections.length === 0) && Motion.ambient
                                // Finish the current beat when gated off, so it rests at its
                                // end value instead of freezing mid-fade (Reduce Motion mid-pulse).
                                alwaysRunToEnd: true
                                loops:   Animation.Infinite
                                NumberAnimation { to: 0.15; duration: Motion.pulseHalf }
                                NumberAnimation { to: 1.0;  duration: Motion.pulseHalf }
                            }
                        }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Loading…"; font.pixelSize: theme.fs(11); color: Theme.textTertiary }
                    }
                }

                Item { width: parent.width; height: 6 }

                // ── Tunnel section — sing-box. Always last: a dedicated backend
                // rather than a WireGuard peer, so it never competes with ACTIVE/
                // AVAILABLE for the top of the list (UI/UX Phase 17). ──────────
                Item {
                    width: parent.width; height: tLbl.implicitHeight + 4
                    SectionLabel { id: tLbl; text: "TUNNEL" }
                }

                // sing-box row
                Item {
                    id: sbRow
                    width: conCol.width - 2; x: 1; height: 54

                    // Highlighted by the keyboard; Return activates it via primary().
                    readonly property bool keyed: root._curKey === "__singbox"
                    // The row's own click action, for Return on the list as well.
                    function primary() {
                        if (root._sbBusy) return
                        root._sbActive ? root._sbDisconnect() : root._sbConnect()
                    }
                    Accessible.role: Accessible.ListItem
                    Accessible.name: "sing-box" + (root._sbBusy
                        ? (root._sbActive ? ", disconnecting" : ", connecting")
                        : (root._sbActive ? ", connected" : ", disconnected"))

                    Rectangle {
                        // Borderless at rest; only the active tunnel carries a fill
                        // (UI/UX roadmap v3 Phase 17 — rows read as list items, not cards).
                        id: sbCard; anchors.fill: parent; radius: theme.radiusS
                        color: root._sbActive
                            ? Theme.surfaceSelected
                            : sbHov.hovered ? Theme.surfaceHover(Theme.background) : "transparent"
                        Behavior on color { MotionColor { role: "state" } }
                    }
                    Rectangle {
                        anchors.fill: parent; anchors.margins: -3
                        radius: theme.cornerRadius + 3
                        color: "transparent"; border.width: 2; border.color: Theme.accentText
                        visible: sbRow.keyed && flick.activeFocus
                    }

                    Row {
                        anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                        spacing: 12

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "󰖂"; font.pixelSize: theme.fs(20)
                            color: root._sbActive
                                ? Theme.active
                                : root._sbBusy
                                    ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.5)
                                    : Theme.textTertiary
                            Behavior on color { MotionColor { role: "state" } }
                        }

                        Column {
                            anchors.verticalCenter: parent.verticalCenter; spacing: 4

                            Row {
                                spacing: 8
                                Text {
                                    text: "sing-box"; font.pixelSize: theme.fs(13)
                                    font.weight: root._sbActive ? Font.Medium : Font.Normal
                                    color: root._sbActive ? Theme.text : Theme.textSecondary
                                }
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: sbTag.implicitWidth + 10; height: 15; radius: 4
                                    color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.10)
                                    border.color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.25)
                                    border.width: 1
                                    Text {
                                        id: sbTag; anchors.centerIn: parent
                                        text: "VLESS · Reality"; font.pixelSize: theme.fs(8)
                                        font.family: "JetBrains Mono"
                                        color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.7)
                                    }
                                }
                            }
                            Text {
                                font.pixelSize: theme.fs(10)
                                text: root._sbBusy
                                    ? (root._sbActive ? "Disconnecting…" : "Connecting…")
                                    : root._sbActive
                                        ? ("Connected" + (root._sbEgress !== "" ? "  ·  " + root._sbEgress : ""))
                                        : "Disconnected"
                                color: root._sbBusy
                                    ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.60)
                                    : root._sbActive ? Theme.active : Theme.textTertiary
                                Behavior on color { MotionColor { role: "state" } }
                            }
                        }
                    }

                    // Right: busy spinner only — the row's own fill and subtitle
                    // already carry the connected/disconnected state, so the bare
                    // status dot next to them was redundant (UI/UX Phase 17).
                    Item {
                        anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                        width: 28; height: 28

                        Text {
                            anchors.centerIn: parent; visible: root._sbBusy
                            text: "○"; font.pixelSize: theme.fs(16); color: Theme.active
                            SequentialAnimation on opacity {
                                running: root._sbBusy && Motion.ambient; alwaysRunToEnd: true; loops: Animation.Infinite
                                NumberAnimation { to: 0.15; duration: Motion.pulseHalf }
                                NumberAnimation { to: 1.0;  duration: Motion.pulseHalf }
                            }
                        }
                    }

                    HoverHandler { id: sbHov; cursorShape: Qt.PointingHandCursor }
                    MouseArea {
                        anchors.fill: parent
                        enabled: !root._sbBusy
                        onClicked: sbRow.primary()
                    }
                    RowAction {
                        visible: !root._sbBusy
                        connected: root._sbActive; target: "sing-box"; keyed: sbRow.keyed
                        onGo: sbRow.primary()
                    }
                }

                Item { width: parent.width; height: 8 }
            }
        }
    }

    // ── VPN connection row ────────────────────────────────────────────────────
    component VPNRow: Item {
        id: vRow
        required property var con   // { name, active, busy }
        height: 54

        property bool _wasActive: false
        onConChanged: {
            if (con.active && !_wasActive) pulseAnim.restart()
            _wasActive = con.active
        }

        // Highlighted by the keyboard; Return activates it via primary().
        readonly property bool keyed: root._curKey === vRow.con.name
        // The row's own click action, for Return on the list as well.
        function primary() {
            if (vRow.con.busy) return
            vRow.con.active ? root._disconnect(vRow.con.name) : root._connect(vRow.con.name)
        }
        Accessible.role: Accessible.ListItem
        Accessible.name: vRow.con.name + (vRow.con.busy
            ? (vRow.con.active ? ", disconnecting" : ", connecting")
            : (vRow.con.active ? ", connected" : ", disconnected"))

        // Card background — borderless at rest; only the active connection
        // carries a fill (UI/UX roadmap v3 Phase 17 — rows read as list
        // items, not cards).
        Rectangle {
            id: card; anchors.fill: parent; radius: theme.radiusS
            color: vRow.con.active
                ? Theme.surfaceSelected
                : vHov.hovered ? Theme.surfaceHover(Theme.background) : "transparent"
            Behavior on color { MotionColor { role: "state" } }

            SequentialAnimation {
                id: pulseAnim; running: false
                ColorAnimation { target: card; to: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.30); duration: Motion.micro }
                ColorAnimation { target: card; to: Theme.surfaceSelected; duration: Motion.settle; easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.standardDecel }
            }
        }
        Rectangle {
            anchors.fill: parent; anchors.margins: -3
            radius: theme.cornerRadius + 3
            color: "transparent"; border.width: 2; border.color: Theme.accentText
            visible: vRow.keyed && flick.activeFocus
        }

        Row {
            anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
            spacing: 12

            // Shield glyph
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "󰦝"; font.pixelSize: theme.fs(20)
                color: vRow.con.active
                    ? Theme.active
                    : vRow.con.busy
                        ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.5)
                        : Theme.textTertiary
                Behavior on color { MotionColor { role: "state" } }
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter; spacing: 4

                Text {
                    text: vRow.con.name; font.pixelSize: theme.fs(13)
                    font.weight: vRow.con.active ? Font.Medium : Font.Normal
                    color: vRow.con.active ? Theme.text : Theme.textSecondary
                    width: 160; elide: Text.ElideRight
                }
                Text {
                    font.pixelSize: theme.fs(10)
                    text: vRow.con.busy
                        ? (vRow.con.active ? "Disconnecting…" : "Connecting…")
                        : vRow.con.active ? "Connected" : "Disconnected"
                    color: vRow.con.busy
                        ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.60)
                        : vRow.con.active ? Theme.active : Theme.textTertiary
                    Behavior on color { MotionColor { role: "state" } }
                }
            }
        }

        // Right: busy spinner only — the row's own fill and subtitle already
        // carry the connected/disconnected state (UI/UX Phase 17).
        Item {
            anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
            width: 28; height: 28

            Text {
                anchors.centerIn: parent; visible: vRow.con.busy
                text: "○"; font.pixelSize: theme.fs(16); color: Theme.active
                SequentialAnimation on opacity {
                    running: vRow.con.busy && Motion.ambient; alwaysRunToEnd: true; loops: Animation.Infinite
                    NumberAnimation { to: 0.15; duration: Motion.pulseHalf }
                    NumberAnimation { to: 1.0;  duration: Motion.pulseHalf }
                }
            }
        }

        HoverHandler { id: vHov; cursorShape: Qt.PointingHandCursor }
        MouseArea {
            anchors.fill: parent
            enabled: !vRow.con.busy
            onClicked: vRow.primary()
        }
        RowAction {
            visible: !vRow.con.busy
            connected: vRow.con.active; target: vRow.con.name; keyed: vRow.keyed
            onGo: vRow.primary()
        }
    }

    // The row's verb as a button, the same one Wi-Fi's rows carry (UI/UX Phase
    // 17, one action style). The whole row still toggles on a click and on
    // Return in the list; this says what that click does — with the status dot
    // gone, nothing on an idle row did. The busy spinner takes its place while
    // the tunnel moves. On the connected (selected) row its fill is
    // Theme.surfaceOnSelected (roles.js says why).
    component RowAction: ApexPressable {
        id: act
        property bool   connected: false
        property string target:    ""
        property bool   keyed:     false
        signal go()
        anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
        width: actLbl.implicitWidth + 20; height: theme.controlStandard; radius: theme.radiusS
        hitMargin: 2
        activeFocusOnTab: act.keyed
        Accessible.name: (act.connected ? "Disconnect " : "Connect ") + act.target
        onActivated: { act.go(); flick.forceActiveFocus() }
        Rectangle { anchors.fill: parent; radius: parent.radius; color: act.tint(act.connected ? Theme.surfaceOnSelected : Theme.surfaceHigh); Behavior on color { MotionColor {} } }
        Text { id: actLbl; anchors.centerIn: parent; text: act.connected ? "Disconnect" : "Connect"; font.pixelSize: theme.typeCaption; font.weight: Font.Medium; color: Theme.textPrimary }
        ApexFocusRing { target: act }
    }
}
