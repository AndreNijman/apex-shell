import QtQuick
import Quickshell.Io
import "../../../"
import "../../"
import "../../../components"
import "../../../components/config"

// Config → Data & Storage
//   • Live disk usage bars (df every 15s via DiskService)
//   • Memory in use (MemService)
//   • Clipboard history wipe (ClipboardService)
//   • Notification history + Do Not Disturb (NotificationService / ShellState)
//   • Screen-recording audio capture toggles (ScreenRecService)
//   • Quick "open folder" shortcuts (xdg-open)
CfgScroll {
    id: root

    // Set by ShellConfig: "the Data & Storage page is genuinely on screen".
    // These two services used to be instantiated here with `active: true`
    // hardcoded, which meant a `df` every 15s and a `cat /proc/meminfo` every 2s
    // from shell startup to logout — for a config sub-page most users open once.
    property bool onScreen: false

    ServiceRef {
        service: DiskService
        active: root.onScreen
    }
    ServiceRef {
        service: MemService
        active: root.onScreen
    }

    property var _openProc: Process { command: []; running: false }
    function openPath(p) {
        _openProc.command = ["bash", "-c", "xdg-open " + p + " & disown"]
        _openProc.running = false
        _openProc.running = true
    }

    // ── Disks ─────────────────────────────────────────────────────────────────
    CfgSection {
        title: "Disks"
        first: true

        Text {
            width:          parent.width
            leftPadding:    10
            visible:        DiskService.disks.length === 0
            text:           "Reading disks…"
            color:          Qt.rgba(1,1,1,0.3)
            font.pixelSize: 11
        }

        Column {
            width:   parent.width
            spacing: 6

            Repeater {
                model: DiskService.disks
                delegate: DiskBar {
                    required property var modelData
                    x:        10
                    width:    parent.width - 20
                    height:   40
                    source:   modelData.source
                    mount:    modelData.mount
                    usedPct:  modelData.usedPct
                    usedStr:  modelData.usedStr
                    totalStr: modelData.totalStr
                }
            }
        }
    }

    // ── Memory ────────────────────────────────────────────────────────────────
    CfgSection {
        title: "Memory"

        CfgRow {
            label:     "In use"
            hoverable: false
            Text {
                text:           MemService.usedStr + " / " + MemService.totalStr
                font.family:    "JetBrains Mono"
                font.pixelSize: 11
                color:          Theme.active
            }
        }
    }

    // ── Clipboard ─────────────────────────────────────────────────────────────
    CfgSection {
        title: "Clipboard"

        CfgRow {
            label:       "History"
            description: ClipboardService.entries.length + " entries stored"
            CfgButton {
                variant: "danger"
                label:   "Clear"
                icon:    "󰩺"
                onClicked: ClipboardService.wipeHistory()
            }
        }
    }

    // ── Notifications ─────────────────────────────────────────────────────────
    CfgSection {
        title: "Notifications"

        CfgRow {
            label:       "Stored"
            description: NotificationService.count + " in history"
            CfgButton {
                label:   "Clear all"
                onClicked: NotificationService.dismissAll()
            }
        }
        CfgRow {
            label:       "Do Not Disturb"
            description: "Silence incoming notifications"
            CfgSwitch {
                checked: ShellState.dnd
                onToggled: function(v) { ShellState.dnd = v }
            }
        }
    }

    // ── Screen recording ──────────────────────────────────────────────────────
    CfgSection {
        title: "Screen recording"

        CfgRow {
            label: "Capture microphone"
            CfgSwitch {
                checked: ScreenRecService.audioMic
                onToggled: function(v) {
                    ScreenRecService.audioMic = v
                    ScreenRecService.saveConfig()
                }
            }
        }
        CfgRow {
            label: "Capture system audio"
            CfgSwitch {
                checked: ScreenRecService.audioSystem
                onToggled: function(v) {
                    ScreenRecService.audioSystem = v
                    ScreenRecService.saveConfig()
                }
            }
        }
        CfgRow {
            label:       "Recordings folder"
            description: "~/Videos/screen_recordings"
            CfgButton {
                label:   "Open"
                icon:    "󰝰"
                onClicked: root.openPath("~/Videos/screen_recordings")
            }
        }
    }

    // ── Open folders ──────────────────────────────────────────────────────────
    CfgSection {
        title: "Open folders"

        Item {
            width:  parent.width
            height: 34
            Row {
                x:       10
                spacing: 8
                CfgButton { label: "Config";     icon: "󰉋"; onClicked: root.openPath("~/.config/apex-shell") }
                CfgButton { label: "Cache";      icon: "󰉋"; onClicked: root.openPath("~/.cache/apex-shell") }
                CfgButton { label: "Wallpapers"; icon: "󰉋"; onClicked: root.openPath(WallpaperService.wallpaperDir) }
            }
        }
    }

    Item { width: parent.width; height: 10 }
}
