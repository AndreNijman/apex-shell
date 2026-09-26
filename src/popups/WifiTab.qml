import QtQuick
import Quickshell.Io
import "../"
import "../components/controls"
import "../components"

// WifiTab
// Connect → attempt without credentials → on failure expand fields inline.
// Enterprise (802.1X) networks get a username field and are saved as a
// PEAP/MSCHAPv2 profile; nmcli autoconnects it afterwards — the common
// school/university setup. Exotic EAP configs remain available via nmtui.
// Off overlay is a direct child of root Item (z:2), not inside Column — no overflow.

Item {
    id: root

    // How tall this tab wants to be: the header block (title row, divider,
    // gap: 49) and the list. The panel sizes its body to it (UI/UX Phase 17,
    // brief §F.4) instead of a fixed 648 px with most of it empty.
    readonly property real preferredHeight: 49 + contentCol.height
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    property var    _networks:      []
    property var    _needsPassword: ({})
    property bool   _scanning:      false
    property bool   _wifiEnabled:   true
    property string _connectingTo:  ""
    property string _forgetSsid:    ""
    property string _expandSsid:    ""

    readonly property var _current: {
        for (var i = 0; i < _networks.length; i++)
            if (_networks[i].inUse) return _networks[i]
        return null
    }
    readonly property var _available: {
        var r = []
        for (var i = 0; i < _networks.length; i++)
            if (!_networks[i].inUse) r.push(_networks[i])
        return r
    }

    Connections {
        target: Popups
        function onNetworkOpenChanged() {
            if (Popups.networkOpen) {
                root._forgetSsid    = ""
                root._expandSsid    = ""
                root._connectingTo  = ""
                root._needsPassword = ({})
                root._checkRadio()
                root._scan(false)
            }
        }
    }

    // ── Processes ─────────────────────────────────────────────────────────────

    Process {
        id: scanProc
        command: []
        running: false
        stdout: SplitParser {
            onRead: function(line) {
                var t = line.trim()
                if (t === "") return
                var lastC = t.lastIndexOf(":")
                if (lastC < 0) return
                var security  = t.substring(lastC + 1)
                var t2        = t.substring(0, lastC)
                var secC      = t2.lastIndexOf(":")
                if (secC < 0) return
                var signalStr = t2.substring(secC + 1)
                var t3        = t2.substring(0, secC)
                var firstC    = t3.indexOf(":")
                if (firstC < 0) return
                var inUseStr  = t3.substring(0, firstC)
                var ssid      = t3.substring(firstC + 1).replace(/\\:/g, ":")
                if (ssid === "" || ssid === "--") return
                var inUse   = inUseStr.trim() === "*"
                var signal  = parseInt(signalStr.trim()) || 0
                var secured = security.trim() !== "" && security.trim() !== "--"
                // nmcli prints enterprise security as e.g. "WPA2 802.1X"
                var enterprise = security.trim().indexOf("802.1X") >= 0
                var nets = root._networks.slice()
                var found = false
                for (var i = 0; i < nets.length; i++) {
                    if (nets[i].ssid === ssid) {
                        if (inUse || signal > nets[i].signal)
                            nets[i] = { ssid: ssid, signal: signal, secured: secured, inUse: inUse, enterprise: enterprise }
                        found = true; break
                    }
                }
                if (!found) nets.push({ ssid: ssid, signal: signal, secured: secured, inUse: inUse, enterprise: enterprise })
                root._networks = nets
            }
        }
        onRunningChanged: if (!running) root._scanning = false
    }

    // First attempt — captures stderr to detect secret requirement
    Process {
        id: connectProc
        command: []
        running: false
        property string _ssid: ""
        stderr: StdioCollector { id: connectStderr }
        onExited: function(code, status) {
            if (code === 0) {
                // Success — clear password state and close the field
                var np = Object.assign({}, root._needsPassword)
                delete np[connectProc._ssid]
                root._needsPassword = np
                root._expandSsid    = ""
            } else {
                var err = connectStderr.text.toLowerCase()
                if (err.indexOf("secret") >= 0 || err.indexOf("password") >= 0
                        || err.indexOf("no network") < 0) {
                    var np2 = Object.assign({}, root._needsPassword)
                    np2[connectProc._ssid] = true
                    root._needsPassword = np2
                    root._expandSsid    = connectProc._ssid
                }
            }
            root._connectingTo = ""
            root._scan(false)
        }
    }

    Process {
        id: passProc
        command: []
        running: false
        property string _ssid: ""
        stderr: StdioCollector { id: passStderr }
        onExited: function(code, status) {
            if (code !== 0 && passProc._ssid !== "") {
                // Failed — re-expand the row so the user can fix and retry
                var np = Object.assign({}, root._needsPassword)
                np[passProc._ssid] = true
                root._needsPassword = np
                root._expandSsid    = passProc._ssid
            } else {
                root._expandSsid = ""
            }
            passProc._ssid     = ""
            root._connectingTo = ""
            root._scan(false)
        }
    }

    Process {
        id: actionProc
        command: []
        running: false
        onRunningChanged: if (!running) {
            root._connectingTo  = ""
            root._forgetSsid    = ""
            root._expandSsid    = ""
            root._needsPassword = ({})
            root._scan(false)
        }
    }

    // nmtui needs a terminal. Rather than hardcoding one emulator, honour
    // $TERMINAL, then xdg-terminal-exec (the freedesktop spec helper), then the
    // common emulators. Every one of these takes `-e CMD` except foot/wezterm,
    // which are invoked without it.
    Process {
        id: nmtuiProc
        command: ["bash", "-c",
            "for t in \"$TERMINAL\" xdg-terminal-exec alacritty kitty ghostty foot wezterm " +
            "gnome-terminal konsole xfce4-terminal xterm; do " +
            "  [ -n \"$t\" ] || continue; " +
            "  command -v \"$t\" >/dev/null 2>&1 || continue; " +
            "  case \"$t\" in " +
            "    xdg-terminal-exec) exec \"$t\" nmtui ;; " +
            "    foot|wezterm)      exec \"$t\" nmtui ;; " +
            "    *)                 exec \"$t\" -e nmtui ;; " +
            "  esac; " +
            "done; " +
            "notify-send -a 'APEX Shell' 'No terminal found' " +
            "'Install a terminal emulator or set $TERMINAL to use the advanced Wi-Fi editor.' " +
            "2>/dev/null; exit 127"]
        running: false
    }

    Process {
        id: radioProc; command: []; running: false
        onRunningChanged: if (!running) root._checkRadio()
    }

    Process {
        id: radioCheckProc
        command: ["bash", "-c", "nmcli radio wifi"]
        running: false
        stdout: SplitParser {
            onRead: function(line) { root._wifiEnabled = line.trim() === "enabled" }
        }
    }

    function _checkRadio() { radioCheckProc.running = false; radioCheckProc.running = true }

    // ── Keyboard (UI/UX roadmap v3 Phase 21) ────────────────────────────────
    // The network list is ONE Tab stop: Up and Down move a highlight over the
    // connected network then the available ones, Return does what the row's
    // own button does (connect, or retry with what was typed). Tab from the
    // list reaches the highlighted row's buttons, which are Tab stops only
    // while it is highlighted, so a list of twenty networks is not sixty stops.
    property string _curSsid: ""
    readonly property var _rowSsids: (root._current ? [root._current.ssid] : [])
                                     .concat(root._available.map(function (n) { return n.ssid }))
    function _stepRow(d) {
        const list = root._rowSsids
        if (list.length === 0) return
        const i = list.indexOf(root._curSsid)
        root._curSsid = i < 0 ? list[d > 0 ? 0 : list.length - 1]
                              : list[Math.max(0, Math.min(list.length - 1, i + d))]
    }
    function _rowFor(ssid) {
        if (currentRow.visible && currentRow.net.ssid === ssid) return currentRow
        for (let i = 0; i < availRows.count; i++) {
            const r = availRows.itemAt(i)
            if (r && r.net.ssid === ssid) return r
        }
        return null
    }

    function _setWifiEnabled(on) {
        root._wifiEnabled = on
        radioProc.command = ["bash", "-c", "nmcli radio wifi " + (on ? "on" : "off")]
        radioProc.running = false; radioProc.running = true
    }

    function _scan(rescan) {
        if (_scanning || !root._wifiEnabled) return
        _scanning = true; _networks = []
        scanProc.command = ["bash", "-c",
            "nmcli -t -f IN-USE,SSID,SIGNAL,SECURITY dev wifi list " +
            (rescan ? "--rescan yes" : "--rescan no") + " 2>/dev/null"]
        scanProc.running = false; scanProc.running = true
    }

    function _disconnect() {
        actionProc.command = ["bash", "-c",
            "nmcli con down \"$(nmcli -t -f NAME,TYPE con show --active" +
            " | grep ':802-11-wireless' | head -1 | cut -d: -f1)\" 2>/dev/null"]
        actionProc.running = false; actionProc.running = true
    }

    function _forget(ssid) {
        actionProc.running = false;
        _forgetSsid = "";
    
        actionProc.command = [
            "bash", "-c",
            "for uuid in $(nmcli -g UUID,TYPE connection show | awk -F: '$2==\"802-11-wireless\"{print $1}'); do " +
            "if [ \"$(nmcli -g 802-11-wireless.ssid connection show \"$uuid\" 2>/dev/null)\" = \"$1\" ]; then " +
            "nmcli connection delete \"$uuid\"; " +
            "fi; done",
            "--", ssid
        ];
    
        actionProc.running = true;
    }

    function _connectFirst(ssid) {
        _connectingTo = ssid; _expandSsid = ""
        connectProc._ssid = ssid
        connectProc.command = ["bash", "-c",
            "nmcli con up id \"$1\" 2>&1 ||" +
            " nmcli dev wifi connect \"$1\" 2>&1",
            "--", ssid]
        connectProc.running = false; connectProc.running = true
    }

    function _connectWithPassword(ssid, password) {
        _connectingTo = ssid; _expandSsid = ""
        var np = Object.assign({}, root._needsPassword)
        delete np[ssid]
        root._needsPassword = np
        passProc._ssid = ssid
        passProc.command = ["bash", "-c",
            "nmcli dev wifi connect \"$1\" password \"$2\" 2>/dev/null",
            "--", ssid, password]
        passProc.running = false; passProc.running = true
    }

    // WPA2-Enterprise (802.1X): school/university networks are almost always
    // PEAP/MSCHAPv2. `con add` saves a profile (nmcli autoconnects it from
    // then on), so subsequent connections are automatic. Any stale profile
    // from a failed earlier attempt is replaced first.
    function _connectEnterprise(ssid, identity, password) {
        _connectingTo = ssid; _expandSsid = ""
        var np = Object.assign({}, root._needsPassword)
        delete np[ssid]
        root._needsPassword = np
        passProc._ssid = ssid
        passProc.command = ["bash", "-c",
            "nmcli con delete \"$1\" 2>/dev/null; " +
            "nmcli con add type wifi con-name \"$1\" ssid \"$1\" -- " +
            "wifi-sec.key-mgmt wpa-eap " +
            "802-1x.eap peap " +
            "802-1x.phase2-auth mschapv2 " +
            "802-1x.identity \"$2\" " +
            "802-1x.password \"$3\"",
            "--", ssid, identity, password]
        passProc.running = false; passProc.running = true
    }

    Component.onCompleted: { _checkRadio(); _scan(false) }

    // ── Components ────────────────────────────────────────────────────────────

    component ScanRings: Item {
        id: ringsRoot
        property string centerGlyph: "󰤨"
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

    component SignalBars: Item {
        id: barsRoot
        required property int signal
        width: 18; height: 14
        Row {
            anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter; spacing: 2
            Repeater {
                model: 4
                delegate: Rectangle {
                    required property int index
                    width: 3; height: 4 + index * 3; radius: 1; anchors.bottom: parent?.bottom
                    readonly property bool lit: {
                        switch (index) {
                            case 0: return barsRoot.signal > 0
                            case 1: return barsRoot.signal > 25
                            case 2: return barsRoot.signal > 50
                            case 3: return barsRoot.signal > 75
                        }; return false
                    }
                    color: lit ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.85) : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.15)
                    Behavior on color { MotionColor { role: "state" } }
                }
            }
        }
    }

    component NetworkRow: Item {
        id: netRow
        required property var  net
        required property bool isCurrent
        // Never for the placeholder the connected row shows while nothing is
        // connected (ssid ""): "" === _expandSsid's resting "" made it EXPANDED,
        // and on every scan and every open it pulled focus into its own hidden
        // password field (measured, UI/UX Phase 21) — the keyboard lost the list.
        readonly property bool real:            net.ssid !== ""
        readonly property bool isForgetPending: real && root._forgetSsid   === net.ssid
        readonly property bool isExpanded:      real && root._expandSsid   === net.ssid
        readonly property bool isConnecting:    real && root._connectingTo === net.ssid
        readonly property bool needsPassword:   !!root._needsPassword[net.ssid]
        property bool _showPass: false
        width: parent?.width ?? 0
        height: baseRow.height + expandArea.height

        // Highlighted by the keyboard: its buttons join the Tab order.
        readonly property bool keyed: real && root._curSsid === net.ssid
        readonly property bool open: isForgetPending || isExpanded
        // The Connect button's action, for Return on the list as well.
        function primary() {
            if (netRow.isCurrent || netRow.isConnecting) return
            root._forgetSsid = ""
            if (netRow.isExpanded && passInput.text !== "") {
                if (netRow.net.enterprise) {
                    if (userInput.text !== "")
                        root._connectEnterprise(netRow.net.ssid, userInput.text, passInput.text)
                } else {
                    root._connectWithPassword(netRow.net.ssid, passInput.text)
                }
            } else {
                root._connectFirst(netRow.net.ssid)
            }
        }
        Accessible.role: Accessible.ListItem
        Accessible.name: net.ssid + (isCurrent ? ", connected" : needsPassword ? ", password required" : "")
        // Escape closes this row's own panel (the password, the forget
        // question) and hands the keys back to the list; with nothing open it
        // passes on, and the pane closes.
        Keys.onEscapePressed: function (event) {
            if (!netRow.open) { event.accepted = false; return }
            root._forgetSsid = ""; root._expandSsid = ""
            root._curSsid = netRow.net.ssid
            flick.forceActiveFocus()
        }

        Rectangle {
            // Borderless at rest; only the connected row carries a fill
            // (UI/UX roadmap v3 Phase 17 — rows read as list items, not cards).
            anchors.fill: parent; radius: theme.radiusS
            color: netRow.isCurrent
                ? Theme.surfaceSelected
                : rHov.hovered ? Theme.surfaceHover(Theme.background) : "transparent"
            Behavior on color { MotionColor { role: "state" } }
        }
        Rectangle {
            anchors.fill: parent; anchors.margins: -3
            radius: theme.cornerRadius + 3
            color: "transparent"; border.width: 2; border.color: Theme.accentText
            visible: netRow.keyed && flick.activeFocus
        }

        Item {
            id: baseRow
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 48

            Column {
                anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                spacing: 3
                Text {
                    text: netRow.net.ssid; font.pixelSize: theme.fs(13)
                    font.weight: netRow.isCurrent ? Font.Medium : Font.Normal
                    color: netRow.isCurrent ? Theme.textPrimary : Theme.textSecondary
                    width: 170; elide: Text.ElideRight
                }
                Text {
                    visible: netRow.needsPassword && !netRow.isCurrent
                    text: netRow.net.enterprise ? "Enterprise login required" : "Password required"
                    font.pixelSize: theme.fs(10)
                    color: Qt.rgba(Theme.warning.r, Theme.warning.g, Theme.warning.b,0.80)
                }
                Text { visible: netRow.isCurrent; text: "Connected"; font.pixelSize: theme.fs(10); color: Theme.active }
            }

            Row {
                anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                spacing: 6

                Text {
                    visible: netRow.net.secured && !netRow.isCurrent
                    text: "󰌾"; font.pixelSize: theme.fs(11); color: Theme.textTertiary
                    anchors.verticalCenter: parent.verticalCenter
                }
                Item {
                    width: 22; height: 16; anchors.verticalCenter: parent.verticalCenter
                    SignalBars { anchors.centerIn: parent; signal: netRow.net.signal }
                }
                Item {
                    visible: netRow.isConnecting; width: 20; height: 20; anchors.verticalCenter: parent.verticalCenter
                    Text {
                        anchors.centerIn: parent; text: "○"; font.pixelSize: theme.fs(14); color: Theme.active
                        SequentialAnimation on opacity {
                            running: netRow.isConnecting && Motion.ambient; alwaysRunToEnd: true; loops: Animation.Infinite
                            NumberAnimation { to: 0.2; duration: Motion.pulseHalf }
                            NumberAnimation { to: 1.0; duration: Motion.pulseHalf }
                        }
                    }
                }
                // Disconnect — same action style as Connect/Forget (UI/UX Phase 17)
                ApexPressable {
                    id: disBtn
                    visible: netRow.isCurrent
                    anchors.verticalCenter: parent.verticalCenter
                    width: disLbl.implicitWidth + 20; height: theme.controlStandard; radius: theme.radiusS
                    hitMargin: 2
                    activeFocusOnTab: netRow.keyed || netRow.open
                    Accessible.name: "Disconnect from " + netRow.net.ssid
                    // The row goes when it disconnects; the keys go back to the list.
                    onActivated: { root._disconnect(); flick.forceActiveFocus() }
                    // On the selected row the sheet colour, not surfaceHigh: in light the
                    // two roles converge and the button vanished into its own row.
                    Rectangle { anchors.fill: parent; radius: parent.radius; color: disBtn.tint(Theme.surfaceBase); Behavior on color { MotionColor {} } }
                    Text { id: disLbl; anchors.centerIn: parent; text: "Disconnect"; font.pixelSize: theme.typeCaption; font.weight: Font.Medium; color: Theme.textPrimary }
                    ApexFocusRing { target: disBtn }
                }
                // Forget — opens the confirmation below; the destructive action
                // lives on that confirmation's own Forget button, not here.
                ApexPressable {
                    id: forBtn
                    visible: netRow.isCurrent
                    anchors.verticalCenter: parent.verticalCenter
                    width: forLbl.implicitWidth + 20; height: theme.controlStandard; radius: theme.radiusS
                    hitMargin: 2
                    activeFocusOnTab: netRow.keyed || netRow.open
                    Accessible.name: "Forget " + netRow.net.ssid
                    onActivated: root._forgetSsid = netRow.isForgetPending ? "" : netRow.net.ssid
                    Rectangle { anchors.fill: parent; radius: parent.radius; color: forBtn.tint(Theme.surfaceBase); Behavior on color { MotionColor { role: "state" } } }
                    Text { id: forLbl; anchors.centerIn: parent; text: "Forget"; font.pixelSize: theme.typeCaption; font.weight: Font.Medium; color: Theme.textPrimary }
                    ApexFocusRing { target: forBtn }
                }
                // Connect
                ApexPressable {
                    id: conBtn
                    visible: !netRow.isCurrent && !netRow.isConnecting
                    anchors.verticalCenter: parent.verticalCenter
                    width: connectLbl.implicitWidth + 20; height: theme.controlStandard; radius: theme.radiusS
                    hitMargin: 2
                    activeFocusOnTab: netRow.keyed || netRow.open
                    Accessible.name: (netRow.isExpanded ? "Retry " : "Connect to ") + netRow.net.ssid
                    // The button goes once the row connects; the keys go back to the list
                    // (a row that asks for a password takes them for its field instead).
                    onActivated: { netRow.primary(); flick.forceActiveFocus() }
                    Rectangle { anchors.fill: parent; radius: parent.radius; color: conBtn.tint(Theme.surfaceHigh); Behavior on color { MotionColor {} } }
                    Text { id: connectLbl; anchors.centerIn: parent; text: netRow.isExpanded ? "Retry" : "Connect"; font.pixelSize: theme.typeCaption; font.weight: Font.Medium; color: Theme.textPrimary }
                    ApexFocusRing { target: conBtn }
                }
            }
        }

        Item {
            id: expandArea
            anchors { top: baseRow.bottom; left: parent.left; right: parent.right }
            clip: true
            height: netRow.isForgetPending ? forgetRow.implicitHeight + 16 : netRow.isExpanded ? passRow.implicitHeight + 16 : 0
            Behavior on height { MotionMove { role: "surfaceEnterSmall" } }

            Item {
                id: forgetRow
                anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 8 }
                implicitHeight: 32
                opacity: netRow.isForgetPending ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { MotionFade {} }
                Rectangle {
                    anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                    radius: 8; color: Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b,0.07)
                    border.color: Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b,0.22); border.width: 1
                    Row {
                        anchors.centerIn: parent; spacing: 12
                        Text { anchors.verticalCenter: parent.verticalCenter; text: "Forget this network?"; font.pixelSize: theme.fs(11); color: Theme.textSecondary }
                        ApexPressable {
                            id: cfBtn
                            width: cfLbl.implicitWidth + 20; height: theme.controlStandard; radius: theme.radiusS; hitMargin: 2
                            Accessible.name: "Keep " + netRow.net.ssid
                            onActivated: { root._forgetSsid = ""; forBtn.forceActiveFocus() }
                            Rectangle { anchors.fill: parent; radius: parent.radius; color: cfBtn.tint(Theme.surfaceHigh); Behavior on color { MotionColor {} } }
                            Text { id: cfLbl; anchors.centerIn: parent; text: "Cancel"; font.pixelSize: theme.typeCaption; font.weight: Font.Medium; color: Theme.textPrimary }
                            ApexFocusRing { target: cfBtn }
                        }
                        // The one destructive action in this pane — Theme.dangerFill,
                        // matching every other confirm-to-delete button in the shell.
                        ApexPressable {
                            id: ffBtn
                            width: ffLbl.implicitWidth + 20; height: theme.controlStandard; radius: theme.radiusS; hitMargin: 2
                            Accessible.name: "Forget " + netRow.net.ssid
                            onActivated: { root._forget(netRow.net.ssid); flick.forceActiveFocus() }
                            Rectangle { anchors.fill: parent; radius: parent.radius; color: Theme.dangerFill }
                            Rectangle {
                                anchors.fill: parent; radius: parent.radius; color: Theme.dangerFillHover
                                opacity: ffBtn.hovered || ffBtn.pressed ? 1 : 0
                                Behavior on opacity { MotionFade {} }
                            }
                            Text { id: ffLbl; anchors.centerIn: parent; text: "Forget"; font.pixelSize: theme.typeCaption; font.weight: Font.Medium; color: Theme.fixedLight }
                            ApexFocusRing { target: ffBtn }
                        }
                    }
                }
            }

            Item {
                id: passRow
                anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 8 }
                implicitHeight: netRow.net.enterprise ? 80 : 40
                opacity: netRow.isExpanded ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { MotionFade {} }
                Column {
                    anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                    spacing: 8
                    // Username — enterprise (802.1X) networks only
                    Rectangle {
                        // Rows for saved-but-not-scanned networks can arrive
                        // without an `enterprise` field at all, and assigning
                        // undefined to a bool is a hard warning.
                        visible: netRow.net?.enterprise ?? false
                        width: parent.width; height: visible ? 32 : 0; radius: 8
                        color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.06)
                        border.color: userInput.activeFocus ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.55) : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.12)
                        border.width: 1; Behavior on border.color { MotionColor { role: "state" } }
                        Text { anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                        text: "Username…"; font.pixelSize: theme.fs(12); color: Theme.textTertiary; visible: userInput.text === "" }
                        TextInput {
                            id: userInput
                            activeFocusOnTab: true
                            anchors { left: parent.left; leftMargin: 10; right: parent.right; rightMargin: 10; top: parent.top; bottom: parent.bottom }
                            verticalAlignment: TextInput.AlignVCenter; color: Theme.text; font.pixelSize: theme.fs(12)
                            selectionColor: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.35); clip: true
                            Keys.onReturnPressed: { if (text.length > 0 && passInput.text.length > 0) root._connectEnterprise(netRow.net.ssid, text, passInput.text) }
                        }
                    }
                    Rectangle {
                        width: parent.width; height: 32; radius: 8
                        color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.06)
                        border.color: passInput.activeFocus ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.55) : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.12)
                        border.width: 1; Behavior on border.color { MotionColor { role: "state" } }
                        Text { anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                        text: "Password…"; font.pixelSize: theme.fs(12); color: Theme.textTertiary; visible: passInput.text === "" }
                        TextInput {
                            id: passInput
                            activeFocusOnTab: true
                            // Updated anchors to make room for the eye button
                            anchors { left: parent.left; leftMargin: 10; right: eyeBtn.left; rightMargin: 6; top: parent.top; bottom: parent.bottom }
                            verticalAlignment: TextInput.AlignVCenter; color: Theme.text; font.pixelSize: theme.fs(12)
                            // Toggle echoMode based on state
                            echoMode: netRow._showPass ? TextInput.Normal : TextInput.Password
                            selectionColor: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.35); clip: true
                            Keys.onReturnPressed: {
                                if (text.length === 0) return
                                if (netRow.net.enterprise) {
                                    if (userInput.text.length > 0) root._connectEnterprise(netRow.net.ssid, userInput.text, text)
                                } else {
                                    root._connectWithPassword(netRow.net.ssid, text)
                                }
                            }
                        }

                        // Added Show Password Button
                        ApexPressable {
                            id: eyeBtn
                            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                            width: 28; height: 28; radius: 6; hitMargin: 2
                            focusOnPress: false
                            Accessible.name: netRow._showPass ? "Hide password" : "Show password"
                            onActivated: netRow._showPass = !netRow._showPass
                            Rectangle { anchors.fill: parent; radius: parent.radius; color: eyeBtn.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.08) : "transparent" }
                            Text { 
                                anchors.centerIn: parent
                                text: netRow._showPass ? "" : ""
                                font.pixelSize: theme.fs(13)
                                color: netRow._showPass ? Theme.active : Theme.textTertiary 
                            }
                            ApexFocusRing { target: eyeBtn }
                        }
                    }
                }
            }

            onVisibleChanged: { if (visible && netRow.isExpanded) Qt.callLater(function() { (netRow.net.enterprise ? userInput : passInput).forceActiveFocus() }) }
        }

        onIsExpandedChanged: {
            if (isExpanded) Qt.callLater(function() { (netRow.net.enterprise ? userInput : passInput).forceActiveFocus() })
            else { passInput.text = ""; userInput.text = "" }
        }

        HoverHandler { id: rHov; enabled: !netRow.isCurrent }
    }

    // ── Layout — Column fills root, overlay is z:2 sibling ───────────────────
    Column {
        anchors.fill: parent; spacing: 0

        Item {
            width: parent.width; height: 40
            Text { anchors { left: parent.left; leftMargin: 2; verticalCenter: parent.verticalCenter }
            text: "Wi-Fi"; font.pixelSize: theme.fs(15); font.weight: Font.Bold; color: Theme.text }
            Row {
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                spacing: 8

                // Header icon trio — borderless, state layer only (UI/UX Phase 17)
                ApexPressable {
                    id: pwrBtn
                    width: 32; height: 32; radius: 8
                    Accessible.name: root._wifiEnabled ? "Turn Wi-Fi off" : "Turn Wi-Fi on"
                    onActivated: root._setWifiEnabled(!root._wifiEnabled)
                    Rectangle { anchors.fill: parent; radius: parent.radius; color: pwrBtn.stateLayer() }
                    Text {
                        anchors.centerIn: parent; text: "⏻"; font.pixelSize: theme.fs(14)
                        // Genuine state colour: accent while off (inviting it back on),
                        // a hover preview of the disable while on.
                        color: !root._wifiEnabled ? Theme.active : pwrBtn.hovered ? Theme.danger : Theme.iconDefault
                        Behavior on color { MotionColor { role: "state" } }
                    }
                    ApexFocusRing { target: pwrBtn }
                }

                ApexPressable {
                    id: setBtn
                    width: 32; height: 32; radius: 8
                    Accessible.name: "Network settings in a terminal"
                    onActivated: { nmtuiProc.running = false; nmtuiProc.running = true }
                    Rectangle { anchors.fill: parent; radius: parent.radius; color: setBtn.stateLayer() }
                    Text { anchors.centerIn: parent; text: "󰒓"; font.pixelSize: theme.fs(14); color: setBtn.hovered ? Theme.textPrimary : Theme.iconDefault; Behavior on color { MotionColor {} } }
                    ApexFocusRing { target: setBtn }
                }

                ApexPressable {
                    id: rfBtn
                    width: 32; height: 32; radius: 8
                    interactive: root._wifiEnabled
                    Accessible.name: "Scan for networks"
                    onActivated: if (!root._scanning) root._scan(true)
                    Rectangle { anchors.fill: parent; radius: parent.radius; color: rfBtn.stateLayer() }
                    Text {
                        id: rfIcon; anchors.centerIn: parent; text: "󰑐"; font.pixelSize: theme.fs(15)
                        // Genuine state colour: dimmed accent while the spin runs.
                        color: root._scanning ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.4) : (rfBtn.hovered ? Theme.textPrimary : Theme.iconDefault)
                        Behavior on color { MotionColor { role: "state" } }
                        RotationAnimator { target: rfIcon; from: 0; to: 360; duration: Motion.spinPeriod; loops: Animation.Infinite; running: root._scanning && Motion.loops; easing.type: Easing.Linear }
                    }
                    ApexFocusRing { target: rfBtn }
                }
            }
        }

        Rectangle { width: parent.width; height: 1; color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07) }
        Item      { width: parent.width; height: 8 }

        Flickable {
            id: flick; width: parent.width; height: parent.height - 49
            contentWidth: width; contentHeight: contentCol.height; clip: true; boundsBehavior: Flickable.StopAtBounds
            activeFocusOnTab: root._rowSsids.length > 0
            Accessible.role: Accessible.List
            Accessible.name: "Wi-Fi networks"
            onActiveFocusChanged: if (activeFocus && root._rowSsids.indexOf(root._curSsid) < 0) root._stepRow(1)
            Keys.onPressed: function (event) {
                if      (event.key === Qt.Key_Down) root._stepRow(1)
                else if (event.key === Qt.Key_Up)   root._stepRow(-1)
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                    const row = root._rowFor(root._curSsid)
                    if (row) row.primary()
                } else return
                event.accepted = true
                // Keep the highlighted row in view.
                const r = root._rowFor(root._curSsid)
                if (r) {
                    const top = r.mapToItem(contentCol, 0, 0).y
                    if (top < flick.contentY) flick.contentY = top
                    else if (top + r.height > flick.contentY + flick.height)
                        flick.contentY = top + r.height - flick.height
                }
            }
            Column {
                id: contentCol; width: flick.width; height: implicitHeight; spacing: 4

                Item { width: parent.width; height: visible ? sLbl1.implicitHeight + 4 : 0; visible: root._current !== null
                    SectionLabel { id: sLbl1; text: "CONNECTED" } }

                NetworkRow { id: currentRow; visible: root._current !== null; width: parent.width - 2; x: 1; net: root._current ?? { ssid: "", signal: 0, secured: false, inUse: true }; isCurrent: true }

                Item { width: parent.width; height: 10; visible: root._current !== null && root._available.length > 0 }

                Item { width: parent.width; height: visible ? sLbl2.implicitHeight + 4 : 0; visible: root._available.length > 0
                    SectionLabel { id: sLbl2; text: "AVAILABLE" } }

                Repeater {
                    id: availRows
                    model: root._available
                    delegate: NetworkRow { required property var modelData; width: contentCol.width - 2; x: 1; net: modelData; isCurrent: false }
                }

                Item {
                    width: parent.width; height: 160
                    visible: !root._scanning && root._networks.length === 0 && root._wifiEnabled
                    Column { anchors.centerIn: parent; spacing: 10
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "󰤭"; font.pixelSize: theme.fs(34); color: Theme.outlineStrong }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "No networks found"; font.pixelSize: theme.fs(12); color: Theme.textTertiary } }
                }

                Item {
                    width: parent.width; height: 160
                    visible: root._scanning && root._networks.length === 0
                    ScanRings { anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 12 }
                    width: 96; height: 96; centerGlyph: "󰤨"; glyphSize: 18 }
                    Text { anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 8 }
                    text: "Scanning…"; font.pixelSize: theme.fs(11); color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.5) }
                }

                Item { width: parent.width; height: 8 }
            }
        }
    }

    // ── WiFi off overlay — covers list area only, stops at parent bounds ─────
    Item {
        anchors {
            fill:      parent
            topMargin: 49   // below header 40 + divider 1 + gap 8
        }
        visible: !root._wifiEnabled
        z: 2

        Rectangle { anchors.fill: parent; color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.95) }

        Column {
            anchors.centerIn: parent; spacing: 16
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: "󰤭"; font.pixelSize: theme.fs(42); color: Theme.outlineStrong }
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Wi-Fi is off"; font.pixelSize: theme.fs(14); font.weight: Font.Medium; color: Theme.textTertiary }
            ApexPressable {
                id: onBtn
                anchors.horizontalCenter: parent.horizontalCenter
                width: wfEnRow.implicitWidth + 24; height: 34; radius: 17
                Accessible.name: "Turn Wi-Fi on"
                onActivated: root._setWifiEnabled(true)
              Rectangle {
                anchors.fill: parent; radius: parent.radius
                color: onBtn.hovered ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.22) : Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.12)
                border.color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.40); border.width: 1
                Behavior on color { MotionColor {} }
              }
                Row { id: wfEnRow; anchors.centerIn: parent; spacing: 8
                    Text { anchors.verticalCenter: parent.verticalCenter; text: "󰤨"; font.pixelSize: theme.fs(14); color: Theme.active }
                    Text { anchors.verticalCenter: parent.verticalCenter; text: "Turn On"; font.pixelSize: theme.fs(12); font.weight: Font.Medium; color: Theme.active }
                }
                ApexFocusRing { target: onBtn }
            }
        }
    }
}
