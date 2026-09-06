pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../"
import "../../"

QtObject {
    id: root

    readonly property string _shellDir: Quickshell.shellDir
    readonly property string _configDir: Quickshell.env("HOME") + "/.config/apex-shell"
    // The Hyprland artifact is a Lua module under the compositor's own config
    // directory, because that is the only place `require("apex.shell-keybinds")`
    // resolves: Hyprland prepends the config FILE's directory to package.path,
    // so a module anywhere else cannot be named. It used to be a hyprlang
    // fragment beside the niri one in ~/.config/apex-shell, sourced by an
    // absolute path (P0-025).
    readonly property string _hyprDir:  Quickshell.env("HOME") + "/.config/hypr"
    readonly property string _luaPath:  _hyprDir + "/apex/shell-keybinds.lua"
    readonly property string _kdlPath:  _configDir + "/ApexShellKeybinds.kdl"
    readonly property string _jsonPath: _configDir + "/src/user_data/keybinds.json"

    // How the generator recognises its own output, and the module the user's
    // own binds are moved to when it does not. Both are read by
    // src/scripts/apex-keybinds-rescue.sh, which runs before every write.
    readonly property string _luaMarker: "APEX-SHELL-GENERATED"
    readonly property string _userModule: "apex.shell-keybinds-user"
    readonly property string _rescue: _shellDir + "/src/scripts/apex-keybinds-rescue.sh"

    // ── Capture gate ──────────────────────────────────────────────────────────
    // Set true by KeybindsPage while a combo is being recorded.
    // In your state handler (ShellState / Popups), observe this and dispatch:
    //   true  →  hyprctl dispatch submap, clean
    //   false →  hyprctl dispatch submap, reset
    property bool isCapturing: false

    // ── Defaults ──────────────────────────────────────────────────────────────
    readonly property var _defaults: ({
        "app-terminal":       { mods: "SUPER",         key: "T",      label: "Terminal",              group: "Applications", type: "exec",     command: "$terminal" },
        "window-close":       { mods: "SUPER",         key: "Q",      label: "Quit Window",           group: "Applications", type: "dispatch", dispatcher: "killactive", arg: "" },
        "app-browser":        { mods: "SUPER",         key: "W",      label: "Browser",               group: "Applications", type: "exec",     command: "$browser" },
        "app-files":          { mods: "SUPER",         key: "E",      label: "File Manager",          group: "Applications", type: "exec",     command: "$fileManager" },
        "session-lock":       { mods: "SUPER",         key: "L",      label: "Lock Screen",           group: "Applications", type: "exec",     command: "$qsIpc lockscreen lock" },
        "dashboard-home":     { mods: "SUPER",         key: "D",      label: "Dashboard: Home",       group: "Dashboard"      },
        "dashboard-stats":    { mods: "CTRL + SHIFT",  key: "ESCAPE", label: "Dashboard: System",     group: "Dashboard"      },
        "dashboard-kanban":   { mods: "SUPER",        key: "Z",      label: "Dashboard: Tasks",     group: "Dashboard"      },
        "dashboard-launcher": { mods: "ALT",          key: "SPACE",  label: "Dashboard: Apps",      group: "Dashboard"      },
        "dashboard-config":   { mods: "SUPER",        key: "C",      label: "Dashboard: Config",    group: "Dashboard"      },
        "PowerMenu-toggle":   { mods: "SUPER",        key: "ESCAPE", label: "Power Menu",           group: "Popups"         },
        "notification-toggle":{ mods: "SUPER",        key: "N",      label: "Notifications",        group: "Popups"         },
        "wallpaper-toggle":   { mods: "SUPER + SHIFT", key: "W",      label: "Wallpaper",            group: "Popups"         },
        "clipboard-toggle":   { mods: "SUPER",        key: "V",      label: "Clipboard",            group: "Popups"         },
        "context-menu":       { mods: "SUPER + SHIFT", key: "M",      label: "Desktop Menu",         group: "Popups"         },
        "wifi-toggle":        { mods: "SUPER + ALT",   key: "W",      label: "Network: Wi-Fi",       group: "Network Tabs"   },
        "bluetooth-toggle":   { mods: "SUPER + ALT",   key: "B",      label: "Network: Bluetooth",   group: "Network Tabs"   },
        "vpn-toggle":         { mods: "SUPER + ALT",   key: "G",      label: "Network: VPN",         group: "Network Tabs"   },
        "hotspot-toggle":     { mods: "SUPER + ALT",   key: "H",      label: "Network: Hotspot",     group: "Network Tabs"   },
        "audioOut-toggle":    { mods: "SUPER",        key: "A",      label: "Audio: Output",        group: "Audio Tabs"     },
        "audioIn-toggle":     { mods: "SUPER + ALT",   key: "I",      label: "Audio: Input",         group: "Audio Tabs"     },
        "audioMix-toggle":    { mods: "SUPER",        key: "M",      label: "Audio: Mixer",         group: "Audio Tabs"     },
        // Media keys on CTRL+SUPER, which nothing else in either session uses.
        // These duplicate the XF86 hardware keys deliberately: laptops without
        // dedicated media keys, and external keyboards that do not emit them,
        // otherwise have no way to drive playback.
        //
        // `repeat` emits Hyprland's `bindel` instead of `bind`, so holding a
        // volume or brightness key keeps stepping. Transport keys are one-shot.
        // Volume goes through wpctl and brightness through brightnessctl, the
        // same commands the XF86 keys use, so the shell's OSD reacts to both
        // without either compositor telling it anything.
        "media-play-pause":   { mods: "CTRL + SUPER", key: "SPACE",  label: "Play / Pause",         group: "Media", type: "exec", command: "playerctl play-pause" },
        "media-next":         { mods: "CTRL + SUPER", key: "RIGHT",  label: "Next Track",           group: "Media", type: "exec", command: "playerctl next" },
        "media-previous":     { mods: "CTRL + SUPER", key: "LEFT",   label: "Previous Track",       group: "Media", type: "exec", command: "playerctl previous" },
        "volume-up":          { mods: "CTRL + SUPER", key: "EQUAL",  label: "Volume Up",            group: "Media", type: "exec", repeat: true, command: "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+" },
        "volume-down":        { mods: "CTRL + SUPER", key: "MINUS",  label: "Volume Down",          group: "Media", type: "exec", repeat: true, command: "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-" },
        "volume-mute":        { mods: "CTRL + SUPER", key: "0",      label: "Mute",                 group: "Media", type: "exec", command: "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle" },
        "brightness-up":      { mods: "CTRL + SUPER", key: "UP",     label: "Brightness Up",        group: "Media", type: "exec", repeat: true, command: "brightnessctl set 5%+" },
        "brightness-down":    { mods: "CTRL + SUPER", key: "DOWN",   label: "Brightness Down",      group: "Media", type: "exec", repeat: true, command: "brightnessctl set 5%-" },
        "focus-toggle":       { mods: "SUPER",        key: "B",      label: "Focus Mode",           group: "Quick Settings" },
        "screenrec-on":       { mods: "ALT",          key: "F9",     label: "Screen Record",        group: "Quick Settings" },
        "screenshot-area":    { mods: "",             key: "PRINT",  label: "Screenshot Area",      group: "Window Management", type: "exec", command: "bash " + root._shellDir + "/src/scripts/screenshot.sh area" },
        "screenshot-screen":  { mods: "SUPER",        key: "PRINT",  label: "Screenshot Screen",    group: "Window Management", type: "exec", command: "bash " + root._shellDir + "/src/scripts/screenshot.sh screen" },
        "window-fullscreen":  { mods: "SUPER",        key: "F",      label: "Toggle Fullscreen",    group: "Window Management", type: "dispatch", dispatcher: "fullscreen", arg: "0" },
        "window-floating":    { mods: "SUPER + SHIFT", key: "SPACE",  label: "Toggle Floating",      group: "Window Management", type: "dispatch", dispatcher: "togglefloating", arg: "" },
        "window-pseudo":      { mods: "SUPER",        key: "P",      label: "Toggle Pseudotile",    group: "Window Management", type: "dispatch", dispatcher: "pseudo", arg: "" },
        "window-split":       { mods: "SUPER",        key: "J",      label: "Toggle Split",         group: "Window Management", type: "dispatch", dispatcher: "layoutmsg", arg: "togglesplit" },
        "focus-left":         { mods: "SUPER",        key: "LEFT",   label: "Focus Left",           group: "Window Management", type: "dispatch", dispatcher: "movefocus", arg: "l" },
        "focus-right":        { mods: "SUPER",        key: "RIGHT",  label: "Focus Right",          group: "Window Management", type: "dispatch", dispatcher: "movefocus", arg: "r" },
        "focus-up":           { mods: "SUPER",        key: "UP",     label: "Focus Up",             group: "Window Management", type: "dispatch", dispatcher: "movefocus", arg: "u" },
        "focus-down":         { mods: "SUPER",        key: "DOWN",   label: "Focus Down",           group: "Window Management", type: "dispatch", dispatcher: "movefocus", arg: "d" },
        "move-left":          { mods: "SUPER + SHIFT", key: "LEFT",   label: "Move Window Left",     group: "Window Management", type: "dispatch", dispatcher: "movewindow", arg: "l" },
        "move-right":         { mods: "SUPER + SHIFT", key: "RIGHT",  label: "Move Window Right",    group: "Window Management", type: "dispatch", dispatcher: "movewindow", arg: "r" },
        "move-up":            { mods: "SUPER + SHIFT", key: "UP",     label: "Move Window Up",       group: "Window Management", type: "dispatch", dispatcher: "movewindow", arg: "u" },
        "move-down":          { mods: "SUPER + SHIFT", key: "DOWN",   label: "Move Window Down",     group: "Window Management", type: "dispatch", dispatcher: "movewindow", arg: "d" },
        "workspace-1":        { mods: "SUPER",         key: "1",      label: "Workspace 1",          group: "Workspaces", type: "dispatch", dispatcher: "workspace", arg: "1" },
        "workspace-2":        { mods: "SUPER",         key: "2",      label: "Workspace 2",          group: "Workspaces", type: "dispatch", dispatcher: "workspace", arg: "2" },
        "workspace-3":        { mods: "SUPER",         key: "3",      label: "Workspace 3",          group: "Workspaces", type: "dispatch", dispatcher: "workspace", arg: "3" },
        "workspace-4":        { mods: "SUPER",         key: "4",      label: "Workspace 4",          group: "Workspaces", type: "dispatch", dispatcher: "workspace", arg: "4" },
        "workspace-5":        { mods: "SUPER",         key: "5",      label: "Workspace 5",          group: "Workspaces", type: "dispatch", dispatcher: "workspace", arg: "5" },
        "workspace-6":        { mods: "SUPER",         key: "6",      label: "Workspace 6",          group: "Workspaces", type: "dispatch", dispatcher: "workspace", arg: "6" },
        "workspace-7":        { mods: "SUPER",         key: "7",      label: "Workspace 7",          group: "Workspaces", type: "dispatch", dispatcher: "workspace", arg: "7" },
        "workspace-8":        { mods: "SUPER",         key: "8",      label: "Workspace 8",          group: "Workspaces", type: "dispatch", dispatcher: "workspace", arg: "8" },
        "workspace-9":        { mods: "SUPER",         key: "9",      label: "Workspace 9",          group: "Workspaces", type: "dispatch", dispatcher: "workspace", arg: "9" },
        "workspace-10":       { mods: "SUPER",         key: "0",      label: "Workspace 10",         group: "Workspaces", type: "dispatch", dispatcher: "workspace", arg: "10" },
        "move-workspace-1":   { mods: "SUPER + SHIFT", key: "1",      label: "Move to Workspace 1",  group: "Workspaces", type: "dispatch", dispatcher: "movetoworkspace", arg: "1" },
        "move-workspace-2":   { mods: "SUPER + SHIFT", key: "2",      label: "Move to Workspace 2",  group: "Workspaces", type: "dispatch", dispatcher: "movetoworkspace", arg: "2" },
        "move-workspace-3":   { mods: "SUPER + SHIFT", key: "3",      label: "Move to Workspace 3",  group: "Workspaces", type: "dispatch", dispatcher: "movetoworkspace", arg: "3" },
        "move-workspace-4":   { mods: "SUPER + SHIFT", key: "4",      label: "Move to Workspace 4",  group: "Workspaces", type: "dispatch", dispatcher: "movetoworkspace", arg: "4" },
        "move-workspace-5":   { mods: "SUPER + SHIFT", key: "5",      label: "Move to Workspace 5",  group: "Workspaces", type: "dispatch", dispatcher: "movetoworkspace", arg: "5" },
        "move-workspace-6":   { mods: "SUPER + SHIFT", key: "6",      label: "Move to Workspace 6",  group: "Workspaces", type: "dispatch", dispatcher: "movetoworkspace", arg: "6" },
        "move-workspace-7":   { mods: "SUPER + SHIFT", key: "7",      label: "Move to Workspace 7",  group: "Workspaces", type: "dispatch", dispatcher: "movetoworkspace", arg: "7" },
        "move-workspace-8":   { mods: "SUPER + SHIFT", key: "8",      label: "Move to Workspace 8",  group: "Workspaces", type: "dispatch", dispatcher: "movetoworkspace", arg: "8" },
        "move-workspace-9":   { mods: "SUPER + SHIFT", key: "9",      label: "Move to Workspace 9",  group: "Workspaces", type: "dispatch", dispatcher: "movetoworkspace", arg: "9" },
        "move-workspace-10":  { mods: "SUPER + SHIFT", key: "0",      label: "Move to Workspace 10", group: "Workspaces", type: "dispatch", dispatcher: "movetoworkspace", arg: "10" },
        "scratchpad-toggle":  { mods: "SUPER",         key: "S",      label: "Toggle Scratchpad",    group: "Workspaces", type: "dispatch", dispatcher: "togglespecialworkspace", arg: "magic" },
        "scratchpad-move":    { mods: "SUPER + SHIFT", key: "S",      label: "Move to Scratchpad",   group: "Workspaces", type: "dispatch", dispatcher: "movetoworkspace", arg: "special:magic" },
    })

    property var keybinds: ({})

    // ── Hyprland binds cache ──────────────────────────────────────────────────
    // Refreshed each time a BindRow enters capture mode.
    property var _hyprBinds: []

    property var _hyprBindsProc: Process {
        command: ["hyprctl", "binds", "-j"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                try   { root._hyprBinds = JSON.parse(text.trim()) }
                catch (e) { root._hyprBinds = [] }
            }
        }
    }

    function loadHyprBinds() {
        if (!Compositor.isHyprland) return   // `hyprctl binds` is Hyprland-only
        _hyprBindsProc.running = false
        _hyprBindsProc.running = true
    }

    // Converts "SUPER + SHIFT" → Hyprland modmask integer
    function _modsToMask(modsStr) {
        var mask = 0
        var parts = modsStr.toUpperCase().split("+")
        for (var i = 0; i < parts.length; i++) {
            var p = parts[i].trim()
            if      (p === "SUPER") mask |= 64
            else if (p === "SHIFT") mask |= 1
            else if (p === "CTRL")  mask |= 4
            else if (p === "ALT")   mask |= 8
        }
        return mask
    }

    // Combos (modmask + lowercased key) that APEX Shell itself claims: every
    // bound action of the saved map, plus the caller's staged edits.
    // `hyprctl binds -j` reports the shell's own generated binds back to us, and
    // both sides are needed to recognise them: the saved map is what was last
    // written to the generated files (so it matches what hyprctl currently
    // holds), the staged edits are what the next write will claim.
    function _ownedCombos(overlay) {
        var owned = {}
        var ov    = overlay || {}
        var ks    = Object.keys(root.keybinds)
        for (var i = 0; i < ks.length; i++) {
            var b = root.keybinds[ks[i]]
            if (b && b.key) owned[_modsToMask(b.mods) + "+" + b.key.toLowerCase()] = true
            var p = ov[ks[i]]
            if (p && p.key) owned[_modsToMask(p.mods) + "+" + p.key.toLowerCase()] = true
        }
        return owned
    }

    // Returns a short description of a conflicting Hyprland bind that APEX Shell
    // does not own, or "".
    // Matching on `ipc call` used to be the "own binds" filter, which only
    // covered IPC actions: every dispatch/exec default (scratchpad move,
    // screenshots, workspace switches, app launches) is reported back by
    // hyprctl too and so conflicted with itself. Ownership is decided by combo
    // instead. Limitation: hyprctl carries no provenance, so an external bind
    // sharing a combo APEX Shell already owns is not reported.
    function wouldConflictHypr(mods, key, overlay) {
        var mask  = _modsToMask(mods)
        var k     = key.toLowerCase()
        var owned = _ownedCombos(overlay)
        for (var i = 0; i < root._hyprBinds.length; i++) {
            var b  = root._hyprBinds[i]
            var bk = (b.key || "").toLowerCase()
            if (b.submap !== "")                  continue  // ignore submaps
            if (b.mouse)                          continue  // ignore mouse binds
            if (owned[b.modmask + "+" + bk])      continue  // our own shell binds
            if (b.modmask === mask && bk === k) {
                var desc = b.dispatcher || ""
                if (b.arg) desc += ": " + b.arg.substring(0, 36)
                return desc || "Hyprland bind"
            }
        }
        return ""
    }

    // ── Internal duplicate detection ──────────────────────────────────────────
    // Comparison key for two bindings. Values are uppercased on write, but a
    // staged edit still carries the raw captured casing ("Escape") and a
    // hand-edited keybinds.json can carry any casing or spacing ("super+shift"),
    // so both sides are folded — the same way _modsToMask() already ignores both.
    function _combo(mods, key) {
        return (mods || "").toUpperCase().replace(/\s+/g, "") + "+" + (key || "").toUpperCase().trim()
    }

    // combo → list of actions claiming it, for any keybind map.
    function _comboMapOf(map) {
        var m  = {}
        var ks = Object.keys(map)
        for (var i = 0; i < ks.length; i++) {
            var b = map[ks[i]]
            if (!b || !b.key) continue
            var combo = _combo(b.mods, b.key)
            if (!m[combo]) m[combo] = [ks[i]]
            else           m[combo] = m[combo].concat([ks[i]])
        }
        return m
    }

    readonly property var _comboMap: root._comboMapOf(root.keybinds)

    function isDuplicate(action) {
        var b = root.keybinds[action]
        if (!b || !b.key) return false
        var combo = _combo(b.mods, b.key)
        return !!(root._comboMap[combo] && root._comboMap[combo].length > 1)
    }

    function conflictsWith(action) {
        var b = root.keybinds[action]
        if (!b || !b.key) return ""
        var list = root._comboMap[_combo(b.mods, b.key)]
        if (!list || list.length < 2) return ""
        for (var i = 0; i < list.length; i++) {
            if (list[i] !== action) {
                var o = root.keybinds[list[i]]
                return o ? o.label : list[i]
            }
        }
        return ""
    }

    // Returns the action whose EFFECTIVE binding already claims mods+key, or "".
    // `overlay` is the Keybinds page's pending map ({ action: { mods, key } }):
    // a candidate resolves to its staged edit when it has one and to its saved
    // binding otherwise, so a combo freed by a staged clear counts as free and a
    // combo taken by a staged edit counts as taken. Only the action id is
    // returned — overlay entries carry no label, so naming is the caller's job.
    function conflictingAction(action, mods, key, overlay) {
        var combo = _combo(mods, key)
        var ov    = overlay || {}
        var ks    = Object.keys(root.keybinds)
        for (var i = 0; i < ks.length; i++) {
            if (ks[i] === action) continue
            var e = ov[ks[i]] !== undefined ? ov[ks[i]] : root.keybinds[ks[i]]
            if (!e || !e.key) continue   // an unbound action claims no combo
            if (_combo(e.mods, e.key) === combo) return ks[i]
        }
        return ""
    }

    // ── Load ──────────────────────────────────────────────────────────────────
    property var _loadProc: Process {
        command: ["bash", "-c",
            "[ -f '" + root._jsonPath + "' ] && cat '" + root._jsonPath + "' || echo '{}'"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                var merged = {}
                var defs   = root._defaults
                var dkeys  = Object.keys(defs)
                for (var i = 0; i < dkeys.length; i++) {
                    var dk = dkeys[i]
                    merged[dk] = Object.assign({}, defs[dk])
                }
                try {
                    var saved = JSON.parse(text.trim())
                    var sk = Object.keys(saved)
                    for (var j = 0; j < sk.length; j++) {
                        var s = sk[j]
                        if (!merged[s]) continue
                        if (saved[s].mods !== undefined) merged[s].mods = saved[s].mods
                        if (saved[s].key  !== undefined) merged[s].key  = saved[s].key
                    }
                } catch(e) {}
                root.keybinds = merged
                root._writeFiles()
                root._ensureInclude()
            }
        }
    }

    // ── Save / Reload ─────────────────────────────────────────────────────────
    function save() {
        var out  = {}
        var defs = root._defaults
        var ks   = Object.keys(root.keybinds)
        for (var i = 0; i < ks.length; i++) {
            var k = ks[i]
            if (!defs[k]) continue
            if (root.keybinds[k].mods !== defs[k].mods || root.keybinds[k].key !== defs[k].key)
                out[k] = { mods: root.keybinds[k].mods, key: root.keybinds[k].key }
        }
        var json = JSON.stringify(out, null, 2)
        _saveProc.command = ["bash", "-c",
            "mkdir -p \"$(dirname \"$2\")\" && printf '%s' \"$1\" > \"$2\"",
            "--", json, root._jsonPath]
        _saveProc.running = false
        _saveProc.running = true
        root._writeFiles()
    }

    property var _saveProc: Process { command: []; running: false }

    property var _reloadProc: Process {
        command: ["hyprctl", "reload"]
        running: false
    }

    // Brief delay lets the file writes flush before hyprctl re-reads them
    property var _reloadTimer: Timer {
        interval: 300
        repeat:   false
        onTriggered: {
            root._reloadProc.running = false
            root._reloadProc.running = true
        }
    }

    function reload() {
        // niri live-reloads its config (and any included file) on change, and has
        // no `hyprctl reload` — skip the Hyprland reload entirely.
        // Positive guard: `hyprctl reload` must not fire on niri OR on a
        // third compositor where isNiri is also false.
        if (!Compositor.isHyprland) return
        _reloadTimer.restart()
    }

    // Persist to disk and reload Hyprland in one call
    function saveAndReload() {
        save()
        reload()
    }

    // Applies a whole batch of staged edits at once: the merged map is written
    // and reloaded exactly once. Applying them one by one re-ran the generated
    // file writes (and, through unbindBinding, hyprctl reload) per edit, so a
    // single Save raced several bash processes on the same three files.
    // An entry with an empty key unbinds its action.
    function applyEdits(pending) {
        if (!pending) return
        var ks = Object.keys(pending)
        if (ks.length === 0) return

        var copy = Object.assign({}, root.keybinds)
        for (var i = 0; i < ks.length; i++) {
            var old = copy[ks[i]]
            if (!old) continue   // unknown action: nothing to merge into
            copy[ks[i]] = Object.assign({}, old, {
                mods: (pending[ks[i]].mods || "").toUpperCase().trim(),
                key:  (pending[ks[i]].key  || "").toUpperCase().trim()
            })
        }

        // A duplicate surviving the merge is applied, not dropped: an A<->B swap
        // can only be expressed by staging both halves, and updateBinding()'s
        // per-action bail would silently discard one of them. Rows keep flagging
        // it through isDuplicate()/conflictsWith(); the log records it too.
        var combos = _comboMapOf(copy)
        var dupes  = Object.keys(combos).filter(function(c) { return combos[c].length > 1 })
        if (dupes.length > 0)
            console.warn("KeybindService: applied keybinds with duplicate combos:", dupes.join(", "))

        root.keybinds = copy
        saveAndReload()
    }

    // Updates in-memory only — does NOT persist.
    // Callers responsible for invoking saveAndReload() when ready.
    function updateBinding(action, newMods, newKey) {
        var old = root.keybinds[action]
        if (!old) return
        var m = newMods.toUpperCase().trim()
        var k = newKey.toUpperCase().trim()
        if (k === "") return
        if (root.conflictingAction(action, m, k) !== "") return
        var copy     = Object.assign({}, root.keybinds)
        copy[action] = Object.assign({}, old, { mods: m, key: k })
        root.keybinds = copy
    }

    // Reset is always immediate — reverts to default and reloads right away
    function resetBinding(action) {
        var def = root._defaults[action]
        if (!def) return
        updateBinding(action, def.mods, def.key)
        saveAndReload()
    }

	// Allows the UI to explicitly unbind an action (or preserve installer unbinds)
    function unbindBinding(action) {
        if (!root.keybinds[action]) return
        
        var edit = {}
        edit[action] = { mods: "", key: "" }
        
        applyEdits(edit)   // one merge path, one write + reload
    }

    // ── File generation ───────────────────────────────────────────────────────
    property var _writeProc: Process { command: []; running: false }

    function _writeFiles() {
        var lua = _genLua()
        var kdl = _genKdl()

        // Both artifacts, so the bindings are already in place whichever session
        // the user picks at the greeter. Contents + paths go in as positional
        // args, never spliced into the script.
        //
        // The hyprlang .conf is no longer written. Hyprland 0.56.2 loads
        // hyprland.lua and never mentions a .conf beside it, so continuing to
        // write one would produce a file that looks current, is read by nothing,
        // and gives no error to say so.
        //
        // mkdir -p because ~/.config/hypr/apex may not exist yet: the
        // provisioner deliberately stopped pre-creating the generated modules
        // once hyprland.lua's loader learned to skip an absent one.
        // The rescue runs FIRST, and its exit status is ignored on purpose.
        //
        // apex/shell-keybinds.lua is not a file only this generator writes:
        // apex-hypr-migrate converts the user's old ApexShellKeybinds.conf and
        // writes the result there, because that is the only name `require` can
        // reach it by. Overwriting it whole on the next start is how a
        // migration that carefully preserved a hand-edited keybind loses it
        // anyway, without a word — P0-025's "no user custom keybind is
        // silently discarded", broken by the shell rather than by the
        // migration. See src/scripts/apex-keybinds-rescue.sh.
        _writeProc.command = ["bash", "-c",
            'mkdir -p "$(dirname "$3")" "$(dirname "$4")"\n'
            + 'bash "$5" "$3" ' + root._luaMarker + ' || true\n'
            + 'printf %s "$1" > "$3"\n'
            + 'printf %s "$2" > "$4"\n',
            "--", lua, kdl, root._luaPath, root._kdlPath, root._rescue]

        _writeProc.running = false
        _writeProc.running = true

        _applyLabwc()
    }

    // ── labwc ─────────────────────────────────────────────────────────────────
    // The fourth session. labwc has no IPC to push bindings over and no include
    // mechanism to append a generated file to, so its bindings cannot be written
    // as a fourth artifact next to the three above — they have to be spliced
    // into rc.xml, which needs an XML-aware edit that preserves the rest of a
    // file the user also owns.
    //
    // That is what /usr/libexec/apex-labwc-keybinds does. Until it existed, a
    // labwc user could rebind the launcher, watch the UI confirm it, and get
    // nothing: three files written, none of which labwc reads.
    //
    // Run unconditionally rather than only on labwc, matching the three above —
    // a user who edits shortcuts on Hyprland and later picks labwc at the
    // greeter should find them already applied.
    //
    // `test -x` first because the shell is a $HOME git checkout that updates
    // independently of the OS image the helper ships in. Without it, every save
    // on a machine running an older image logs a failed spawn.
    property var _labwcProc: Process {
        command: ["bash", "-c",
                  "test -x /usr/libexec/apex-labwc-keybinds "
                  + "&& exec /usr/libexec/apex-labwc-keybinds apply"]
        running: false
    }

    function _applyLabwc() {
        _labwcProc.running = false
        _labwcProc.running = true
    }

    function _grouped() {
        var groups = {}; var order = []
        var ks = Object.keys(root.keybinds)
        for (var i = 0; i < ks.length; i++) {
            var k = ks[i]; var b = root.keybinds[k]
            if (!b || !b.key) continue
            var g = b.group || "Other"
            if (!groups[g]) { groups[g] = []; order.push(g) }
            groups[g].push(Object.assign({ k: k }, b))
        }
        return { groups: groups, order: order }
    }

    // ── Hyprland dispatcher -> Lua ────────────────────────────────────────────
    // Every name checked against /usr/share/hypr/stubs/hl.meta.lua for the
    // Hyprland the image ships, not the wiki.
    //
    // These used to be emitted as `hl.dsp.exec_cmd("hyprctl dispatch <verb>")`:
    // the compositor spawning a shell to run a client that talks back to the
    // compositor, once per keypress, for something the Lua API does directly.
    // It also meant every window-management bind depended on hyprctl being on
    // PATH inside the session.
    //
    // hyprlang took one-letter directions (`movefocus, l`); the Lua dispatcher
    // spells them out.
    readonly property var _luaDirections: ({
        l: "left", r: "right", u: "up", d: "down"
    })

    function _luaStr(s) {
        return '"' + String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'
    }

    // Returns the Lua dispatcher expression for a dispatch entry, or "" when
    // there is no equivalent — reported in the file rather than guessed at.
    function _luaDispatch(e) {
        var arg = e.arg || ""
        switch (e.dispatcher) {
        case "killactive":             return "hl.dsp.window.close()"
        case "fullscreen":             return "hl.dsp.window.fullscreen({ mode = " + (arg || "0") + " })"
        case "togglefloating":         return 'hl.dsp.window.float({ action = "toggle" })'
        case "pseudo":                 return "hl.dsp.window.pseudo()"
        case "layoutmsg":              return "hl.dsp.layout(" + root._luaStr(arg) + ")"
        case "togglespecialworkspace": return "hl.dsp.workspace.toggle_special(" + root._luaStr(arg || "special") + ")"
        case "movefocus":
            if (!root._luaDirections[arg]) return ""
            return "hl.dsp.focus({ direction = " + root._luaStr(root._luaDirections[arg]) + " })"
        case "movewindow":
            if (!root._luaDirections[arg]) return ""
            return "hl.dsp.window.move({ direction = " + root._luaStr(root._luaDirections[arg]) + " })"
        case "workspace":
            return "hl.dsp.focus({ workspace = " + (/^\d+$/.test(arg) ? arg : root._luaStr(arg)) + " })"
        case "movetoworkspace":
            return "hl.dsp.window.move({ workspace = " + (/^\d+$/.test(arg) ? arg : root._luaStr(arg)) + " })"
        }
        return ""
    }

    // Command variables, resolved. Matches _niriApps below — `$browser` is NOT
    // a browser name: apex-open-browser opens whichever browser the user has
    // set as default, which is the whole reason nothing in APEX hardcodes one.
    // This generator used to substitute `firefox` here while the niri and conf
    // paths used the helper, so a Hyprland user's SUPER+W ignored their own
    // default browser and every other session honoured it.
    function _luaCommand(command) {
        return String(command)
            .replace("$terminal",    "alacritty")
            .replace("$browser",     "/usr/libexec/apex-open-browser")
            .replace("$fileManager", "thunar")
            .replace("$qsIpc",       "qs -p " + root._shellDir + " ipc call")
    }

    function _genLua() {
        var data = _grouped()

        var lines = [
            "-- ==============================================================================",
            "-- APEX Shell Keybinds",
            "-- " + root._luaMarker + " — rewritten in full every time the shell starts.",
            "-- Edit the Keybinds page in APEX Settings, or put your own binds in",
            "-- apex/shell-keybinds-user.lua, which is required at the bottom of this file",
            "-- and is never regenerated.",
            "--",
            "-- Required by ~/.config/hypr/hyprland.lua as `apex.shell-keybinds`, and loaded",
            "-- after apex/keybindings.lua so these win.",
            "-- ==============================================================================",
            "",
            "local shell = " + root._luaStr(root._shellDir),
            "",
            "-- ==============================================================================",
            "-- ApexShell Capture Submap (Disables all normal binds during recording)",
            "-- ==============================================================================",
            "hl.define_submap(\"ApexShell_clean\", function()",
            "    -- Emergency exit in case the shell crashes during capture",
            "    hl.bind(\"CTRL + ESCAPE\", function()",
            "        hl.dispatch(hl.dsp.exec_cmd(\"notify-send 'ApexShell' 'Emergency Exit: Keybinds re-enabled.'\"))",
            "        hl.dispatch(hl.dsp.submap(\"reset\"))",
            "    end, { description = \"Emergency return to global submap\" })",
            "end)",
            "",
            "-- ==============================================================================",
            "-- Switch off the APEX default on every combo this file claims",
            "-- ==============================================================================",
            "-- hl.bind returns a handle with :set_enabled(false), and",
            "-- apex/keybindings.lua keeps one per default under a canonical combo key. So",
            "-- a combo bound here has its APEX default switched off first, and the key",
            "-- does ONE thing — Hyprland fires BOTH actions for a doubly-bound combo,",
            "-- which is how SUPER+Q once closed the window AND opened the launcher.",
            "--",
            "-- The hyprlang generator emitted an `unbind` line for every APEX default on",
            "-- every write, whether or not the user had touched it, because hyprlang could",
            "-- only remove a bind by key and had no way to disable one. disable() touches",
            "-- exactly the bind being replaced and is a no-op when there is nothing there.",
            "--",
            "-- pcall because a hand-written hyprland.lua need not load the APEX modules at",
            "-- all; without the APEX defaults there is nothing to disable and these binds",
            "-- stand alone.",
            "local ok, defaults = pcall(require, \"apex.keybindings\")",
            "local function claim(mods, key)",
            "    if ok and defaults and defaults.disable then defaults.disable(mods, key) end",
            "end",
            ""
        ]

        // ── Release the combo an action was moved OFF ────────────────────────
        //
        // Claiming the combo each bind now uses is only half of it. apex-os's
        // apex/keybindings.lua binds SUPER+T, SUPER+Q, SUPER+W, SUPER+E,
        // SUPER+L and both Print keys — the same actions this file owns. Rebind
        // Terminal from SUPER+T to SUPER+SHIFT+T and the loop below claims the
        // new combo, while SUPER+T keeps opening a terminal from the OS module.
        // Unbind it entirely and _grouped() emits nothing at all for it, so the
        // UI says the key is free and SUPER+T still fires.
        //
        // The hyprlang generator did not have this bug: it emitted an `unbind`
        // for every APEX default on every write, indiscriminately, because
        // hyprlang could not disable a bind by handle. Moving to disable() lost
        // the indiscriminate pass and did not replace it. This is the
        // replacement, and it is narrow: only defaults the user has actually
        // moved away from or switched off.
        const released = {}
        const defKeys = Object.keys(root._defaults)
        for (let di = 0; di < defKeys.length; di++) {
            const dk  = defKeys[di]
            const def = root._defaults[dk]
            if (!def || !def.key) continue
            const cur     = root.keybinds[dk]
            const curMods = cur ? (cur.mods || "") : ""
            const curKey  = cur ? (cur.key  || "") : ""
            if (curMods === (def.mods || "") && curKey === def.key) continue
            const tag = (def.mods || "") + "|" + def.key
            if (released[tag]) continue
            released[tag] = true
            lines.push("-- " + dk + " has moved off its default combo")
            lines.push("claim(" + root._luaStr(def.mods || "") + ", "
                       + root._luaStr(def.key) + ")")
        }
        if (defKeys.length > 0) lines.push("")

        for (var gi = 0; gi < data.order.length; gi++) {
            var g = data.order[gi]
            lines.push("-- " + g)
            var entries = data.groups[g]
            for (var ei = 0; ei < entries.length; ei++) {
                var e = entries[ei]
                var combo = e.mods ? e.mods + " + " + e.key : e.key

                var expression
                if (e.type === "dispatch") {
                    expression = root._luaDispatch(e)
                    if (expression === "") {
                        // Recorded in the file rather than guessed at or
                        // silently skipped, the way the niri generator does it.
                        lines.push("-- " + e.k + ": no Lua equivalent of "
                                   + e.dispatcher + " " + (e.arg || ""))
                        continue
                    }
                } else if (e.type === "exec") {
                    expression = "hl.dsp.exec_cmd(" + root._luaStr(root._luaCommand(e.command)) + ")"
                } else {
                    expression = "hl.dsp.exec_cmd(\"qs -p \" .. shell .. \" ipc call "
                                 + e.k + " toggle\")"
                }

                // `repeat` is hyprlang's bindel: repeats while held AND fires
                // with the screen locked or off. Volume and brightness are
                // useless without it. The old Lua provider dropped the flag
                // entirely and emitted a plain bind, so holding a volume key on
                // a Lua config stepped exactly once.
                var opts = e.repeat ? ", { locked = true, repeating = true }" : ""

                lines.push("claim(" + root._luaStr(e.mods) + ", " + root._luaStr(e.key) + ")")
                lines.push("hl.bind(" + root._luaStr(combo) + ", " + expression + opts + ")")
            }
            lines.push("")
        }

        // Last, so a combo the user bound themselves runs their action too.
        // pcall because the module usually does not exist — it is created only
        // when this generator finds a shell-keybinds.lua it did not write, and
        // `require` on a missing module is an error, not a nil.
        lines.push("-- ==============================================================================")
        lines.push("-- Your own binds")
        lines.push("-- ==============================================================================")
        lines.push("-- Anything you wrote yourself, or that apex-hypr-migrate carried over from")
        lines.push("-- the hyprlang ApexShellKeybinds fragment, was moved to " + root._userModule)
        lines.push("-- so this file could be regenerated without discarding it. Loaded last.")
        lines.push("pcall(require, " + root._luaStr(root._userModule) + ")")
        lines.push("")
        return lines.join("\n")
    }

    // _genConf is gone. It wrote the hyprlang fragment the seeded
    // hyprland.conf sourced, and emitted an `unbind` line for every APEX
    // default on every save because hyprlang had no way to disable one.
    // Hyprland 0.56.2 loads hyprland.lua and never mentions a .conf beside
    // it, so keeping the generator would have produced a file that looks
    // current, is read by nothing, and says nothing when it is ignored.

    // ── niri KDL generation ───────────────────────────────────────────────────
    // niri config is KDL. Bindings live in a top-level `binds { }` block; each
    // action is a node whose child is the action call. We use `spawn` with one
    // quoted token per argv element — niri spawns WITHOUT a shell, so this is
    // injection-safe by construction (no word-splitting, no interpolation).
    //
    // niri (v25.11+) supports `include`, and included files merge at the key
    // level with later definitions overriding — so the user adds a single
    // `include` line pointing at this file (documented in the header comment).

    // "SUPER + SHIFT" → ["Mod", "Shift"] (niri modifier tokens).
    function _modsToKdl(modsStr) {
        var out   = []
        var parts = modsStr.toUpperCase().split("+")
        for (var i = 0; i < parts.length; i++) {
            var p = parts[i].trim()
            if      (p === "SUPER") out.push("Mod")
            else if (p === "SHIFT") out.push("Shift")
            else if (p === "CTRL")  out.push("Ctrl")
            else if (p === "ALT")   out.push("Alt")
        }
        return out
    }

    // Escape a value for a KDL double-quoted string.
    function _kdlStr(s) {
        return String(s).replace(/\\/g, "\\\\").replace(/"/g, "\\\"")
    }

    // ── niri: what an APEX default becomes ────────────────────────────────────
    // Every name here was verified against the installed `niri msg action
    // --help` rather than remembered. A wrong verb is silent: niri rejects the
    // include and the user loses every binding in it, not just the bad one.
    //
    // Hyprland dispatcher -> niri action. `null` means niri has no equivalent,
    // and those bindings are reported in the generated file rather than dropped
    // without trace.
    readonly property var _niriActions: ({
        "killactive":     "close-window",
        "fullscreen":     "fullscreen-window",
        "togglefloating": "toggle-window-floating",
        // niri is column-based: left/right move between columns, up/down within
        // one. That is the honest mapping of Hyprland's directional focus onto a
        // scrolling layout, not an approximation.
        "movefocus":  ({ l: "focus-column-left",  r: "focus-column-right",
                         u: "focus-window-up",    d: "focus-window-down" }),
        "movewindow": ({ l: "move-column-left",   r: "move-column-right",
                         u: "move-window-up",     d: "move-window-down" }),
        "workspace":        "focus-workspace",
        "movetoworkspace":  "move-window-to-workspace",
        // No concept in a scrolling compositor.
        "pseudo":    null,
        "layoutmsg": null
    })

    // Hyprland config variables, resolved. niri spawns WITHOUT a shell, so an
    // unresolved `$browser` would be passed to execvp as a literal filename.
    readonly property var _niriApps: ({
        "$terminal":    "alacritty",
        // Not a browser name: opens whichever browser the user has set as
        // default, the same reason hyprland.conf and labwc's rc.xml stopped
        // naming one.
        "$browser":     "/usr/libexec/apex-open-browser",
        "$fileManager": "thunar"
    })

    // Split a command into argv. niri spawns without a shell, so this is the
    // tokenisation the shell would otherwise do — and it is why the commands in
    // _defaults must stay free of quoting and pipes. They are, and the suite
    // asserts it.
    function _niriArgv(command) {
        var cmd = String(command).trim()
        var keys = Object.keys(root._niriApps)
        for (var i = 0; i < keys.length; i++) {
            if (cmd.indexOf(keys[i]) === 0)
                cmd = root._niriApps[keys[i]] + cmd.slice(keys[i].length)
        }
        if (cmd.indexOf("$") === 0) return null   // an unresolved variable
        var parts = cmd.split(/\s+/).filter(function (t) { return t !== "" })
        return parts.length > 0 ? parts : null
    }

    function _niriSpawn(argv) {
        var out = []
        for (var i = 0; i < argv.length; i++) out.push('"' + _kdlStr(argv[i]) + '"')
        return "spawn " + out.join(" ") + ";"
    }

    function _genKdl() {
        var sd   = root._shellDir
        var kp   = root._kdlPath
        var data = _grouped()

        var lines = [
            "// ==============================================================================",
            "// APEX Shell Keybinds (niri)",
            "// Auto-generated by Quickshell. Do not edit manually.",
            "//",
            "// niri supports config includes since v25.11. To load these bindings, add this",
            "// line at the TOP LEVEL of your ~/.config/niri/config.kdl (it live-reloads):",
            "//",
            "//     include \"" + kp + "\"",
            "//",
            "// Includes are positional and merge at the key level: place the line AFTER your",
            "// own binds { } block so these shell bindings win on conflicts (or before it to",
            "// let your own bindings win). On niri OLDER than v25.11 (no include support),",
            "// paste the binds { } block below into the binds { } block already in your",
            "// config.kdl instead.",
            "// ==============================================================================",
            "",
            "binds {"
        ]

        for (var gi = 0; gi < data.order.length; gi++) {
            var g = data.order[gi]
            lines.push("    // " + g)
            var entries = data.groups[g]
            for (var ei = 0; ei < entries.length; ei++) {
                var e = entries[ei]
                var combo = _modsToKdl(e.mods).concat([e.key]).join("+")

                // `if (e.type) continue` used to sit here, commented "native
                // compositor actions remain in niri's own config". It also
                // skipped every type: "exec" APP LAUNCH, so a niri session had
                // no SUPER+W, SUPER+T or SUPER+E at all — the shell popups
                // worked and the applications simply were not bound. An app
                // launch is a spawn, which niri does natively; the guard was
                // catching far more than it meant to.
                if (e.type === "exec") {
                    var argv = root._niriArgv(e.command)
                    if (!argv) { lines.push("    // " + e.k + ": command does not resolve on niri"); continue }
                    lines.push("    " + combo + " { " + root._niriSpawn(argv) + " }")
                    continue
                }

                if (e.type === "dispatch") {
                    var mapped = root._niriActions[e.dispatcher]
                    if (mapped === undefined || mapped === null) {
                        lines.push("    // " + e.k + ": no niri equivalent of " + e.dispatcher)
                        continue
                    }
                    var verb = (typeof mapped === "string") ? mapped : mapped[e.arg]
                    if (!verb) {
                        lines.push("    // " + e.k + ": no niri equivalent of "
                                   + e.dispatcher + " " + e.arg)
                        continue
                    }
                    // focus-workspace / move-window-to-workspace take the
                    // workspace as a positional reference; the rest take none.
                    var needsArg = (e.dispatcher === "workspace"
                                    || e.dispatcher === "movetoworkspace")
                    var act = needsArg ? (verb + ' "' + _kdlStr(e.arg) + '"') : verb
                    lines.push("    " + combo + " { " + act + "; }")
                    continue
                }

                // No type: a shell IPC toggle.
                // spawn tokens: qs -p <shell> ipc call <action> toggle
                var spawn = 'spawn "qs" "-p" "' + _kdlStr(sd) +
                            '" "ipc" "call" "' + _kdlStr(e.k) + '" "toggle";'
                lines.push("    " + combo + " { " + spawn + " }")
            }
            lines.push("")
        }
        lines.push("}")
        return lines.join("\n")
    }

    // ── Auto-include in hyprland configs ──────────────────────────────────────
    property var _includeProc: Process { command: []; running: false }

    function _ensureInclude() {
        // Hyprland only: make sure the user's hyprland.lua actually loads what
        // this service just wrote. niri users add the `include` line manually
        // (see the .kdl header comment) — we never rewrite config.kdl, to avoid
        // breaking pre-v25.11 niri.
        if (!Compositor.isHyprland) return

        // The APEX-seeded hyprland.lua already requires this module, so on an
        // APEX machine this is a no-op every time. It exists for a hyprland.lua
        // the user wrote themselves, or one from before the module existed.
        //
        // `require`, not `dofile`. The previous Lua branch appended
        // dofile("<absolute path>"), which worked but pinned the file to one
        // home directory and re-ran the chunk on every reload without going
        // through package.loaded. require resolves because Hyprland prepends the
        // config file's own directory to package.path — which is also why the
        // module had to move into ~/.config/hypr/apex to be nameable at all.
        //
        // Appended at the END so it loads after the APEX defaults, which is what
        // makes claim()/disable() reach a bind that already exists.
        // A machine still on hyprlang gets NOTHING out of this, and would get it
        // silently: the module is written, no hyprland.lua exists to require it,
        // and the Keybinds page looks like it worked. That is the exact shape of
        // the regression ShellState documents, so it is said out loud instead.
        // /usr/libexec/apex-hypr-migrate is what fixes it, and on APEX it has
        // already run at login.
        if (ShellState.configProvider !== "lua") {
            console.warn("KeybindService: this session has no ~/.config/hypr/hyprland.lua, "
                         + "so the generated keybinds are not loaded by anything. "
                         + "Hyprland 0.55 deprecated hyprlang; run "
                         + "/usr/libexec/apex-hypr-migrate to convert the config.")
        }

        _includeProc.command = ["bash", "-c", [
            "LUA=\"$HOME/.config/hypr/hyprland.lua\"",
            "[ -f \"$LUA\" ] || exit 0",
            "grep -q 'apex\\.shell-keybinds' \"$LUA\" && exit 0",
            "grep -q 'apex(\"shell-keybinds\")' \"$LUA\" && exit 0",
            "printf '\\n-- APEX Shell keybinds\\nrequire(\"apex.shell-keybinds\")\\n' >> \"$LUA\"",
        ].join("\n")]

        _includeProc.running = false
        _includeProc.running = true
    }

    Component.onCompleted: _loadProc.running = true
}
