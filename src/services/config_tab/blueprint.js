// Pure logic behind §10's blueprint editor: reading `apex blueprint show --json`,
// classifying a plan from `apex blueprint diff --json`, and building the JSON
// that goes back out through `apex blueprint set --json -`.
//
// Kept out of the QML files so tests/blueprint-editor-test.js can exercise it
// under Node — the same file the shell loads, not a copy of it. Nothing here
// spawns a process or touches a file: every function takes strings and objects
// and returns verdicts. That is deliberate. No CI runner has a compositor, so a
// behavioural QML suite always skips there, and a suite that skips proves
// nothing; this module is the half of the editor that can be proved anywhere.
//
// ── THE ONE RULE THIS FILE EXISTS TO ENFORCE ─────────────────────────────────
//
// The editor never authors TOML. It reads a blueprint as JSON, mutates that
// object, and writes the object back. `apex blueprint set --json -` puts it
// through the same normalise() + validate() + to_toml() + atomic write a
// hand-edited file goes through, so what this page writes is indistinguishable
// from what a human types, and an invalid one is refused with the identical
// message. Rendering TOML here would be a second implementation of the schema
// that drifts the first time a field is added.
// ──────────────────────────────────────────────────────────────────────────────

// ── vocabularies ─────────────────────────────────────────────────────────────
//
// Mirrors of the closed sets in apexd/apexd-core/src/blueprint.rs. They exist
// to populate dropdowns, so the user picks a valid value instead of typing one
// and finding out on save.
//
// They are NOT a reimplementation of validate(). This file never decides that a
// blueprint is invalid — the CLI does, and its stderr is shown verbatim, which
// is the property the write verb was built for. These lists only decide what the
// UI offers. tests/blueprint-editor-test.js asserts their exact contents so a
// silent edit here is loud, and tests/check-blueprint-editor.sh checks they
// still match the Rust source when apex-os is checked out beside the shell.
//
// There is no vocabulary-discovery verb, so a mirrored constant plus a parity
// test is the honest ceiling. A `blueprint schema --json` would close it.
var COMPOSITORS = ["hyprland", "niri", "labwc"]
var THEMES      = ["content", "tonal-spot", "fidelity", "fruit-salad", "neutral", "monochrome"]
var AGENTS      = ["claude", "opencode", "codex", "gemini", "kimi", "generic"]
var SANDBOXES   = ["unrestricted", "project", "strict"]
var LANGUAGES   = ["c", "cpp", "go", "javascript", "python", "rust", "shell", "typescript"]

// The sections a blueprint has, and which keys live in each. Used to decide
// when a section has gone empty and must be dropped rather than left as `{}`.
var SECTIONS = {
    desktop:     ["compositor", "theme"],
    apps:        ["install"],
    development: ["languages"],
    agent:       ["default", "sandbox"],
    gaming:      ["enabled"]
}

function _isObject(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v)
}

function _clone(v) {
    return JSON.parse(JSON.stringify(v === undefined ? null : v))
}

// ── reading `apex blueprint show --json` ─────────────────────────────────────

// Parse what `show --json` printed.
//
// Returns { ok, blueprint, source, digest, paths, applied, error }. On failure
// `blueprint` is null rather than an empty object, because "could not read" and
// "manages nothing" must not look alike: saving the second over the first would
// erase a blueprint the page failed to load.
function readShow(raw) {
    var text = String(raw === undefined || raw === null ? "" : raw).trim()
    if (text === "")
        return { ok: false, blueprint: null, source: null, digest: "",
                 paths: {}, applied: null,
                 error: "apex blueprint show printed nothing" }

    var obj
    try {
        obj = JSON.parse(text)
    } catch (e) {
        return { ok: false, blueprint: null, source: null, digest: "",
                 paths: {}, applied: null,
                 error: "Could not read the blueprint: " + e }
    }
    if (!_isObject(obj) || !_isObject(obj.blueprint))
        return { ok: false, blueprint: null, source: null, digest: "",
                 paths: {}, applied: null,
                 error: "apex blueprint show did not return a blueprint" }

    return {
        ok: true,
        blueprint: obj.blueprint,
        // null is a real value here: no blueprint anywhere on disk.
        source: obj.source === undefined ? null : obj.source,
        digest: String(obj.digest === undefined ? "" : obj.digest),
        paths: _isObject(obj.paths) ? obj.paths : {},
        applied: obj.applied === undefined ? null : obj.applied,
        error: ""
    }
}

