pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "search.js" as Search
// The built-in providers, by relative directory — the same arrangement
// Dashboard.qml uses for "../components". They are deliberately NOT in
// src/services/qmldir: nothing outside this host has any business
// instantiating one, and a provider that could be dropped into another file
// would be a second, ungated way to put a row in front of the user.
import "search"
import "../"

// ─────────────────────────────────────────────────────────────────────────────
// SearchService — the host of APEX Search (roadmap §15).
//
// This file is an ADAPTER and almost nothing else. Every decision it appears to
// make is made in src/services/search.js:
//
//   which providers to consult      Search.providerWants()
//   what to run for one of them     Search.requestArgv()
//   when to run it, and what to
//   cancel when it is superseded    Search.plan()
//   how to rank the answers         Search.merge()
//
// The split is not tidiness. No CI runner has a compositor, so every
// behavioural QML suite in this repo skips there — which means anything decided
// in a QML binding is decided somewhere nothing checks. A launcher that can
// restart a service or install a package cannot have its rules live there. So
// the rules live in a .js file that Node runs directly, and this file's job is
// to be so thin that "the QML went around the reducer" is a thing a static
// check can look for. tests/check-unified-search.sh looks for exactly that.
//
// ── The provider contract ────────────────────────────────────────────────────
//
// Every built-in provider is the same shape a third-party `launcher-provider`
// plugin is (see PluginLauncher.qml's header — this is that contract verbatim):
//
//     property var    api:     null      // assigned once by the host
//     property string query:   ""        // written by the host, debounced
//     property var    results: []        // read by the host
//     function activate(index) { }       // optional
//
// A built-in is trusted, so its `api` carries more than a plugin's — but it is
// still assigned once, still by the host, and a provider still cannot ask for
// anything that is not in it.
//
// ── The one thing a built-in gets that a plugin cannot ───────────────────────
//
// `property string data` on the four providers whose answer comes from a
// subprocess. The host runs the command — chosen by Search.requestArgv(), not
// by the provider — and writes the output into that string. A provider owns no
// Process, imports no Quickshell.Io, and cannot ask for a command to be run.
//
// That asymmetry is the finding §15 was asked to produce, and it is not
// arbitrary. A plugin provider that could name a command would hold the
// `system` permission, which manifest.js refuses at load because "no permission
// may grant a capability that subsumes the others". The built-ins do not get
// around that rule; they get a narrower thing — a fixed, host-chosen read.
//
// ── Cost ─────────────────────────────────────────────────────────────────────
//
// The refcount convention (components/ServiceRef.qml). Nothing here runs unless
// something is holding a reference: with the launcher closed there is no timer,
// no subprocess, no cache and no results array. `AppLauncher` holds the ref and
// binds it to genuinely-on-screen, not to Item visibility — an Item inside a
// hidden window still reports visible, which is how the stats page once kept
// six pollers running after the dashboard was closed.
// ─────────────────────────────────────────────────────────────────────────────

