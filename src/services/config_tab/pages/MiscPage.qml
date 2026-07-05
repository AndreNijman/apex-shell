import QtQuick
import Quickshell
import Quickshell.Io
import "../../../"
import "../../../components/config"

// Config → Misc
//   • About — name, version, repo, config provider
//   • Updates — auto-update toggle, status, check / apply
//   • Shell — reload the Quickshell config
//   • Keybinds — reset every shortcut to default (two-click confirm)
//   • Reset — restore all appearance/layout settings (two-click confirm)
CfgScroll {
    id: root

    // ── Live version (git describe) ───────────────────────────────────────────
    property string version: "…"

    property var _verProc: Process {
        command: ["bash", "-c", "git -C ~/.local/src/Brain_Shell describe --tags --always 2>/dev/null"]
        running: false
        stdout: SplitParser {
            onRead: function(line) { if (line.trim() !== "") root.version = line.trim() }
        }
    }

    // ── xdg-open helper ───────────────────────────────────────────────────────
    property var _openProc: Process { command: []; running: false }
    function openPath(p) {
        _openProc.command = ["bash", "-c", "xdg-open " + p + " & disown"]
        _openProc.running = false
        _openProc.running = true
    }

    // ── Two-click confirm state ───────────────────────────────────────────────
    property bool _kbArmed: false
    Timer { id: kbTimer; interval: 2500; onTriggered: root._kbArmed = false }

    property bool _rsArmed: false
    Timer { id: rsTimer; interval: 2500; onTriggered: root._rsArmed = false }

    Component.onCompleted: _verProc.running = true

    // ── About ─────────────────────────────────────────────────────────────────
    CfgSection {
        title: "About"
        first: true

        Item {
            width:  parent.width
            height: 60

            Row {
                x: 10
                anchors.verticalCenter: parent.verticalCenter
                spacing: 12

                Text {
                    text:           "󰧑"
                    font.pixelSize: 30
                    color:          Theme.active
                    anchors.verticalCenter: parent.verticalCenter
                }
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Text {
                        text:        "Brain_Shell"
                        font.pixelSize: 16
                        font.weight: Font.Medium
                        color:       Theme.text
                    }
                    Text {
                        text:        root.version + "  ·  Void / AMD fork"
                        font.pixelSize: 10
                        color:       Qt.rgba(1,1,1,0.4)
                        font.family: "JetBrains Mono"
                    }
                }
            }
        }

        CfgRow {
            label:       "Repository"
            description: "github.com/AndreNijman/brain-shell-void"
            CfgButton {
                label: "Open"
                icon:  "󰈺"
                onClicked: root.openPath("https://github.com/AndreNijman/brain-shell-void")
            }
        }

        CfgRow {
            label:     "Config provider"
            hoverable: false
            Text {
                text:        ShellState.configProvider
                font.family: "JetBrains Mono"
                font.pixelSize: 11
                color:       Theme.active
            }
        }
    }

    // ── Updates ───────────────────────────────────────────────────────────────
    CfgSection {
        title: "Updates"

        CfgRow {
            label:       "Automatic updates"
            description: "Check origin/main on startup"
            CfgSwitch {
                checked: UpdateService.autoUpdate
                onToggled: function(v) { UpdateService.setAutoUpdate(v) }
            }
        }

        CfgRow {
            label:       "Status"
            description: UpdateService.checking
                ? "Checking…"
                : (UpdateService.commitsBehind > 0
                    ? (UpdateService.commitsBehind + " update(s) available")
                    : "Up to date")
            CfgButton {
                label: "Check now"
                icon:  "󰑐"
                onClicked: UpdateService.check()
            }
        }

        Item {
            width:   parent.width
            height:  UpdateService.updateAvailable ? 38 : 0
            clip:    true
            visible: UpdateService.updateAvailable
            CfgButton {
                x: 10
                anchors.verticalCenter: parent.verticalCenter
                variant: "accent"
                label:   "Update now"
                icon:    "󰚰"
                onClicked: UpdateService.stashAndUpdate()
            }
        }
    }

    // ── Shell ─────────────────────────────────────────────────────────────────
    CfgSection {
        title: "Shell"

        CfgRow {
            label:       "Reload shell"
            description: "Reload the Quickshell config"
            CfgButton {
                label: "Reload"
                icon:  "󰑐"
                onClicked: Quickshell.reload(true)
            }
        }
    }

    // ── Keybinds ──────────────────────────────────────────────────────────────
    CfgSection {
        title: "Keybinds"

        CfgRow {
            label:       "Reset all shortcuts"
            description: "Restore every keybind to its default"
            CfgButton {
                variant: "danger"
                label:   root._kbArmed ? "Click to confirm" : "Reset"
                onClicked: {
                    if (!root._kbArmed) {
                        root._kbArmed = true
                        kbTimer.restart()
                    } else {
                        root._kbArmed = false
                        // Set the map straight from defaults (exact casing, no
                        // conflict-bail from updateBinding), then persist + reload.
                        var fresh = {}
                        var ks = Object.keys(KeybindService._defaults)
                        for (var i = 0; i < ks.length; i++) {
                            var d = KeybindService._defaults[ks[i]]
                            fresh[ks[i]] = { mods: d.mods, key: d.key, label: d.label, group: d.group }
                        }
                        KeybindService.keybinds = fresh
                        KeybindService.saveAndReload()
                    }
                }
            }
        }
    }

    // ── Reset ─────────────────────────────────────────────────────────────────
    CfgSection {
        title: "Reset"

        CfgRow {
            label:       "Reset appearance & layout"
            description: "Restore all sliders and toggles to defaults (keybinds and wallpaper are untouched)"
            CfgButton {
                variant: "danger"
                label:   root._rsArmed ? "Click to confirm" : "Reset"
                onClicked: {
                    if (!root._rsArmed) {
                        root._rsArmed = true
                        rsTimer.restart()
                    } else {
                        root._rsArmed = false
                        SettingsService.resetAll()
                    }
                }
            }
        }
    }

    Item { width: parent.width; height: 10 }
}