// Which of the three provenance states this page is editing, as a sentence.
//
// This matters before the first Save, not after it. `set` writes `paths.user`
// unconditionally, so saving while editing the site default FORKS it into the
// user's own file and site updates stop reaching them from then on. A page that
// did not say so would make that decision silently.
function saveNotice(show) {
    if (!show || !show.ok)
        return ""
    var user = (show.paths && show.paths.user) ? show.paths.user : "~/.config/apex/blueprint.toml"
    var site = (show.paths && show.paths.site) ? show.paths.site : "/etc/apex/blueprint.toml"

    if (show.source === null || show.source === "")
        return "No blueprint exists yet. Saving creates " + user + "."
    if (show.source === user)
        return "Editing your own blueprint at " + user + "."
    if (show.source === site)
        return "This is the site default at " + site + ", which you do not own. " +
               "Saving copies it to " + user + " and later changes to the site " +
               "default will no longer reach you."
    return "Loaded from " + show.source + ". Saving writes " + user + "."
}

// ── classifying a plan from `diff --json` / `apply --dry-run --json` ─────────

// Split a plan's changes into the three disjoint buckets the page presents.
//
// The trap this function exists to avoid: Plan::is_converged() is
// `all(step.is_none())`, so a plan whose only changes are BLOCKED reports
// converged: true. That is correct on the CLI side — a Daily machine asked for
// `[gaming] enabled = true` would otherwise never report converged no matter
// how many times apply ran — but a page that rendered `converged` as "nothing
// to say" would hide exactly the changes nobody can fix. So convergence and
// blocked-ness are reported as two separate facts.
//
// The buckets, from the CLI's own shape:
//   blocked != null  ⇒ step == null, domain == null. Cannot be converged at all.
//   domain == "user" ⇒ a plain `apex apply` performs it.
//   domain == "root" ⇒ information only. This page never escalates.
function classify(raw) {
    var text = String(raw === undefined || raw === null ? "" : raw).trim()
    var empty = {
        ok: false, converged: false, error: "",
        user: [], root: [], blocked: [], unknown: [],
        digest: "", source: null
    }
    if (text === "") {
        empty.error = "apex blueprint diff printed nothing"
        return empty
    }
    var obj
    try {
        obj = JSON.parse(text)
    } catch (e) {
        empty.error = "Could not read the plan: " + e
        return empty
    }
    if (!_isObject(obj)) {
        empty.error = "apex blueprint diff did not return a plan"
        return empty
    }

    var changes = Array.isArray(obj.changes) ? obj.changes : []
    var out = {
        ok: true,
        // Taken from the CLI, never recomputed. Deciding convergence here would
        // be a second planner.
        converged: obj.converged === true,
        error: "",
        user: [], root: [], blocked: [], unknown: [],
        digest: String(obj.digest === undefined ? "" : obj.digest),
        source: obj.source === undefined ? null : obj.source
    }

    for (var i = 0; i < changes.length; i++) {
        var c = changes[i]
        if (!_isObject(c)) continue
        var entry = {
            what:    String(c.what === undefined ? "" : c.what),
            current: String(c.current === undefined ? "" : c.current),
            desired: String(c.desired === undefined ? "" : c.desired),
            step:    (c.step === undefined || c.step === null) ? "" : String(c.step),
            blocked: (c.blocked === undefined || c.blocked === null) ? "" : String(c.blocked)
        }
        if (entry.blocked !== "") {
            out.blocked.push(entry)
        } else if (c.domain === "user") {
            out.user.push(entry)
        } else if (c.domain === "root") {
            out.root.push(entry)
        } else {
            // A change with no blocked reason and no domain is a shape this
            // build does not understand. Shown rather than dropped: silently
            // discarding a row would under-report what apply is about to do.
            out.unknown.push(entry)
        }
    }
    return out
}

// The informational line about root-domain changes, or "" when there are none.
//
// Information, deliberately, with no button behind it. `apex apply` converges
// the domain it is already running in and reports the other; it never runs
// sudo, which is the reason it cannot raise an authentication prompt at all.
// A button here that tried to escalate would undo that property.
function rootNotice(plan) {
    if (!plan || !plan.ok) return ""
    var n = plan.root.length
    if (n === 0) return ""
    return n + (n === 1 ? " change needs" : " changes need") +
           " root — run `sudo apex apply`"
}

