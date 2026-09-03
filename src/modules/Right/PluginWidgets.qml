import QtQuick
import "../../"

// ─── PluginWidgets ────────────────────────────────────────────────────────────
// The `bar-widget` extension point (roadmap §16), end to end. A plugin whose
// manifest says `"extensionPoint": "bar-widget"` gets its root item mounted
// here, in the bar's right-hand cluster next to the clock and the battery.
//
// This is deliberately the ONLY extension point in apiVersion 1. §16 lists
// eight — widgets, panels, launcher providers, quick settings, background
// services, notifications, themes, project and agent integrations — and five
// stubs would be five surfaces nobody has run a plugin against. One that
// actually works tells you what the other seven need; a stub tells you nothing.
// Adding the next one is a new host like this file plus a name in
// EXTENSION_POINTS, and no change to PluginService.
//
// ── Crash isolation ───────────────────────────────────────────────────────────
// This is the practical half of §16's "crash isolation where practical". Each
// plugin sits in its own Loader:
//
//   * A plugin whose QML fails to parse, references a missing type, or throws
//     while its bindings are being set up puts that Loader into Loader.Error.
//     The bar keeps running, the other plugins keep running, and the failure
//     is recorded against that plugin instead of appearing as a shell fault.
//   * `asynchronous: true` means a slow or pathological plugin cannot stall
//     the bar's first paint. The bar is the always-mapped window; anything
//     that blocks here is visible as the whole desktop hanging on login.
//   * The size clamp below is isolation too, of a duller kind.
//
// What this does NOT isolate, and there is no point pretending otherwise: a
// plugin that hard-crashes the process (an infinite loop in a binding, a real
// segfault down in Qt) takes the shell with it, because it is running in the
// shell's process. Surviving that needs an out-of-process plugin runtime. See
// the header of PluginService.qml for where that boundary actually sits.
// ──────────────────────────────────────────────────────────────────────────────

Row {
    id: root

    spacing: Theme.spacing

    // No plugins is the overwhelmingly common case, and an empty Row still
    // participates in the bar's width arithmetic. Collapsing it entirely keeps
    // a machine with no plugins byte-identical to one built before §16.
    visible: repeater.count > 0

    // A widget may not grow without limit. The bar's notch has a fixed width
    // budget it shares with the clock, the battery and the tray; a plugin
    // reporting an implicitWidth of ten thousand would push all of them off
    // screen. A clamp is not an insult to plugin authors — it is the thing
    // that lets an author's mistake be visibly their widget's problem rather
    // than an unexplained bar that stopped showing the time.
    readonly property int maxWidgetWidth: Math.round(120 * Theme.scale)

    Repeater {
        id: repeater

        // Only granted plugins for THIS extension point. A refused plugin is
        // absent here by construction: its entryUrl stays empty and it never
        // appears in `loaded`.
        model: PluginService.widgetsFor("bar-widget")

        delegate: Item {
            id: mount

            required property var modelData

            // Clamped, and clipped to what the clamp allows.
            implicitWidth:  Math.min(hostLoader.implicitWidth, root.maxWidgetWidth)
            implicitHeight: hostLoader.implicitHeight
            width:          implicitWidth
            height:         parent ? parent.height : implicitHeight
            clip:           true

            Loader {
                id: hostLoader

                anchors.verticalCenter: parent.verticalCenter

                // By URL, from the record. Never a type name and never a path
                // this file builds — PluginService is the only thing that turns
                // a manifest into a loadable URL, and it leaves entryUrl empty
                // for anything it refused.
                source: mount.modelData ? mount.modelData.entryUrl : ""

                // See the header: the bar must paint before a plugin does.
                asynchronous: true

                onStatusChanged: {
                    if (status === Loader.Error) {
                        // The Loader has already logged the QML error. Record
                        // it against the plugin and stop pointing at it, so a
                        // broken plugin is one line in the log and a note in
                        // Settings rather than a retry on every layout pass.
                        if (mount.modelData && mount.modelData.reportLoadError)
                            mount.modelData.reportLoadError("QML failed to load")
                        source = ""
                        return
                    }

                    if (status === Loader.Ready)
                        mount._inject()
                }
            }

            // ── Handing over the capability object ────────────────────────────
            // The contract, and it is the whole of apiVersion 1's extension
            // API: a bar-widget plugin's root item declares
            //
            //     property var api: null
            //
            // and the host assigns it once, before the plugin is on screen.
            // Everything a plugin can do arrives through that object; see
            // PluginService's `api` for the surface.
            //
            // Wrapped in try/catch because assigning to a property a plugin
            // forgot to declare throws, and a plugin author's omission must
            // read as "that plugin is broken", not as a shell exception during
            // startup. The widget still loads — it simply gets nothing, which
            // is the correct outcome for something that never asked.
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
        }
    }
}
