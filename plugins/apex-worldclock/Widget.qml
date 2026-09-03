import QtQuick

// ─── World Clock ──────────────────────────────────────────────────────────────
// The reference APEX Shell plugin (roadmap §16). A second timezone in the bar,
// beside the local clock.
//
// It is here to be READ as much as to be used, so it exercises each part of the
// apiVersion 1 contract exactly once:
//
//   * `property var api` — the host assigns the capability object here, once,
//     before this widget is on screen. Declaring it is the whole handshake.
//     A plugin that forgets gets a log line and runs without an api.
//   * `api.theme` — the shell's colours and font sizes. A plugin may not
//     `import "../../"`, so the Theme singleton is not reachable by name from
//     here; anything needed to look native arrives through the api. Every
//     binding below falls back to a literal, because `api` is null until the
//     host assigns it and a widget that renders blank in that window looks
//     broken rather than pending.
//   * `api.files.readText()` — the `files` permission, declared in
//     plugin.json. Reads config.json out of this plugin's own directory. That
//     is the entire extent of the permission: read-only, own directory. See
//     permitsPath() in src/services/plugins/manifest.js for why it is not
//     more than that.
//   * No `network` permission, so `api.net.get()` would be refused. Try it if
//     you want to see the gate work — it returns a refusal and nothing is
//     spawned.
//
// ── What a plugin may contain ─────────────────────────────────────────────────
// One .qml file, imports limited to QtQuick and its Layouts/Shapes/Effects, and
// none of Loader, eval, XMLHttpRequest, dynamic QML construction or
// `parent.parent`. The loader refuses a plugin that breaks any of those before
// the QML engine ever sees it. docs/plugins.md explains what that does and does
// not buy — it is not a sandbox, and this file is not the place to re-argue it.
// ──────────────────────────────────────────────────────────────────────────────

Item {
    id: root

    // ── The handshake ─────────────────────────────────────────────────────────
    // Assigned by the host. Must be declared, must be `var`, must start null.
    property var api: null

    // ── Configuration, from this plugin's own directory ───────────────────────
    // config.json is optional: { "label": "NYC", "offsetMinutes": -240 }
    // Absent means UTC, which is the useful default for a second clock.
    property string label:        "UTC"
    property int    offsetMinutes: 0

    property string clockText: "--:--"

    implicitWidth:  row.implicitWidth
    implicitHeight: row.implicitHeight

    Row {
        id: row
        spacing: root.api ? Math.max(3, root.api.theme.spacing / 2) : 4

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text:           root.label
            color:          root.api ? root.api.theme.subtext : "#808080"
            font.pixelSize: root.api ? root.api.theme.smallFont : 11
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text:           root.clockText
            color:          root.api ? root.api.theme.foreground : "#c0c0c0"
            font.pixelSize: root.api ? root.api.theme.fontSize : 14
        }
    }

    // ── The clock ─────────────────────────────────────────────────────────────
    // Ticks once a minute, not once a second: this widget shows no seconds, so
    // a 1 Hz timer would wake the whole shell sixty times for every visible
    // change. The bar's own clock makes the same distinction, and on a laptop
    // it is the difference between a plugin being free and being a battery
    // complaint nobody traces back here.
    Timer {
        interval:         60000
        running:          true
        repeat:           true
        triggeredOnStart: true
        onTriggered:      root._tick()
    }

    function _tick() {
        // Shift epoch-UTC by the configured offset, then read the UTC fields.
        // Doing it this way keeps the local timezone out of the arithmetic
        // entirely — reading local fields and correcting afterwards is where
        // DST bugs come from.
        const d = new Date(Date.now() + root.offsetMinutes * 60000)
        const hh = ("0" + d.getUTCHours()).slice(-2)
        const mm = ("0" + d.getUTCMinutes()).slice(-2)
        root.clockText = hh + ":" + mm
    }

    // ── Reading configuration ─────────────────────────────────────────────────
    // `api` arrives after this component is constructed, so the read hangs off
    // the change rather than Component.onCompleted — which runs first and would
    // see null.
    onApiChanged: {
        if (!root.api)
            return

        root._tick()

        // A well-behaved plugin checks before it calls, so a refusal is a
        // branch rather than a surprise. This one holds `files`, so it
        // proceeds; if the permission were removed from plugin.json the widget
        // would simply stay on UTC.
        if (!root.api.has("files"))
            return

        root.api.files.readText("config.json", function (ok, text) {
            if (!ok || !text)
                return          // no config: UTC, as documented
            try {
                const cfg = JSON.parse(text)
                if (typeof cfg.label === "string" && cfg.label !== "")
                    root.label = cfg.label.slice(0, 8)
                const off = parseInt(cfg.offsetMinutes, 10)
                // Real UTC offsets run -12:00 to +14:00. Clamping rather than
                // trusting the file keeps a typo from rendering a clock that
                // is merely wrong instead of obviously wrong.
                if (!isNaN(off) && off >= -720 && off <= 840)
                    root.offsetMinutes = off
            } catch (e) {
                // A malformed config is the user's typo, not a reason for the
                // widget to disappear.
            }
            root._tick()
        })
    }
}
