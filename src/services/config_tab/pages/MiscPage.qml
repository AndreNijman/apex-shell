import QtQuick
import Quickshell
import Quickshell.Io
import "../../../"
import "../../../components"
import "../../../components/config"
// src/services — the module whose qmldir registers SystemStats, reached the
// same way DataPage reaches DiskService and MemService. Not "../../system":
// that directory holds pragma-Singleton services too, and the qmldir entry
// exists precisely to hand this type out.
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
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    lifecycle: "live"
    lifecycleError: SettingsService.lastError

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

            // Anchored rather than `x: 10` (roadmap P2-004): this Row has an
            // intrinsic width, so an explicit x pins it to the LEFT of the pane
            // in a right-to-left layout while the rows above and below it move.
            // LayoutMirroring resolves anchors and cannot touch an x.
            Row {
                anchors.left:           parent.left
                anchors.leftMargin:     10
                anchors.verticalCenter: parent.verticalCenter
                spacing: 12

                Text {
                    text:           "󰧑"
                    font.pixelSize: theme.fs(30)
                    color:          Theme.active
                    anchors.verticalCenter: parent.verticalCenter
                }
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Text {
                        text:        "APEX Shell"
                        font.pixelSize: theme.fs(16)
                        font.weight: Font.Medium
                        color:       Theme.text
                    }
                    Text {
                        text:        root.version + "  ·  APEX-OS"
                        font.pixelSize: theme.fs(10)
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
                font.pixelSize: theme.fs(11)
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
                // The PRODUCT name, not the id. A user who has never heard of
                // labwc still knows whether their windows float or tile, and
                // that is the whole of what this row is for. Where the shell is
                // running under something it has no adapter for, say so plainly
                // rather than printing an empty label — `modeName` is "" there
                // by design.
                text:        (Compositor.modeName !== "" ? Compositor.modeName
                                                         : "Not a compositor APEX supports")
                             + (Compositor.overrideName === "" ? "  ·  auto" : "  ·  override")
                font.family: "JetBrains Mono"
                font.pixelSize: theme.fs(11)
                color:       Theme.active
            }
        }

        Text {
            x:        10
            width:    parent.width - 20
            // The old wording printed `Compositor.detected`, a raw id, and named
            // only niri as the degrading target — which left a Floating user
            // reading a sentence about two compositors that were not theirs and
            // said nothing true about their own.
            //
            // EVERY CLAIM BELOW IS READ OFF THE CAPABILITY MAPS, and
            // tests/check-compositor-naming.sh fails if a backend changes one
            // of them without this sentence being revisited. As shipped:
            // accentBorder, gaps, tilingLayout, keyboardInterception,
            // screenShader and specialWorkspace are Hyprland's alone; overview
            // is niri's alone; windowMove is false on labwc only; nightLight is
            // true on all three, so it is deliberately NOT listed as degrading.
            text:     "Auto follows what APEX detects at login; pick one to pin it instead. Tiling is the only one the shell can give window gaps, an accent border, a layout indicator, a shader filter and a special workspace. Scrolling has an overview the other two do not. On Floating the shell cannot move a window to another workspace."
            font.pixelSize: theme.fs(10)
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
                // VALUES ARE IDS AND MUST NOT BE TRANSLATED — setOverride
                // writes them straight into config_Provider.json's `compositor`
                // key and Compositor.isValidName is what accepts them. Only the
                // labels are the product's words.
                //
                // labwc was missing from this list entirely while
                // isValidName() has always accepted it and CompositorService
                // has always loaded LabwcBackend.qml. So a Floating user could
                // not pin their own compositor here at all, and an override set
                // by hand in config_Provider.json left this control with no
                // option matching its own `value` — nothing highlighted, and no
                // way back to Auto except another hand edit.
                options: [
                    { value: "auto",     label: "Auto"      },
                    { value: "hyprland", label: "Tiling"    },
                    { value: "niri",     label: "Scrolling" },
                    { value: "labwc",    label: "Floating"  }
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
            // Anchored, not `x: 10` — same reason as the About row above.
            CfgButton {
                anchors.left:           parent.left
                anchors.leftMargin:     10
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
                        // Reset goes past every change, including a draft the
                        // Keybinds page is still holding. Leaving it staged
                        // would mean the next Apply there put back exactly what
                        // this button was pressed to remove.
                        KeybindService.revertStaged()
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
