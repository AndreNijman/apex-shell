import QtQuick
import QtQuick.Controls
import "../"

Item {
    id: root

    // One row can be in capture mode at a time
    property string _capturing: ""

    // Groups computed from defaults (stable, doesn't need to react)
    readonly property var _groups: {
        var groups = {}; var order = []
        var defs = KeybindService._defaults
        var ks   = Object.keys(defs)
        for (var i = 0; i < ks.length; i++) {
            var g = defs[ks[i]].group
            if (!groups[g]) { groups[g] = []; order.push(g) }
            groups[g].push(ks[i])
        }
        return order.map(function(g) { return { name: g, actions: groups[g] } })
    }

    Flickable {
        anchors { fill: parent; margins: 12 }
        contentWidth:   width
        contentHeight:  _col.implicitHeight + 16
        clip:           true
        boundsBehavior: Flickable.StopAtBounds

        ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
            contentItem: Rectangle {
                implicitWidth: 3; implicitHeight: 40; radius: 1.5
                color: Qt.rgba(1, 1, 1, 0.22)
            }
            background: Item {}
        }

        Column {
            id: _col
            width:   parent.width - 12
            spacing: 2

            Repeater {
                model: root._groups
                delegate: Column {
                    required property var modelData
                    required property int index
                    width:   _col.width
                    spacing: 2

                    // Group header
                    Item {
                        width:  parent.width
                        height: index > 0 ? 30 : 16
                        Text {
                            anchors.bottom:       parent.bottom
                            anchors.bottomMargin: 4
                            text:           modelData.name
                            font.pixelSize: 9
                            font.weight:    Font.Bold
                            color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.55)
                        }
                    }

                    Repeater {
                        model: modelData.actions
                        delegate: BindRow {
                            required property string modelData
                            width:      _col.width
                            action:     modelData
                            isCapturing: root._capturing === modelData
                            onRequestCapture:  root._capturing = modelData
                            onReleaseCapture:  root._capturing = ""
                        }
                    }
                }
            }
        }
    }

    // ── BindRow ───────────────────────────────────────────────────────────────
    component BindRow: Item {
        id: br

        property string action:     ""
        property bool   isCapturing: false

        signal requestCapture()
        signal releaseCapture()

        // Capture state
        property int    _pressedMods: 0
        property string _liveMods:    ""
        property string capturedMods: ""
        property string capturedKey:  ""

        // Derived from service
        readonly property var    _b:         KeybindService.keybinds[action]
        readonly property var    _def:       KeybindService._defaults[action]
        readonly property bool   _isDefault: !!_b && !!_def && _b.mods === _def.mods && _b.key === _def.key
        readonly property string _bindText:  _b ? (_b.mods ? _b.mods + " + " + _b.key : _b.key) : "..."
        readonly property bool   _savedDupe: KeybindService.isDuplicate(action)

        // Local conflict check for the currently captured combo
        readonly property string _conflictLabel: {
            if (!capturedKey) return ""
            return KeybindService.wouldConflict(action, capturedMods, capturedKey)
        }
        readonly property bool _hasConflict: _conflictLabel !== ""

        height: isCapturing ? 58 : 36
        clip: true
        Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

        onIsCapturingChanged: {
            if (isCapturing) {
                br._pressedMods = 0
                br._liveMods    = ""
                br.capturedMods = ""
                br.capturedKey  = ""
                Qt.callLater(function() { _captureArea.forceActiveFocus() })
            }
        }

        // ── Background ────────────────────────────────────────────────────────
        Rectangle {
            anchors.fill: parent
            radius: 8
            color: br.isCapturing
                ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.07)
                : _rH.hovered ? Qt.rgba(1, 1, 1, 0.04) : "transparent"
            border.color: br._savedDupe
                ? Qt.rgba(248/255, 113/255, 113/255, 0.35)
                : br.isCapturing
                    ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.20)
                    : "transparent"
            border.width: 1
            Behavior on color { ColorAnimation { duration: 120 } }
        }

        // ── Invisible focus target for key capture ─────────────────────────────
        Item {
            id: _captureArea
            anchors.fill: parent
            focus: br.isCapturing
            visible: br.isCapturing

            Keys.onPressed: function(event) {
                event.accepted = true
                if (_isMod(event.key)) {
                    br._liveMods = _mods(event.modifiers)
                    return
                }
                br._pressedMods = event.modifiers
                br._liveMods    = _mods(event.modifiers)
            }

            Keys.onReleased: function(event) {
                event.accepted = true
                if (_isMod(event.key)) {
                    if (!br.capturedKey) br._liveMods = _mods(event.modifiers)
                    return
                }
                // Plain Escape = cancel
                if (event.key === Qt.Key_Escape && br._pressedMods === Qt.NoModifier) {
                    br.releaseCapture()
                    return
                }
                var k = _keyName(event.key)
                if (k !== "") {
                    br.capturedMods = _mods(br._pressedMods)
                    br.capturedKey  = k
                }
            }
        }

        // ── Normal display ────────────────────────────────────────────────────
        Item {
            anchors { top: parent.top; left: parent.left; right: parent.right
                      leftMargin: 10; rightMargin: 8 }
            height: 36
            visible: !br.isCapturing

            Text {
                anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                text:           br._b ? br._b.label : br.action
                font.pixelSize: 12
                color:          br._savedDupe ? "#f87171" : Qt.rgba(1, 1, 1, 0.68)
                Behavior on color { ColorAnimation { duration: 120 } }
            }

            Row {
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                spacing: 6

                // Saved duplicate warning
                Text {
                    visible: br._savedDupe
                    anchors.verticalCenter: parent.verticalCenter
                    text:           "⚠ " + KeybindService.conflictsWith(br.action)
                    font.pixelSize: 9
                    color:          Qt.rgba(248/255, 113/255, 113/255, 0.75)
                }

                // Reset to default
                Rectangle {
                    visible: !br._isDefault
                    width: 22; height: 22; radius: 6
                    color: _rstH.hovered ? Qt.rgba(1,1,1,0.09) : "transparent"
                    Behavior on color { ColorAnimation { duration: 100 } }
                    Text { anchors.centerIn: parent; text: "↺"; font.pixelSize: 11
                        color: _rstH.hovered ? Theme.active : Qt.rgba(1,1,1,0.28) }
                    HoverHandler { id: _rstH; cursorShape: Qt.PointingHandCursor }
                    MouseArea { anchors.fill: parent
                        onClicked: KeybindService.resetBinding(br.action) }
                }

                // Binding pill — click to enter capture
                Rectangle {
                    height: 24; radius: 6
                    width:  _pillT.implicitWidth + 18
                    color: _pillH.hovered
                        ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.16)
                        : Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.08)
                    border.color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.24)
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: 100 } }
                    Text {
                        id: _pillT
                        anchors.centerIn: parent
                        text:           br._bindText
                        font.pixelSize: 10; font.family: "JetBrains Mono"
                        color:          Theme.active
                    }
                    HoverHandler { id: _pillH; cursorShape: Qt.PointingHandCursor }
                    MouseArea { anchors.fill: parent; onClicked: br.requestCapture() }
                }
            }
        }

        // ── Capture display ───────────────────────────────────────────────────
        Column {
            anchors { top: parent.top; left: parent.left; right: parent.right
                      leftMargin: 10; rightMargin: 8 }
            spacing: 0
            visible: br.isCapturing

            // Row 1: label + capture pill + confirm/cancel
            Item {
                width: parent.width; height: 36

                Text {
                    anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                    text:           br._b ? br._b.label : br.action
                    font.pixelSize: 12
                    color:          Qt.rgba(1, 1, 1, 0.68)
                }

                Row {
                    anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                    spacing: 6

                    // Live capture display
                    Rectangle {
                        height: 24; radius: 6
                        width:  Math.max(120, _capT.implicitWidth + 18)
                        color:  Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.08)
                        border.color: br._hasConflict
                            ? Qt.rgba(248/255, 113/255, 113/255, 0.55)
                            : Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b,
                                      br.capturedKey !== "" ? 0.40 : 0.18)
                        border.width: 1
                        Behavior on border.color { ColorAnimation { duration: 120 } }

                        Text {
                            id: _capT
                            anchors.centerIn: parent
                            font.pixelSize: 10; font.family: "JetBrains Mono"
                            color: br._hasConflict
                                ? "#f87171"
                                : br.capturedKey !== ""
                                    ? Theme.active
                                    : Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.45)
                            text: {
                                if (br.capturedKey !== "")
                                    return (br.capturedMods ? br.capturedMods + " + " : "") + br.capturedKey
                                if (br._liveMods !== "")
                                    return br._liveMods + " + ?"
                                return "Press a key..."
                            }
                        }
                    }

                    // Confirm (hidden when no key or conflict)
                    Rectangle {
                        visible: br.capturedKey !== "" && !br._hasConflict
                        width: 28; height: 24; radius: 6
                        color: _cfH.hovered
                            ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.24)
                            : Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.10)
                        border.color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.30)
                        border.width: 1
                        Behavior on color { ColorAnimation { duration: 100 } }
                        Text { anchors.centerIn: parent; text: "✓"; font.pixelSize: 12; color: Theme.active }
                        HoverHandler { id: _cfH; cursorShape: Qt.PointingHandCursor }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                KeybindService.updateBinding(br.action, br.capturedMods, br.capturedKey)
                                br.releaseCapture()
                            }
                        }
                    }

                    // Cancel
                    Rectangle {
                        visible: br.capturedKey !== ""
                        width: 28; height: 24; radius: 6
                        color: _cnH.hovered ? Qt.rgba(1,1,1,0.09) : "transparent"
                        Behavior on color { ColorAnimation { duration: 100 } }
                        Text { anchors.centerIn: parent; text: "✕"; font.pixelSize: 10
                            color: Qt.rgba(1,1,1,0.38) }
                        HoverHandler { id: _cnH; cursorShape: Qt.PointingHandCursor }
                        MouseArea { anchors.fill: parent; onClicked: br.releaseCapture() }
                    }
                }
            }

            // Row 2: conflict warning (animated in/out)
            Item {
                width: parent.width; height: 22
                opacity: (br.capturedKey !== "" && br._hasConflict) ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 140 } }

                Text {
                    anchors { left: parent.left; leftMargin: 2; verticalCenter: parent.verticalCenter }
                    text:           "⚠  Conflicts with: " + br._conflictLabel
                    font.pixelSize: 10
                    color:          "#f87171"
                }
            }
        }

        // ── Key helpers ───────────────────────────────────────────────────────
        function _isMod(k) {
            return k === Qt.Key_Shift    || k === Qt.Key_Control  ||
                   k === Qt.Key_Meta     || k === Qt.Key_Alt      ||
                   k === Qt.Key_Super_L  || k === Qt.Key_Super_R  ||
                   k === Qt.Key_Hyper_L  || k === Qt.Key_Hyper_R  ||
                   k === Qt.Key_AltGr    || k === Qt.Key_CapsLock ||
                   k === Qt.Key_NumLock  || k === Qt.Key_ScrollLock
        }

        function _mods(flags) {
            var p = []
            if (flags & Qt.MetaModifier)    p.push("SUPER")
            if (flags & Qt.ShiftModifier)   p.push("SHIFT")
            if (flags & Qt.ControlModifier) p.push("CTRL")
            if (flags & Qt.AltModifier)     p.push("ALT")
            return p.join(" ")
        }

        function _keyName(k) {
            if (_isMod(k)) return ""
            if (k >= Qt.Key_A && k <= Qt.Key_Z)    return String.fromCharCode(k)
            if (k >= Qt.Key_0 && k <= Qt.Key_9)    return String.fromCharCode(k)
            if (k >= Qt.Key_F1 && k <= Qt.Key_F35) return "F" + (k - Qt.Key_F1 + 1)
            var m = {}
            m[Qt.Key_Escape]       = "Escape"
            m[Qt.Key_Return]       = "Return"
            m[Qt.Key_Enter]        = "KP_Enter"
            m[Qt.Key_Tab]          = "Tab"
            m[Qt.Key_Backspace]    = "BackSpace"
            m[Qt.Key_Delete]       = "Delete"
            m[Qt.Key_Insert]       = "Insert"
            m[Qt.Key_Home]         = "Home"
            m[Qt.Key_End]          = "End"
            m[Qt.Key_PageUp]       = "Prior"
            m[Qt.Key_PageDown]     = "Next"
            m[Qt.Key_Left]         = "Left"
            m[Qt.Key_Right]        = "Right"
            m[Qt.Key_Up]           = "Up"
            m[Qt.Key_Down]         = "Down"
            m[Qt.Key_Space]        = "Space"
            m[Qt.Key_Print]        = "Print"
            m[Qt.Key_Pause]        = "Pause"
            m[Qt.Key_Minus]        = "minus"
            m[Qt.Key_Equal]        = "equal"
            m[Qt.Key_BracketLeft]  = "bracketleft"
            m[Qt.Key_BracketRight] = "bracketright"
            m[Qt.Key_Backslash]    = "backslash"
            m[Qt.Key_Semicolon]    = "semicolon"
            m[Qt.Key_Apostrophe]   = "apostrophe"
            m[Qt.Key_Comma]        = "comma"
            m[Qt.Key_Period]       = "period"
            m[Qt.Key_Slash]        = "slash"
            m[Qt.Key_QuoteLeft]    = "grave"
            return m[k] || ""
        }

        HoverHandler { id: _rH; enabled: !br.isCapturing }
    }
}