// One line summarising a plan, covering the converged-but-blocked case.
function summary(plan) {
    if (!plan) return ""
    if (!plan.ok) return plan.error || "The plan could not be read."

    var parts = []
    var actionable = plan.user.length + plan.root.length + plan.unknown.length
    if (actionable === 0)
        parts.push("This machine matches the blueprint.")
    else
        parts.push(actionable + (actionable === 1 ? " change" : " changes") + " to make.")

    if (plan.blocked.length > 0)
        parts.push(plan.blocked.length +
                   (plan.blocked.length === 1 ? " thing" : " things") +
                   " APEX cannot converge.")
    return parts.join(" ")
}

// ── building the draft that goes back out through `set --json -` ────────────

// The draft IS the object `show --json` returned, cloned — never rebuilt from a
// template.
//
// Blueprint serialises with skip_serializing_if on every field, so `show`'s
// blueprint omits empty sections and omits `version` when the user never wrote
// one. Synthesising a draft would add a `version = 1` line to a file that never
// had one, and every save would produce a visible diff against a file the user
// hand-wrote. Load, mutate one field, stringify.
function draftFrom(show) {
    if (!show || !show.ok || !_isObject(show.blueprint))
        return null
    return _clone(show.blueprint)
}

// Set one scalar field, or clear it.
//
// CLEARING OMITS THE KEY, IT DOES NOT NULL IT. `#[serde(default)]` fires on an
// absent field, not on an explicit null: `"install": null` and
// `"languages": null` are hard deserialisation errors, so a cleared list must
// disappear from the object entirely. Scalars would survive a null, but they go
// the same way so there is one rule to remember and one rule under test.
//
// Returns a new object; the caller's draft is untouched, which is what lets a
// QML property binding notice the change.
function setField(draft, section, key, value) {
    if (!_isObject(draft)) return draft
    var next = _clone(draft)
    var cleared = (value === null || value === undefined || value === "")

    if (cleared) {
        if (_isObject(next[section])) {
            delete next[section][key]
            if (Object.keys(next[section]).length === 0)
                delete next[section]
        }
        return next
    }
    if (!_isObject(next[section])) next[section] = {}
    next[section][key] = value
    return next
}

// Replace a list-valued field. An empty list clears the key, per setField.
function setList(draft, section, key, items) {
    var list = Array.isArray(items) ? items.slice() : []
    // Dedupe preserving first-seen order, matching normalise(). Done here only
    // so the UI shows what the file will contain; the CLI dedupes regardless.
    var seen = {}
    var uniq = []
    for (var i = 0; i < list.length; i++) {
        var s = String(list[i])
        if (s === "") continue
        if (seen[s]) continue
        seen[s] = true
        uniq.push(s)
    }
    if (uniq.length === 0)
        return setField(draft, section, key, null)
    return setField(draft, section, key, uniq)
}

function addToList(draft, section, key, item) {
    var current = (_isObject(draft) && _isObject(draft[section]) && Array.isArray(draft[section][key]))
        ? draft[section][key] : []
    return setList(draft, section, key, current.concat([String(item)]))
}

function removeFromList(draft, section, key, item) {
    var current = (_isObject(draft) && _isObject(draft[section]) && Array.isArray(draft[section][key]))
        ? draft[section][key] : []
    var kept = []
    for (var i = 0; i < current.length; i++)
        if (String(current[i]) !== String(item)) kept.push(current[i])
    return setList(draft, section, key, kept)
}

// Read a scalar for display. "" means unmanaged, which is not the same as any
// valid value — the UI shows it as "not managed", never as a default.
function fieldOf(draft, section, key) {
    if (!_isObject(draft) || !_isObject(draft[section])) return ""
    var v = draft[section][key]
    if (v === undefined || v === null) return ""
    return v
}

function listOf(draft, section, key) {
    if (!_isObject(draft) || !_isObject(draft[section])) return []
    var v = draft[section][key]
    return Array.isArray(v) ? v.slice() : []
}

