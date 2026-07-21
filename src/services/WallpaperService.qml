pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../"

// ============================================================
// WallpaperService — wallpaper list + apply pipeline
//
// Flow:
//   Component.onCompleted → readConfigProc (sets currentWall etc.)
//                         → refresh() (populates wallpapers list)
//   apply(path)           → awww img + ln -sf ~/.curr_wall + matugen
//                         → saveConfig() (writes src/user_data/wallpaper.json)
// ============================================================

QtObject {
    id: root

    // ── Config path — src/user_data/wallpaper.json (relative to this file) ──────
	readonly property string configPath: Quickshell.env("HOME") + "/.config/apex-shell/src/user_data/wallpaper.json"

    // ── Rendered matugen config — matugen can't expand ~/env in template paths,
    //    so the shipped src/config/matugen.toml.in is rendered (with the live
    //    $HOME + shell dir) into this real config that matugen actually reads. ──
    readonly property string matugenConfig: Quickshell.env("HOME") + "/.config/apex-shell/matugen.toml"

    // ── State ─────────────────────────────────────────────────────────────────
    property var    wallpapers:   []
    property var    tempWalls:   []
    property string currentWall:  ""
    property string previewWall:  ""
    property string scheme:       "content"
    property bool   applying:     false
    property string wallpaperDir: "~/Pictures/Wallpapers"

    readonly property var schemes: [
        "content", "tonal-spot", "fidelity", "fruit-salad", "neutral", "monochrome"
    ]

    // Emitted when the full apply pipeline exits cleanly (exitCode === 0).
    signal wallpaperApplied(string path)

    // ── File listing ──────────────────────────────────────────────────────────
    function refresh() {
        if (listProc.running) return
        root.tempWalls = [] // Clear the temp array, not the live one yet
        listProc.running = true
    }

    property var listProc: Process {
        command: [
            "bash", "-c",
            "find \"$1\" -maxdepth 1 -type f " +
            "\\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' " +
            "-o -iname '*.gif' -o -iname '*.webp' \\) | sort",
            "--", root.wallpaperDir.replace(/^~(?=\/|$)/, Quickshell.env("HOME"))
        ]
        stdout: SplitParser {
            onRead: function(line) {
                var t = line.trim()
                if (t !== "") root.tempWalls.push(t)
            }
        }
        onExited: function() {
            // Push everything to the UI at once
            root.wallpapers = root.tempWalls
        }
    }

    // ── Config read — runs on startup, then calls refresh() ──────────────────
    property string _cfgBuf: ""
    property var readConfigProc: Process {
        command: ["bash", "-c", "cat '" + root.configPath + "' 2>/dev/null"]
        stdout: SplitParser {
            onRead: function(line) { root._cfgBuf += line }
        }
        onExited: function() {
            if (root._cfgBuf !== "") {
                try {
                    var obj = JSON.parse(root._cfgBuf)
                    if (obj.currentWall  && obj.currentWall  !== "") root.currentWall  = obj.currentWall
                    if (obj.wallpaperDir && obj.wallpaperDir !== "") root.wallpaperDir = obj.wallpaperDir
                    if (obj.scheme       && obj.scheme       !== "") root.scheme       = obj.scheme
                } catch(e) {}
            }
            if (root.currentWall === "") {
                var defaultWall = Quickshell.shellDir + "/src/assets/wallpapers/apex-shell-default-0.png"
                root.apply(defaultWall)
            }
            root.refresh()
        }
    }

    // ── Config write — called after a successful apply ────────────────────────
    function saveConfig() {
        var json = JSON.stringify({
            currentWall:  root.currentWall,
            wallpaperDir: root.wallpaperDir,
            scheme:       root.scheme
        })
        // JSON and path go in as positional args, never spliced into the script.
        saveConfigProc.command = [
            "bash", "-c",
            "mkdir -p \"$(dirname \"$2\")\" && printf '%s' \"$1\" > \"$2\"",
            "--", json, root.configPath
        ]
        saveConfigProc.running = true
    }

    property var saveConfigProc: Process {}   // silent — no stdout/stderr needed

    // ── Apply pipeline ────────────────────────────────────────────────────────
    function apply(path) {
        if (root.applying || path === "") return
        root.applying    = true
        root.currentWall = path
        applyProc.command = [
            "bash", "-c",
            // Render the portable matugen.toml.in template into the real config
            // matugen reads — substitute the live shell dir ($2) and $HOME. This
            // is idempotent and keeps the paths correct wherever the shell lives.
            "CFG=\"$HOME/.config/apex-shell/matugen.toml\"; " +
            "mkdir -p \"$(dirname \"$CFG\")\" && " +
            "sed -e \"s|@SRCDIR@|$2|g\" -e \"s|@HOME@|$HOME|g\" \"$2/src/config/matugen.toml.in\" > \"$CFG\" && " +
            "awww img --transition-type grow --transition-step 200 --transition-duration 1.2 --transition-fps 60 --transition-pos bottom \"$1\" " +
            "&& ln -sf \"$1\" ~/.curr_wall " +
            "&& (if [[ \"$1\" == *.gif ]]; then " +
            "rm -f ~/.curr_wall_static.jpg; magick \"$1[0]\" ~/.curr_wall_static.jpg || true; " +
            "else ln -sf \"$1\" ~/.curr_wall_static.jpg; fi) " +
            "&& matugen image \"$(readlink -f ~/.curr_wall_static.jpg)\" -c \"$CFG\" --source-color-index 0 --type \"scheme-$3\" " +
            "&& matugen image \"$(readlink -f ~/.curr_wall_static.jpg)\" --source-color-index 0 --type \"scheme-$3\" || true",
            "--", path, Quickshell.shellDir, root.scheme
        ]
        applyProc.running = true
    }
    
    property Process applyProc: Process {
        onExited: function(exitCode, exitStatus) {
            root.applying = false
            if (exitCode === 0) {
                root.wallpaperApplied(root.currentWall)
                root.saveConfig()

                // Trigger border update after wallpaper application finishes
                updateBorders()
            }
        }
    }

    // New function to update borders based on config provider
    function updateBorders() {
        // niri manages its own borders (config.kdl) and has no hyprctl — skip
        // silently so there's no error spam on every wallpaper apply.
        if (Compositor.isNiri) return

        // Strip '#' from the colors (assuming QML hex format #RRGGBB)
        let primary = String(Theme.active).replace('#', '')
        

        // Build command based on config provider
        if (ShellState.configProvider === "lua") {
            // Using hl.config with RGB strings in Lua
            borderUpdateProc.command = [
                "bash", "-c",
                "hyprctl eval 'hl.config({ general = { [\"col.active_border\"] = { colors = { \"rgb(" + primary + ")\" } } } })'"
            ]
        } else {
            // Using hyprctl keyword for .conf
            borderUpdateProc.command = [
                "bash", "-c",
                "hyprctl keyword general:col.active_border \"rgb(" + primary + ")\""
            ]
        }
        
        borderUpdateProc.running = true
    }

    property Process borderUpdateProc: Process {
        command: []
    }

    Component.onCompleted: {
        readConfigProc.running = true
        if (Theme.active && String(Theme.active).trim() !== "") {
            updateBorders()
        }
    }
}
