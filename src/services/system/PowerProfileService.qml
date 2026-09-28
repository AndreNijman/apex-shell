pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// ─────────────────────────────────────────────────────────────────────────────
// PowerProfileService — Rime Shell front-end for rimed, the Rime OS power daemon
// (D-Bus org.rimeos.Rimed1.Power). Set goes through the `rime` CLI, which calls
// SetTier over D-Bus; rimed applies the governor/EPP/platform_profile for the
// tier and authorizes the call via polkit — passwordless for the active local
// user. The RyzenAdj reapply loop this comment used to mention went with the
// tiers that drove it.
//
// The three tier IDs are exactly rimed's (performance … power-saver). The current
// tier is read from the D-Bus `Tier` property via busctl, so rimed's AC↔battery
// auto-switching (it changes tier on plug/unplug) is reflected in the UI
// regardless of which surface set it. If rimed is not running, reads fail
// silently and the last/optimistic value stands.
//
// Singleton + refcounted. The read used to poll every 4s for the entire session
// — one `busctl` fork every 4 seconds forever — to keep a tier label fresh on a
// dashboard page that is almost never open. It now polls only while something
// displays it, and re-reads immediately on acquiring the first ref, so opening
// the page always shows the true current tier.
// ─────────────────────────────────────────────────────────────────────────────

Singleton {
    id: root

    property int refCount: 0

    property int interval: 4000

    // High→low, matching rimed's tier ladder and the historical picker order.
    //
    // `ultra-max` and `ultra` are NOT here and must not come back. rimed removed
    // both in the universal-hardware pass — `rimed-core/src/tier.rs` says so, and
    // `rimed-core/tests/tier_plan.rs` asserts that neither string parses into a
    // Tier. This list went on offering them anyway, so two buttons sat on the
    // System page that could only ever fail: `rime tier ultra` exits non-zero and
    // the optimistic label snapped back on the next poll. Nobody noticed for a
    // release; Andre found them by looking at the page.
    //
    // `check-tier-parity` in rime-os now fails CI if this list and rimed's
    // `Tier` disagree, in either direction.
    readonly property var profiles: [
        {
            "id": "performance",
            "label": "Performance"
        },
        {
            "id": "balanced",
            "label": "Balanced"
        },
        {
            "id": "power-saver",
            "label": "Power Saver"
        }
    ]

    property string current: "balanced"

    // set: `rime tier <id>` → rimed SetTier (D-Bus, polkit-authorized). Refresh
    // from the daemon once the call returns so the UI settles on the real value.
    readonly property Process setProc: Process {
        command: []
        running: false
        onExited: root._refresh()
    }

    function setProfile(id) {
        root.current = id                       // optimistic; the daemon confirms
        root.setProc.command = ["rime", "tier", id]
        root.setProc.running = false
        root.setProc.running = true
    }

    // read: busctl get-property prints `s "balanced"`; pull the quoted value.
    readonly property Process getProc: Process {
        command: ["busctl", "--system", "get-property", "org.rimeos.Rimed1", "/org/rimeos/Rimed1", "org.rimeos.Rimed1.Power", "Tier"]
        running: false
        stdout: SplitParser {
            onRead: function (line) {
                const m = line.match(/"([^"]+)"/)
                if (m && m[1] !== "")
                    root.current = m[1]
            }
        }
    }

    function _refresh() {
        root.getProc.running = false
        root.getProc.running = true
    }

    readonly property Timer poll: Timer {
        interval: root.interval
        running: root.refCount > 0
        repeat: true
        triggeredOnStart: true
        onTriggered: root._refresh()
    }
}
