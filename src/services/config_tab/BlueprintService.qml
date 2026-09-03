pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "blueprint.js" as BP

// ─── BlueprintService ─────────────────────────────────────────────────────────
// §10's GUI blueprint editor: the process boundary. Every decision it makes
// lives in blueprint.js, which Node can exercise headlessly; this file only
// spawns the CLI and moves strings.
//
//   apex blueprint show --json        ──►  the file, as JSON        (read)
//   apex blueprint diff --json        ──►  a plan                  (compare)
//   apex apply --dry-run --json       ──►  the same plan            (preview)
//   apex blueprint set --json -       ◄──  the file, as JSON        (write)
//
// ── THE EDITOR NEVER AUTHORS TOML ────────────────────────────────────────────
//
// Not once, nowhere in this file. It reads a blueprint as JSON and writes the
// same shape back on stdin, and `apex blueprint set` puts it through the same
// normalise() + validate() + to_toml() + atomic write a hand-edited file goes
// through. So what this page writes is byte-identical to what a person types,
// and an invalid one is refused with the same message. Rendering TOML here
// would be a second implementation of the schema that drifts the first time a
// field is added — and the lossless round-trip is the property the whole
// declarative design rests on.
//
// Lossless SEMANTICALLY, which is the property that matters and the one the
// digest measures. Verified against a locally built CLI: a blueprint read with
// `show --json` and written straight back through `set --json -` comes back as
// the same blueprint with the same digest, and no `version` key is invented for
// a file that never had one.
//
// It is not byte-for-byte, and that is the CLI's doing rather than something to
// work around here: `to_toml()` is toml::to_string_pretty, which expands a
// hand-written inline array — `install = ["firefox", "git"]` — into a
// multi-line one. So the first save through this page reformats arrays in a
// hand-edited file. The values, the digest and `diff` are all unaffected; only
// the layout changes, and it changes the same way for anyone who runs any
// command that writes the file. The digest being stable across that is what
// makes the stale-write guard below usable at all — if reformatting moved the
// digest, every save would make the page believe someone else had edited the
// file.
//
// ── NOTHING APPLIES ON EDIT ──────────────────────────────────────────────────
//
// Two separate separations, and both matter:
//
//   stage   editing a field changes a draft in memory. No process runs.
//   save    writes the user's blueprint. Changes the machine not at all.
//   apply   converges. Behind an explicit button, never a timer.
//
// `save` and `apply` being different verbs is the whole point of a declarative
// file: you say what the machine should be, look at what that would change, and
// then decide. A page that applied on save would make the blueprint an
// imperative remote control with extra steps.
//
// There is no debounce anywhere in this file. `set` is a full-file replace, so
// copying InputService's debounce-then-write would rewrite the user's blueprint
// on every keystroke — and every intermediate keystroke is a blueprint the CLI
// would refuse or, worse, accept.
//
// ── APPLY NEVER ESCALATES ────────────────────────────────────────────────────
//
// `apex apply` converges the privilege domain it is already running in and
// merely reports the other. It never runs sudo, which is the reason it cannot
// raise an authentication prompt at all. So the root-domain changes are shown
// as information naming `sudo apex apply`, and there is deliberately no button
// behind that line. Adding one would undo the property.
//
// ── WHEN apex IS NOT ON THIS IMAGE ───────────────────────────────────────────
//
// No P1 verb has been merged and no image has been built, so the installed
// /usr/bin/apex has none of this. A process that never starts emits neither
// stdout nor stderr, so `onExited` is what sets `loaded` and a reason —
// DisplayService's pattern, for the same cause: without it the page renders
// completely blank, with no error and nothing to explain it.
// ──────────────────────────────────────────────────────────────────────────────