// True when this draft manages nothing at all.
//
// `{}` is the one input `set` accepts that it arguably should not: it clears the
// empty-stdin guard, deserialises to Blueprint::default(), renders to an empty
// string, and atomically writes an empty file — erasing everything the user had
// declared. The CLI guards empty STDIN, not an empty BLUEPRINT, and this editor
// is its only caller. So the page gates that save behind an explicit confirm
// instead of sending it.
function managesNothing(draft) {
    if (!_isObject(draft)) return true
    for (var name in SECTIONS) {
        if (!Object.prototype.hasOwnProperty.call(SECTIONS, name)) continue
        var sec = draft[name]
        if (_isObject(sec) && Object.keys(sec).length > 0) return false
    }
    return true
}

// True when saving this draft would drop the last managed section of a
// blueprint that had one. The exact condition that needs a confirmation.
function wouldEraseEverything(original, draft) {
    return !managesNothing(original) && managesNothing(draft)
}

// ── what changed, as a field-level list ─────────────────────────────────────

// The pending-changes list the page shows instead of a TOML preview.
//
// There is no verb that renders an unsaved draft to TOML, and building one here
// is the forbidden thing. So pending state is described field by field, and the
// TOML the page displays is only ever the saved file as `show` printed it.
function pendingChanges(original, draft) {
    var out = []
    if (!_isObject(original) || !_isObject(draft)) return out

    var names = ["desktop", "apps", "development", "agent", "gaming"]
    for (var n = 0; n < names.length; n++) {
        var section = names[n]
        var keys = SECTIONS[section]
        for (var k = 0; k < keys.length; k++) {
            var key = keys[k]
            var before = _isObject(original[section]) ? original[section][key] : undefined
            var after  = _isObject(draft[section])    ? draft[section][key]    : undefined
            if (JSON.stringify(before === undefined ? null : before) ===
                JSON.stringify(after  === undefined ? null : after))
                continue
            out.push({
                what:   "[" + section + "] " + key,
                before: _render(before),
                after:  _render(after)
            })
        }
    }
    return out
}

function _render(v) {
    if (v === undefined || v === null) return "not managed"
    if (Array.isArray(v)) return v.length === 0 ? "not managed" : v.join(", ")
    return String(v)
}

function isDirty(original, draft) {
    return pendingChanges(original, draft).length > 0
}

// ── the stale-write guard ───────────────────────────────────────────────────

// `set` has no compare-and-swap, and the blueprint is a human-owned file that
// can be hand-edited while this page is open. So the page re-runs
// `show --json` immediately before writing and compares digests; a mismatch
// refuses the save and offers a reload. One extra call and one string compare,
// and it closes the only stale-read window in the system.
//
// An empty `fresh` digest is treated as stale: it means the pre-write read did
// not produce a digest, and writing on the strength of a read that did not
// happen is the thing this guard exists to prevent.
function isStale(loadedDigest, freshDigest) {
    var a = String(loadedDigest === undefined || loadedDigest === null ? "" : loadedDigest)
    var b = String(freshDigest === undefined || freshDigest === null ? "" : freshDigest)
    if (b === "") return true
    return a !== b
}

function staleNotice() {
    return "The blueprint changed on disk since this page read it — someone " +
           "edited the file by hand. Nothing was written. Reload to see the " +
           "current file, then make the change again."
}

// The exact bytes handed to `apex blueprint set --json -` on stdin.
//
// Passed to the process as an argv element and printf'd into the pipe, never
// interpolated into a shell string: package names come off disk and out of
// synced bundles, so splicing them into a command line is an injection.
function toStdin(draft) {
    return JSON.stringify(draft === undefined ? null : draft)
}

// Node (tests) sees `module`; the QML engine does not, and ignores this.
if (typeof module !== "undefined" && module.exports)
    module.exports = {
        COMPOSITORS: COMPOSITORS, THEMES: THEMES, AGENTS: AGENTS,
        SANDBOXES: SANDBOXES, LANGUAGES: LANGUAGES, SECTIONS: SECTIONS,
        readShow: readShow, saveNotice: saveNotice,
        classify: classify, rootNotice: rootNotice, summary: summary,
        draftFrom: draftFrom, setField: setField, setList: setList,
        addToList: addToList, removeFromList: removeFromList,
        fieldOf: fieldOf, listOf: listOf,
        managesNothing: managesNothing, wouldEraseEverything: wouldEraseEverything,
        pendingChanges: pendingChanges, isDirty: isDirty,
        isStale: isStale, staleNotice: staleNotice, toStdin: toStdin
    }
