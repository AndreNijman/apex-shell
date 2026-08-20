pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// ─── Compositor ───────────────────────────────────────────────────────────────
// Single source of truth for which Wayland compositor the shell is running under.
// The rest of the shell branches on isHyprland / isNiri so Hyprland-only features
// can degrade gracefully on niri.
//
// Detection order (startup, from environment):
//   HYPRLAND_INSTANCE_SIGNATURE set → "hyprland"
//   NIRI_SOCKET                 set → "niri"
//   XDG_CURRENT_DESKTOP ~ labwc     → "labwc"
//   none of the above               → ""  (unknown; compositor-specific paths off)
//
// Manual override: the optional "compositor" key in
//   ~/.config/apex-shell/src/user_data/config_Provider.json
// wins over detection. Values: "hyprland" | "niri" | "labwc" | "auto"/""
// (= use detection).
// Written by the Config → Misc page through setOverride(); the sibling
// "configProvider" key (read by ShellState) is preserved on every write.
// ──────────────────────────────────────────────────────────────────────────────

QtObject {
    id: root

    // ── Environment probes ────────────────────────────────────────────────────
    readonly property string _hyprSig:  Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || ""
    readonly property string _niriSock: Quickshell.env("NIRI_SOCKET") || ""
    readonly property string _desktop:  (Quickshell.env("XDG_CURRENT_DESKTOP") || "").toLowerCase()

    // Auto-detected compositor from the environment.
    //
    // The neither-branch used to return "hyprland", commented "degrades
    // nothing". It degrades plenty: on sway, river, KDE Wayland or GNOME every
    // isHyprland consumer went live, so LayoutDisplayer polled `hyprctl -j
    // activeworkspace` every 4s forever and KeybindService appended include
    // lines to a Hyprland config at startup. It now returns "" (unknown) so
    // Hyprland-only paths stay off. XDG_CURRENT_DESKTOP is consulted first so a
    // shell launched from a systemd unit that did not inherit
    // HYPRLAND_INSTANCE_SIGNATURE is still recognised.
    // labwc has no equivalent of HYPRLAND_INSTANCE_SIGNATURE or NIRI_SOCKET —
    // by design it exposes no IPC socket at all and is controllable only
    // through Wayland protocols — so XDG_CURRENT_DESKTOP is the only signal.
    // labwc sets it to "labwc:wlroots".
    readonly property string detected:
        _hyprSig  !== ""                 ? "hyprland"
      : _niriSock !== ""                 ? "niri"
      : _desktop.indexOf("hyprland") >= 0 ? "hyprland"
      : _desktop.indexOf("niri")     >= 0 ? "niri"
      : _desktop.indexOf("labwc")    >= 0 ? "labwc"
      :                                    ""

    // False when the shell is running under something that is neither Hyprland
    // nor niri — the signal for "skip compositor-specific behaviour entirely".
    readonly property bool isKnown: name !== ""

    // Manual override loaded from config_Provider.json ("" / "auto" = detect).
    property string overrideName: ""

    // ── Public API ────────────────────────────────────────────────────────────
    // Resolved compositor — a valid override wins, otherwise detection.
    // The compositors this shell has explicit support for. Anything else stays
    // unknown so compositor-specific paths remain off rather than guessing.
    function isValidName(n) {
        return n === "hyprland" || n === "niri" || n === "labwc"
    }

    readonly property string name:
        root.isValidName(overrideName) ? overrideName : detected

    readonly property bool isHyprland: name === "hyprland"
    readonly property bool isNiri:     name === "niri"
    readonly property bool isLabwc:    name === "labwc"

    // $NIRI_SOCKET path (empty off niri) — consumed by NiriService.
    readonly property string niriSocket: _niriSock

    // ── config_Provider.json (override persistence) ───────────────────────────
    readonly property string _cfgPath:
        Quickshell.env("HOME") + "/.config/apex-shell/src/user_data/config_Provider.json"

    // Last parsed file contents — cloned on write so sibling keys never drop.
    property var _cfgData: ({})

    property var _cfgFile: FileView {
        id: cfgFile
        path: root._cfgPath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root._parse(cfgFile.text())
    }

    function _parse(jsonString) {
        if (!jsonString || jsonString === "") return
        try {
            var data = JSON.parse(jsonString)
            root._cfgData = data
            root.overrideName = root.isValidName(data.compositor) ? data.compositor : ""
        } catch (e) {
            console.error("APEX Shell: Compositor failed to parse config_Provider.json")
        }
    }

    // Persist the override. mode: "hyprland" | "niri" | "auto" (clears the key).
    property var _writeProc: Process { command: []; running: false }

    function setOverride(mode) {
        // Clone existing keys so configProvider (and anything else) survives.
        var data = {}
        var ks = Object.keys(root._cfgData || {})
        for (var i = 0; i < ks.length; i++) data[ks[i]] = root._cfgData[ks[i]]

        if (root.isValidName(mode)) data.compositor = mode
        else                        delete data.compositor

        root._cfgData     = data
        root.overrideName = root.isValidName(mode) ? mode : ""

        var json = JSON.stringify(data, null, 2)
        // JSON + path go in as positional args — never spliced into the script.
        root._writeProc.command = ["bash", "-c",
            "mkdir -p \"$(dirname \"$2\")\" && printf '%s' \"$1\" > \"$2\"",
            "--", json, root._cfgPath]
        root._writeProc.running = false
        root._writeProc.running = true
    }
}
