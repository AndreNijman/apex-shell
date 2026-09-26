import QtQuick
import Quickshell.Services.Pipewire
import "../components"
import "../components/controls"
import "../popups"
import "../"

Item {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    readonly property var sink:   Pipewire.defaultAudioSink
    readonly property var source: Pipewire.defaultAudioSource
    
    function reset() { switcher.reset() }

    PwObjectTracker {
        objects: Pipewire.nodes.values
    }

    readonly property var sinkNodes: {
        var result = []
        var nodes = Pipewire.nodes.values
        for (var i = 0; i < nodes.length; i++) {
            var n = nodes[i]
            if (n.audio !== null && !n.isStream && n.isSink)
                result.push(n)
        }
        return result
    }

    readonly property var sourceNodes: {
        var result = []
        var nodes = Pipewire.nodes.values
        for (var i = 0; i < nodes.length; i++) {
            var n = nodes[i]
            if (n.audio !== null && !n.isStream && !n.isSink)
                result.push(n)
        }
        return result
    }

    function deviceName(node) {
        if (!node) return "Unknown"
        return node.nickname || node.description || node.name || "Unknown"
    }

    property string page: Popups.audioPage

    Connections {
        target: Popups
        function onAudioPageChanged() {
            root.page = Popups.audioPage
        }
    }

    Row {
        anchors.fill: parent
        spacing: 8

        // ── Page content ──────────────────────────────────────────────────────
        Item {
            width:  parent.width - switcher.implicitWidth - parent.spacing - 1 - parent.spacing
            height: parent.height
            clip:   true

            // Output
            PopupPage {
                anchors.fill: parent
                visible:      root.page === "output"

                ChannelColumn {
                    width:  parent.width
                    trackHeight: 160; gap: 8; muteText: true; labelWidth: barW + 60
                    accessibleName: "Output volume"
                    label:  (root.sink && root.sink.ready) ? root.deviceName(root.sink) : "Output"
                    icon: {
                        if (!root.sink || !root.sink.ready)           return "󰕾"
                        if (root.sink.audio.muted)        return "󰖁"
                        if (root.sink.audio.volume > 0.6) return "󰕾"
                        if (root.sink.audio.volume > 0.2) return "󰖀"
                        return "󰕿"
                    }
                    value:  (root.sink && root.sink.ready) ? root.sink.audio.volume : 0
                    muted:  (root.sink && root.sink.audio) ? root.sink.audio.muted : false
                    active: (root.sink && root.sink.ready) || false
                    onVolumeChanged: function(v) {
                        if (root.sink && root.sink.ready) root.sink.audio.volume = v
                    }
                    onMuteToggled: {
                        if (root.sink && root.sink.ready)
                            root.sink.audio.muted = !root.sink.audio.muted
                    }
                }
            }

            // Input
            PopupPage {
                anchors.fill: parent
                visible:      root.page === "input"

                ChannelColumn {
                    width:  parent.width
                    trackHeight: 160; gap: 8; muteText: true; labelWidth: barW + 60
                    accessibleName: "Input volume"
                    label:  (root.source && root.source.ready) ? root.deviceName(root.source) : "Input"
                    icon:   (root.source && root.source.audio && root.source.audio.muted) ? "󰍭" : "󰍬"
                    value:  (root.source && root.source.ready) ? root.source.audio.volume : 0
                    muted:  (root.source && root.source.audio) ? root.source.audio.muted : false
                    active: (root.source && root.source.ready) || false
                    onVolumeChanged: function(v) {
                        if (root.source && root.source.ready) root.source.audio.volume = v
                    }
                    onMuteToggled: {
                        if (root.source && root.source.ready)
                            root.source.audio.muted = !root.source.audio.muted
                    }
                }
            }

            // Mixer
            PopupPage {
                anchors.fill: parent
                visible:      root.page === "mixer"

                SectionLabel { text: "Output Devices" }

                DeviceList {
                    width:    parent.width
                    listName: "Output devices"
                    nodes:    root.sinkNodes
                    current:  (root.sink && root.sink.ready) ? root.sink.name : ""
                    onChosen: function (node) { Pipewire.preferredDefaultAudioSink = node }
                }

                Text {
                    visible:        root.sinkNodes.length === 0
                    text:           "No output devices"
                    color:          Theme.textTertiary
                    font.pixelSize: theme.fs(11)
                    leftPadding:    10
                }

                Rectangle {
                    width: parent.width; height: 1
                    color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.06)
                }

                SectionLabel { text: "Input Devices" }

                DeviceList {
                    width:    parent.width
                    listName: "Input devices"
                    nodes:    root.sourceNodes
                    current:  (root.source && root.source.ready) ? root.source.name : ""
                    onChosen: function (node) { Pipewire.preferredDefaultAudioSource = node }
                }

                Text {
                    visible:        root.sourceNodes.length === 0
                    text:           "No input devices"
                    color:          Theme.textTertiary
                    font.pixelSize: theme.fs(11)
                    leftPadding:    10
                }
            }
        }

        // Divider
        Rectangle {
            width: 1; height: parent.height
            color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.1)
        }

        // Tab switcher — right side
        TabSwitcher {
            id: switcher
            orientation: "vertical"
            height: (parent.height - 17)
            anchors.verticalCenter: parent.verticalCenter
            model: [
                { key: "output", icon: "󰕾" },
                { key: "input",  icon: "󰍬" },
                { key: "mixer",  icon: "󰾝" },
            ]
            currentPage: root.page
            onPageChanged: function(key) { Popups.audioPage = key }
        }
    }
}