QtObject {
    id: root

    // Overridable so a locally built binary can be exercised without installing
    // into /usr. The default is the installed path, so a normal session needs no
    // environment at all. Mirrors DisplayService's APEX_DISPLAY_ENGINE.
    readonly property string cli: {
        const override = Quickshell.env("APEX_BLUEPRINT_CLI") || ""
        return override !== "" ? override : "apex"
    }

    // ── What the file says ────────────────────────────────────────────────────
    property var blueprint: null      // the object `show --json` returned
    property string source: ""        // which file it came from
    property string digest: ""        // read again before every write
    property var paths: ({})
    property string toml: ""          // the SAVED file, rendered by the CLI
    property bool loaded: false
    property string lastError: ""

    // True when the CLI could not be run at all, as opposed to running and
    // failing. The page shows an explanation rather than an empty editor.
    property bool available: true
    property string unavailableReason: ""

    // ── What the user has staged ──────────────────────────────────────────────
    // A copy of `blueprint`, edited. Nothing here has touched disk.
    property var draft: null

    readonly property var pending: root.blueprint && root.draft
        ? BP.pendingChanges(root.blueprint, root.draft) : []
    readonly property bool dirty: root.pending.length > 0
    readonly property string saveNotice:
        BP.saveNotice({ ok: root.loaded && root.blueprint !== null,
                        source: root.source === "" ? null : root.source,
                        paths: root.paths })

    // Set when a save would unmanage everything. The page must confirm.
    readonly property bool eraseWarning: root.blueprint && root.draft
        ? BP.wouldEraseEverything(root.blueprint, root.draft) : false

    // ── The plan ──────────────────────────────────────────────────────────────
    property var plan: null           // classify()'d output, or null
    property bool planning: false
    readonly property string planSummary: root.plan ? BP.summary(root.plan) : ""
    readonly property string rootNotice: root.plan ? BP.rootNotice(root.plan) : ""

    // ── Write state ───────────────────────────────────────────────────────────
    property bool saving: false
    property string saveError: ""     // the CLI's stderr, verbatim
    property string saveMessage: ""

    // ── Apply state ───────────────────────────────────────────────────────────
    property bool applying: false
    property string applyError: ""
    property string applyOutput: ""

    // ── vocabularies, for the page's dropdowns ────────────────────────────────
    readonly property var compositors: BP.COMPOSITORS
    readonly property var themes: BP.THEMES
    readonly property var agents: BP.AGENTS
    readonly property var sandboxes: BP.SANDBOXES
    readonly property var languages: BP.LANGUAGES

    // ── reading ───────────────────────────────────────────────────────────────

    function refresh() {
        root._showProc.running = true
    }

    /// Throw the draft away and go back to what is on disk.
    function revert() {
        root.draft = root.blueprint === null ? null : JSON.parse(JSON.stringify(root.blueprint))
        root.saveError = ""
        root.saveMessage = ""
    }

    property var _showProc: Process {
        command: [root.cli, "blueprint", "show", "--json"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                const r = BP.readShow(text)
                if (!r.ok) {
                    // A failed read must not become an empty draft: saving that
                    // over a real blueprint would erase it.
                    root.lastError = r.error
                    root.blueprint = null
                    root.draft = null
                    return
                }
                root.blueprint = r.blueprint
                root.source = r.source === null ? "" : r.source
                root.digest = r.digest
                root.paths = r.paths
                root.lastError = ""
                root.available = true
                root.unavailableReason = ""
                root.draft = JSON.parse(JSON.stringify(r.blueprint))
                // The rendered file, for display only. Never parsed, never
                // edited, never written — `show` without --json is the CLI
                // rendering its own TOML, which is the only TOML this page ever
                // shows.
                root._tomlProc.running = true
            }
        }
        stderr: StdioCollector {
            onStreamFinished: {
                const t = text.trim()
                if (t !== "" && root.blueprint === null) root.lastError = t
            }
        }
        onExited: function(code) {
            root.loaded = true
            if (code !== 0 && root.blueprint === null) {
                root.available = false
                root.unavailableReason =
                    "Could not run `" + root.cli + " blueprint show` (exit " + code + "). " +
                    "The blueprint verbs ship with APEX-OS; on an image or a " +
                    "checkout that predates them this page has nothing to talk to."
                if (root.lastError !== "")
                    root.unavailableReason += "\n\n" + root.lastError
            }
        }
    }

    property var _tomlProc: Process {
        command: [root.cli, "blueprint", "show"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: { root.toml = text }
        }
    }

    // ── staging: in memory only, no process, no timer ─────────────────────────

    function stage(section, key, value) {
        if (root.draft === null) return
        root.draft = BP.setField(root.draft, section, key, value)
        root.saveMessage = ""
    }

    function stageList(section, key, items) {
        if (root.draft === null) return
        root.draft = BP.setList(root.draft, section, key, items)
        root.saveMessage = ""
    }

    function addItem(section, key, item) {
        if (root.draft === null || String(item).trim() === "") return
        root.draft = BP.addToList(root.draft, section, key, String(item).trim())
        root.saveMessage = ""
    }

    function removeItem(section, key, item) {
        if (root.draft === null) return
        root.draft = BP.removeFromList(root.draft, section, key, item)
        root.saveMessage = ""
    }

    function fieldOf(section, key)  { return BP.fieldOf(root.draft, section, key) }
    function listOf(section, key)   { return BP.listOf(root.draft, section, key) }

    // ── the plan: `diff --json`, and the dry run ──────────────────────────────
    //
    // Both emit plan_json, so the two cannot describe the same plan
    // differently. `preview()` is the dry run — and it is a dry run in the CLI's
    // own sense: a real run and a dry run call the planner once each and differ
    // only in whether the steps reach a converger that touches anything.

    function compare() {
        root._planCommand = [root.cli, "blueprint", "diff", "--json"]
        root._runPlan()
    }

    function preview() {
        // --dry-run is not optional here and is not a variable. A preview that
        // could lose the flag through a binding is an apply.
        root._planCommand = [root.cli, "apply", "--dry-run", "--json"]
        root._runPlan()
    }

    property var _planCommand: []

    function _runPlan() {
        root.planning = true
        root.plan = null
        root._planProc.command = root._planCommand
        root._planProc.running = true
    }

    property var _planProc: Process {
        command: []
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                const p = BP.classify(text)
                root.plan = p
                if (!p.ok) root.lastError = p.error
            }
        }
        stderr: StdioCollector {
            onStreamFinished: {
                const t = text.trim()
                if (t !== "" && root.plan === null) root.lastError = t
            }
        }
        onExited: function(code) {
            root.planning = false
            // Exit 1 is DRIFT, not failure: `diff` reports a machine that
            // differs from its blueprint with a non-zero code on purpose, and
            // treating that as an error would show a red banner on the normal
            // case.
            if (code > 1 && root.plan === null) {
                root.lastError =
                    "Could not read the plan (exit " + code + ")."
                root.available = false
                root.unavailableReason = root.lastError
            }
        }
    }

    // ── saving: the only write, and it is explicit ────────────────────────────
    //
    // Re-reads the digest first. `set` has no compare-and-swap, and the
    // blueprint is a human-owned file that can be hand-edited while this page
    // is open; without this a save would silently overwrite an edit the user
    // made in a text editor thirty seconds ago.

    function save() {
        if (root.draft === null || root.saving) return
        if (root.eraseWarning && !root._eraseConfirmed) {
            // Guarded in the page too, but refused here as well: `{}` clears the
            // CLI's empty-stdin check and atomically writes an empty file.
            root.saveError =
                "This would unmanage everything in the blueprint. " +
                "Confirm to write it anyway."
            return
        }
        root.saving = true
        root.saveError = ""
        root.saveMessage = ""
        root._recheckProc.running = true
    }

    property bool _eraseConfirmed: false
    function confirmErase() { root._eraseConfirmed = true; root.save() }

    // The pre-write read. Its only job is to produce a digest to compare.
    property var _recheckProc: Process {
        command: [root.cli, "blueprint", "show", "--json"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                const fresh = BP.readShow(text)
                if (BP.isStale(root.digest, fresh.digest)) {
                    root.saving = false
                    root.saveError = BP.staleNotice()
                    return
                }
                root._write()
            }
        }
        onExited: function(code) {
            if (code !== 0 && root.saving) {
                root.saving = false
                root.saveError =
                    "Could not re-read the blueprint before writing (exit " +
                    code + "); nothing was written."
            }
        }
    }

    function _write() {
        // The JSON is a bash ARGUMENT, never interpolated into the script.
        // Package names come off disk and out of `apex sync import` bundles, so
        // splicing them into a command line is an injection — the same reason
        // DisplayService passes its model as an argv element.
        root._setProc.command = ["bash", "-c",
            'printf %s "$1" | "$2" blueprint set --json -',
            "--", BP.toStdin(root.draft), root.cli]
        root._setProc.running = true
    }

    property var _setProc: Process {
        command: []
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                const t = text.trim()
                if (t !== "") root.saveMessage = t
            }
        }
        stderr: StdioCollector {
            onStreamFinished: {
                // Verbatim. An editor's rejection must be identical to a
                // hand-edit's rejection — that is what the write verb was built
                // for, and paraphrasing it here would be a second, worse
                // validator.
                const t = text.trim()
                if (t !== "") root.saveError = t
            }
        }
        onExited: function(code) {
            root.saving = false
            root._eraseConfirmed = false
            if (code !== 0) {
                if (root.saveError === "")
                    root.saveError = "apex blueprint set exited " + code +
                                     "; the previous blueprint is unchanged."
                return
            }
            // Re-read rather than assuming: the file on disk is what the CLI
            // normalised, which may differ from the draft (deduped lists), and
            // showing the draft as if it were the file would be the page
            // believing in a blueprint that does not exist.
            root.refresh()
            // A saved blueprint makes any previous plan stale.
            root.plan = null
        }
    }

    // ── applying: explicit, un-escalated, and never on a timer ────────────────

    function apply() {
        if (root.applying) return
        root.applying = true
        root.applyError = ""
        root.applyOutput = ""
        root._applyProc.running = true
    }

    property var _applyProc: Process {
        // No --dry-run: this is the live one, and it is reachable only from the
        // Apply button. Never sudo — `apex apply` converges the domain it is
        // already in and reports the other, and that is what makes it unable to
        // raise an auth prompt.
        command: [root.cli, "apply"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: { root.applyOutput = text.trim() }
        }
        stderr: StdioCollector {
            onStreamFinished: {
                const t = text.trim()
                if (t !== "") root.applyError = t
            }
        }
        onExited: function(code) {
            root.applying = false
            // 1 is residual drift, which apply reports after re-measuring
            // rather than assuming its own success. Not an error.
            if (code > 1 && root.applyError === "")
                root.applyError = "apex apply exited " + code
            root.compare()
        }
    }
}
