pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "manifest.js" as Manifest
import "../../"

// ─── PluginService ────────────────────────────────────────────────────────────
// The APEX Shell plugin platform. Roadmap §16: "Stable extension APIs …
// Plugin permissions for filesystem, network, location, system controls and
// secrets. Crash isolation where practical. Versioned API and compatibility
// policy."
//
// This file discovers plugins, decides what each one is allowed to do, and
// hands out the capability object that is the only thing a plugin can act
// through. All of the *deciding* lives in manifest.js next door — see the long
// header there for the permission vocabulary and the compatibility policy, and
// for the reason it is plain JavaScript.
//
// ── Three extension points, and this file knows about none of them ───────────
// apiVersion 1.1 mounts `bar-widget`, `launcher-provider` and
// `quick-settings-tile`. Each has its own host; this file has no branch for any
// of them. A host asks pluginsFor("its-name") and gets the granted records that
// declared it, and the name it passes is checked against EXTENSION_POINTS in
// manifest.js at load time, so a plugin cannot land on a point that has no host
// and a host cannot mount a point the manifest layer does not know about.
//
// ── READ THIS BEFORE YOU TRUST THE WORD "PERMISSION" ─────────────────────────
// QML plugins run IN-PROCESS in the shell's own QML engine. There is no
// sandbox, no separate address space, no syscall filter. So:
//
//   * A plugin that did not declare `network` cannot make a network call
//     THROUGH THIS API. `api.net.get()` refuses before anything is spawned,
//     and the host — not the plugin — builds the argv and runs curl. That
//     refusal is real and it is tested.
//
//   * A plugin is refused at load if its source reaches for raw engine power
//     instead of the API: any import outside a four-module allowlist,
//     XMLHttpRequest, dynamic QML construction, eval, Loader, object-graph
//     walking. That closes the accidental routes and raises the cost of the
//     deliberate ones.
//
//   * It is NOT a sandbox. A plugin written specifically to defeat a textual
//     scan runs with the shell's full authority. apiVersion 1 does not claim
//     otherwise, and docs/plugins.md says so in the same words. Real isolation
//     needs an out-of-process plugin runtime, which is a §16 follow-up.
//
// The line that matters: **the permission model gates the API, and the scan
// defends the API's monopoly. Neither one confines hostile code.** If a future
// change makes that paragraph read as too pessimistic, the change is wrong or
// the paragraph needs rewriting — do not quietly leave it stale, because the
// whole value of this file is that a reader can tell what it does not do.
//
// ── Layout on disk ───────────────────────────────────────────────────────────
//   ~/.config/apex-shell/plugins/<id>/plugin.json
//   ~/.config/apex-shell/plugins/<id>/<Entry>.qml
//
// One .qml per plugin, and the directory name must equal the manifest id. Both
// are enforced, and the second is why the enumeration below checks the id
// charset before it interpolates a directory name into a path: comparing the
// id to its directory later does not save you from a directory called "..".
//
// ── Cost ─────────────────────────────────────────────────────────────────────
// One subprocess, once, at first use. There is deliberately NO timer: the
// shell's telemetry services were rewritten to stop forking at idle and a
// plugin rescan on a poll would put that back. Plugins are picked up on
// shell start or on an explicit rescan(), and that is the whole story.
// ──────────────────────────────────────────────────────────────────────────────

