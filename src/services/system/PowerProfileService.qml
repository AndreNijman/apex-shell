import QtQuick
import Quickshell
import Quickshell.Io

// ─────────────────────────────────────────────────────────────────────────────
// PowerProfileService — APEX Shell front-end for apexd, the APEX-OS power daemon
// (D-Bus org.apexos.Apexd1.Power). Set goes through the `apex` CLI, which calls
// SetTier over D-Bus; apexd applies the governor/EPP/platform_profile for the
// tier (+ the RyzenAdj reapply loop on ultra-max where the profile enables it)
// and authorizes the call via polkit — passwordless for the active local user.
//
// The five tier IDs are exactly apexd's (ultra-max … power-saver). The current
// tier is read from the D-Bus `Tier` property via busctl and polled, so apexd's
// AC↔battery auto-switching (it changes tier on plug/unplug) is reflected in the
// UI regardless of which surface set it. If apexd is not running, reads fail
// silently and the last/optimistic value stands.
// ─────────────────────────────────────────────────────────────────────────────
QtObject {
    id: root

    // High→low, matching apexd's tier ladder and the historical picker order.
    readonly property var profiles: [
        { "id": "ultra-max",   "label": "Ultra-Max"         },
        { "id": "ultra",       "label": "Ultra Performance" },
        { "id": "performance", "label": "Performance"       },
        { "id": "balanced",    "label": "Balanced"          },
        { "id": "power-saver", "label": "Power Saver"       }
    ]

    property string current: "balanced"

    // set: `apex tier <id>` → apexd SetTier (D-Bus, polkit-authorized). Refresh
    // from the daemon once the call returns so the UI settles on the real value.
    property var _setProc: Process {
        command: []
        running: false
        onExited: root._refresh()
    }
    function setProfile(id) {
        root.current = id                       // optimistic; the daemon confirms
        _setProc.command = ["apex", "tier", id]
        _setProc.running = false
        _setProc.running = true
    }

    // read: busctl get-property prints `s "ultra"`; pull the quoted value.
    property var _getProc: Process {
        command: ["busctl", "--system", "get-property",
                  "org.apexos.Apexd1", "/org/apexos/Apexd1",
                  "org.apexos.Apexd1.Power", "Tier"]
        running: false
        stdout: SplitParser {
            onRead: function(line) {
                var m = line.match(/"([^"]+)"/)
                if (m && m[1] !== "") root.current = m[1]
            }
        }
    }
    function _refresh() { _getProc.running = false; _getProc.running = true }

    // Poll so apexd-side changes (AC/battery autoswitch, `apex` CLI, another
    // surface) propagate to this UI within a few seconds.
    property var _poll: Timer {
        interval: 4000; running: true; repeat: true
        onTriggered: root._refresh()
    }

    Component.onCompleted: _refresh()
}
