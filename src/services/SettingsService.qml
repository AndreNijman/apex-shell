pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

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
    property int  animDuration:      320
    property bool reduceMotion:      false

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

    property int  dashboardWidth:    900
    property int  dashboardHeight:   520
    property int  notificationsWidth: 400

    // ── Derived (not persisted) ───────────────────────────────────────────────
    // When reduce-motion is on, every Behavior driven by Theme.animDuration
    // collapses to an instant transition.
    readonly property int effectiveAnim: reduceMotion ? 0 : animDuration

    // ── Ordered schema — drives (de)serialization & reset ─────────────────────
    readonly property var _keys: [
        "cornerRadius", "borderWidth", "notchRadius", "notchHeight",
        "barEnabled", "spacing", "exclusionGap", "animDuration", "reduceMotion",
        "dashboardWidth", "dashboardHeight", "notificationsWidth",
        "lockBackground", "scaleMode", "scaleManual", "scaleScreen"
    ]
    readonly property var _defaults: ({
        cornerRadius: 17, borderWidth: 6, notchRadius: 15, notchHeight: 40,
        barEnabled: false, spacing: 10, exclusionGap: 34, animDuration: 320,
        reduceMotion: false, dashboardWidth: 900, dashboardHeight: 520,
        notificationsWidth: 400,
        lockBackground: "",
        scaleMode: "auto", scaleManual: 1.0, scaleScreen: ""
    })

    // Bounds used by the UI sliders AND clamped on load so a hand-edited file
    // can never wedge the shell into an unusable geometry.
    readonly property var _bounds: ({
        cornerRadius:      [0, 40], borderWidth:  [0, 24],
        notchRadius:       [0, 30], notchHeight:  [24, 72],
        spacing:           [0, 40], exclusionGap: [0, 80],
        animDuration:      [0, 1200],
        dashboardWidth:    [700, 1400], dashboardHeight: [360, 900],
        notificationsWidth:[280, 640],
        // A scale below 0.5 makes the shell unreadable and above 3.0 makes it
        // unusable; either way the user would have to hand-edit the file to
        // recover, so clamp on load as well as in the UI.
        scaleManual:       [0.5, 3.0]
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
    readonly property var _realKeys: ["scaleManual"]

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
            root[key] = value === undefined || value === null ? "" : String(value)
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
    onAnimDurationChanged:      _scheduleSave()
    onReduceMotionChanged:      _scheduleSave()
    onDashboardWidthChanged:    _scheduleSave()
    onDashboardHeightChanged:   _scheduleSave()
    onNotificationsWidthChanged:_scheduleSave()
    onLockBackgroundChanged:    _scheduleSave()
    onScaleModeChanged:         _scheduleSave()
    onScaleManualChanged:       _scheduleSave()
    onScaleScreenChanged:       _scheduleSave()

    function _scheduleSave() { if (_loaded) _saveTimer.restart() }

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
                    for (var i = 0; i < root._keys.length; i++) {
                        var k = root._keys[i]
                        if (o[k] === undefined) continue
                        if (typeof root._defaults[k] === "boolean")
                            root[k] = !!o[k]
                        else if (typeof root._defaults[k] === "string")
                            root[k] = String(o[k])
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
    property var _saveProc: Process { command: []; running: false }

    function _save() {
        var o = {}
        for (var i = 0; i < _keys.length; i++) o[_keys[i]] = root[_keys[i]]
        var json = JSON.stringify(o)
        _saveProc.command = ["bash", "-c",
            "mkdir -p \"$(dirname '" + _cfgPath + "')\" && " +
            "printf '%s' '" + json.replace(/'/g, "'\\''") + "' > '" + _cfgPath + "'"]
        _saveProc.running = false
        _saveProc.running = true
    }

    Component.onCompleted: _initProc.running = true
}