Singleton {
    id: root

    // The plugin API version this shell implements. A plugin declares what it
    // was built against and manifest.js decides whether the two are compatible.
    readonly property string apiVersion: Manifest.API_VERSION

    // Writable so a test can point the whole platform at a fixture tree instead
    // of the developer's real plugin directory. This is the same escape hatch
    // CompositorService gives its display and input engines, and for the same
    // reason: a suite that runs against the live session is a suite that can
    // damage the live session, and this repo has already done that once.
    property string pluginDir:
        Quickshell.env("HOME") + "/.config/apex-shell/plugins"

    // ── Discovery ─────────────────────────────────────────────────────────────
    // [{ id, qmlCount, symlinks, qmlName }] straight off the filesystem, before
    // any manifest has been read.
    property var found: []

    // True once a scan has completed, whatever it found. Distinguishes "no
    // plugins" from "not looked yet", which a consumer showing an empty list
    // genuinely needs to tell apart.
    property bool scanned: false

    signal scanCompleted()

    // ── Records ───────────────────────────────────────────────────────────────
    // One object per discovered directory, in discovery order. Each carries its
    // own grant and its own capability object; see the _Record component below.
    property var records: []

    readonly property var loaded:  root.records.filter(function (r) { return r.state === "loaded" })
    readonly property var refused: root.records.filter(function (r) { return r.state === "refused" })

    // Records for one extension point, ready to be instantiated. Each host
    // calls this with its own name and gets only the plugins that asked for it;
    // adding the launcher-provider and quick-settings-tile hosts needed no
    // change to this function, which is the claim the first version made and
    // this is the version that tested it.
    //
    // Called pluginsFor(), not widgetsFor(): two of the three extension points
    // do not produce a widget. A launcher provider hands back rows and a
    // quick-settings tile hands back a state; the shell draws both.
    function pluginsFor(extensionPoint) {
        return root.loaded.filter(function (r) {
            return r.grant && r.grant.extensionPoint === extensionPoint
        })
    }

    function recordFor(id) {
        for (var i = 0; i < root.records.length; i++)
            if (root.records[i].pluginId === id) return root.records[i]
        return null
    }

    // ── The theme handed to plugins ───────────────────────────────────────────
    // A plain snapshot, not the Theme singleton. A plugin may not import
    // "../../" — that is what makes the shell's singletons unreachable by name
    // from plugin code — so anything a widget needs in order to look native has
    // to arrive through the API. Keeping it a plain object also means a plugin
    // cannot write to Theme by assigning through the reference it was given.
    //
    // This is the surface that has to stay stable across apiVersion 1.x: adding
    // a key is a minor bump, removing or renaming one is a major bump.
    readonly property var theme: ({
        background:  String(Theme.background),
        foreground:  String(Theme.text),
        subtext:     String(Theme.subtext),
        accent:      String(Theme.active),
        icon:        String(Theme.icon),
        border:      String(Theme.border),
        fontSize:    Theme.fs(16),
        smallFont:   Theme.fs(12),
        spacing:     Theme.spacing,
        radius:      Theme.cornerRadius
    })

    // ── Enumeration ───────────────────────────────────────────────────────────
    // One shell pass produces a tab-separated line per candidate directory:
    //
    //     <id>\t<qmlCount>\t<symlinkCount>\t<theOneQmlName>
    //
    // Emitting the .qml name here rather than deriving it from the manifest is
    // what lets both FileViews below know their path immediately, instead of
    // chaining "read the manifest, then read whatever it points at".
    //
    // ── The symlink count is a security check, not bookkeeping ────────────────
    // A plugin directory may contain NO symlinks, anywhere, at any depth. One
    // present refuses the plugin.
    //
    // Two separate holes close on this, and the second is the one that is easy
    // to miss:
    //
    //   1. `entry` is validated as a bare filename, so the only way the entry
    //      path can escape the plugin directory is a symlinked .qml.
    //
    //   2. `files` is documented as read-only access INSIDE the plugin's own
    //      directory, and permitsPath() enforces that by rejecting "..", any
    //      absolute path and any dot-component. None of that resolves symlinks.
    //      A plugin shipping `data` as a symlink to $HOME turns
    //      `readText("data/Documents/tax.pdf")` into a read of the user's
    //      documents — no "..", no dot-component, and the path handed to
    //      FileView is exactly what the check approved. The textual rules
    //      cannot see it; only the filesystem can.
    //
    // So `find -type l` over the whole subtree, not a loop over *.qml. Refusing
    // the whole plugin is the right response rather than filtering individual
    // reads: a plugin has no legitimate reason to ship a symlink, and a
    // structural rule enforced once at load beats a resolution check that every
    // future file entry point would have to remember to repeat.
    readonly property string _scanScript:
        'd="$1"\n' +
        '[ -d "$d" ] || exit 0\n' +
        'for p in "$d"/*/; do\n' +
        '  [ -d "$p" ] || continue\n' +
        '  id=${p%/}; id=${id##*/}\n' +
        '  [ -f "$p/plugin.json" ] || continue\n' +
        '  n=0; only=\n' +
        '  for q in "$p"*.qml; do\n' +
        '    { [ -e "$q" ] || [ -L "$q" ]; } || continue\n' +
        '    n=$((n+1)); only=${q##*/}\n' +
        '  done\n' +
        '  link=$(find "$p" -type l 2>/dev/null | wc -l)\n' +
        '  printf \'%s\\t%s\\t%s\\t%s\\n\' "$id" "$n" "$link" "$only"\n' +
        'done\n'

    readonly property Process _scanProc: Process {
        command: []
        running: false
        stdout: StdioCollector {
            onStreamFinished: root._ingest(this.text)
        }
        // A scan that cannot run at all must still settle `scanned`, or a
        // consumer waiting on it waits forever. The plugin directory not
        // existing is the normal state on a machine with no plugins, and the
        // script exits 0 with no output for that; this is for the rarer case
        // where the process never started.
        onRunningChanged: if (!running && !root.scanned) root._settle.restart()
    }

    readonly property Timer _settle: Timer {
        interval: 200
        repeat: false
        onTriggered: if (!root.scanned) root._ingest("")
    }

    function rescan() {
        root._scanProc.command = ["bash", "-c", root._scanScript, "--", root.pluginDir]
        root._scanProc.running = false
        root._scanProc.running = true
    }

    function _ingest(text) {
        const out = []
        const lines = String(text || "").split("\n")
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i]
            if (line === "") continue
            const f = line.split("\t")
            if (f.length !== 4) continue
            // The id is checked BEFORE it is used to build a path. See the
            // note on validId() in manifest.js.
            if (!Manifest.validId(f[0])) {
                console.log("PluginService: ignoring plugin directory with an unusable name")
                continue
            }
            out.push({
                "id":       f[0],
                "qmlCount": parseInt(f[1], 10) || 0,
                "symlinks": parseInt(f[2], 10) || 0,
                "qmlName":  f[3]
            })
        }
        root.found = out
        root.scanned = true
        root.scanCompleted()
    }

    // One scan at construction. PluginService is not force-instantiated in
    // shell.qml — the bar's widget host is what pulls it in — so this runs when
    // something first actually wants plugins.
    Component.onCompleted: root.rescan()

    // ── One record per discovered plugin ──────────────────────────────────────
    // An inline Component, deliberately. This file is reached THROUGH
    // src/qmldir, so src/services/plugins/ is NOT on the import path and a
    // sibling `PluginRecord {}` would fail with "is not a type" — the trap that
    // has already cost this repo a debugging session and is why
    // CompositorService loads its backends by URL. An inline Component has no
    // such problem, and the record needs to be this file's business anyway: it
    // is where a manifest turns into authority.
    readonly property Instantiator _records: Instantiator {
        model: root.found

        onObjectAdded:   root._collect()
        onObjectRemoved: root._collect()

        delegate: QtObject {
            id: rec

            required property var modelData

            readonly property string pluginId: rec.modelData.id
            readonly property string dir:      root.pluginDir + "/" + rec.pluginId

            // "pending" until both files have settled, then "loaded" or
            // "refused". A consumer must tolerate "pending": the two FileViews
            // are asynchronous and the bar is built before they land.
            property string state:  "pending"
            property string reason: ""
            property string detail: ""

            // The validated manifest, or null. This object IS the grant —
            // nothing downstream re-reads plugin.json, so there is exactly one
            // place where a manifest becomes authority.
            property var grant: null

            // Where the crash-isolating Loader points. Empty until granted, so
            // a refused plugin's source is never handed to the QML engine.
            readonly property url entryUrl:
                rec.state === "loaded"
                    ? Qt.resolvedUrl("file://" + rec.dir + "/" + rec.grant.entry)
                    : ""

            readonly property string displayName:
                rec.grant ? rec.grant.name : rec.pluginId

            property string _manifestText: ""
            property string _sourceText:   ""
            property bool   _manifestDone: false
            property bool   _sourceDone:   false

            function _refuse(reason, detail) {
                rec.grant  = null
                rec.reason = reason
                rec.detail = detail === undefined ? "" : detail
                rec.state  = "refused"
                console.log("PluginService: refused " + rec.pluginId + " — "
                            + Manifest.describeRefusal({ ok: false, reason: reason,
                                                         detail: rec.detail }))
                root._collect()
            }

            function _decide() {
                if (!rec._manifestDone || !rec._sourceDone) return

                // Structural checks first — these are about the directory, not
                // the manifest, so no amount of manifest editing changes them.
                if (rec.modelData.symlinks > 0)
                    return rec._refuse("entry-outside-plugin",
                                       "the plugin directory contains a symlink")
                if (rec.modelData.qmlCount === 0)
                    return rec._refuse("entry-missing", "no .qml in the plugin directory")
                if (rec.modelData.qmlCount > 1)
                    return rec._refuse("extra-qml",
                                       rec.modelData.qmlCount + " .qml files; apiVersion 1 allows one")

                const g = Manifest.validateManifest(rec._manifestText, rec.pluginId,
                                                    root.apiVersion)
                if (!g.ok) return rec._refuse(g.reason, g.detail)

                // The manifest names an entry; the directory contains exactly
                // one .qml. They have to be the same file, or the scan below
                // would be checking something other than what gets loaded.
                if (g.entry !== rec.modelData.qmlName)
                    return rec._refuse("entry-missing",
                                       "entry is " + g.entry + " but the directory holds "
                                       + rec.modelData.qmlName)

                const s = Manifest.scanSource(rec._sourceText)
                if (!s.ok) return rec._refuse(s.reason, s.detail)

                rec.grant  = g
                rec.reason = ""
                rec.detail = ""
                rec.state  = "loaded"
                root._collect()
            }

            // Both paths are known from the enumeration, so both files load in
            // parallel and _decide() runs when the second one settles.
            readonly property FileView _manifestFile: FileView {
                path: rec.dir + "/plugin.json"
                // A missing or unreadable manifest is a refusal, not a crash,
                // and Quickshell would otherwise log it as a shell fault.
                printErrors: false
                onLoaded: {
                    rec._manifestText = this.text() || ""
                    rec._manifestDone = true
                    rec._decide()
                }
                onLoadFailed: {
                    rec._manifestText = ""
                    rec._manifestDone = true
                    rec._decide()
                }
            }

            readonly property FileView _sourceFile: FileView {
                path: rec.dir + "/" + rec.modelData.qmlName
                printErrors: false
                onLoaded: {
                    rec._sourceText = this.text() || ""
                    rec._sourceDone = true
                    rec._decide()
                }
                onLoadFailed: {
                    rec._sourceText = ""
                    rec._sourceDone = true
                    rec._decide()
                }
            }

            // ── The capability object ─────────────────────────────────────────
            // This is the whole of what a plugin can do. It is handed to the
            // loaded item as `api`, and every entry point on it re-checks the
            // grant — the check is never "the host already checked", because
            // the host is the only thing that ever calls these and a future
            // second caller would inherit the hole.
            readonly property var api: ({
                "apiVersion": root.apiVersion,
                "id":         rec.pluginId,
                "theme":      root.theme,
                "permissions": rec.grant ? rec.grant.permissions : [],

                // api.net.get(url, function (ok, body, err) { … })
                //
                // Refuses unless the plugin declared `network` AND named this
                // URL's host. The plugin never sees an argv and never spawns
                // anything; see curlArgv() in manifest.js for the three
                // properties of that argv that are load-bearing.
                "net": {
                    "get": function (url, cb) { rec._netGet(url, cb) }
                },

                // api.files.readText(name, function (ok, text, err) { … })
                //
                // Read-only, inside the plugin's own directory. See
                // permitsPath() in manifest.js for why it is read-only — a
                // writable plugin directory would let a plugin rewrite the
                // source that the load-time scan just approved.
                "files": {
                    "readText": function (name, cb) { rec._readText(name, cb) }
                },

                // What the plugin asked for and did not get, so a well-behaved
                // plugin can degrade instead of calling and being refused.
                "has": function (permission) {
                    if (!rec.grant) return false
                    return rec.grant.permissions.indexOf(permission) >= 0
                }
            })

            // ── net ───────────────────────────────────────────────────────────
            property var _netCb: null

            readonly property Process _netProc: Process {
                command: []
                running: false
                stdout: StdioCollector { onStreamFinished: rec._netBody = this.text }
                stderr: StdioCollector { onStreamFinished: rec._netErr  = this.text }
                onExited: function (code) { rec._netFinish(code) }
                onRunningChanged: if (!running && rec._netCb) rec._netSettle.restart()
            }
            property string _netBody: ""
            property string _netErr:  ""

            // curl not existing, or the process failing to start, means
            // `running` drops back to false with no exit code and the callback
            // would sit pending forever. CompositorService hit exactly this
            // with its display helper.
            readonly property Timer _netSettle: Timer {
                interval: 200
                repeat: false
                onTriggered: rec._netFinish(-1)
            }

            function _netFinish(code) {
                const cb = rec._netCb
                if (!cb) return
                rec._netCb = null
                try {
                    if (code === 0) cb(true, rec._netBody, "")
                    else cb(false, "", rec._netErr !== "" ? rec._netErr
                                                          : "request failed (" + code + ")")
                } catch (e) {
                    // A plugin throwing inside its own callback is the
                    // plugin's problem and must not become the shell's.
                    console.log("PluginService: " + rec.pluginId
                                + " threw in a net callback: " + e)
                }
            }

            function _netGet(url, cb) {
                if (typeof cb !== "function") return
                const verdict = Manifest.permitsUrl(rec.grant, url)
                if (!verdict.ok) {
                    // Refusal, not failure: the plugin gets told, nothing is
                    // spawned, and the shell logs which plugin asked for what
                    // so a user can see a plugin probing outside its manifest.
                    console.log("PluginService: denied " + rec.pluginId + " → "
                                + Manifest.describeRefusal(verdict))
                    try { cb(false, "", Manifest.describeRefusal(verdict)) }
                    catch (e) { /* see _netFinish */ }
                    return
                }
                if (rec._netCb) {
                    try { cb(false, "", "a request is already in flight") } catch (e) {}
                    return
                }
                rec._netCb   = cb
                rec._netBody = ""
                rec._netErr  = ""
                rec._netProc.command = Manifest.curlArgv(url)
                rec._netProc.running = false
                rec._netProc.running = true
            }

            // ── files ─────────────────────────────────────────────────────────
            // A FileView per read rather than a Process, so no shell is
            // involved and there is nothing to quote. The path is built from
            // the plugin's own directory plus a name permitsPath() has already
            // refused every traversal shape in.
            property var _fileCb: null

            readonly property FileView _readFile: FileView {
                path: ""
                printErrors: false
                onLoaded:     rec._fileFinish(true,  this.text() || "", "")
                onLoadFailed: rec._fileFinish(false, "", "could not read that file")
            }

            function _fileFinish(ok, text, err) {
                const cb = rec._fileCb
                if (!cb) return
                rec._fileCb = null
                try { cb(ok, text, err) }
                catch (e) {
                    console.log("PluginService: " + rec.pluginId
                                + " threw in a files callback: " + e)
                }
            }

            function _readText(name, cb) {
                if (typeof cb !== "function") return
                const verdict = Manifest.permitsPath(rec.grant, name)
                if (!verdict.ok) {
                    console.log("PluginService: denied " + rec.pluginId + " → "
                                + Manifest.describeRefusal(verdict))
                    try { cb(false, "", Manifest.describeRefusal(verdict)) } catch (e) {}
                    return
                }
                if (rec._fileCb) {
                    try { cb(false, "", "a read is already in flight") } catch (e) {}
                    return
                }
                rec._fileCb = cb
                rec._readFile.path = rec.dir + "/" + verdict.name
            }

            // A plugin whose Loader reported an error is marked here, so the
            // Settings list can say so and so a broken plugin is not retried
            // on every layout pass. Called by the extension-point host.
            function reportLoadError(message) {
                rec._refuse("load-error", String(message || "").slice(0, 200))
            }
        }
    }

    // Rebuilds `records` from the Instantiator. A plain array rather than
    // exposing the Instantiator, because a consumer indexing objectAt() would
    // break the moment the model reorders.
    function _collect() {
        const out = []
        for (let i = 0; i < root._records.count; i++) {
            const o = root._records.objectAt(i)
            if (o) out.push(o)
        }
        root.records = out
    }
}
