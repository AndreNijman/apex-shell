import QtQuick
import "plugins/manifest.js" as Manifest
import "../"

// ─── PluginLauncher ───────────────────────────────────────────────────────────
// The `launcher-provider` extension point (roadmap §16), end to end. A plugin
// whose manifest says `"extensionPoint": "launcher-provider"` is handed the
// launcher's query and its rows are appended to the results in AppLauncher.
//
// ── This host is the inverse of PluginWidgets ────────────────────────────────
// `bar-widget` gives a plugin a rectangle and lets it paint. This point does
// the opposite: the plugin never paints. It is loaded, it is given a string,
// and it puts an array on a property. The SHELL draws the rows, in the
// launcher's own list, next to rows the shell produced itself.
//
// That is a strictly smaller capability — a provider cannot put a pixel on
// screen, cannot cover the search box, cannot animate — and a strictly larger
// checking burden, because a string the shell renders as its own UI is a string
// a user will read as the shell's. Every row therefore goes through
// Manifest.launcherResults(), which builds a fresh object out of four
// allowlisted keys. See the PLUGIN OUTPUT section of manifest.js; the short
// version is that AppLauncher.activate() dispatches on `entry` and `exec`, so a
// row arriving with either one would be arbitrary execution granted to a plugin
// that declared no permissions at all.
//
// `visible: false` on this item and on every mount below is that guarantee made
// structural rather than assumed. A provider's root item is in the scene graph
// so its bindings and timers run, and it is invisible so nothing it contains
// can be rendered. A provider that gates work on `visible` will never run —
// it is driven by `query`, which is the whole contract.
//
// ── The contract ─────────────────────────────────────────────────────────────
//     Item {
//         property var    api:     null      // assigned once by the host
//         property string query:   ""        // written by the host, debounced
//         property var    results: []        // read by the host
//         function activate(index) { }       // optional; called on Enter
//     }
//
// A row is `{ title, subtitle, icon }`. `title` is required and is ALSO the
// payload: activating a row copies the title, so what the user sees is what
// they get. There is no separate value field, deliberately — see manifest.js.
// `icon` is an XDG icon name, never a path.
//
// ── Crash isolation ──────────────────────────────────────────────────────────
// One Loader per provider, asynchronous, with Loader.Error recorded against the
// plugin — the same arrangement PluginWidgets uses and for the same reasons.
// The failure that matters here is different in kind, though: a bar widget that
// throws leaves a blank in the bar, while a provider that throws while the user
// is typing would otherwise take the launcher's result list with it. The
// sanitiser is what stops that: it returns an empty array for anything it
// cannot use and never throws, so a broken provider contributes nothing rather
// than breaking the search.
// ──────────────────────────────────────────────────────────────────────────────

