import QtQuick
import Quickshell
import Quickshell.Io

// ─────────────────────────────────────────────────────────────────────────────
// PowerProfileService — apex-shell front-end for Andre's `powermode` tool
// (the same backend his GNOME `ultra-power@andre.local` extension drives).
//
//   /usr/local/bin/powermode {ultra-max|ultra|performance|balanced|power-saver}
//   current mode is written to /run/powermode/mode (by powermode + its monitor)
//
// ultra / ultra-max layer extras on top of power-profiles-daemon's performance
// profile (pinned CPU floor, GPU dpm high, ASPM off, + a 62 W RyzenAdj reapply
// loop for ultra-max). powermode self-escalates via passwordless sudo, so we just
// invoke it directly — exactly like the GNOME extension's Gio.Subprocess call.
// ─────────────────────────────────────────────────────────────────────────────
QtObject {
    id: root

    // Order matches the GNOME picker: Ultra-Max on top, then down to Power Saver.
    // `id` is the powermode CLI arg AND the value written to /run/powermode/mode.
    readonly property var profiles: [
        { "id": "ultra-max",   "label": "Ultra-Max"         },
        { "id": "ultra",       "label": "Ultra Performance" },
        { "id": "performance", "label": "Performance"       },
        { "id": "balanced",    "label": "Balanced"          },
        { "id": "power-saver", "label": "Power Saver"       }
    ]

    property string current: "balanced"

    // Watch /run/powermode/mode — the single source of truth, shared with the
    // GNOME extension, so the active tier stays correct no matter which UI sets it.
    property var _file: FileView {
        id: modeFile
        path: "/run/powermode/mode"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            var t = modeFile.text().trim()
            if (t !== "") root.current = t
        }
    }

    property var _setProc: Process { command: []; running: false }

    function setProfile(id) {
        root.current = id                                   // optimistic; /run confirms
        _setProc.command = ["/usr/local/bin/powermode", id]
        _setProc.running = false
        _setProc.running = true
    }
}
