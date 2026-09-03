import QtQuick
import Quickshell
import Quickshell.Io
import "../../../"
import "../../../components"
import "../../../components/config"
// src/services — where SystemStats is registered in qmldir, the same way
// DataPage reaches DiskService and MemService. Not "../../system": that
// directory is not on the import path, and the registered type is the one the
// qmldir entry exists to provide.
import "../../"

// Config → Misc
//   • About — name, version, repo, config provider
//   • System — distro, kernel, WM, uptime, packages, hostname (SystemStats)
//   • Updates — auto-update toggle, status, check / apply
//   • Shell — reload the Quickshell config
//   • Keybinds — reset every shortcut to default (two-click confirm)
//   • Reset — restore all appearance/layout settings (two-click confirm)
CfgScroll {
    id: root

    // Set by ShellConfig and Nexus: "the Misc page is genuinely on screen".
    // Declared because SystemStats costs a subprocess and is refcounted on it;
    // PageRegistry marks this page needsScreen: true so both hosts bind it.
    property bool onScreen: false

    // ── Live version (git describe) ───────────────────────────────────────────
    property string version: "…"

    property var _verProc: Process {
        command: ["bash", "-c", "git -C \"$1\" describe --tags --always 2>/dev/null",
                  "--", Quickshell.shellDir]
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

    // ── Wolfram AppID entry ───────────────────────────────────────────────────
    // Written once typing settles, so pasting a key does not rewrite the
    // credential file on every keystroke.
    property string _appIdDraft: ""
    Timer {
        id: appIdTimer
        interval: 700
        onTriggered: WolframService.setAppId(root._appIdDraft)
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
                    font.pixelSize: Theme.fs(30)
                    color:          Theme.active
                    anchors.verticalCenter: parent.verticalCenter
                }
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Text {
                        text:        "APEX Shell"
                        font.pixelSize: Theme.fs(16)
                        font.weight: Font.Medium
                        color:       Theme.text
                    }
                    Text {
                        text:        root.version + "  ·  APEX-OS"
                        font.pixelSize: Theme.fs(10)
                        color:       Qt.rgba(1,1,1,0.4)
                        font.family: "JetBrains Mono"
                    }
                }
            }
        }

        CfgRow {
            label:       "Repository"
            description: "github.com/AndreNijman/apex-shell"
            CfgButton {
                label: "Open"
                icon:  "󰈺"
                onClicked: root.openPath("https://github.com/AndreNijman/apex-shell")
            }
        }

        CfgRow {
            label:     "Config provider"
            hoverable: false
            Text {
                text:        ShellState.configProvider
                font.family: "JetBrains Mono"
                font.pixelSize: Theme.fs(11)
                color:       Theme.active
            }
        }
    }

    // ── System ────────────────────────────────────────────────────────────────
    // Distro, kernel, WM, uptime, packages, hostname.
    //
    // Here rather than on the Data & Storage page or a new About panel: this is
    // the page that already answers "what am I running" — shell version, config
    // provider, detected compositor — and every row SystemStats prints is the
    // same question about the machine underneath. Data & Storage is live
    // telemetry with bars and controls; these are static identity facts, and
    // splitting the WM row from the Compositor section two sections below would
    // have put the same fact in two places on two pages.
    CfgSection {
        title: "System"

        // The subprocess runs only while this page is genuinely on screen.
        // NOT `active: sysStats.visible` — an Item inside a hidden window
        // reports visible: true, so that would mean "always". `onScreen` is
        // bound by ShellConfig and Nexus to window visibility AND page
        // selection AND, in Nexus, not-locked.
        ServiceRef {
            service: sysStats
            active:  root.onScreen
        }

        Item {
            width:  parent.width
            height: sysStats.implicitHeight

            SystemStats {
                id: sysStats
                x:     10
                width: parent.width - 20
            }
        }
    }

    // ── Credits ─────────────────────────────────────────────────────────────
    CfgSection {
        title: "Credits"

        CfgRow {
            label:       "Inspired by Brain_Shell"
            description: "Originally derived from Brain_Shell by Brainitech (MIT)"
            CfgButton {
                label: "Open"
                icon:  "󰈺"
                onClicked: root.openPath("https://github.com/Brainitech/Brain_Shell")
            }
        }
    }

    // ── Compositor ────────────────────────────────────────────────────────────
    CfgSection {
        title: "Compositor"

        CfgRow {
            label:     "Active"
            hoverable: false
            Text {
                text:        Compositor.name + (Compositor.overrideName === "" ? "  ·  auto" : "  ·  override")
                font.family: "JetBrains Mono"
                font.pixelSize: Theme.fs(11)
                color:       Theme.active
            }
        }

        Text {
            x:        10
            width:    parent.width - 20
            text:     "Detected " + Compositor.detected + " from the environment. Choose which compositor APEX Shell targets — Auto follows detection. Hyprland-only features (layout indicator, night light, shader filter, special workspace) degrade automatically on niri."
            font.pixelSize: Theme.fs(10)
            color:    Qt.rgba(1,1,1,0.4)
            wrapMode: Text.WordWrap
        }
        Item { width: parent.width; height: 8 }

        Item {
            width:  parent.width
            height: compSeg.implicitHeight

            CfgSegmented {
                id: compSeg
                x:     10
                width: parent.width - 20
                options: [
                    { value: "auto",     label: "Auto"     },
                    { value: "hyprland", label: "Hyprland" },
                    { value: "niri",     label: "niri"     }
                ]
                value: Compositor.overrideName === "" ? "auto" : Compositor.overrideName
                onSelected: function(v) { Compositor.setOverride(v) }
            }
        }
        Item { width: parent.width; height: 4 }
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

    // ── Launcher ──────────────────────────────────────────────────────────────
    CfgSection {
        title: "Launcher"

        CfgRow {
            label:       "Wolfram|Alpha AppID"
            description: WolframService.configured
                ? "Answers launcher queries that start with ?"
                : "Free at developer.wolframalpha.com — without it, ? does arithmetic only"
            CfgTextField {
                text:        WolframService.appId
                placeholder: "XXXXXX-XXXXXXXXXX"
                onEdited:    function(t) { root._appIdDraft = t; appIdTimer.restart() }
                onAccepted:  function(t) { appIdTimer.stop(); WolframService.setAppId(t) }
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
