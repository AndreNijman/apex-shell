import QtQuick
import "../plugins/manifest.js" as Manifest
import "../../"

// ─── PluginTiles ──────────────────────────────────────────────────────────────
// The `quick-settings-tile` extension point (roadmap §16), end to end. A plugin
// whose manifest says `"extensionPoint": "quick-settings-tile"` gets one tile in
// the quick-settings grid, below the shell's own.
//
// ── The plugin does not draw the tile ────────────────────────────────────────
// This is the tightest of the three points. A bar widget paints its own
// rectangle. A launcher provider hands back rows. A tile plugin hands back four
// values — on, icon, label, sublabel — and the SHELL draws the shell's own tile
// around them, using the same TglBtn the Wi-Fi and Bluetooth toggles use.
//
// So a plugin tile cannot look like anything other than a quick-settings tile,
// cannot cover the grid, cannot animate and cannot be a different size. That is
// a deliberate ordering: the quick-settings grid is where a user goes to change
// their machine's state, and a surface that lets third-party code paint
// arbitrary pixels next to the Airplane Mode switch is a surface for drawing a
// fake Airplane Mode switch.
//
// ── What a plugin tile cannot do, and why that is not a gap ──────────────────
// It cannot flip a system switch. Not Wi-Fi, not Bluetooth, not brightness, not
// a power profile, not the night light. Every one of those is a command, and
// "run a command" is the `system` permission, which is refused at load — see
// IMPLEMENTED_PERMISSIONS in manifest.js for why granting it would make
// `network` and `files` decorative.
//
// So the honest description of this point is not "plugins can add quick
// settings", it is "plugins can add a tile": a tile surfaces information the
// plugin has, and taking action on a click means acting inside whatever the
// plugin was granted. plugins/apex-pomodoro is the example, and it holds no
// permissions at all — the round trip it proves is host → toggle() → the
// plugin's own state → back out through the sanitiser to the tile, which is the
// whole of the contract and needs nothing privileged to demonstrate.
//
// ── The contract ─────────────────────────────────────────────────────────────
//     Item {
//         property var    api:      null     // assigned once by the host
//         property bool   on:       false    // read by the host
//         property string icon:     ""       // a glyph
//         property string label:    ""       // falls back to the plugin's name
//         property string sublabel: ""       // optional second line
//         function toggle() { }              // called when the tile is clicked
//     }
//
// `on` is compared with `=== true` and not coerced; see quickTile() for why
// truthiness is the wrong tool for the value that decides what a user is being
// told about their own machine.
//
// ── Crash isolation ──────────────────────────────────────────────────────────
// One Loader per plugin, asynchronous, Loader.Error recorded against the
// plugin. Same as the other two hosts. The sanitiser returning null rather than
// throwing is the other half: a plugin whose properties are garbage loses its
// tile, and the grid — which holds the Wi-Fi and Airplane Mode toggles — keeps
// working.
// ──────────────────────────────────────────────────────────────────────────────

Item {
    id: root

    // A tile plugin never paints. See the header.
    visible: false
    implicitWidth: 0
    implicitHeight: 0

    // Sanitised tile descriptors, in discovery order, ready for a Repeater.
    // { pluginId, on, icon, label, sublabel }
    property var tiles: []

    function _collect() {
        const out = []
        for (let i = 0; i < repeater.count; i++) {
            const m = repeater.itemAt(i)
            if (m && m.tile) out.push(m.tile)
        }
        root.tiles = out
    }

    // Called by the grid when a plugin tile is clicked.
    function toggle(pluginId) {
        for (let i = 0; i < repeater.count; i++) {
            const m = repeater.itemAt(i)
            if (!m || !m.modelData || m.modelData.pluginId !== pluginId) continue
            m._toggle()
            return
        }
    }

    Repeater {
        id: repeater

        model: PluginService.pluginsFor("quick-settings-tile")

        delegate: Item {
            id: mount

            required property var modelData

            visible: false
            implicitWidth: 0
            implicitHeight: 0

            // The plugin item goes straight into the sanitiser, rather than
            // being snapshotted into a plain object here first. That is on
            // purpose: quickTile() holds the ONLY list of keys that cross this
            // boundary, and a snapshot built in this file would be a second
            // copy of that list, free to drift from the one the tests exercise.
            //
            // QML's property capture reaches through the call, so this binding
            // re-evaluates when the plugin changes any property quickTile()
            // reads — which is how a click turns into a redrawn tile.
            readonly property var tile:
                Manifest.quickTile(mount.modelData ? mount.modelData.grant : null,
                                   hostLoader.item)

            onTileChanged: root._collect()

            Loader {
                id: hostLoader

                source: mount.modelData ? mount.modelData.entryUrl : ""
                asynchronous: true

                onStatusChanged: {
                    if (status === Loader.Error) {
                        if (mount.modelData && mount.modelData.reportLoadError)
                            mount.modelData.reportLoadError("QML failed to load")
                        source = ""
                        return
                    }
                    if (status === Loader.Ready)
                        mount._inject()
                }
            }

            function _inject() {
                const item = hostLoader.item
                if (!item || !mount.modelData) return
                try {
                    item.api = mount.modelData.api
                } catch (e) {
                    console.log("PluginService: " + mount.modelData.pluginId
                                + " has no `property var api` to receive the plugin API; "
                                + "it will run without one")
                }
            }

            function _toggle() {
                const item = hostLoader.item
                if (!item || typeof item.toggle !== "function") {
                    console.log("PluginService: " + mount.modelData.pluginId
                                + " is a quick-settings tile with no toggle(); "
                                + "its tile does nothing when clicked")
                    return
                }
                try {
                    item.toggle()
                } catch (e) {
                    // A plugin throwing in its own toggle() is the plugin's
                    // problem and must not become the grid's.
                    console.log("PluginService: " + mount.modelData.pluginId
                                + " threw in toggle(): " + e)
                }
            }
        }
    }
}
