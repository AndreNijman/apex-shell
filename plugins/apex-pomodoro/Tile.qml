import QtQuick

// ─── Pomodoro ─────────────────────────────────────────────────────────────────
// The reference `quick-settings-tile` plugin (roadmap §16). A 25-minute focus
// timer in the quick-settings grid: click to start, click again to stop, and
// the tile's second line counts down.
//
// It is here to be READ as much as to be used, so it exercises the whole
// quick-settings-tile contract and nothing else:
//
//   * `property var api` — the host assigns the capability object here, once.
//     Same handshake as every other extension point.
//   * `property bool on` / `icon` / `label` / `sublabel` — the host READS these
//     four and draws the shell's own tile from them. Nothing else crosses; see
//     quickTile() in src/services/plugins/manifest.js for the allowlist.
//   * `function toggle()` — the host calls this when the tile is clicked.
//
// ── It asks for no permissions, and that is the demonstration ────────────────
// `"permissions": []`. A tile plugin cannot flip a system switch — not Wi-Fi,
// not brightness, not a power profile — because every one of those is a command
// and "run a command" is the `system` permission, which this shell refuses at
// load. So the useful thing to show is the ROUND TRIP that needs nothing
// privileged: the host calls toggle(), this plugin changes its own state, and
// the host's binding pulls that state back out through the sanitiser and
// redraws the tile. That is the entire extension point, and if it works with no
// permissions at all then nothing about it is hiding behind one.
//
// ── This plugin does not draw the tile ────────────────────────────────────────
// The shell draws it, with the same TglBtn the Bluetooth toggle uses. So there
// is no Rectangle here, no Text, and no use for api.theme: the tile matches the
// grid because it IS the grid's tile.
//
// ── On the 1 Hz timer ─────────────────────────────────────────────────────────
// apex-worldclock deliberately ticks once a MINUTE, because it shows no seconds
// and a 1 Hz timer would wake the shell sixty times per visible change. This
// one ticks once a second, and the difference is not carelessness:
//
//   * It shows seconds. A countdown that updates once a minute is not a
//     countdown.
//   * It runs ONLY while the timer is running, which is only after the user
//     clicked the tile. Idle cost is exactly zero — the timer's `running` is
//     bound to `on`, so an installed-but-unused Pomodoro costs nothing.
//
// The rule the two plugins share is the real one: never wake the shell more
// often than something visibly changes, and never wake it at all when nothing
// is asking.
// ──────────────────────────────────────────────────────────────────────────────

Item {
    id: root

    // ── The handshake ─────────────────────────────────────────────────────────
    property var api: null

    // ── The four values the host reads ────────────────────────────────────────
    property bool   on:       false
    property string icon:     root.on ? "󰔟" : "󰔚"
    property string label:    "Pomodoro"
    property string sublabel: root.on ? root._clock() : ""

    // ── State ─────────────────────────────────────────────────────────────────
    readonly property int sessionSeconds: 25 * 60
    property int remaining: root.sessionSeconds

    // ── The host calls this ───────────────────────────────────────────────────
    // Starting resets the clock, so a second run is a fresh 25 minutes rather
    // than whatever was left over from the last one.
    function toggle() {
        if (root.on) {
            root.on = false
            root.remaining = root.sessionSeconds
        } else {
            root.remaining = root.sessionSeconds
            root.on = true
        }
    }

    function _clock() {
        const mm = Math.floor(root.remaining / 60)
        const ss = root.remaining % 60
        return ("0" + mm).slice(-2) + ":" + ("0" + ss).slice(-2)
    }

    // Bound to `on`, so nothing runs until the user asks and nothing keeps
    // running once the session ends.
    Timer {
        interval: 1000
        running:  root.on
        repeat:   true
        onTriggered: {
            if (root.remaining <= 1) {
                // Session over. The tile goes dark and resets, which is all a
                // plugin holding no permissions can do — it cannot raise a
                // notification, because there is no notification extension
                // point and the permission such a point would need does not
                // exist. See EXTENSION_POINTS in manifest.js.
                root.on = false
                root.remaining = root.sessionSeconds
                return
            }
            root.remaining = root.remaining - 1
        }
    }
}
