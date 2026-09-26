import QtQuick
import Quickshell.Io
import "../"
import "../components/controls"
import "../components"

// BluetoothTab — bluetooth device management.
// _btPowered tracks adapter state; overlay shows when off.
// Scan disabled while adapter is off.

Item {
    id: root

    // How tall this tab wants to be — the header block (49) and its content —
    // as WifiTab reports it (UI/UX Phase 17). The panel sized every other tab
    // to a fixed 648 px, most of it empty.
    readonly property real preferredHeight: 49 + devCol.height + (root._scanning ? 90 : 0)
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    property var    _allDevices:  []
    property bool   _scanning:    false
    property bool   _btPowered:   true
    property string _actionMac:   ""
    property string _removeMac:   ""
    property string _removingMac: ""
    property string _pairingMac:  ""

    readonly property var _paired: {
        var r = []
        for (var i = 0; i < _allDevices.length; i++)
            if (_allDevices[i].paired) r.push(_allDevices[i])
        return r
    }
    readonly property var _available: {
        var r = []
        for (var i = 0; i < _allDevices.length; i++)
            if (!_allDevices[i].paired) r.push(_allDevices[i])
        return r
    }

    function _iconFromName(name) {
        var n = name.toLowerCase()
        if (n.match(/head(phone|set)|earphone|earpad|airpod|buds|wf-|wh-|ep-|tws/)) return "headphone"
        if (n.match(/speaker|soundbar|boom|jbl|bose|harman|charge|flip|pulse/))      return "speaker"
        if (n.match(/keyboard|kbd/))                                                   return "keyboard"
        if (n.match(/mouse|trackpad|trackball|mx master|mx anywhere/))                return "mouse"
        if (n.match(/phone|iphone|android|galaxy|pixel|oneplus|xperia|redmi/))        return "phone"
        if (n.match(/macbook|laptop|thinkpad|xps|zenbook|surface/))                   return "laptop"
        if (n.match(/watch|band|garmin|fitbit|amazfit|mi band|polar/))                return "watch"
        if (n.match(/controller|gamepad|dualshock|dualsense|xbox|joycon|steam/))      return "gamepad"
        if (n.match(/tv |television|bravia|smart-tv/))                                 return "tv"
        return "default"
    }

    function _glyph(t) {
        switch(t){
            case "headphone": return "󰋋"
            case "speaker":   return "󰓃"
            case "keyboard":  return "󰌌"
            case "mouse":     return "󰍽"
            case "phone":     return "󰄜"
            case "laptop":    return "󰌢"
            case "watch":     return "󰢗"
            case "gamepad":   return "󰊖"
            case "tv":        return "󰔮"
            default:          return "󰂯"
        }
    }

    Connections {
        target: Popups
        function onNetworkOpenChanged() {
            if (Popups.networkOpen && root.visible) {
                root._pairingMac  = ""
                root._removeMac   = ""
                root._removingMac = ""
                root._actionMac   = ""
                root._loadDevices()
            }
        }
    }

    // List query — includes POWERED check
    Process {
        id: listProc
        command: [
            "bash", "-c",
            "echo 'POWERED:'; " +
            "bluetoothctl show 2>/dev/null | awk '/Powered:/{print $2}'; " +
            "echo 'PAIRED:'; " +
            "bluetoothctl devices Paired    2>/dev/null | awk '{print $2}'; " +
            "echo 'CONNECTED:'; " +
            "bluetoothctl devices Connected 2>/dev/null | awk '{print $2}'; " +
            "echo 'ALL:'; " +
            "bluetoothctl devices           2>/dev/null"
        ]
        running: false
        stdout: StdioCollector { onStreamFinished: root._parseDevices(text) }
    }

    // Scan — pipe commands into interactive bluetoothctl
    Process {
        id: scanProc
        command: [
            "bash", "-c",
            "trap 'echo scan off | bluetoothctl 2>/dev/null' EXIT; " +
            "(echo 'power on'; echo 'scan on'; sleep 8) | timeout 9 bluetoothctl 2>/dev/null"
        ]
        running: false
        stdout: SplitParser {
            onRead: function(line) {
                var m = line.match(/\[NEW\]\s+Device\s+([0-9A-Fa-f:]{17})\s+(.+)/)
                if (!m) return
                var mac = m[1]; var name = m[2].trim()
                var devs = root._allDevices.slice()
                for (var i = 0; i < devs.length; i++) if (devs[i].mac === mac) return
                devs.push({ mac: mac, name: name, paired: false, connected: false, iconType: root._iconFromName(name) })
                root._allDevices = devs
            }
        }
        onRunningChanged: if (!running) { root._scanning = false; scanPollTimer.stop(); root._loadDevices() }
    }

    Timer { id: scanPollTimer; interval: 2000; repeat: true; running: false; onTriggered: root._loadDevices() }

    Process {
        id: actionProc
        command: []
        running: false
        onRunningChanged: if (!running) { root._actionMac = ""; root._loadDevices() }
    }

    Process {
        id: removeProc
        command: []
        running: false
        onRunningChanged: if (!running) { root._removingMac = ""; root._loadDevices() }
    }

    Process {
        id: powerProc
        command: []
        running: false
        onRunningChanged: if (!running) root._loadDevices()
    }

    Process { id: bluemanProc; command: ["blueman-manager"]; running: false }

    // Refresh the device list while the tab is actually being looked at. This
    // used to be `running: true`, so once the network popup had been opened even
    // once, `bluetoothctl` ran every 8 seconds for the rest of the session — the
    // same guard already used for the scan trigger at the top of this file.
    Timer {
        interval: 8000
        repeat: true
        running: Popups.networkOpen && root.visible
        triggeredOnStart: true
        onTriggered: if (!root._scanning) root._loadDevices()
    }

    function _loadDevices() {
        if (listProc.running) return
        listProc.running = false
        listProc.running = true
    }

    function _parseDevices(raw) {
        var lines = raw.split("\n")
        var mode = ""; var paired = {}; var conn = {}; var known = {}

        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim()
            if (line === "POWERED:")   { mode = "powered";   continue }
            if (line === "PAIRED:")    { mode = "paired";    continue }
            if (line === "CONNECTED:") { mode = "connected"; continue }
            if (line === "ALL:")       { mode = "all";       continue }
            if (line === "")           continue

            if (mode === "powered") {
                var p = line.toLowerCase() === "yes"
                root._btPowered = p
                continue
            }
            if (mode === "paired")    { paired[line] = true; continue }
            if (mode === "connected") { conn[line]   = true; continue }
            if (mode === "all") {
                var parts = line.split(" ")
                if (parts.length < 3 || parts[0] !== "Device") continue
                var mac = parts[1]; var name = parts.slice(2).join(" ")
                if (mac && name) known[mac] = name
            }
        }

        var seenMac = {}; var devs = []
        for (var mac in known) {
            if (seenMac[mac]) continue
            seenMac[mac] = true
            devs.push({ mac: mac, name: known[mac], paired: !!paired[mac], connected: !!conn[mac], iconType: root._iconFromName(known[mac]) })
        }
        var existing = root._allDevices
        for (var j = 0; j < existing.length; j++) {
            var d = existing[j]
            if (seenMac[d.mac]) continue
            seenMac[d.mac] = true
            devs.push({ mac: d.mac, name: d.name, paired: !!paired[d.mac], connected: !!conn[d.mac], iconType: d.iconType })
        }
        root._allDevices = devs
    }

    // ── Keyboard (UI/UX roadmap v3 Phase 21) ────────────────────────────────
    // The device list is ONE Tab stop: Up and Down move a highlight over the
    // paired devices then the available ones, Return does what the row's own
    // button does (connect/disconnect, or pair). Tab from the list reaches the
    // highlighted row's buttons, which are Tab stops only while it is
    // highlighted, so a list of many devices is not many times that in stops.
    property string _curMac: ""
    readonly property var _rowMacs: root._paired.map(function (d) { return d.mac })
                                     .concat(root._available.map(function (d) { return d.mac }))
    function _stepRow(d) {
        const list = root._rowMacs
        if (list.length === 0) return
        const i = list.indexOf(root._curMac)
        root._curMac = i < 0 ? list[d > 0 ? 0 : list.length - 1]
                             : list[Math.max(0, Math.min(list.length - 1, i + d))]
    }
    function _rowFor(mac) {
        for (let i = 0; i < pairedRows.count; i++) {
            const r = pairedRows.itemAt(i)
            if (r && r.device.mac === mac) return r
        }
        for (let i = 0; i < availRows.count; i++) {
            const r = availRows.itemAt(i)
            if (r && r.device.mac === mac) return r
        }
        return null
    }

    function _setPower(on) {
        root._btPowered = on
        if (!on) root._allDevices = []
        powerProc.command = ["bluetoothctl", "power", on ? "on" : "off"]
        powerProc.running = false
        powerProc.running = true
    }

    function _startScan() {
        if (!root._btPowered) return
        if (root._scanning) {
            root._scanning = false
            scanProc.running = false
            scanPollTimer.stop()
            root._loadDevices()
            return
        }
        root._scanning = true
        scanProc.running = false
        scanProc.running = true
        scanPollTimer.restart()
    }

    function _connect(mac) {
        root._actionMac = mac
        root._pairingMac = ""
        actionProc.command = ["bluetoothctl", "connect", mac]
        actionProc.running = false; actionProc.running = true
    }

    function _disconnect(mac) {
        root._actionMac = mac
        actionProc.command = ["bluetoothctl", "disconnect", mac]
        actionProc.running = false; actionProc.running = true
    }

    function _pair(mac, pin) {
        root._actionMac = mac; root._pairingMac = ""
        actionProc.command = pin !== ""
            ? ["bash", "-c",
                "(echo 'default-agent'; echo \"trust $1\"; echo \"pair $1\"; sleep 1; printf '%s\\n' \"$2\"; sleep 4) | timeout 12 bluetoothctl 2>/dev/null",
                "--", mac, pin]
            : ["bash", "-c",
                "(echo 'default-agent'; echo \"trust $1\"; echo \"pair $1\"; sleep 1; echo 'yes'; sleep 4) | timeout 12 bluetoothctl 2>/dev/null",
                "--", mac]
        actionProc.running = false; actionProc.running = true
    }

    function _remove(mac) {
        root._removeMac = ""; root._removingMac = mac
        removeProc.command = ["bash", "-c",
            "bluetoothctl untrust \"$1\" 2>/dev/null; " +
            "bluetoothctl disconnect \"$1\" 2>/dev/null; " +
            "bluetoothctl remove \"$1\" 2>/dev/null",
            "--", mac]
        removeProc.running = false; removeProc.running = true
    }

    Component.onCompleted: _loadDevices()

    // ── Scan rings ────────────────────────────────────────────────────────────
    component ScanRings: Item {
        id: ringsRoot
        property string centerGlyph: "󰂯"
        property int    glyphSize:   18
        Repeater {
            model: 4
            delegate: Rectangle {
                required property int index
                anchors.centerIn: parent
                width: ringsRoot.width; height: ringsRoot.width; radius: ringsRoot.width / 2
                color: "transparent"
                border.color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.80)
                border.width: 1.5; opacity: 0; scale: 0.08
                SequentialAnimation {
                    running: root._scanning && Motion.ambient; alwaysRunToEnd: true; loops: Animation.Infinite
                    PauseAnimation { duration: index * Motion.scanStagger }
                    ParallelAnimation {
                        NumberAnimation { property: "scale";   from: 0.08; to: 1.0; duration: Motion.scanPeriod; easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.standardDecel }
                        NumberAnimation { property: "opacity"; from: 0.80; to: 0.0; duration: Motion.scanPeriod; easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.standardDecel }
                    }
                }
            }
        }
        Text {
            anchors.centerIn: parent; text: ringsRoot.centerGlyph; font.pixelSize: ringsRoot.glyphSize
            color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.55)
            SequentialAnimation on opacity {
                running: root._scanning && Motion.ambient; alwaysRunToEnd: true; loops: Animation.Infinite
                NumberAnimation { to: 0.20; duration: Motion.pulseHalf; easing.type: Easing.InOutSine }
                NumberAnimation { to: 0.80; duration: Motion.pulseHalf; easing.type: Easing.InOutSine }
            }
        }
    }

    // ── Device row ────────────────────────────────────────────────────────────
    component DeviceRow: Item {
        id: dRow
        required property var  device
        required property bool isPaired

        readonly property bool isConnected:     device.connected
        readonly property bool inAction:        root._actionMac   === device.mac
        readonly property bool inRemove:        root._removingMac === device.mac
        readonly property bool isPairingOpen:   root._pairingMac  === device.mac
        readonly property bool isRemovePending: root._removeMac   === device.mac

        width: parent?.width ?? 0
        height: baseRow.height + expandArea.height

        // Highlighted by the keyboard: its buttons join the Tab order.
        readonly property bool keyed: root._curMac === device.mac
        readonly property bool open: isRemovePending || isPairingOpen
        // The row's default action for Return on the list as well: connect or
        // disconnect a paired device, pair (without a PIN) an available one.
        function primary() {
            if (dRow.inAction || dRow.inRemove) return
            if (dRow.isPaired) {
                dRow.isConnected ? root._disconnect(dRow.device.mac) : root._connect(dRow.device.mac)
            } else {
                root._removeMac = ""; root._pairingMac = ""; root._pair(dRow.device.mac, "")
            }
        }
        Accessible.role: Accessible.ListItem
        Accessible.name: device.name + (isConnected ? ", connected" : isPaired ? ", paired" : "")
        // Escape closes this row's own panel (the remove question, PIN entry)
        // and hands the keys back to the list; with nothing open it passes on,
        // and the pane closes.
        Keys.onEscapePressed: function (event) {
            if (!dRow.open) { event.accepted = false; return }
            root._removeMac = ""; root._pairingMac = ""
            root._curMac = dRow.device.mac
            devFlick.forceActiveFocus()
        }

        Rectangle {
            // Borderless at rest; only the connected row carries a fill
            // (UI/UX roadmap v3 Phase 17 — rows read as list items, not cards).
            anchors.fill: parent; radius: theme.radiusS
            color: dRow.isConnected
                ? Theme.surfaceSelected
                : rowHov.hovered && !dRow.isPaired ? Theme.surfaceHover(Theme.background) : "transparent"
            Behavior on color { MotionColor { role: "state" } }
        }
        Rectangle {
            anchors.fill: parent; anchors.margins: -3
            radius: theme.cornerRadius + 3
            color: "transparent"; border.width: 2; border.color: Theme.accentText
            visible: dRow.keyed && devFlick.activeFocus
        }

        Item {
            id: baseRow
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 50

            Text {
                anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                text: root._glyph(dRow.device.iconType); font.pixelSize: theme.fs(18)
                color: dRow.isConnected ? Theme.active
                    : (dRow.inAction || dRow.inRemove) ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.5) : Theme.textTertiary
                Behavior on color { MotionColor { role: "state" } }
            }

            Column {
                anchors { left: parent.left; leftMargin: 44; verticalCenter: parent.verticalCenter }
                spacing: 3
                Text {
                    text: dRow.device.name; font.pixelSize: theme.fs(13)
                    font.weight: dRow.isConnected ? Font.Medium : Font.Normal
                    color: dRow.isConnected ? Theme.text : Theme.textSecondary
                    width: 160; elide: Text.ElideRight
                }
                Text {
                    visible: dRow.isConnected || dRow.inAction || dRow.inRemove
                    text: dRow.inRemove ? "Removing…" : dRow.inAction ? "Working…" : "Connected"
                    font.pixelSize: theme.fs(10)
                    color: (dRow.inAction || dRow.inRemove) ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.55) : Theme.active
                }
            }

            Row {
                anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                spacing: 6

                // Spinner
                Text {
                    visible: dRow.inAction || dRow.inRemove
                    text: "○"; font.pixelSize: theme.fs(15); color: Theme.active
                    anchors.verticalCenter: parent.verticalCenter
                    SequentialAnimation on opacity {
                        running: (dRow.inAction || dRow.inRemove) && Motion.ambient; alwaysRunToEnd: true; loops: Animation.Infinite
                        NumberAnimation { to: 0.15; duration: Motion.pulseHalf }
                        NumberAnimation { to: 1.0;  duration: Motion.pulseHalf }
                    }
                }

                // Paired: connect/disconnect — one action style (UI/UX Phase 17).
                // The row's subtitle already says "Connected", so the connected
                // state is a "Disconnect" button rather than a filled pill with a dot.
                ApexPressable {
                    id: togBtn
                    visible: dRow.isPaired && !dRow.inAction && !dRow.inRemove
                    anchors.verticalCenter: parent.verticalCenter
                    width: togLbl.implicitWidth + 20; height: theme.controlStandard; radius: theme.radiusS
                    hitMargin: 2
                    activeFocusOnTab: dRow.keyed || dRow.open
                    Accessible.name: (dRow.isConnected ? "Disconnect " : "Connect ") + dRow.device.name
                    // The button hides while the action runs; the keys go back to the list.
                    onActivated: { dRow.isConnected ? root._disconnect(dRow.device.mac) : root._connect(dRow.device.mac); devFlick.forceActiveFocus() }
                    // On the selected row: Theme.surfaceOnSelected (roles.js says why).
                    Rectangle { anchors.fill: parent; radius: parent.radius; color: togBtn.tint(dRow.isConnected ? Theme.surfaceOnSelected : Theme.surfaceHigh); Behavior on color { MotionColor { role: "state" } } }
                    Text { id: togLbl; anchors.centerIn: parent; text: dRow.isConnected ? "Disconnect" : "Connect"; font.pixelSize: theme.typeCaption; font.weight: Font.Medium; color: Theme.textPrimary }
                    ApexFocusRing { target: togBtn }
                }

                // Paired: remove — opens the confirmation below; same non-destructive
                // action style as everything else (the destructive fill lives on the
                // confirmation's own Remove button).
                ApexPressable {
                    id: rmBtn
                    visible: dRow.isPaired && !dRow.inAction && !dRow.inRemove
                    anchors.verticalCenter: parent.verticalCenter
                    width: rmLbl.implicitWidth + 20; height: theme.controlStandard; radius: theme.radiusS
                    hitMargin: 2
                    activeFocusOnTab: dRow.keyed || dRow.open
                    Accessible.name: "Remove " + dRow.device.name
                    onActivated: { root._pairingMac = ""; root._removeMac = dRow.isRemovePending ? "" : dRow.device.mac }
                    Rectangle { anchors.fill: parent; radius: parent.radius; color: rmBtn.tint(dRow.isConnected ? Theme.surfaceOnSelected : Theme.surfaceHigh); Behavior on color { MotionColor { role: "state" } } }
                    Text { id: rmLbl; anchors.centerIn: parent; text: "Remove"; font.pixelSize: theme.typeCaption; font.weight: Font.Medium; color: Theme.textPrimary }
                    ApexFocusRing { target: rmBtn }
                }

                // Available: Pair + PIN icon
                Row {
                    visible: !dRow.isPaired && !dRow.inAction
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6

                    ApexPressable {
                        id: pairBtn
                        width: pairLbl.implicitWidth + 20; height: theme.controlStandard; radius: theme.radiusS
                        hitMargin: 2
                        activeFocusOnTab: dRow.keyed || dRow.open
                        Accessible.name: "Pair with " + dRow.device.name
                        // The row loses this button once pairing starts; the keys go back to the list.
                        onActivated: { root._removeMac = ""; root._pairingMac = ""; root._pair(dRow.device.mac, ""); devFlick.forceActiveFocus() }
                        Rectangle { anchors.fill: parent; radius: parent.radius; color: pairBtn.tint(Theme.surfaceHigh); Behavior on color { MotionColor {} } }
                        Text { id: pairLbl; anchors.centerIn: parent; text: "Pair"; font.pixelSize: theme.typeCaption; font.weight: Font.Medium; color: Theme.textPrimary }
                        ApexFocusRing { target: pairBtn }
                    }

                    ApexPressable {
                        id: pinBtn
                        width: 24; height: 28; radius: 6; anchors.verticalCenter: parent?.verticalCenter
                        hitMargin: 4
                        activeFocusOnTab: dRow.keyed || dRow.open
                        Accessible.name: dRow.isPairingOpen ? "Close PIN entry for " + dRow.device.name : "Enter PIN for " + dRow.device.name
                        onActivated: {
                            root._removeMac  = ""
                            root._pairingMac = dRow.isPairingOpen ? "" : dRow.device.mac
                            if (!dRow.isPairingOpen) Qt.callLater(function() { pinInput.forceActiveFocus() })
                            else pinInput.text = ""
                        }
                        Rectangle { anchors.fill: parent; radius: parent.radius; color: pinBtn.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10) : dRow.isPairingOpen ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.12) : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.04); border.color: dRow.isPairingOpen ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.30) : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.09); border.width: 1; Behavior on color { MotionColor { role: "state" } } }
                        Text { anchors.centerIn: parent; text: "󰌾"; font.pixelSize: theme.fs(12); color: dRow.isPairingOpen ? Theme.active : pinBtn.hovered ? Theme.textPrimary : Theme.textTertiary; Behavior on color { MotionColor { role: "state" } } }
                        ApexFocusRing { target: pinBtn }
                    }
                }
            }
        }

        // Expandable
        Item {
            id: expandArea
            anchors { top: baseRow.bottom; left: parent.left; right: parent.right }
            clip: true
            height: dRow.isRemovePending ? removeRow.implicitHeight + 16 : dRow.isPairingOpen ? pinRow.implicitHeight + 16 : 0
            Behavior on height { MotionMove { role: "surfaceEnterSmall" } }

            // Remove confirmation
            Item {
                id: removeRow
                anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 8 }
                implicitHeight: 32
                opacity: dRow.isRemovePending ? 1 : 0
                Behavior on opacity { MotionFade {} }
                Rectangle {
                    anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
                    radius: 8; color: Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b,0.06); border.color: Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b,0.22); border.width: 1
                    Row {
                        anchors.centerIn: parent; spacing: 12
                        Text { anchors.verticalCenter: parent.verticalCenter; text: "Remove this device?"; font.pixelSize: theme.fs(11); color: Theme.textSecondary }
                        ApexPressable {
                            id: cxBtn
                            width: cxLbl.implicitWidth + 20; height: theme.controlStandard; radius: theme.radiusS; hitMargin: 2
                            Accessible.name: "Keep " + dRow.device.name
                            onActivated: { root._removeMac = ""; rmBtn.forceActiveFocus() }
                            Rectangle { anchors.fill: parent; radius: parent.radius; color: cxBtn.tint(Theme.surfaceHigh); Behavior on color { MotionColor {} } }
                            Text { id: cxLbl; anchors.centerIn: parent; text: "Cancel"; font.pixelSize: theme.typeCaption; font.weight: Font.Medium; color: Theme.textPrimary }
                            ApexFocusRing { target: cxBtn }
                        }
                        // The one destructive action in this pane — Theme.dangerFill,
                        // matching every other confirm-to-delete button in the shell.
                        ApexPressable {
                            id: rxBtn
                            width: rxLbl.implicitWidth + 20; height: theme.controlStandard; radius: theme.radiusS; hitMargin: 2
                            Accessible.name: "Remove " + dRow.device.name
                            onActivated: { root._remove(dRow.device.mac); devFlick.forceActiveFocus() }
                            Rectangle { anchors.fill: parent; radius: parent.radius; color: Theme.dangerFill }
                            Rectangle {
                                anchors.fill: parent; radius: parent.radius; color: Theme.dangerFillHover
                                opacity: rxBtn.hovered || rxBtn.pressed ? 1 : 0
                                Behavior on opacity { MotionFade {} }
                            }
                            Text { id: rxLbl; anchors.centerIn: parent; text: "Remove"; font.pixelSize: theme.typeCaption; font.weight: Font.Medium; color: Theme.fixedLight }
                            ApexFocusRing { target: rxBtn }
                        }
                    }
                }
            }

            // PIN row
            Item {
                id: pinRow
                anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 8 }
                implicitHeight: pinCol.implicitHeight
                opacity: dRow.isPairingOpen ? 1 : 0
                Behavior on opacity { MotionFade {} }
                Column {
                    id: pinCol
                    anchors { left: parent.left; right: parent.right; leftMargin: 8; rightMargin: 8 }
                    spacing: 6
                    Text { width: parent.width; text: "Legacy PIN pairing — enter the PIN shown on your device"; font.pixelSize: theme.fs(10); color: Theme.textTertiary; wrapMode: Text.WordWrap }
                    Row {
                        width: parent.width; spacing: 8
                        Rectangle {
                            width: parent.width - pairConfBtn.width - parent.spacing; height: 32; radius: 8
                            color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.06)
                            border.color: pinInput.activeFocus ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.55) : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.12)
                            border.width: 1; Behavior on border.color { MotionColor { role: "state" } }
                            Text { anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                            text: "PIN (optional)…"; font.pixelSize: theme.fs(12); color: Theme.textTertiary; visible: pinInput.text === "" }
                            TextInput {
                                id: pinInput
                                activeFocusOnTab: true
                                anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                                verticalAlignment: TextInput.AlignVCenter; color: Theme.text
                                font.pixelSize: theme.fs(12); font.family: "JetBrains Mono"
                                inputMethodHints: Qt.ImhDigitsOnly; maximumLength: 8
                                selectionColor: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.35); clip: true
                                Keys.onReturnPressed: root._pair(dRow.device.mac, text)
                            }
                        }
                        ApexPressable {
                            id: pairConfBtn; width: pairConfLbl.implicitWidth + 20; height: theme.controlStandard; radius: theme.radiusS
                            Accessible.name: "Pair with " + dRow.device.name
                            // Pairing clears _pairingMac and collapses this row; the keys go back to the list.
                            onActivated: { root._pair(dRow.device.mac, pinInput.text); devFlick.forceActiveFocus() }
                            Rectangle { anchors.fill: parent; radius: parent.radius; color: pairConfBtn.tint(Theme.surfaceHigh); Behavior on color { MotionColor {} } }
                            Text { id: pairConfLbl; anchors.centerIn: parent; text: "Pair"; font.pixelSize: theme.typeCaption; font.weight: Font.Medium; color: Theme.textPrimary }
                            ApexFocusRing { target: pairConfBtn }
                        }
                    }
                }
            }
        }

        onIsPairingOpenChanged: { if (!isPairingOpen) pinInput.text = "" }
        HoverHandler { id: rowHov; enabled: !dRow.isPaired }
    }

    // ── Main layout ───────────────────────────────────────────────────────────
    Column {
        anchors.fill: parent; spacing: 0

        // Header
        Item {
            width: parent.width; height: 40

            Text { anchors { left: parent.left; leftMargin: 2; verticalCenter: parent.verticalCenter }
            text: "Bluetooth"; font.pixelSize: theme.fs(15); font.weight: Font.Bold; color: Theme.text }

            Row {
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                spacing: 8

                // Power toggle — borderless, state layer only (UI/UX Phase 17)
                ApexPressable {
                    id: pwrBtn
                    width: 32; height: 32; radius: 8
                    Accessible.name: root._btPowered ? "Turn Bluetooth off" : "Turn Bluetooth on"
                    onActivated: root._setPower(!root._btPowered)
                    Rectangle { anchors.fill: parent; radius: parent.radius; color: pwrBtn.stateLayer() }
                    Text {
                        anchors.centerIn: parent; text: "⏻"; font.pixelSize: theme.fs(14)
                        // Genuine state colour: accent while off (inviting it back on),
                        // a hover preview of the disable while on.
                        color: !root._btPowered ? Theme.active : pwrBtn.hovered ? Theme.danger : Theme.iconDefault
                        Behavior on color { MotionColor { role: "state" } }
                    }
                    ApexFocusRing { target: pwrBtn }
                }

                // Settings — blueman-manager
                ApexPressable {
                    id: setBtn
                    width: 32; height: 32; radius: 8
                    Accessible.name: "Bluetooth device manager"
                    onActivated: { bluemanProc.running = false; bluemanProc.running = true }
                    Rectangle { anchors.fill: parent; radius: parent.radius; color: setBtn.stateLayer() }
                    Text { anchors.centerIn: parent; text: "󰒓"; font.pixelSize: theme.fs(14); color: setBtn.hovered ? Theme.textPrimary : Theme.iconDefault; Behavior on color { MotionColor {} } }
                    ApexFocusRing { target: setBtn }
                }

                // Scan / Stop — one action style (UI/UX Phase 17): scanning is a
                // real running state, so it takes the same ON treatment as the
                // VPN Kill Switch (surfaceSelected + accentText); the pulsing dot
                // is genuine state, the same class as the header refresh spin.
                ApexPressable {
                    id: scanBtn
                    width: scanRow.implicitWidth + 20; height: theme.controlStandard; radius: theme.radiusS
                    hitMargin: 2
                    interactive: root._btPowered
                    Accessible.name: root._scanning ? "Stop scanning" : "Scan for devices"
                    onActivated: root._startScan()
                    Rectangle {
                        anchors.fill: parent; radius: parent.radius
                        color: root._scanning ? scanBtn.tint(Theme.surfaceSelected) : scanBtn.tint(Theme.surfaceHigh)
                        Behavior on color { MotionColor { role: "state" } }
                    }
                    Row {
                        id: scanRow; anchors.centerIn: parent; spacing: 7
                        Rectangle {
                            width: 7; height: 7; radius: 4; anchors.verticalCenter: parent.verticalCenter
                            color: root._scanning ? Theme.accentText : Theme.textSecondary
                            Behavior on color { MotionColor { role: "state" } }
                            SequentialAnimation on opacity {
                                running: root._scanning && Motion.ambient; alwaysRunToEnd: true; loops: Animation.Infinite; NumberAnimation { to: 0.15; duration: Motion.pulseHalf }
                                NumberAnimation { to: 1.0; duration: Motion.pulseHalf }
                            }
                        }
                        Text { anchors.verticalCenter: parent.verticalCenter; text: root._scanning ? "Stop" : "Scan"; font.pixelSize: theme.typeCaption; font.weight: Font.Medium; color: root._scanning ? Theme.accentText : Theme.textPrimary; Behavior on color { MotionColor { role: "state" } } }
                    }
                    ApexFocusRing { target: scanBtn }
                }
            }
        }

        Rectangle { width: parent.width; height: 1; color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07) }
        Item      { width: parent.width; height: 8 }

        // Scan animation strip
        Item {
            width: parent.width; height: root._scanning ? 90 : 0; clip: true
            Behavior on height { MotionMove { role: "surfaceEnterSmall" } }
            ScanRings { anchors.centerIn: parent; width: 52; height: 52; centerGlyph: "󰂯"; glyphSize: 14 }
            Text { anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 6 }
            text: "Scanning for devices…"; font.pixelSize: theme.fs(10); color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.50) }
        }

        Flickable {
            id: devFlick
            width: parent.width
            height: parent.height - 49 - (root._scanning ? 90 : 0)
            contentWidth: width; contentHeight: devCol.height
            clip: true; boundsBehavior: Flickable.StopAtBounds
            Behavior on height { MotionMove { role: "surfaceEnterSmall" } }
            activeFocusOnTab: root._rowMacs.length > 0
            Accessible.role: Accessible.List
            Accessible.name: "Bluetooth devices"
            onActiveFocusChanged: if (activeFocus && root._rowMacs.indexOf(root._curMac) < 0) root._stepRow(1)
            Keys.onPressed: function (event) {
                if      (event.key === Qt.Key_Down) root._stepRow(1)
                else if (event.key === Qt.Key_Up)   root._stepRow(-1)
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                    const row = root._rowFor(root._curMac)
                    if (row) row.primary()
                } else return
                event.accepted = true
                // Keep the highlighted row in view.
                const r = root._rowFor(root._curMac)
                if (r) {
                    const top = r.mapToItem(devCol, 0, 0).y
                    if (top < devFlick.contentY) devFlick.contentY = top
                    else if (top + r.height > devFlick.contentY + devFlick.height)
                        devFlick.contentY = top + r.height - devFlick.height
                }
            }

            Column {
                id: devCol; width: parent.width; height: implicitHeight; spacing: 4

                Item { width: parent.width; height: visible ? pLbl.implicitHeight + 4 : 0; visible: root._paired.length > 0
                    SectionLabel { id: pLbl; text: "PAIRED" } }

                Repeater {
                    id: pairedRows
                    model: root._paired
                    delegate: DeviceRow { required property var modelData; width: devCol.width - 2; x: 1; device: modelData; isPaired: true }
                }

                Item { width: parent.width; height: 10; visible: root._paired.length > 0 && root._available.length > 0 }

                Item { width: parent.width; height: visible ? aLbl.implicitHeight + 4 : 0; visible: root._available.length > 0
                    SectionLabel { id: aLbl; text: root._scanning ? "DISCOVERED" : "AVAILABLE" } }

                Repeater {
                    id: availRows
                    model: root._available
                    delegate: DeviceRow { required property var modelData; width: devCol.width - 2; x: 1; device: modelData; isPaired: false }
                }

                // Empty state
                Item {
                    width: parent.width; height: 120
                    visible: !root._scanning && root._allDevices.length === 0 && root._btPowered
                    // The shared empty state (UI/UX Phase 17).
                    EmptyState {
                        anchors.centerIn: parent; width: parent.width * 0.8
                        glyph: "󰂯"
                        title: "No devices found"
                        hint: "Scan to find devices nearby."
                    }
                }

                Item { width: parent.width; height: 8 }
            }
        }
    }

    // ── Bluetooth off overlay — anchors.fill + topMargin, no overflow ─────────
    Item {
        anchors { fill: parent; topMargin: 49 }
        visible: !root._btPowered
        z: 2

        Rectangle { anchors.fill: parent; color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.95) }

        Column {
            anchors.centerIn: parent; spacing: 16
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: "󰂲"; font.pixelSize: theme.fs(42); color: Theme.textTertiary }
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Bluetooth is off"; font.pixelSize: theme.fs(14); font.weight: Font.Medium; color: Theme.textTertiary }
            ApexPressable {
                id: onBtn
                anchors.horizontalCenter: parent.horizontalCenter
                width: enableRow.implicitWidth + 24; height: 34; radius: 17
                Accessible.name: "Turn Bluetooth on"
                onActivated: root._setPower(true)
                Rectangle {
                    anchors.fill: parent; radius: parent.radius
                    color: onBtn.hovered ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.22) : Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.12)
                    border.color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.40); border.width: 1
                    Behavior on color { MotionColor {} }
                }
                Row { id: enableRow; anchors.centerIn: parent; spacing: 8
                    Text { anchors.verticalCenter: parent.verticalCenter; text: "󰂯"; font.pixelSize: theme.fs(14); color: Theme.active }
                    Text { anchors.verticalCenter: parent.verticalCenter; text: "Turn On"; font.pixelSize: theme.fs(12); font.weight: Font.Medium; color: Theme.active }
                }
                ApexFocusRing { target: onBtn }
            }
        }
    }
}
