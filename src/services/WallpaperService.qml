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

    // ── Config path — ~/.config/apex-shell/src/user_data/wallpaper.json ─────────
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

    // ── Light or dark ─────────────────────────────────────────────────────────
    // matugen derives BOTH schemes from every wallpaper and `-m` picks which one
    // the templates render; `{{ colors.x.default.hex }}` resolves to the chosen
    // mode. Without this the flag was never passed, matugen defaulted to dark,
    // and the light half of every palette in the tree — including the light
    // status colours Theme.Colors selects on a light surface — was unreachable.
    //
    // APEX-OS seeds `color-scheme='prefer-dark'` as a dconf DEFAULT rather than
    // a lock (files/system/dconf/00-apex-dark), so the GTK apps beside the shell
    // follow the same switch a user is free to throw. `dark` here matches that
    // default, so nothing moves on an existing install until it is changed.
    property string mode: "dark"

    readonly property var modes: ["dark", "light"]

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
    //
    // The default is applied — and, through apply(), PERSISTED — only when the
    // file does not exist or holds no currentWall. A file that exists but cannot
    // be read or parsed is left alone: falling back there used to overwrite the
    // user's choice with the shipped default, turning one bad read (a truncated
    // write, a permission slip) into a wallpaper that resets on every boot.
    property string _cfgBuf: ""
    property var readConfigProc: Process {
        command: ["bash", "-c",
            "[ -e \"$1\" ] || { echo __ABSENT__; exit 0; }; cat -- \"$1\" || exit 3",
            "--", root.configPath]
        stdout: SplitParser {
            onRead: function(line) { root._cfgBuf += line }
        }
        onExited: function(exitCode) {
            var absent = root._cfgBuf === "__ABSENT__"
            var readable = !absent && exitCode === 0
            if (readable) {
                try {
                    var obj = JSON.parse(root._cfgBuf)
                    if (obj.currentWall  && obj.currentWall  !== "") root.currentWall  = obj.currentWall
                    if (obj.wallpaperDir && obj.wallpaperDir !== "") root.wallpaperDir = obj.wallpaperDir
                    if (obj.scheme       && obj.scheme       !== "") root.scheme       = obj.scheme
                    if (obj.mode === "light" || obj.mode === "dark") root.mode         = obj.mode
                } catch(e) {
                    readable = false
                }
            }
            if (!absent && !readable) {
                console.warn("WallpaperService: " + root.configPath
                    + " exists but could not be read or parsed; leaving it and the current wallpaper alone")
            } else if (root.currentWall === "") {
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
            scheme:       root.scheme,
            mode:         root.mode
        })
        // JSON and path go in as positional args, never spliced into the script.
        // Written beside the target and renamed over it, so a crash or power cut
        // mid-write leaves the previous choice instead of an empty file.
        saveConfigProc.command = [
            "bash", "-c",
            "mkdir -p \"$(dirname \"$2\")\" && printf '%s\\n' \"$1\" > \"$2.tmp\" && mv -f \"$2.tmp\" \"$2\"",
            "--", json, root.configPath
        ]
        saveConfigProc.running = true
    }

    // A failed save used to be silent, so a choice that never persisted only
    // showed up as "the wallpaper resets on reboot". Say so in the shell log.
    property var saveConfigProc: Process {
        stderr: SplitParser {
            onRead: function(line) { console.warn("WallpaperService: save: " + line) }
        }
        onExited: function(exitCode) {
            if (exitCode !== 0)
                console.warn("WallpaperService: could not save " + root.configPath
                    + " (exit " + exitCode + "); this wallpaper will not survive a restart")
        }
    }

    // Switch the palette between matugen's two modes and re-derive it from the
    // wallpaper that is already up. saveConfig() runs either way, so the choice
    // survives a session that has no wallpaper to re-render yet.
    function setMode(m) {
        if (m !== "light" && m !== "dark") return
        if (m === root.mode) return
        root.mode = m
        if (root.currentWall !== "") root.apply(root.currentWall)
        else                         root.saveConfig()
    }

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
            "mkdir -p \"$(dirname \"$CFG\")\" || exit 1; " +
            "sed -e \"s|@SRCDIR@|$2|g\" -e \"s|@HOME@|$HOME|g\" \"$2/src/config/matugen.toml.in\" > \"$CFG\" || exit 1; " +
            // Wallpaper daemon is discovered at runtime: awww (the APEX default,
            // AUR-only) → swww (upstream). Having neither is no longer fatal:
            // previously the `&&` chain aborted yet the trailing `|| true` still
            // reported success, so the wallpaper AND the generated palette were
            // silently skipped. Now the symlink + matugen theming always run.
            "SETTER=\"\"; for S in awww swww; do " +
            "if command -v \"$S\" >/dev/null 2>&1; then SETTER=\"$S\"; break; fi; done; " +
            "[ -n \"$SETTER\" ] && \"$SETTER\" img --transition-type grow --transition-step 200 --transition-duration 1.2 --transition-fps 60 --transition-pos bottom \"$1\"; " +
            // -n: never follow an existing ~/.curr_wall that points at a directory —
            // plain -sf descends into it, fails there, and `exit 1` then skipped
            // saveConfig while the new wallpaper was already on screen.
            "ln -sfn \"$1\" ~/.curr_wall || exit 1; " +
            "if [[ \"$1\" == *.gif ]]; then " +
            "rm -f ~/.curr_wall_static.jpg; " +
            // ImageMagick 7 ships `magick`, ImageMagick 6 only `convert`.
            "if command -v magick >/dev/null 2>&1; then magick \"$1[0]\" ~/.curr_wall_static.jpg || true; " +
            "elif command -v convert >/dev/null 2>&1; then convert \"$1[0]\" ~/.curr_wall_static.jpg || true; fi; " +
            "else ln -sfn \"$1\" ~/.curr_wall_static.jpg; fi; " +
            "STATIC=\"$(readlink -f ~/.curr_wall_static.jpg)\"; " +
            // -m is what makes the light half of the palette reachable. Passed
            // to BOTH invocations: the second one renders whatever templates the
            // user has in their own matugen config, and a shell in light mode
            // beside a terminal still in dark is worse than either.
            "if command -v matugen >/dev/null 2>&1; then " +
            "matugen image \"$STATIC\" -c \"$CFG\" --source-color-index 0 --type \"scheme-$3\" -m \"$4\" || true; " +
            "matugen image \"$STATIC\" --source-color-index 0 --type \"scheme-$3\" -m \"$4\" || true; " +
            "fi; " +
            // Repaint the labwc session. matugen has just rewritten
            // ~/.config/labwc/themerc-override, but labwc only reads it on
            // reconfigure, so without this the floating session keeps the old
            // titlebar colours until the next login.
            //
            // Guarded on a labwc process actually running: `labwc
            // --reconfigure` with no server up prints an error, and this runs
            // on every wallpaper change in Hyprland and niri too.
            "if command -v labwc >/dev/null 2>&1 && pgrep -x labwc >/dev/null 2>&1; then " +
            "labwc --reconfigure >/dev/null 2>&1 || true; " +
            "fi; " +
            // Publish the new wallpaper to the LOGIN / LOCK SCREEN. Without
            // this the greeter stays on the shipped default forever: it runs as
            // the `greetd` system user, outside any session, and cannot read a
            // mode-0700 home directory — so it needs a copy somewhere it may
            // read. The root helper does exactly that and nothing else; see
            // /usr/libexec/apex-greet-wallpaper. `sudo -n` never prompts, and
            // the whole thing is best-effort: on a machine without the helper
            // (a non-APEX-OS host running this shell) the wallpaper still
            // applies exactly as before.
            "if [ -x /usr/libexec/apex-greet-wallpaper ]; then " +
            "sudo -n /usr/libexec/apex-greet-wallpaper >/dev/null 2>&1 || true; " +
            "fi; exit 0",
            "--", path, Quickshell.shellDir, root.scheme, root.mode
        ]
        applyProc.running = true
    }
    
    property Process applyProc: Process {
        onExited: function(exitCode, exitStatus) {
            root.applying = false
            if (exitCode !== 0)
                console.warn("WallpaperService: apply of " + root.currentWall
                    + " failed (exit " + exitCode + "); the choice was not saved")
            if (exitCode === 0) {
                root.wallpaperApplied(root.currentWall)
                root.saveConfig()

                // Trigger border update after wallpaper application finishes
                updateBorders()
            }
        }
    }

    // Retint the active-window border to match the wallpaper.
    //
    // Only some compositors can be told this at runtime. niri and labwc keep the
    // colour in config.kdl and themerc-override, which are files with other
    // writers — matugen generates the labwc one — so a live override there would
    // be a second writer racing the generator. CompositorService reports that as
    // `can.accentBorder` and refuses silently; the two-dialect Hyprland split
    // this used to carry lives in HyprlandBackend now.
    function updateBorders() {
        CompositorService.setAccentBorder(String(Theme.active).replace('#', ''))
    }

    // Theme.active arrives asynchronously: ColorLoader watches matugen's
    // colors.json, so at Component.onCompleted it is usually still the built-in
    // default rather than the wallpaper's accent. Retinting only there set the
    // border once from a palette that had not loaded and never again until the
    // user next changed wallpaper — which is why a freshly booted session sat on
    // the stock chartreuse while the rest of the bar was warm. Following the
    // property covers both the first load and every later matugen run.
    // Wrapped in a property because the root is a QtObject, which has no default
    // property — a bare child here is silently dropped rather than rejected.
    property var _accentWatch: Connections {
        target: Theme
        function onActiveChanged() { root.updateBorders() }
    }

    Component.onCompleted: {
        readConfigProc.running = true
        if (Theme.active && String(Theme.active).trim() !== "") {
            updateBorders()
        }
    }
}