Item {
    id: root

    // A provider never renders. See the header.
    visible: false
    implicitWidth: 0
    implicitHeight: 0

    // Written by AppLauncher on every keystroke.
    property string query: ""

    // Whether providers are consulted for the current query at all. The
    // predicate is in manifest.js rather than in this binding, because no CI
    // runner has a compositor and a condition only a compositor can evaluate is
    // a condition nothing checks. The clause that earns its keep is "?": a
    // query starting with "?" is an answer query, AppLauncher returns
    // answerRows() and nothing else, and a provider row appearing there would
    // sit exactly where the calculator's answer goes.
    readonly property bool consulted: Manifest.launcherWantsProviders(root.query)

    // What the providers actually see. Debounced, and empty whenever the
    // launcher is not consulting them.
    //
    // The debounce is not about the shell's own cost — matching a query against
    // a plugin's array is free. It is that a provider is third-party code on
    // the keystroke path, and 120 ms is the difference between a slow provider
    // being slightly late and a slow provider making the search box feel
    // broken. The timer is one-shot; a repeating timer anywhere in the plugin
    // platform is what the idle-cost check in tests/check-plugin-platform.sh
    // exists to catch.
    property string liveQuery: ""

    onQueryChanged: debounce.restart()

    Timer {
        id: debounce
        interval: 120
        repeat: false
        onTriggered: root.liveQuery = root.consulted ? root.query : ""
    }

    // The sanitised rows, in provider order. AppLauncher appends these AFTER
    // its own app hits, so a provider adds to the list and never reorders it.
    property var rows: []

    onLiveQueryChanged: root._collect()

    function _collect() {
        // Belt and braces over the same rule liveQuery already applies: a
        // provider that ignores `query` and returns rows unconditionally
        // contributes nothing while the launcher is not consulting. The gate is
        // the host's, not the plugin's good behaviour.
        if (root.liveQuery === "") {
            if (root.rows.length !== 0) root.rows = []
            return
        }
        let out = []
        for (let i = 0; i < repeater.count; i++) {
            const m = repeater.itemAt(i)
            if (m && m.rows) out = out.concat(m.rows)
        }
        root.rows = out
    }

    // Called by AppLauncher when the user activates a provider row. The host
    // has already copied the title; this tells the plugin which of ITS rows was
    // chosen, by index into the array it returned, so a plugin can record usage
    // or refine its next answer.
    //
    // By index and not by object: handing the plugin back a row object would
    // let it mutate what the shell is still rendering, and handing it the
    // sanitised copy would tell it less than it already knows.
    function notifyActivated(pluginId, index) {
        for (let i = 0; i < repeater.count; i++) {
            const m = repeater.itemAt(i)
            if (!m || !m.modelData || m.modelData.pluginId !== pluginId) continue
            m._activate(index)
            return
        }
    }

    Repeater {
        id: repeater

        // Only granted plugins that asked for THIS point. A bar widget is not
        // in this model and cannot be — the extension point is part of the
        // grant, and PluginService is what turns a manifest into one.
        model: PluginService.pluginsFor("launcher-provider")

        delegate: Item {
            id: mount

            required property var modelData

            visible: false
            implicitWidth: 0
            implicitHeight: 0

            // The plugin's raw `results` read through the sanitiser. Reading a
            // property the plugin never declared yields undefined, which the
            // sanitiser turns into an empty array — so a provider that forgot
            // `property var results` is quiet rather than broken.
            readonly property var rows:
                Manifest.launcherResults(mount.modelData ? mount.modelData.grant : null,
                                         hostLoader.item ? hostLoader.item.results : null)

            onRowsChanged: root._collect()

            // A plain binding rather than a Connections block, so the push is a
            // declarative dependency on the host's debounced query.
            readonly property string ask: root.liveQuery
            onAskChanged: mount._push()

            Loader {
                id: hostLoader

                // By URL, from the record. PluginService leaves entryUrl empty
                // for anything it refused, so a refused plugin's source is
                // never handed to the QML engine.
                source: mount.modelData ? mount.modelData.entryUrl : ""

                asynchronous: true

                onStatusChanged: {
                    if (status === Loader.Error) {
                        if (mount.modelData && mount.modelData.reportLoadError)
                            mount.modelData.reportLoadError("QML failed to load")
                        source = ""
                        return
                    }
                    if (status === Loader.Ready) {
                        mount._inject()
                        mount._push()
                    }
                }
            }

            // The same handshake bar-widget plugins use: one assignment of the
            // capability object, before the plugin is asked for anything.
            // Wrapped because assigning to a property a plugin forgot to
            // declare throws, and a plugin author's omission must read as
            // "that plugin is broken" rather than as a shell exception.
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

            function _push() {
                const item = hostLoader.item
                if (!item) return
                try {
                    item.query = root.liveQuery
                } catch (e) {
                    console.log("PluginService: " + mount.modelData.pluginId
                                + " is a launcher provider with no `property string query`; "
                                + "it will never be asked anything")
                }
            }

            function _activate(index) {
                const item = hostLoader.item
                if (!item || typeof item.activate !== "function") return
                try {
                    item.activate(index)
                } catch (e) {
                    // A provider throwing in its own activate() is the
                    // provider's problem. The title has already been copied and
                    // the launcher has already closed.
                    console.log("PluginService: " + mount.modelData.pluginId
                                + " threw in activate(): " + e)
                }
            }
        }
    }
}
