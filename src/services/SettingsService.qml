pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../theme/motion.js" as MotionTable

// ─────────────────────────────────────────────────────────────────────────────
// SettingsService — single source of truth for user-tunable shell metrics &
// behavior. Persisted to  ~/.config/apex-shell/src/user_data/settings.json.
//
// Metrics.qml binds its configurable properties to these, so any change here
// reflows the live shell (border radius, notch size, animation speed, …) and
// is written back to disk (debounced).
//
// Defaults MUST match the historical Metrics literals so a fresh install with
// no settings.json behaves identically to before.
// ─────────────────────────────────────────────────────────────────────────────
QtObject {
    id: root

    // ── Persisted values (defaults = original Metrics literals) ───────────────
    // Appearance
    property int  cornerRadius: 17
    property int  borderWidth:  6
    property int  notchRadius:  15
    property int  notchHeight:  40

    // Layout & behavior
    property bool barEnabled:        false
    property int  spacing:           10
    property int  exclusionGap:      34
    property bool reduceMotion:      false

    // ── Motion speed ─────────────────────────────────────────────────────────
    // A preset — "snappy", "balanced", "relaxed" — and an advanced multiplier on
    // top of it (0 = no motion at all, 2.5 = the slowest the page offers). They
    // replace the old `animDuration` milliseconds, which set every large surface
    // to the same length and could not say "hovers fast, the Dashboard slower";
    // theme/Motion.qml turns these two into per-role durations. A settings.json
    // that still carries animDuration is migrated on load (see _initProc).
    property string motionSpeed:     "balanced"
    property real   motionScale:     1.0

    // ── Display scaling ──────────────────────────────────────────────────────
    // "auto" derives a factor from the reference screen's height; "manual" uses
    // scaleManual verbatim. scaleScreen names the output that drives the auto
    // factor (empty = the tallest connected one), which is how a mixed-DPI desk
    // picks the monitor it actually works on. See theme/Metrics.qml.
    property string scaleMode:       "auto"
    property real   scaleManual:     1.0
    property string scaleScreen:     ""

    // Absolute path to a dedicated lock-screen background. Empty means "follow
    // the current desktop wallpaper", which is the historical behaviour.
    property string lockBackground:  ""

    // ── Night light ──────────────────────────────────────────────────────────
    // Kelvin. 6500 is neutral on both mechanisms, so the slider's top end is
    // "no shift at all" rather than a warmer white. 5600 is what the tile has
    // always used — it was a literal inside the hyprsunset invocation and there
    // was no way to change it — so the default is that, and a user who never
    // touches the slider sees exactly the shift they saw before.
    property int nightLightTemp: 5600

    property int  dashboardWidth:    900
    property int  dashboardHeight:   520
    property int  notificationsWidth: 400

    // ── Derived (not persisted) ───────────────────────────────────────────────
    // The one duration the shell ran on before theme/Motion.qml: what 320 ms
    // became at the user's speed, still 0 when reduce-motion is on. Kept for the
    // callers not yet migrated to a semantic token; nothing new should read it.
    readonly property int effectiveAnim: reduceMotion ? 0 : MotionTable.legacyDuration(
        MotionTable.speedScale(motionSpeed, motionScale), false)

    // ── Ordered schema — drives (de)serialization & reset ─────────────────────
    readonly property var _keys: [
        "cornerRadius", "borderWidth", "notchRadius", "notchHeight",
        "barEnabled", "spacing", "exclusionGap", "reduceMotion",
        "motionSpeed", "motionScale",
        "dashboardWidth", "dashboardHeight", "notificationsWidth",
        "lockBackground", "scaleMode", "scaleManual", "scaleScreen",
        "nightLightTemp"
    ]
    readonly property var _defaults: ({
        cornerRadius: 17, borderWidth: 6, notchRadius: 15, notchHeight: 40,
        barEnabled: false, spacing: 10, exclusionGap: 34,
        reduceMotion: false, motionSpeed: "balanced", motionScale: 1.0,
        dashboardWidth: 900, dashboardHeight: 520,
        notificationsWidth: 400,
        lockBackground: "",
        scaleMode: "auto", scaleManual: 1.0, scaleScreen: "",
        nightLightTemp: 5600
    })

    // Bounds used by the UI sliders AND clamped on load so a hand-edited file
    // can never wedge the shell into an unusable geometry.
    readonly property var _bounds: ({
        cornerRadius:      [0, 40], borderWidth:  [0, 24],
        notchRadius:       [0, 30], notchHeight:  [24, 72],
        spacing:           [0, 40], exclusionGap: [0, 80],
        motionScale:       [0, 2.5],
        dashboardWidth:    [700, 1400], dashboardHeight: [360, 900],
        notificationsWidth:[280, 640],
        // A scale below 0.5 makes the shell unreadable and above 3.0 makes it
        // unusable; either way the user would have to hand-edit the file to
        // recover, so clamp on load as well as in the UI.
        scaleManual:       [0.5, 3.0],
        // 1000K is the warmest either tool will take and 6500K is neutral.
        // Above neutral both start ADDING blue, which is the opposite of what
        // a control called Night Light is for.
        nightLightTemp:    [1000, 6500]
    })

    readonly property bool isDefault: {
        for (var i = 0; i < _keys.length; i++) {
            var k = _keys[i]
            if (root[k] !== _defaults[k]) return false
        }
        return true
    }

    // Keys whose value is a real rather than a whole number. Without this
    // scaleManual would be parseInt'd and 1.25 would silently become 1.
    readonly property var _realKeys: ["scaleManual", "motionScale"]

    // String settings that only take one of a fixed set. Anything else — a
    // hand-edited typo — falls back to the default instead of reaching Motion
    // as a preset name nobody defined.
    readonly property var _choices: ({
        motionSpeed: ["snappy", "balanced", "relaxed"]
    })
    function _choice(k, v) {
        var c = _choices[k]
        if (!c) return v
        return c.indexOf(v) >= 0 ? v : _defaults[k]
    }

    function _clampInt(k, v) {
        var b = _bounds[k]
        var n = (_realKeys.indexOf(k) >= 0) ? parseFloat(v) : parseInt(v)
        if (isNaN(n)) return _defaults[k]
        if (!b) return n
        return Math.max(b[0], Math.min(b[1], n))
    }

    // ── State ─────────────────────────────────────────────────────────────────
    property bool _loaded: false
    readonly property string _cfgPath:
        Quickshell.env("HOME") + "/.config/apex-shell/src/user_data/settings.json"

    // ── Setters (clamp + persist) ─────────────────────────────────────────────
    // The UI calls set(key, value); bindings update live, then a debounced write.
    function set(key, value) {
        if (_keys.indexOf(key) < 0) return
        if (typeof _defaults[key] === "boolean")
            root[key] = !!value
        else if (typeof _defaults[key] === "string")
            root[key] = _choice(key, value === undefined || value === null ? "" : String(value))
        else
            root[key] = _clampInt(key, value)
    }

    function resetAll() {
        for (var i = 0; i < _keys.length; i++)
            root[_keys[i]] = _defaults[_keys[i]]
    }

    // ── Persist on any change (debounced) ─────────────────────────────────────
    onCornerRadiusChanged:      _scheduleSave()
    onBorderWidthChanged:       _scheduleSave()
    onNotchRadiusChanged:       _scheduleSave()
    onNotchHeightChanged:       _scheduleSave()
    onBarEnabledChanged:        _scheduleSave()
    onSpacingChanged:           _scheduleSave()
    onExclusionGapChanged:      _scheduleSave()
    onReduceMotionChanged:      { _scheduleSave(); _scheduleGreetPublish() }
    onMotionSpeedChanged:       { _scheduleSave(); _scheduleGreetPublish() }
    onMotionScaleChanged:       { _scheduleSave(); _scheduleGreetPublish() }
    onDashboardWidthChanged:    _scheduleSave()
    onDashboardHeightChanged:   _scheduleSave()
    onNotificationsWidthChanged:_scheduleSave()
    onLockBackgroundChanged:    _scheduleSave()
    onScaleModeChanged:         _scheduleSave()
    onScaleManualChanged:       _scheduleSave()
    onScaleScreenChanged:       _scheduleSave()
    onNightLightTempChanged:    _scheduleSave()

    function _scheduleSave() { if (_loaded) _saveTimer.restart() }

    // ── The login screen follows the motion settings ─────────────────────────
    // The greeter runs before any session and cannot read this file, so the
    // same root helper that publishes the wallpaper and accent for it
    // (/usr/libexec/apex-greet-wallpaper, called by WallpaperService) also
    // publishes these three, validated, to /var/lib/apex-greet/motion/<user>.
    // Waited out well past the 350 ms save debounce, because the helper reads
    // the file on disk. Best-effort and silent: `sudo -n` never prompts, and
    // on a host without the helper nothing happens at all.
    function _scheduleGreetPublish() { if (_loaded) _greetPublishTimer.restart() }
    property var _greetPublishTimer: Timer {
        interval: 1500; repeat: false
        onTriggered: root._greetPublish.running = true
    }
    property var _greetPublish: Process {
        command: ["sh", "-c",
            "if [ -x /usr/libexec/apex-greet-wallpaper ]; then " +
            "sudo -n /usr/libexec/apex-greet-wallpaper >/dev/null 2>&1 || true; " +
            "fi; exit 0"]
        running: false
    }

    property var _saveTimer: Timer {
        interval: 350; repeat: false
        onTriggered: root._save()
    }

    // ── Load ──────────────────────────────────────────────────────────────────
    property var _initProc: Process {
        command: ["bash", "-c",
            "[ -f '" + root._cfgPath + "' ] || " +
            "(mkdir -p \"$(dirname '" + root._cfgPath + "')\" && printf '%s' '{}' > '" + root._cfgPath + "'); " +
            "cat '" + root._cfgPath + "'"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var o = JSON.parse(text.trim() || "{}")
                    // A file from before the motion system carries the old
                    // single duration instead. Its ratio to the old default is
                    // exactly what motionScale means, so a user who had slowed
                    // the shell to 480 ms keeps a 1.5x shell rather than being
                    // silently reset to the default speed.
                    if (o.motionScale === undefined && o.animDuration !== undefined) {
                        var legacy = parseFloat(o.animDuration)
                        if (!isNaN(legacy))
                            o.motionScale = Math.round(legacy / 320 * 100) / 100
                    }
                    for (var i = 0; i < root._keys.length; i++) {
                        var k = root._keys[i]
                        if (o[k] === undefined) continue
                        if (typeof root._defaults[k] === "boolean")
                            root[k] = !!o[k]
                        else if (typeof root._defaults[k] === "string")
                            root[k] = root._choice(k, String(o[k]))
                        else
                            root[k] = root._clampInt(k, o[k])
                    }
                } catch (e) {
                    console.log("SettingsService: parse failed:", e)
                }
                root._loaded = true
                console.log("SettingsService: loaded settings.")
            }
        }
    }

    // ── Save ──────────────────────────────────────────────────────────────────
    //
    // Non-empty when the last write was refused. Six settings pages write
    // through this service and every one of them wrote as you dragged, so a
    // home directory the shell could not write to looked exactly like one it
    // could: the slider moved, the shell reflowed, and the value was gone at
    // the next login. The pages show this on their CfgLifecycle line
    // (roadmap P0-023, criterion 4).
    property string lastError: ""

    property var _saveProc: Process {
        command: []
        running: false
        onExited: function(code, status) {
            root.lastError = code === 0
                ? ""
                : "Could not write " + root._cfgPath + " (exit " + code
                  + "). Settings changed here will be gone at the next login."
        }
    }

    function _save() {
        var o = {}
        for (var i = 0; i < _keys.length; i++) o[_keys[i]] = root[_keys[i]]
        var json = JSON.stringify(o)
        // JSON and path go in as positional arguments rather than spliced into
        // the script, the rule KeybindService and Compositor already follow.
        //
        // Not a bug fix, and the commit that introduced it said it was: the
        // form this replaced escaped apostrophes correctly ('\'' for each one)
        // and `lockBackground` with a quote in it round-tripped. What it
        // removes is the need to hold that argument in your head — and the
        // path, which was spliced unescaped, so a $HOME with a quote in it
        // really did break it.
        _saveProc.command = ["bash", "-c",
            "mkdir -p \"$(dirname \"$2\")\" && printf '%s' \"$1\" > \"$2\"",
            "--", json, root._cfgPath]
        _saveProc.running = false
        _saveProc.running = true
    }

    Component.onCompleted: _initProc.running = true
}
