import QtQuick
import QtQuick.Effects
import Quickshell.Io
import Quickshell.Services.Mpris
import "../../"
import "../../components"
import "../../components/controls"

Item {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    // ── Source blocklist ──────────────────────────────────────────────────────
    readonly property var _blocked: [
        "kdeconnect", 
        "gsconnect", 
        "playerctld",
        "plasma-browser-integration"
    ]

    // Explicit count tracker — forces filteredPlayers to re-evaluate whenever
    // a player joins or leaves the MPRIS list.
    property int _mprisCount: Mpris.players.values.length

    readonly property var filteredPlayers: {
        var _dep = root._mprisCount  // explicit dependency on list size changes
        var result = []
        var vals = Mpris.players.values
        for (var i = 0; i < vals.length; i++) {
            var id = (vals[i].identity || "").toLowerCase()
            var isBlocked = false
            
            for (var j = 0; j < root._blocked.length; j++) {
                if (id.indexOf(root._blocked[j]) !== -1) {
                    isBlocked = true
                    break
                }
            }
            
            if (!isBlocked) {
                result.push(vals[i])
            }
        }
        return result
    }

    property int selectedPlayerIndex: 0
    property bool _dropdownOpen: false

    onVisibleChanged: if (!visible) root._dropdownOpen = false

    onFilteredPlayersChanged: {
        // Prefer keeping the same player object selected after list change.
        var oldPlayer = root.player
        if (oldPlayer) {
            for (var i = 0; i < root.filteredPlayers.length; i++) {
                if (root.filteredPlayers[i] === oldPlayer) {
                    root.selectedPlayerIndex = i
                    return
                }
            }
        }
        // Fallback: clamp to valid range
        if (root.selectedPlayerIndex >= root.filteredPlayers.length)
            root.selectedPlayerIndex = Math.max(0, root.filteredPlayers.length - 1)
    }

    // ── MPRIS ─────────────────────────────────────────────────────────────────
    readonly property var player: root.filteredPlayers.length > 0
                                  ? root.filteredPlayers[root.selectedPlayerIndex] : null

    readonly property bool   isPlaying: root.player?.playbackState === MprisPlaybackState.Playing ?? false
    readonly property string artUrl:    root.player?.trackArtUrl ?? ""

    // The card's ink. Over album art it sits on a fixed dark scrim, so it is
    // white; with no art there is no scrim and the card is an ordinary palette
    // surface, so it is the palette's text (UI/UX Phase 18: a scrim over
    // nothing was a dark slab in a light Dashboard).
    readonly property bool  onArt: root.artUrl !== ""
    readonly property color ink:   root.onArt ? Theme.fixedLight : Theme.textPrimary
    function inkA(a) { return Qt.rgba(root.ink.r, root.ink.g, root.ink.b, a) }

    readonly property string title: {
        var t = root.player?.trackTitle
        return (t && t !== "") ? t : "Nothing Playing"
    }
    readonly property string artist: {
        var a = root.player?.trackArtists
        if (!a) return ""
        if (typeof a === "string") return a
        if (typeof a.join === "function") return a.join(", ")
        return a.toString()
    }

    readonly property real length:   root.player?.length   ?? 0
    readonly property real position: root.player?.position ?? 0

    property real _pos: 0
    onPositionChanged: root._pos = position

    Timer {
        interval: 1000; running: root.isPlaying; repeat: true
        onTriggered: {
            if (root.length > 0)
                root._pos = Math.min(root._pos + 1, root.length)
        }
    }

    function _fmt(sec) {
        var s = Math.floor(sec)
        return Math.floor(s / 60) + ":" + (s % 60 < 10 ? "0" : "") + (s % 60)
    }

    readonly property real _progress: root.length > 0 ? root._pos / root.length : 0

    // Tell CavaService the dash visualiser is on screen. The dash is a popup, so
    // this is false whenever it is closed — which is nearly always. Declarative
    // rather than a counter, for the reason spelled out in CavaService.
    Binding {
        target:   CavaService
        property: "dashWants"
        value:    root.visible
    }

    // ── Shared cava bars (32 bars from CavaService) ───────────────────────────
    readonly property int _cavaBars: 32
    readonly property var _bars: CavaService.bars

    // ── Player icon helper ────────────────────────────────────────────────────
    function _playerIcon(player) {
        if (!player) return "♪"
        var id = (player.identity || "").toLowerCase()
        if (id.indexOf("spotify")  !== -1) return ""
        if (id.indexOf("firefox")  !== -1) return ""
        if (id.indexOf("chromium") !== -1) return ""
        if (id.indexOf("chrome")   !== -1) return ""
        if (id.indexOf("brave")    !== -1) return ""
        if (id.indexOf("youtube")  !== -1) return ""
        return "♪"
    }

    // ── Player label helper ───────────────────────────────────────────────────
    function _playerLabel(player) {
        if (!player) return "—"
        var id = (player.identity || "").toLowerCase()
        if (id.indexOf("spotify")  !== -1) return "Spotify"
        if (id.indexOf("firefox")  !== -1) return "Firefox"
        if (id.indexOf("chromium") !== -1) return "Chromium"
        if (id.indexOf("chrome")   !== -1) return "Chrome"
        if (id.indexOf("brave")    !== -1) return "Brave"
        if (id.indexOf("youtube")  !== -1) return "YouTube"
        if (id.indexOf("edge")     !== -1) return "Edge"
        if (id.indexOf("opera")    !== -1) return "Opera"
        if (id.indexOf("vivaldi")  !== -1) return "Vivaldi"
        return player.identity || "Player"
    }

    // ── Background visuals ────────────────────────────────────────────────────
    // With no art, the card is filled like every other Home card (StatCard).
    Rectangle {
        anchors.fill: parent
        radius:       theme.cornerRadius
        visible:      !root.onArt
        color:        Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.04)
    }

    Item {
        id: bgSource
        anchors.fill:  parent
        opacity:       0
        layer.enabled: true

        Item {
            id: artSource
            anchors.fill:  parent
            layer.enabled: true
            Image {
                anchors.fill: parent
                source:   root.artUrl
                fillMode: Image.PreserveAspectCrop
                smooth:   true
            }
        }

        MultiEffect {
            source:       artSource
            anchors.fill: parent
            visible:      root.artUrl !== ""
            opacity:      root.artUrl !== "" ? 1 : 0
            blurEnabled:  true
            blur:         0.5
            blurMax:      32
            saturation:   0.2
            Behavior on opacity { MotionFade { role: "fadeIn" } }
        }

        Rectangle {
            anchors.fill: parent
            visible: root.onArt
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(0,0,0,0.38) }
                GradientStop { position: 0.4; color: Qt.rgba(0,0,0,0.50) }
                GradientStop { position: 1.0; color: Qt.rgba(0,0,0,0.88) }
            }
        }
    }

    Rectangle {
        id: bgMask
        anchors.fill:  parent
        radius:        theme.cornerRadius
        visible:       false
        layer.enabled: true
    }

    MultiEffect {
        source:           bgSource
        anchors.fill:     parent
        maskEnabled:      true
        maskSource:       bgMask
        maskThresholdMin: 0.5
        maskSpreadAtMin:  1.0
    }

    // ── Track name + artist ───────────────────────────────────────────────────
    Column {
        anchors {
            left:  parent.left;  leftMargin:  120 
            right: parent.right; rightMargin: 120 
            top:   parent.top;   topMargin:   16
        }
        spacing: 4
        clip: true // Ensure nothing bleeds outside the column boundaries
        // ── Title with Marquee Scroll ──
        Item {
            width: parent.width
            height: 22 
            clip: true 
            TextMetrics {
                id: titleMetrics
                font: titleText.font
                text: root.title
            }
            Text {
                id: titleText
                text: root.title
                font.pixelSize: theme.fs(18); font.weight: Font.Bold
                color: root.ink
                anchors.horizontalCenter: titleMetrics.width <= parent.width ? parent.horizontalCenter : undefined
                NumberAnimation on x {
                    id: marqueeAnim
                    running: titleMetrics.width > titleText.parent.width && root.isPlaying && Motion.ambient
                    from: titleText.parent.width
                    to: -titleMetrics.width
                    duration: Math.max(0, (titleMetrics.width + titleText.parent.width) * 20)
                    loops: Animation.Infinite
                    // Stopped — paused, or gated off by Reduce Motion — the
                    // title rests at its start rather than wherever the scroll
                    // happened to be.
                    onStopped: titleText.x = 0
                }
                onTextChanged: marqueeAnim.restart()
            }
        }
        Text {
            width:   parent.width
            text:    root.artist
            visible: root.artist !== ""
            font.pixelSize: theme.fs(13)
            color: root.inkA(0.55)

            maximumLineCount: 1
            elide: Text.ElideRight
            
            horizontalAlignment: Text.AlignHCenter
        }
    }

    // ── Bottom stack: controls + progress (raised to give room for picker) ──────
    Column {
        anchors {
            left:   parent.left;   leftMargin:   14
            right:  parent.right;  rightMargin:  14
            bottom: parent.bottom; bottomMargin: 54
        }
        spacing: 6

        // Controls
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 28
            Repeater {
                model: [ { key: "prev" }, { key: "play" }, { key: "next" } ]
                delegate: ApexPressable {
                    id: ctrlBtn
                    required property var  modelData
                    required property int  index
                    readonly property bool isPlay: modelData.key === "play"
                    readonly property string dispIcon: {
                        if (modelData.key === "prev") return "󰒫"
                        if (modelData.key === "next") return "󰒬"
                        return !root.isPlaying ? "󰐊" : "󰏤"
                    }
                    width: 36; height: 36
                    radius: height / 2
                    // Disabled (dimmed, no Tab stop) for what this player cannot
                    // do — and all three with no player at all.
                    interactive: {
                        if (!root.player) return false
                        if (modelData.key === "prev") return root.player.canGoPrevious
                        if (modelData.key === "next") return root.player.canGoNext
                        return root.player.canTogglePlaying
                    }
                    Accessible.name: modelData.key === "prev" ? "Previous track"
                                     : modelData.key === "next" ? "Next track"
                                     : (root.isPlaying ? "Pause" : "Play")
                    onActivated: {
                        if (!root.player) return
                        switch (modelData.key) {
                            case "play":
                                if (root.player.canTogglePlaying)
                                    root.player.isPlaying = !root.player.isPlaying
                                break
                            case "prev":
                                if (root.player.canGoPrevious) root.player.previous()
                                break
                            case "next":
                                if (root.player.canGoNext) root.player.next()
                                break
                        }
                    }
                    Rectangle {
                        anchors.fill: parent; radius: parent.radius
                        color: ctrlBtn.isPlay
                               ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.18)
                               : ctrlBtn.hovered ? root.inkA(0.14) : root.inkA(0.06)
                        border.color: ctrlBtn.isPlay ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.3) : "transparent"
                        border.width: 1
                        Behavior on color { MotionColor { role: "state" } }
                    }
                    Text {
                        anchors.centerIn: parent
                        text: ctrlBtn.dispIcon
                        font.pixelSize: ctrlBtn.isPlay ? 18 : 14
                        color: ctrlBtn.isPlay ? (root.onArt ? Theme.fixedLight : Theme.accentText) : root.inkA(0.7)
                    }
                    ApexFocusRing { target: ctrlBtn }
                }
            }
        }

        // Progress bar + timestamps
        Column {
            width: parent.width; spacing: 3
            Item {
                id: seekBar
                width: parent.width; height: 6

                // On the keyboard: a Tab stop while the player can seek;
                // Left/Right 5 s, Page Up/Down 30 s, Home the start.
                readonly property bool seekable: !!root.player && root.player.canSeek && root.length > 0
                activeFocusOnTab: seekBar.seekable
                Accessible.role: Accessible.Slider
                Accessible.name: "Seek"
                Accessible.description: root._fmt(root._pos) + " of " + root._fmt(root.length)
                function _seekTo(s) {
                    const t = Math.max(0, Math.min(root.length, s))
                    root.player.position = t
                    root._pos = t
                }
                Keys.onPressed: function (event) {
                    if (!seekBar.seekable) return
                    if      (event.key === Qt.Key_Right)    seekBar._seekTo(root._pos + 5)
                    else if (event.key === Qt.Key_Left)     seekBar._seekTo(root._pos - 5)
                    else if (event.key === Qt.Key_PageUp)   seekBar._seekTo(root._pos + 30)
                    else if (event.key === Qt.Key_PageDown) seekBar._seekTo(root._pos - 30)
                    else if (event.key === Qt.Key_Home)     seekBar._seekTo(0)
                    else return
                    event.accepted = true
                }
                Rectangle {
                    anchors.fill: parent; anchors.margins: -4
                    radius: height / 2
                    color: "transparent"; border.width: 2; border.color: Theme.accentText
                    visible: seekBar.activeFocus
                }

                Rectangle {
                    anchors.fill: parent; radius: height / 2
                    color: root.inkA(0.2)
                    MouseArea {
                        // A 6 px bar with a 20 px target; x still maps 1:1.
                        anchors.fill: parent; anchors.topMargin: -7; anchors.bottomMargin: -7
                        cursorShape: Qt.PointingHandCursor
                        onClicked: function(mouse) {
                            if (root.player && root.length > 0) {
                                var f = mouse.x / width
                                root.player.position = f * root.length
                                root._pos = f * root.length
                            }
                        }
                    }
                    Rectangle {
                        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                        width:  Math.max(radius * 2, parent.width * root._progress)
                        radius: parent.radius; color: Theme.active
                        Behavior on width { MotionMove { role: "valueFollow"; curve: Motion.fastSpatial } }
                    }
                }
            }
            Item {
                width: parent.width; height: 14

                Text {
                    anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                    text: root._fmt(root._pos)
                    font.pixelSize: theme.fs(9); font.family: "JetBrains Mono"
                    color: root.inkA(0.4)
                }

                Text {
                    anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                    text: root._fmt(root.length)
                    font.pixelSize: theme.fs(9); font.family: "JetBrains Mono"
                    color: root.inkA(0.4)
                }
            }
        }
    }

    // ── Source picker — upward-expanding pill ─────────────────────────────────
    // Sits in the gap between the controls and the card bottom; expands upward.
    Item {
        id: sourcePicker
        anchors {
            top:          parent.top
            right:        parent.right
            topMargin:    12
            rightMargin:  12
        }
        visible: root.filteredPlayers.length > 1
        z:       30
        
        width:  pill.width
        height: pill.height

        Rectangle {
            id: pill
            anchors.top:   parent.top
            anchors.right: parent.right

            // Width tracks the active row + padding
            width: activeRow.implicitWidth + 24

            readonly property int _rowH: 26
            height: root._dropdownOpen 
                    ? (_rowH * root.filteredPlayers.length) 
                    : _rowH
            Behavior on height { MotionMove { role: "surfaceEnterSmall" } }

            radius:       _rowH / 2
            clip:         true
            color:        Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.15)
            border.color: root._dropdownOpen
                          ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.30)
                          : "transparent"
            border.width: 1
            Behavior on border.color { MotionColor { role: "state" } }

            // Stacks downward from the top
            Column {
                anchors.top:   parent.top
                anchors.left:  parent.left
                anchors.right: parent.right
                spacing: 0

                // ── Active player row (Always at the top) ─────────────
                ApexPressable {
                    id: activeRowBtn
                    height: pill._rowH
                    width:  parent.width
                    Accessible.checkable: true
                    Accessible.checked: root._dropdownOpen
                    Accessible.name: "Player: " + (root.player ? root._playerLabel(root.player) : "Player")
                                     + ", choose player"
                    onActivated: root._dropdownOpen = !root._dropdownOpen

                    Row {
                        id: activeRow
                        anchors.centerIn: parent
                        spacing: 6

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text:           root.player ? root._playerIcon(root.player) : "♪"
                            font.pixelSize: theme.fs(11)
                            color:          Theme.active
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text:           root.player ? root._playerLabel(root.player) : "Player"
                            font.pixelSize: theme.fs(11)
                            font.weight:    Font.Medium
                            color:          root.inkA(0.92)
                            // Cap width so crazy browser identities don't stretch the pill
                            width:          Math.min(implicitWidth, 120)
                            elide:          Text.ElideRight
                        }
                    }

                    ApexFocusRing { target: activeRowBtn }
                }

                // ── Other player rows (Drop down below active) ─────────
                Repeater {
                    model: root.filteredPlayers
                    delegate: ApexPressable {
                        id: dropBtn
                        required property var modelData
                        required property int index
                        readonly property bool isCurrent: index === root.selectedPlayerIndex

                        width:  parent.width
                        height: isCurrent ? 0 : (root._dropdownOpen ? pill._rowH : 0)
                        visible: !isCurrent
                        interactive: root._dropdownOpen && !isCurrent
                        opacity: root._dropdownOpen ? 1 : 0
                        Accessible.name: "Switch to " + root._playerLabel(modelData)

                        Behavior on height  { MotionMove { role: "surfaceEnterSmall" } }
                        Behavior on opacity { MotionFade {} }

                        onActivated: {
                            const byKey = dropBtn.focusVisible
                            root.selectedPlayerIndex = index
                            root._dropdownOpen = false
                            if (byKey) activeRowBtn.forceActiveFocus()   // this row just hid itself
                        }

                        Row {
                            anchors.centerIn: parent
                            spacing: 6

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text:           root._playerIcon(modelData)
                                font.pixelSize: theme.fs(11)
                                color:          dropBtn.hovered ? root.inkA(0.90) : root.inkA(0.55)
                                Behavior on color { MotionColor {} }
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text:           root._playerLabel(modelData)
                                font.pixelSize: theme.fs(11)
                                color:          dropBtn.hovered ? root.inkA(0.90) : root.inkA(0.55)
                                width:          Math.min(implicitWidth, 120)
                                elide:          Text.ElideRight
                                Behavior on color { MotionColor {} }
                            }
                        }

                        ApexFocusRing { target: dropBtn }
                    }
                }
            }
        }
    } 

    // ── Cava bars — independent, always flush with the card bottom ────────────
    Item {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 7; rightMargin: 7; bottomMargin: 4 }
        height: 32
        Row {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            spacing: 2
            readonly property real barW: Math.max(1, (parent.width - spacing * (root._cavaBars - 1)) / root._cavaBars)
            // model is the COUNT, not the array — see the note in
            // CenterContent. `bars` is replaced with a new array 30x/sec and a
            // Repeater cannot diff an array model, so this used to destroy and
            // rebuild all 32 delegates every frame, in addition to the 32
            // CenterContent was already rebuilding. Fixed count -> the delegates
            // persist and only the height binding re-evaluates. The per-delegate
            // Behavior is dropped for the same reason as there: a 50 ms
            // animation restarted every 33 ms never finished.
            Repeater {
                model: CavaService.barCount
                delegate: Item {
                    required property int index
                    width: parent.barW; height: 32
                    Rectangle {
                        anchors.bottom: parent.bottom
                        width:  parent.width
                        readonly property real _amp: root.isPlaying
                            ? ((root._bars[parent.index] !== undefined ? root._bars[parent.index] : 0) / 100)
                            : 0
                        height: Math.max(2, _amp * 32)
                        radius: width / 2
                        color:  Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.25 + _amp * 0.65)
                    }
                }
            }
        }
    }

    // Border
    Rectangle {
        anchors.fill: parent
        radius:       theme.cornerRadius
        color:        "transparent"
        border.color: root.inkA(0.08)
        border.width: 1
    }

    // Close dropdown on click outside
    TapHandler {
        enabled: root._dropdownOpen
        onTapped: root._dropdownOpen = false
    }
}