QtObject {
    id: root

    // ── Demand ────────────────────────────────────────────────────────────────
    // `refCount` is the name components/ServiceRef.qml expects. A service with
    // its own differently-named counter cannot be used with it, and a
    // hand-rolled counter at each call site is exactly the drift ServiceRef
    // exists to stop.
    property int refCount: 0
    readonly property bool active: root.refCount > 0

    onActiveChanged: {
        if (!root.active)
            root.query = ""
        root._applyPlan(Search.plan(root._state,
                                    { "type": "demand", "on": root.active }))
        // Clipboard history is a subprocess, so it is read on DEMAND and never
        // on a keystroke: one `cliphist list` when the launcher opens, and none
        // at all when it does not.
        if (root.active)
            ClipboardService.load()
    }

    // ── The query ─────────────────────────────────────────────────────────────
    // Written by AppLauncher on every keystroke. Forced empty while nothing
    // holds a reference, so a stale query cannot survive a close and re-open.
    property string query: ""

    readonly property var parsed: Search.parseQuery(root.active ? root.query : "")

    // What the host knows and search.js must not guess. Assigned into every
    // provider's `api` once, at construction.
    readonly property var api: ({
        "shellDir": Quickshell.shellDir,
        "home":     Quickshell.env("HOME")
    })

    // ── The providers ─────────────────────────────────────────────────────────
    // Declared, not discovered. A registry built by scanning a directory would
    // mean the set of things that can put a row in front of the user depends on
    // what is on disk, which is the property that makes a plugin directory a
    // plugin directory and a built-in set a built-in set.
    readonly property CalcProvider      _calc:      CalcProvider      { api: root.api }
    readonly property AppsProvider      _apps:      AppsProvider      { api: root.api }
    readonly property CommandsProvider  _commands:  CommandsProvider  { api: root.api }
    readonly property WindowsProvider   _windows:   WindowsProvider   { api: root.api }
    readonly property SettingsProvider  _settings:  SettingsProvider  { api: root.api }
    readonly property AgentsProvider    _agents:    AgentsProvider    { api: root.api }
    readonly property ClipboardProvider _clipboard: ClipboardProvider { api: root.api }
    readonly property ProjectsProvider  _projects:  ProjectsProvider  { api: root.api }
    readonly property HostsProvider     _hosts:     HostsProvider     { api: root.api }
    readonly property FilesProvider     _files:     FilesProvider     { api: root.api }
    readonly property PackagesProvider  _packages:  PackagesProvider  { api: root.api }

    function _providerFor(id) {
        switch (id) {
        case "calc":      return root._calc
        case "apps":      return root._apps
        case "commands":  return root._commands
        case "windows":   return root._windows
        case "settings":  return root._settings
        case "agents":    return root._agents
        case "clipboard": return root._clipboard
        case "projects":  return root._projects
        case "hosts":     return root._hosts
        case "files":     return root._files
        case "packages":  return root._packages
        }
        return null
    }

    // The descriptor each provider's rows are sanitised against. `kind` lives
    // here rather than on the provider for the same reason manifest.js sets
    // `kind: "plugin"` itself: it is what AppLauncher.activate() dispatches on,
    // so a provider choosing its own would be choosing which branch runs.
    readonly property var _descriptors: ({
        "calc":      { "id": "calc",      "kind": "answer",  "builtin": true },
        "apps":      { "id": "apps",      "kind": "app",     "builtin": true },
        "commands":  { "id": "commands",  "kind": "command", "builtin": true },
        "windows":   { "id": "windows",   "kind": "window",  "builtin": true },
        "settings":  { "id": "settings",  "kind": "setting", "builtin": true },
        "agents":    { "id": "agents",    "kind": "agent",   "builtin": true },
        "clipboard": { "id": "clipboard", "kind": "clip",    "builtin": true },
        "projects":  { "id": "projects",  "kind": "project", "builtin": true },
        "hosts":     { "id": "hosts",     "kind": "host",    "builtin": true },
        "files":     { "id": "files",     "kind": "file",    "builtin": true },
        "packages":  { "id": "packages",  "kind": "package", "builtin": true }
    })

    // ── Pushing the query down ────────────────────────────────────────────────
    // Every provider is written on every query change: the ones being consulted
    // get the raw query, the rest get "". A provider that ignored `query` and
    // produced rows unconditionally would still contribute nothing, because the
    // gate is the host's rather than the provider's good behaviour — the same
    // belt-and-braces PluginLauncher applies to plugins.
    onParsedChanged: root._push()

    function _push() {
        for (var i = 0; i < Search.PROVIDER_IDS.length; i++) {
            var id = Search.PROVIDER_IDS[i]
            var p = root._providerFor(id)
            if (!p) continue
            p.query = Search.providerWants(id, root.parsed) ? root.query : ""
        }
        root._applyPlan(Search.plan(root._state,
                                    { "type": "query", "wants": root.wants }))
    }

    // ── What would have to be read ────────────────────────────────────────────
    // Built from the parsed query by search.js. Providers do not appear here at
    // all unless answering them costs a subprocess, and the argv is never
    // composed in QML.
    readonly property var wants: {
        const out = []
        if (!root.active)
            return out
        for (const id of Search.PROVIDER_IDS) {
            const argv = Search.requestArgv(id, root.parsed, root.api)
            if (argv.length > 0)
                out.push({ "id": id, "argv": argv })
        }
        return out
    }

    // ── The reducer's state, and the single place it is applied ───────────────
    property var _state: Search.initialState()

    // The one debounce timer in the whole surface. One-shot: a repeating timer
    // anywhere on this path is what turns "search" into "poll".
    readonly property Timer _debounce: Timer {
        interval: Search.DEBOUNCE_MS
        repeat: false
        onTriggered: root._applyPlan(Search.plan(root._state,
                                                 { "type": "deadline",
                                                   "wants": root.wants }))
    }

    // _applyPlan is the ONLY function that reads a plan, and _spawn below is the
    // only function in this file that starts a process. Both are asserted: a
    // second `running = true` anywhere here would be the QML going around the
    // reducer, and then everything measured about debouncing in
    // tests/search-test.js would be measuring a file the shell no longer obeys.
    function _applyPlan(p) {
        root._state = p.state

        for (var i = 0; i < p.cancel.length; i++)
            root._cancel(p.cancel[i])
        for (var j = 0; j < p.start.length; j++)
            root._spawn(p.start[j].id, p.start[j].seq, p.start[j].argv)

        if (p.armMs > 0) {
            root._debounce.interval = p.armMs
            root._debounce.restart()
        } else if (p.armMs === 0) {
            root._debounce.stop()
        }

        root._deliver()
    }

    // ── Subprocesses ──────────────────────────────────────────────────────────
    // One per provider that can need one, created up front and reused. `slot`
    // holds the reducer's token for the run in flight, or -1 for "nobody is
    // waiting on this".
    readonly property Process _projectsProc: Process {
        property int slot: -1
        property string buf: ""
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._projectsProc.buf = text }
        onExited: function (code) { root._finish("projects", root._projectsProc, code) }
    }
    readonly property Process _hostsProc: Process {
        property int slot: -1
        property string buf: ""
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._hostsProc.buf = text }
        onExited: function (code) { root._finish("hosts", root._hostsProc, code) }
    }
    readonly property Process _filesProc: Process {
        property int slot: -1
        property string buf: ""
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._filesProc.buf = text }
        onExited: function (code) { root._finish("files", root._filesProc, code) }
    }
    readonly property Process _packagesProc: Process {
        property int slot: -1
        property string buf: ""
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._packagesProc.buf = text }
        onExited: function (code) { root._finish("packages", root._packagesProc, code) }
    }

    function _procFor(id) {
        switch (id) {
        case "projects": return root._projectsProc
        case "hosts":    return root._hostsProc
        case "files":    return root._filesProc
        case "packages": return root._packagesProc
        }
        return null
    }

    // The slot is cleared BEFORE the kill, so the exited() the kill produces is
    // ignored rather than recorded against whatever is asked for next. That
    // ordering is a lesson from §20's remote agent sweep, where the reverse
    // order let one device's answer land on another device's row.
    function _cancel(id) {
        const pr = root._procFor(id)
        if (!pr)
            return
        pr.slot = -1
        pr.running = false
    }

    function _spawn(id, seq, argv) {
        const pr = root._procFor(id)
        if (!pr)
            return
        root._cancel(id)
        pr.buf = ""
        pr.slot = seq
        pr.command = argv
        pr.running = true
    }

    function _finish(id, pr, code) {
        const seq = pr.slot
        pr.slot = -1
        if (seq < 0)
            return
        // A non-zero exit is silent, on purpose. `apex host list` does not
        // exist on the apex this machine has installed today — the subcommand
        // lands with §20 — so a device query failing is a NORMAL state, not a
        // fault, and a warning per launcher open would fill the log with a
        // message about something working as designed. The first SUCCESSFUL
        // answer is announced once instead, which makes the data path
        // observable without making the normal case noisy.
        root._applyPlan(Search.plan(root._state,
                                    { "type": "result", "id": id, "seq": seq,
                                      "ok": code === 0, "text": pr.buf }))
        if (code === 0 && !root._announced[id]) {
            root._announced[id] = true
            console.info("SearchService: " + id + " answered")
        }
    }

    property var _announced: ({})

    // ── Handing answers to the providers that asked for them ──────────────────
    // A plain string per provider, replaced wholesale so the provider's
    // `results` binding re-evaluates. Read out of the reducer's cache rather
    // than kept separately, so a cache HIT — the user backspacing to something
    // already fetched — puts the old answer back on screen without a process.
    function _deliver() {
        for (var i = 0; i < root.wants.length; i++) {
            var w = root.wants[i]
            var p = root._providerFor(w.id)
            if (!p)
                continue
            var c = Search.cached(root._state, w.id, w.argv)
            p.data = (c !== null && c.ok) ? c.text : ""
        }
        root._epoch = root._epoch + 1
    }

    // ── The results ───────────────────────────────────────────────────────────
    // Every provider's rows, sanitised against its descriptor and merged into
    // one ranked list. `_epoch` is bumped whenever an answer arrives; it is in
    // the binding so a subprocess landing re-runs the merge, which a binding
    // over provider properties alone would not do reliably for a value the host
    // wrote into a provider.
    property int _epoch: 0

    readonly property var results: {
        void root._epoch
        if (!root.active || root.parsed.term === "")
            return []
        // "?" is Wolfram's alone: AppLauncher answers it with answerRows() and
        // nothing else, and no provider — built-in or plugin — appears there.
        if (root.parsed.scope === Search.SCOPE.ANSWER)
            return []

        const groups = []
        for (const id of Search.PROVIDER_IDS) {
            if (!Search.providerWants(id, root.parsed))
                continue
            const p = root._providerFor(id)
            if (!p)
                continue
            groups.push(Search.rowsFrom(root._descriptors[id], p.results,
                                        root.parsed.term))
        }
        return Search.merge(groups)
    }

    // ── The resting view ──────────────────────────────────────────────────────
    // What an empty query shows: pinned apps, then frecency-ranked recents,
    // then everything else. Produced by the apps provider so the ordering lives
    // in one place, and costing nothing but a binding over the DesktopEntries
    // index the shell already maintains.
    readonly property var restingRows: {
        if (!root.active)
            return []
        return Search.rowsFrom(root._descriptors["apps"], root._apps.resting, "")
    }

    // ── Actions ───────────────────────────────────────────────────────────────
    // The one place a non-safe action becomes a running process, and it is
    // reachable only through AppLauncher's commit path, which is gated by
    // Search.commitDecision(). Nothing else in this file starts an action.
    readonly property Process _actionProc: Process { command: []; running: false }

    function preview(row) {
        if (!row || !row.action || row.action === "")
            return null
        return Search.actionPreview(row.action, row.arg, root.api)
    }

    function runAction(row) {
        const argv = row && row.action
                   ? Search.actionArgv(row.action, row.arg, root.api)
                   : null
        if (argv === null)
            return false
        root._actionProc.command = argv
        root._actionProc.running = false
        root._actionProc.running = true
        return true
    }

    // ── The package preview ───────────────────────────────────────────────────
    // `apex resolve <name>` prints every candidate source, which APEX would
    // pick and why, and the exact command for each alternative. Its own help
    // says why it is the right thing to put in a preview: "Read-only, so it
    // needs no root — 'what would this do' should never cost a password."
    //
    // Started by ACTIVATION and never by selection. Arrowing down twenty
    // package rows must not run twenty of these: resolve reaches the package
    // metadata, and dnf5 may refresh it over the network.
    property string resolveFor: ""
    property string resolveText: ""
    property bool   resolveBusy: false

    readonly property Process _resolveProc: Process {
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root.resolveText = text }
        onExited: function (code) { root.resolveBusy = false }
    }

    function resolve(name) {
        const argv = Search.resolveArgv(name)
        if (argv === null)
            return
        if (root.resolveFor === name && root.resolveText !== "")
            return
        root.resolveFor = name
        root.resolveText = ""
        root.resolveBusy = true
        root._resolveProc.command = argv
        root._resolveProc.running = false
        root._resolveProc.running = true
    }

    function forgetResolve() {
        root._resolveProc.running = false
        root.resolveFor = ""
        root.resolveText = ""
        root.resolveBusy = false
    }
}
