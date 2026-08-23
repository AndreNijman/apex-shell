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
    readonly property string _luaPath:  _configDir + "/ApexShellKeybinds.lua"
    readonly property string _confPath: _configDir + "/ApexShellKeybinds.conf"
    readonly property string _kdlPath:  _configDir + "/ApexShellKeybinds.kdl"
    readonly property string _jsonPath: _configDir + "/src/user_data/keybinds.json"
    
    property string configProvider: ShellState.configProvider

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
        var lua  = _genLua()
        var conf = _genConf()
        var kdl  = _genKdl()

        // Write all three artifacts so the user has them regardless of what they
        // run (Hyprland .lua/.conf, niri .kdl). Contents + paths go in as
        // positional args, never spliced into the script.
        _writeProc.command = ["bash", "-c",
            "printf '%s' \"$1\" > \"$4\" && printf '%s' \"$2\" > \"$5\" && printf '%s' \"$3\" > \"$6\"",
            "--", lua, conf, kdl, root._luaPath, root._confPath, root._kdlPath]

        _writeProc.running = false
        _writeProc.running = true
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

    // Note: this provider emits plain `hl.bind` for every entry, including the
    // ones flagged `repeat` — holding volume or brightness steps once here,
    // whereas the .conf provider below emits `bindel` and repeats.
    function _genLua() {
        var sd   = root._shellDir.replace(/"/g, "\\\"")
        var data = _grouped()
        
        var lines = [
            "-- ==============================================================================",
            "-- APEX Shell Keybinds",
            "-- Auto-generated by Quickshell. Do not edit manually.",
            "-- ==============================================================================",
            "",
            "local shell = \"" + sd + "\"",
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
            "-- User Defined Bindings",
            "-- ==============================================================================",
            ""
        ]
        
        for (var gi = 0; gi < data.order.length; gi++) {
            var g = data.order[gi]
            lines.push("-- " + g)
            var entries = data.groups[g]
            for (var ei = 0; ei < entries.length; ei++) {
                var e = entries[ei]
                var combo = e.mods ? e.mods + " + " + e.key : e.key
                if (e.type === "dispatch") {
                    var dispatchCmd = "hyprctl dispatch " + e.dispatcher + (e.arg ? " " + e.arg : "")
                    lines.push("hl.bind(\"" + combo + "\", hl.dsp.exec_cmd(\"" + dispatchCmd + "\"))")
                } else if (e.type === "exec") {
                    var execCmd = e.command
                        .replace("$terminal", "alacritty")
                        .replace("$browser", "firefox")
                        .replace("$fileManager", "thunar")
                        .replace("$qsIpc", "qs -p " + sd + " ipc call")
                    lines.push("hl.bind(\"" + combo + "\", hl.dsp.exec_cmd(\"" + execCmd.replace(/\"/g, "\\\"") + "\"))")
                } else {
                    lines.push("hl.bind(\"" + combo + "\", hl.dsp.exec_cmd(\"qs -p \" .. shell .. \" ipc call " + e.k + " toggle\"))")
                }
            }
            lines.push("")
        }
        return lines.join("\n")
    }

    function _genConf() {
        var data = _grouped()
        
        var lines = [
            "# ==============================================================================",
            "# APEX Shell Keybinds",
            "# Auto-generated by Quickshell. Do not edit manually.",
            "# ==============================================================================",
            "",
            "# ==============================================================================",
            "# ApexShell Capture Submap (Disables all normal binds during recording)",
            "# ==============================================================================",
            "submap = ApexShell_clean",
            "bind = CTRL, ESCAPE, exec, notify-send 'ApexShell' 'Emergency Exit: Keybinds re-enabled.'",
            "bind = CTRL, ESCAPE, submap, reset",
            "submap = reset",
            "",
            "# ==============================================================================",
            "# User Defined Bindings",
            "# ==============================================================================",
            ""
        ]

        // Native APEX defaults are also present in the seeded Hyprland config.
        // Remove those first so this generated file is authoritative: changing
        // SUPER+Q here must replace, not duplicate, the static killactive bind.
        var defs = root._defaults
        var dkeys = Object.keys(defs)
        for (var di = 0; di < dkeys.length; di++) {
            var def = defs[dkeys[di]]
            if (!def.type) continue
            var defMods = def.mods.replace(/\s*\+\s*/g, " ")
            lines.push("unbind = " + defMods + ", " + def.key)
        }
        lines.push("")
        
        for (var gi = 0; gi < data.order.length; gi++) {
            var g = data.order[gi]
            lines.push("# " + g)
            var entries = data.groups[g]
            for (var ei = 0; ei < entries.length; ei++) {
                var e = entries[ei]
                // Hyprland .conf format drops the '+' symbol between modifiers
                var confMods = e.mods.replace(/\s*\+\s*/g, " ")
                // `bindel` = repeat while held, and still fires with the screen
                // locked or off. Volume and brightness are useless without it;
                // everything else must stay one-shot.
                var verb = e.repeat ? "bindel" : "bind"
                if (e.type === "dispatch") {
                    lines.push(verb + " = " + confMods + ", " + e.key + ", " + e.dispatcher
                               + (e.arg ? ", " + e.arg : ""))
                } else {
                    var cmd = e.type === "exec"
                        ? e.command
                        : "qs -p " + root._shellDir + " ipc call " + e.k + " toggle"
                    lines.push(verb + " = " + confMods + ", " + e.key + ", exec, " + cmd)
                }
            }
            lines.push("")
        }
        return lines.join("\n")
    }

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
                if (e.type) continue // Native compositor actions remain in niri's own config.
                var combo = _modsToKdl(e.mods).concat([e.key]).join("+")
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
        // Hyprland only: append a source/dofile line to the user's hyprland config.
        // niri users add the `include` line manually (see the .kdl header comment) —
        // we never rewrite config.kdl to avoid breaking pre-v25.11 niri.
        if (!Compositor.isHyprland) return

        var lp = root._luaPath.replace(/"/g, "\\\"")
        var cp = root._confPath.replace(/"/g, "\\\"")

        if (configProvider === "lua") {
            _includeProc.command = ["bash", "-c", [
                "MARKER='ApexShellKeybinds'",
                "LUA=\"$HOME/.config/hypr/hyprland.lua\"",
                "if [ -f \"$LUA\" ] && ! grep -qF \"$MARKER\" \"$LUA\"; then",
                "  printf '\\n-- ApexShellKeybinds\\ndofile(\"" + lp + "\")\\n' >> \"$LUA\"",
                "fi",
            ].join("\n")]
        } else {
            _includeProc.command = ["bash", "-c", [
                "MARKER='ApexShellKeybinds'",
                "CONF=\"$HOME/.config/hypr/hyprland.conf\"",
                "if [ -f \"$CONF\" ] && ! grep -qF \"$MARKER\" \"$CONF\"; then",
                "  printf '\\n# ApexShellKeybinds\\nsource = " + cp + "\\n' >> \"$CONF\"",
                "fi",
            ].join("\n")]
        }
        
        _includeProc.running = false
        _includeProc.running = true
    }

    Component.onCompleted: _loadProc.running = true
}
