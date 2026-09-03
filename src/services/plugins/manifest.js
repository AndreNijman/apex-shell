// ─────────────────────────────────────────────────────────────────────────────
// The APEX Shell plugin platform's decision logic (roadmap §16).
//
// Everything in this file answers one of five questions and nothing else:
//
//   validateManifest()  is this plugin.json loadable, and what did it ask for?
//   scanSource()        does this QML file stay inside the sanctioned API?
//   permitsUrl()        may this plugin fetch this URL?
//   curlArgv()          exactly how does the HOST fetch it?
//   launcherResults()   what of this plugin's OUTPUT may the shell render?
//   quickTile()         (the same question, for the quick-settings grid)
//
// The last two arrived with the second and third extension points. The first
// point, `bar-widget`, hands a plugin a rectangle and lets it paint; there is
// nothing to sanitise because the plugin IS the pixels. A launcher provider and
// a quick-settings tile are the other shape: the plugin supplies DATA and the
// shell draws it, inside the shell's own chrome. That inverts where the risk
// sits — a plugin cannot paint a fake system toggle, but it can hand back a
// string, and a string the shell renders as its own UI has to be checked
// before it is believed.
//
// It is plain JavaScript rather than QML for the reason answer.js is: the QML
// engine loads this file with `import "manifest.js" as Manifest`, and Node
// `require`s the very same file in tests/plugin-manifest-test.js. Not a copy —
// the file the shell actually runs. That matters more here than it does for the
// launcher's calculator, because this is the file that decides whether a
// third-party plugin gets to touch the network, and a security check that is
// only exercised by a test double is not exercised at all.
//
// No CI runner has a compositor, so every behavioural QML test in this repo
// skips there. Putting the security-critical half in a .js file is what stops
// §16's coverage from being three greps and a shrug.
//
// ── WHAT THE PERMISSION MODEL ACTUALLY GUARANTEES ────────────────────────────
// Read this before you believe anything else in this file.
//
// QML plugins run IN-PROCESS in the shell's own QML engine. There is no
// sandbox, no separate address space and no syscall filter. What this platform
// enforces is therefore narrower than "plugins are confined", and saying so
// plainly is the point:
//
//   * A plugin that did not declare `network` cannot make a network call
//     THROUGH THE SANCTIONED API. `api.net.get()` refuses before anything is
//     spawned. That refusal is real, total and tested.
//
//   * The load-time source scan below refuses plugins that reach for raw engine
//     power instead of the API — Quickshell.Io, XMLHttpRequest, dynamic QML
//     construction, `eval`, object-graph walking. That raises the cost of going
//     around the API and catches every accidental case.
//
//   * It is NOT a sandbox. A plugin deliberately written to defeat a textual
//     scan runs with the shell's full authority. apiVersion 1 does not claim
//     otherwise. Real isolation needs an out-of-process plugin runtime, which
//     is a §16 follow-up and not this phase.
//
// The honest one-line version, which belongs in any doc that describes this:
// **the permission model gates the API, and the scan defends the API's
// monopoly. Neither one confines hostile code.**
//
// ── Why single-file plugins ──────────────────────────────────────────────────
// An apiVersion 1 plugin is exactly ONE .qml file. That is not a stylistic
// preference. The moment a plugin can pull in a second file, the source scan
// has to prove it has seen every file that can ever execute — through relative
// imports, through `Loader { source: }`, through a computed string. That proof
// is not available textually, and a scan with a hole in it is worse than no
// scan because it reads as a guarantee.
//
// One file, no relative imports, no Loader. Then "what did the scan see" and
// "what can run" are the same set, by construction.
//
// A pleasant side effect: because relative imports are refused, the shell's own
// singletons are not in a plugin's scope AT ALL. `Theme`, `CompositorService`
// and the rest are reachable only through `import "../../"`, which no plugin
// may write. A plugin gets what the host hands it and has no name for anything
// else. That is a structural barrier rather than a textual one, and it is the
// strongest thing in this file.
// ─────────────────────────────────────────────────────────────────────────────

// ── Versioning and the compatibility policy ──────────────────────────────────
// "MAJOR.MINOR". The host declares what it implements; a plugin declares what
// it was written against.
//
//   * MAJOR must match exactly. A major bump means the API changed shape and
//     old plugins cannot be carried forward — they are refused, loudly, rather
//     than loaded into an API that no longer means what they expect.
//   * MINOR must be <= the host's. Minor bumps are additive, so a plugin
//     written against 1.0 runs fine on a 1.3 host. The reverse is not true: a
//     1.3 plugin on a 1.0 host is asking for API that does not exist yet, and
//     the failure mode of letting it load is an undefined property deep inside
//     third-party code, which surfaces as "the shell is broken".
//
// Refusing forward-dated plugins is the whole reason the field exists. A
// version check that only catches major bumps would let the common case — a
// plugin from a newer shell — through.
//
// 1.0 → 1.1 is this policy being used rather than described. Two extension
// points were added and nothing was removed or renamed, which is the definition
// of a minor bump: every apiVersion 1.0 plugin still loads (apex-worldclock
// still declares 1.0 and is still granted), and a plugin that needs one of the
// new points declares 1.1 so a 1.0 host refuses it with
// "api-version-unsupported" instead of "unknown-extension-point". The second
// message tells an author their manifest is wrong; the first tells them the
// truth, which is that their shell is older than their plugin.
var API_VERSION = "1.1";

// The closed permission vocabulary, straight from the roadmap: "Plugin
// permissions for filesystem, network, location, system controls and secrets."
var PERMISSIONS = ["network", "files", "system", "secrets", "location"];

// Of those, the ones apiVersion 1 can actually ENFORCE. The gap is deliberate
// and it is the reason this list is separate from the one above.
//
// A manifest declaring anything in the gap is REFUSED, with a reason that names
// the permission. The alternative — accepting the field and granting nothing —
// is a decorative permission, and a decorative permission is actively harmful:
// it reads, both to the plugin author and to a user reviewing what a plugin
// asked for, as a capability that was considered and granted. The vocabulary
// keeps all five words so a later apiVersion can implement one without renaming
// anything.
//
//   `system` is the interesting refusal. A "system controls" permission that
//   means "run a command" is not a permission at all — it is a bypass of the
//   entire model, because a plugin that can spawn a process can curl anything
//   and read any file, which makes `network` and `files` decorative in turn.
//   No permission may grant a capability that subsumes the others. Until there
//   is a specific, enumerable set of system ACTIONS to expose (set brightness,
//   toggle a profile) rather than a general escape hatch, apiVersion 1 offers
//   none of it.
//
//   THAT SET NOW EXISTS, and this note is the only thing that changed about
//   the refusal. §15's unified search surface needed the shell's OWN launcher
//   rows to do things — restart Bluetooth, install a package, reboot — so it
//   built `ACTIONS` in src/services/search.js: a closed, host-owned table
//   where the TABLE owns the argv, the privilege, the preview and the class,
//   and a row only names an id in it. That is the enumerable set this
//   paragraph was waiting for.
//
//   It is deliberately NOT wired to a permission here. Built-in rows may carry
//   an `action` field; the sanitiser in search.js drops it from anything that
//   did not come from a built-in descriptor, so a plugin row carrying one gets
//   silence. Exposing the table to plugins is now a permission question rather
//   than an architecture one — a later apiVersion can add `actions`, scoped to
//   the classes it is willing to grant — and it is a decision for whoever
//   makes that version, not a side effect of §15. What must not happen is the
//   thing search.js also avoids: letting a provider supply the command.
//
//   `secrets` would need a broker that holds credentials the plugin never sees.
//   There is no secret store in this shell to broker.
//
//   `location` would need a geolocation source and the user-facing precision
//   control the roadmap's weather example implies ("Location: approximate").
//   The shell has neither.
var IMPLEMENTED_PERMISSIONS = ["network", "files"];

// ── Extension points ─────────────────────────────────────────────────────────
// Three are real. §16 names nine — widgets, panels, launcher providers, quick
// settings, background services, notifications, themes, project integrations
// and agent integrations — and the rule that decided which three is the same
// one that stopped the first round shipping five stubs: a point is only on this
// list once a host mounts it, an example plugin uses it, and both halves of the
// suite assert it. A name here with no host is a lie told to plugin authors.
//
//   bar-widget           the plugin paints. It gets a rectangle in the bar's
//                        right-hand cluster and draws whatever it likes in it.
//   launcher-provider    the plugin answers a query. The shell draws the rows.
//   quick-settings-tile  the plugin holds a state. The shell draws the tile.
//
// The split between the first and the other two is the interesting part and it
// is not cosmetic. A painting plugin owns its pixels, so nothing it renders can
// be mistaken for the shell's own UI — it is visibly a third-party widget in a
// third-party widget's slot. A DATA plugin's output is rendered by the shell,
// in the shell's chrome, indistinguishable from a row the shell produced
// itself. So every string crossing that boundary goes through launcherResults()
// or quickTile() below, and neither one passes the plugin's object through: both
// build a fresh object out of an allowlist of keys.
//
// Why an allowlist and not "delete the dangerous keys": the launcher's
// activate() dispatches on fields it finds on a row — `entry` runs a
// DesktopEntry, `exec` goes to `bash -c`. A row that reached it carrying either
// one would be the `system` permission, granted silently, to any plugin that
// asked for nothing. Copying known-good keys onto a new object makes that
// unreachable by construction rather than by remembering to strip a list that
// grows every time the launcher learns a new row shape.
//
// ── The three §16 points that are NOT here, and why ──────────────────────────
// `notification-handler` is the one worth writing down, because it is the one
// that looks easy. A plugin that handles notifications reads their summary and
// body: 2FA codes, message previews, password-reset links — the most sensitive
// text stream the shell touches. That is a capability, and it maps to NOTHING
// in the closed vocabulary above. `secrets` is nearest in spirit and is defined
// as a broker holding credentials the plugin never sees, which is the opposite
// arrangement. So shipping it means either inventing a sixth permission, or
// handing over the shell's most sensitive stream with no declaration at all.
// The second is worse. It stays off this list until the vocabulary has a word
// for what it needs.
//
// Note the asymmetry, because it decides what a later version can do: EMITTING
// a notification is a much smaller capability than reading them, and it could
// be added under a name of its own. §16 names a handler, which is the reading
// direction. `panel`, `theme` and the integrations are simply not built yet —
// no permission problem, just no host.
var EXTENSION_POINTS = ["bar-widget", "launcher-provider", "quick-settings-tile"];

// ── The import allowlist ─────────────────────────────────────────────────────
// A plugin may import these and nothing else. An allowlist rather than a
// denylist because the set of QML modules that can reach the filesystem, the
// network or a subprocess is open-ended and grows with every Qt release, while
// the set a bar widget needs to draw itself is small and stable.
//
// Quickshell.Io is the specific thing being kept out: it carries Process,
// FileView and Socket, which is raw system, files and network in one import.
var ALLOWED_IMPORTS = [
    "QtQuick",
    "QtQuick.Layouts",
    "QtQuick.Shapes",
    "QtQuick.Effects"
];

// ── Forbidden constructs ─────────────────────────────────────────────────────
// Each entry is a route to capability that needs no import at all, which is why
// the allowlist above is not sufficient on its own.
//
// `Qt.createQmlObject` deserves special mention: it takes QML source as a
// STRING, so a plugin could write `import Quickshell.Io; Process {}` inside a
// string literal and never trip the import scan. Any dynamic QML construction
// defeats a static scan by definition, so all of it is refused.
//
// `parent.parent` is object-graph walking. A plugin's root item is parented
// into the bar; from there, enough `.parent` hops reach the window, the shell
// root and every singleton anchored off it — with zero imports. A bare `parent`
// is left alone because `anchors.fill: parent` is how QML is written; it is the
// second hop that has no legitimate use in a leaf widget.
var FORBIDDEN_SOURCE = [
    { pattern: /\bXMLHttpRequest\b/,        name: "XMLHttpRequest" },
    { pattern: /\bQt\s*\.\s*createQmlObject\b/, name: "Qt.createQmlObject" },
    { pattern: /\bQt\s*\.\s*createComponent\b/, name: "Qt.createComponent" },
    { pattern: /\bQt\s*\.\s*openUrlExternally\b/, name: "Qt.openUrlExternally" },
    { pattern: /\bQt\s*\.\s*(exit|quit)\b/, name: "Qt.exit / Qt.quit" },
    { pattern: /\beval\s*\(/,               name: "eval()" },
    { pattern: /\bnew\s+Function\b/,        name: "new Function" },
    { pattern: /\bFunction\s*\(/,           name: "Function()" },
    { pattern: /\bLoader\b/,                name: "Loader" },
    { pattern: /\bparent\s*\.\s*parent\b/,  name: "parent.parent" }
];

// A plugin id becomes a path segment under ~/.config/apex-shell/plugins/, so it
// is validated as a charset BEFORE it is used to build one. Checking the id
// against its directory name is not enough on its own: the check would pass for
// a directory literally named "..", and then every later path join is a
// traversal. Lowercase, digits and dashes; must start alphanumeric.
var ID_RE = /^[a-z0-9][a-z0-9-]*$/;

// Semver-ish, for the plugin's OWN version. Not compared against anything by
// the host — it exists so a catalog and a human can tell two builds apart — so
// it is validated for shape only.
var VERSION_RE = /^[0-9]+\.[0-9]+(\.[0-9]+)?([-+][0-9A-Za-z.-]+)?$/;

var API_VERSION_RE = /^([0-9]+)\.([0-9]+)$/;

// A hostname in a `network` allowlist. No wildcards in apiVersion 1: "*.foo.com"
// looks like it means one thing and, depending on whose matcher reads it, means
// another. An explicit list of hosts is unambiguous and a plugin needing three
// hosts can name three.
var HOST_RE = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/;

function _refuse(reason, detail) {
    return { ok: false, reason: reason, detail: detail === undefined ? "" : detail };
}

function _has(list, v) {
    for (var i = 0; i < list.length; i++)
        if (list[i] === v) return true;
    return false;
}

// ── apiCompatible(want, have) ────────────────────────────────────────────────
// Both are "MAJOR.MINOR" strings. See the policy note on API_VERSION.
function apiCompatible(want, have) {
    var w = API_VERSION_RE.exec(String(want || ""));
    var h = API_VERSION_RE.exec(String(have || API_VERSION));
    if (!w || !h) return false;
    if (parseInt(w[1], 10) !== parseInt(h[1], 10)) return false;
    return parseInt(w[2], 10) <= parseInt(h[2], 10);
}

// ── validateManifest(raw, dirName, hostApiVersion) ───────────────────────────
// `raw` is the parsed plugin.json (or a string to parse). `dirName` is the
// directory basename it was found in.
//
// Returns either { ok: false, reason, detail } or a frozen-in-spirit grant
// object: { ok: true, id, name, version, apiVersion, entry, permissions,
// networkHosts, extensionPoint }. The grant is what the host consults later —
// nothing downstream re-reads plugin.json, so there is exactly one place where
// a manifest turns into authority.
function validateManifest(raw, dirName, hostApiVersion) {
    var m = raw;
    if (typeof raw === "string") {
        try { m = JSON.parse(raw); }
        catch (e) { return _refuse("manifest-unparseable", String(e)); }
    }
    if (!m || typeof m !== "object" || Array.isArray(m))
        return _refuse("manifest-not-object");

    // ── id ───────────────────────────────────────────────────────────────────
    if (typeof m.id !== "string" || m.id === "")
        return _refuse("missing-field", "id");
    if (!ID_RE.test(m.id))
        return _refuse("bad-id", m.id);
    if (dirName !== undefined && dirName !== null && String(dirName) !== m.id)
        return _refuse("id-directory-mismatch", m.id + " != " + dirName);

    // ── name ─────────────────────────────────────────────────────────────────
    // Shown to a human deciding whether to trust the thing, so it must exist
    // and must not be able to smuggle control characters into a list.
    if (typeof m.name !== "string" || m.name.trim() === "")
        return _refuse("missing-field", "name");
    if (m.name.length > 64 || /[\x00-\x1f\x7f]/.test(m.name))
        return _refuse("bad-name", m.name);

    // ── version ──────────────────────────────────────────────────────────────
    if (typeof m.version !== "string" || m.version === "")
        return _refuse("missing-field", "version");
    if (!VERSION_RE.test(m.version))
        return _refuse("bad-version", m.version);

    // ── apiVersion ───────────────────────────────────────────────────────────
    if (typeof m.apiVersion !== "string" || m.apiVersion === "")
        return _refuse("missing-field", "apiVersion");
    if (!API_VERSION_RE.test(m.apiVersion))
        return _refuse("bad-api-version", m.apiVersion);
    if (!apiCompatible(m.apiVersion, hostApiVersion || API_VERSION))
        return _refuse("api-version-unsupported",
                       m.apiVersion + " vs host " + (hostApiVersion || API_VERSION));

    // ── entry ────────────────────────────────────────────────────────────────
    // One .qml file, directly in the plugin directory. No subdirectory, because
    // "no subdirectory" is a rule a string check can actually enforce, whereas
    // "this relative path stays inside the plugin dir" invites symlink games.
    // The host additionally resolves the real path and re-checks containment;
    // this is the cheap half that runs first.
    if (typeof m.entry !== "string" || m.entry === "")
        return _refuse("missing-field", "entry");
    if (m.entry.indexOf("/") >= 0 || m.entry.indexOf("\\") >= 0)
        return _refuse("bad-entry", "entry must be a bare filename: " + m.entry);
    if (m.entry === "." || m.entry === ".." || m.entry.charAt(0) === ".")
        return _refuse("bad-entry", m.entry);
    if (!/^[A-Za-z][A-Za-z0-9_]*\.qml$/.test(m.entry))
        return _refuse("bad-entry", m.entry);

    // ── extensionPoint ───────────────────────────────────────────────────────
    if (typeof m.extensionPoint !== "string" || m.extensionPoint === "")
        return _refuse("missing-field", "extensionPoint");
    if (!_has(EXTENSION_POINTS, m.extensionPoint))
        return _refuse("unknown-extension-point", m.extensionPoint);

    // ── permissions ──────────────────────────────────────────────────────────
    // Absent means none. An explicit empty array means the same thing and is
    // the friendlier way to write it.
    var perms = [];
    if (m.permissions !== undefined && m.permissions !== null) {
        if (!Array.isArray(m.permissions))
            return _refuse("bad-permissions", "permissions must be an array");
        for (var i = 0; i < m.permissions.length; i++) {
            var p = m.permissions[i];
            if (typeof p !== "string")
                return _refuse("bad-permissions", "non-string entry");
            if (!_has(PERMISSIONS, p))
                return _refuse("unknown-permission", p);
            if (!_has(IMPLEMENTED_PERMISSIONS, p))
                return _refuse("permission-not-implemented", p);
            if (!_has(perms, p)) perms.push(p);
        }
    }

    // ── network hosts ────────────────────────────────────────────────────────
    // The roadmap's own examples are host-scoped — "Network: weather service
    // only", "Network: github.com" — so `network` alone grants nothing. A
    // plugin must name the hosts, and the grant is the intersection of "has the
    // permission" and "named this host".
    var hosts = [];
    if (m.network !== undefined && m.network !== null) {
        if (!Array.isArray(m.network))
            return _refuse("bad-network-hosts", "network must be an array of hostnames");
        for (var j = 0; j < m.network.length; j++) {
            var h = m.network[j];
            if (typeof h !== "string")
                return _refuse("bad-network-hosts", "non-string entry");
            var lower = h.toLowerCase();
            if (!HOST_RE.test(lower))
                return _refuse("bad-network-hosts", h);
            if (!_has(hosts, lower)) hosts.push(lower);
        }
    }
    if (_has(perms, "network") && hosts.length === 0)
        return _refuse("network-without-hosts",
                       "declare the hosts this plugin may reach");
    if (!_has(perms, "network") && hosts.length > 0)
        return _refuse("hosts-without-network",
                       "network hosts listed but the network permission was not declared");

    return {
        ok: true,
        id: m.id,
        name: m.name.trim(),
        version: m.version,
        apiVersion: m.apiVersion,
        entry: m.entry,
        extensionPoint: m.extensionPoint,
        permissions: perms,
        networkHosts: hosts,
        description: typeof m.description === "string" ? m.description.slice(0, 200) : ""
    };
}

// ── stripCommentLines(text) ──────────────────────────────────────────────────
// Removes lines whose first non-whitespace characters are `//`, and nothing
// else. The scan below would otherwise refuse a plugin for DOCUMENTING what
// plugins may not do — which is not hypothetical, it is how the reference
// plugin was written, and it is the same reason this repo's existing CI checks
// pipe through `grep -vE '^[^:]+:[0-9]+:[[:space:]]*//'`.
//
// ── Why only whole lines ─────────────────────────────────────────────────────
// The obvious implementation — strip from every `//` to end of line — is a
// BYPASS, and a subtle one. Consider:
//
//     property string u: "a//b"; property var z: eval("…")
//
// The `//` inside that string literal is not a comment. A stripper that treats
// it as one deletes the rest of the line, and `eval` vanishes from the text the
// scan reads while remaining very much present in the file QML executes. The
// same trap swallows block comments, template literals and regex literals; a
// correct version needs a real tokeniser, and a not-quite-correct tokeniser
// hands an attacker a way to hide any construct on this list.
//
// A whole-line rule needs no tokeniser and cannot go wrong in that direction.
// A line whose first non-whitespace is `//` is either a comment or the interior
// of a multi-line template literal. Neither one executes, so removing it can
// never hide code — the worst case is that a forbidden word inside a string
// stops being flagged, and a word inside a string is not a call.
//
// The cost is a rule plugin authors have to know: prose mentioning a forbidden
// construct belongs on its own comment line, not trailing after code and not in
// a /* block */. docs/plugins.md says so. That is a small price for a scan with
// no hole in it, and erring toward refusing a legitimate plugin is the right
// direction for this particular check to be wrong in.
function stripCommentLines(text) {
    var lines = String(text || "").split("\n");
    var out = [];
    for (var i = 0; i < lines.length; i++) {
        var t = lines[i].replace(/^[ \t]+/, "");
        if (t.slice(0, 2) === "//") {
            out.push("");   // keep the line count, so any future line-numbered
            continue;       // diagnostic still points at the right place
        }
        out.push(lines[i]);
    }
    return out.join("\n");
}

// ── scanSource(text) ─────────────────────────────────────────────────────────
// The load-time check that defends the API's monopoly. Returns
// { ok: true } or { ok: false, reason, detail }.
//
// Re-read the header before trusting this further than it goes: it stops a
// plugin from casually reaching past the API, not a plugin written to beat it.
function scanSource(text) {
    var raw = String(text === undefined || text === null ? "" : text);
    if (raw.trim() === "")
        return _refuse("empty-source");

    var src = stripCommentLines(raw);

    // Imports. QML allows leading whitespace, a version, and an `as` qualifier;
    // the module is the first token after `import`.
    var importRe = /^[ \t]*import[ \t]+(\S+)/gm;
    var mm;
    while ((mm = importRe.exec(src)) !== null) {
        var mod = mm[1];
        // A quoted import is a path — a sibling .qml, a .js, a directory. All
        // refused: see "Why single-file plugins" in the header.
        if (mod.charAt(0) === '"' || mod.charAt(0) === "'")
            return _refuse("relative-import", mod);
        if (!_has(ALLOWED_IMPORTS, mod))
            return _refuse("forbidden-import", mod);
    }

    for (var i = 0; i < FORBIDDEN_SOURCE.length; i++) {
        if (FORBIDDEN_SOURCE[i].pattern.test(src))
            return _refuse("forbidden-construct", FORBIDDEN_SOURCE[i].name);
    }

    return { ok: true, reason: "", detail: "" };
}

// ── parseUrl(u) ──────────────────────────────────────────────────────────────
// Deliberately hand-rolled. The QML engine has no `URL` class, and a matcher
// that behaves differently in Node and in the shell is a matcher whose tests
// mean nothing.
function parseUrl(u) {
    if (typeof u !== "string" || u === "") return null;
    if (u.length > 2000) return null;
    // Control characters and whitespace anywhere in a URL are a smuggling
    // attempt, not a typo.
    if (/[\x00-\x20\x7f]/.test(u)) return null;

    var m = /^([A-Za-z][A-Za-z0-9+.\-]*):\/\/([^/?#]*)([^?#]*)((?:\?[^#]*)?)((?:#.*)?)$/.exec(u);
    if (!m) return null;

    return {
        scheme: m[1].toLowerCase(),
        authority: m[2],
        path: m[3] === "" ? "/" : m[3]
    };
}

// ── permitsUrl(grant, url) ───────────────────────────────────────────────────
// The gate. `grant` is a validateManifest() result. Returns
// { ok: true, host } or { ok: false, reason, detail }.
//
// Every clause here is a mistake someone has shipped in a URL allowlist:
//
//   * suffix matching, so "api.github.com.evil.com" passes a check for
//     "api.github.com". The host is compared with `===`, never with endsWith.
//   * matching against the whole URL rather than the parsed host, so
//     "https://evil.com/?x=api.github.com" passes.
//   * userinfo, where "https://api.github.com@evil.com/" reads to a human as
//     one host and to a resolver as another. Refused outright.
//   * case, where "API.GitHub.com" misses a lowercase allowlist.
//   * scheme, where http:// is accepted and the whole thing is observable and
//     rewritable in transit anyway.
//
// The sixth — redirects — cannot be fixed here, because it happens after this
// function has said yes. It is fixed in curlArgv(). See the note there.
function permitsUrl(grant, url) {
    if (!grant || grant.ok !== true)
        return _refuse("no-grant");
    if (!_has(grant.permissions || [], "network"))
        return _refuse("permission-denied", "network");

    var p = parseUrl(url);
    if (!p) return _refuse("bad-url", String(url).slice(0, 80));

    if (p.scheme !== "https")
        return _refuse("scheme-denied", p.scheme);

    if (p.authority.indexOf("@") >= 0)
        return _refuse("userinfo-denied", p.authority);

    var host = p.authority;
    var port = "";
    var colon = host.lastIndexOf(":");
    if (colon >= 0) {
        port = host.slice(colon + 1);
        host = host.slice(0, colon);
    }
    // An IPv6 literal has no business in a plugin allowlist and its bracket
    // syntax makes the colon split above wrong; refuse rather than special-case.
    if (host.indexOf("[") >= 0 || host.indexOf("]") >= 0)
        return _refuse("bad-url", p.authority);
    if (port !== "" && port !== "443")
        return _refuse("port-denied", port);

    host = host.toLowerCase();
    if (host === "") return _refuse("bad-url", p.authority);

    if (!_has(grant.networkHosts || [], host))
        return _refuse("host-denied", host);

    return { ok: true, host: host, reason: "", detail: "" };
}

// ── validId(id) ──────────────────────────────────────────────────────────────
// The id charset check on its own, for the ONE caller that needs it before a
// manifest exists: directory enumeration. PluginService reads a directory
// listing off the filesystem and has to build "<dir>/<id>/plugin.json" before
// it can validate anything, so the name it interpolates is checked first.
// Checking the id against the directory name later does not help — that check
// would happily pass for a directory literally named "..".
function validId(id) {
    return typeof id === "string" && ID_RE.test(id);
}

// ── permitsPath(grant, name) ─────────────────────────────────────────────────
// The `files` gate. Returns { ok: true, name } or a refusal.
//
// apiVersion 1's `files` permission is READ-ONLY access to the plugin's OWN
// directory, and nothing else. Two deliberate limits:
//
//   * Own directory only. "Read any file the shell can read" is the version of
//     this permission that would be genuinely useful and genuinely dangerous,
//     and there is no UI in this shell for a user to scope it to something
//     narrower. An unscopeable grant is not a permission.
//
//   * READ-only, and this one is not a comfort choice. The plugin directory is
//     where the plugin's own source lives. A plugin that could write there
//     could pass the load-time source scan and then rewrite its entry .qml for
//     the next start — the scan would be checking a file the plugin controls
//     between checks. Classic time-of-check/time-of-use, and it would quietly
//     void the one thing the scan is for. Writable per-plugin storage needs a
//     data directory separate from the code directory; that is a v2 concern.
//
// `name` is a relative path under the plugin directory. No leading separator,
// no "..", no component beginning with a dot — the last of those is what stops
// a plugin reading a ".git" or an editor backup someone left in the folder.
function permitsPath(grant, name) {
    if (!grant || grant.ok !== true)
        return _refuse("no-grant");
    if (!_has(grant.permissions || [], "files"))
        return _refuse("permission-denied", "files");
    if (typeof name !== "string" || name === "")
        return _refuse("bad-path", String(name).slice(0, 80));
    if (name.length > 255)
        return _refuse("bad-path", "too long");
    if (/[\x00-\x1f\x7f]/.test(name))
        return _refuse("bad-path", "control characters");
    if (name.charAt(0) === "/" || name.indexOf("\\") >= 0)
        return _refuse("bad-path", name);

    var parts = name.split("/");
    for (var i = 0; i < parts.length; i++) {
        if (parts[i] === "" || parts[i].charAt(0) === ".")
            return _refuse("bad-path", name);
    }
    return { ok: true, name: name, reason: "", detail: "" };
}

// ─────────────────────────────────────────────────────────────────────────────
// PLUGIN OUTPUT
//
// Everything above decides what a plugin may DO. The rest of this file decides
// what of a plugin's output the shell will RENDER, which is a separate question
// and it only exists because of the second and third extension points.
//
// `bar-widget` needs none of this: the plugin owns its rectangle and paints it.
// A launcher provider and a quick-settings tile hand back data that the shell
// draws in its own chrome, so the shell is putting third-party strings on
// screen under its own name. Three things follow, and all three are enforced
// here rather than in the hosts:
//
//   1. A fresh object, built from an allowlist. Never the plugin's object with
//      the bad keys deleted. See the note on EXTENSION_POINTS: the launcher
//      dispatches on `entry` and `exec`, so a row that carried either would be
//      arbitrary execution handed to a plugin that declared no permissions.
//      An allowlist cannot fall behind a launcher that learns a new row shape.
//
//   2. Control characters stripped from every string. A newline in a launcher
//      row draws over two lines and can impersonate the row beneath it; a
//      carriage return can blank what precedes it. `validateManifest` already
//      refuses these in `name` for the same reason, and there they are a
//      refusal because a manifest is read once. Here they are stripped, because
//      this runs on every keystroke and refusing a whole plugin over one stray
//      byte in one row is the wrong response.
//
//   3. Lengths capped. The launcher elides and the tile clips, so a long
//      string is a layout problem rather than a security one — but a plugin
//      returning a megabyte per row on every keystroke is a denial of service
//      against the shell's own main loop, and that is cheaper to prevent than
//      to diagnose.
//
// None of these functions return a refusal object and none of them throw. They
// run on the render path; the failure mode has to be "that row is not shown",
// never "the launcher stopped working". A plugin that hands back garbage gets
// silence.
// ─────────────────────────────────────────────────────────────────────────────

// Rows one provider may contribute to a single query. Providers append BELOW
// the app results — see launcherWantsProviders() — so this is not about
// crowding out the shell, it is about a ranked list staying a ranked list. Five
// is enough to be useful and short enough that two providers plus the apps
// still fit on one screen.
//
// There is deliberately no equivalent cap on quick-settings tiles. That grid
// scrolls and the shell's own tiles are unconditionally first, so a tile from
// the twelfth plugin is merely far down a scroll; a row from the twelfth
// provider would be competing for a position in a list the user is scanning by
// rank. Different failure, different answer.
var MAX_LAUNCHER_RESULTS = 5;

// Below this, a query is too broad to be worth asking a provider about: on one
// character nearly every provider matches nearly everything, and the rows are
// noise over the app the user is three keystrokes from selecting.
var MIN_PROVIDER_QUERY = 2;

var MAX_ROW_TITLE  = 120;
var MAX_ROW_DETAIL = 120;
var MAX_TILE_LABEL = 24;
var MAX_TILE_SUB   = 32;

// A tile's icon is a glyph — the quick-settings grid renders Nerd Font
// characters as Text. Four UTF-16 units covers any single glyph including
// surrogate pairs and a variation selector, and stops a plugin passing a
// paragraph where an icon goes.
var MAX_TILE_ICON = 4;

// A launcher row's icon is an XDG ICON NAME and never a path.
//
// This is the one rule here that is about capability rather than layout. The
// launcher's delegate turns a leading "/" into "file://" + the value and hands
// it to an Image. A plugin-supplied path would therefore have the shell attempt
// to decode an arbitrary file as an image, and Image.status coming back Ready
// or Error is a readable signal — a file-existence oracle over the whole
// filesystem, for a plugin holding no `files` permission at all. Names only,
// no slashes, and anything that does not match becomes "".
var ICON_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._+-]*$/;

// Coerce to a displayable string: control characters removed, whitespace
// collapsed and trimmed, capped. Not a validator — it always returns a string,
// possibly "", and the callers decide whether "" means "drop this".
function _plain(v, max) {
    if (typeof v !== "string") return "";
    var s = v.replace(/[\x00-\x1f\x7f]/g, "");
    s = s.replace(/[ \t]+/g, " ").replace(/^ +| +$/g, "");
    if (s.length > max) s = s.slice(0, max);
    return s;
}

// ── launcherWantsProviders(query) ────────────────────────────────────────────
// Whether the launcher should consult its provider plugins for this query at
// all. Lives here, not in the launcher, so it is asserted headlessly — the
// alternative is a condition inside a QML binding that only a compositor can
// evaluate, and this repo's behavioural suite skips on every CI runner.
//
// The "?" clause is the load-bearing one. A query starting with "?" is an
// ANSWER query: AppLauncher returns answerRows() and nothing else, so a
// provider row appearing there would not merely be noise, it would be a
// third-party string sitting where the calculator's answer goes.
function launcherWantsProviders(query) {
    if (typeof query !== "string") return false;
    var q = query.replace(/^[ \t]+|[ \t]+$/g, "");
    if (q === "") return false;
    if (q.charAt(0) === "?") return false;
    return q.length >= MIN_PROVIDER_QUERY;
}

// ── launcherResults(grant, raw) ──────────────────────────────────────────────
// `grant` is a validateManifest() result; `raw` is whatever the plugin item has
// on its `results` property. Returns an array of rows the launcher may render,
// possibly empty.
//
// Each row is a NEW object carrying exactly:
//
//   kind      always "plugin". Set here, never by the plugin — it is what the
//             launcher dispatches on, so a plugin choosing its own would be
//             choosing which branch of activate() runs.
//   pluginId  from the grant.
//   name      the row's title, AND its payload. There is no separate value
//             field, deliberately: activation copies the title, so what the
//             user sees is what they get. A row that displayed one string and
//             copied another would be a clipboard-hijack primitive with a user
//             gesture already attached to it.
//   detail    the second line. The plugin's own subtitle if it gave one, and in
//             every case ending in the plugin's NAME FROM THE GRANT, so a row
//             always says where it came from and a plugin cannot claim to be
//             the shell. Composed here rather than in the delegate so the
//             composition is asserted rather than eyeballed.
//   icon      an XDG icon name or "". See ICON_NAME_RE.
//   index     the row's position in the plugin's own array, so the host can
//             tell the plugin which row was activated without handing back an
//             object the plugin could have swapped underneath it.
function launcherResults(grant, raw) {
    if (!grant || grant.ok !== true) return [];
    if (grant.extensionPoint !== "launcher-provider") return [];
    if (!raw || !Array.isArray(raw)) return [];

    var source = _plain(grant.name, 40);
    var out = [];
    for (var i = 0; i < raw.length && out.length < MAX_LAUNCHER_RESULTS; i++) {
        var r = raw[i];
        if (!r || typeof r !== "object" || Array.isArray(r)) continue;

        var title = _plain(r.title, MAX_ROW_TITLE);
        if (title === "") continue;     // a row with no visible text is not a row

        var sub  = _plain(r.subtitle, MAX_ROW_DETAIL);
        var icon = _plain(r.icon, 64);
        if (!ICON_NAME_RE.test(icon)) icon = "";

        out.push({
            kind:     "plugin",
            pluginId: grant.id,
            name:     title,
            detail:   sub === "" ? source : sub + " · " + source,
            icon:     icon,
            index:    i
        });
    }
    return out;
}

// ── quickTile(grant, raw) ────────────────────────────────────────────────────
// `raw` is the plugin item itself — the host reads `on`, `icon`, `label` and
// `sublabel` off it. Returns a tile descriptor the quick-settings grid may
// draw, or null.
//
// A tile plugin never paints. It holds a state and the shell renders the
// shell's own tile around it, which is a tighter boundary than bar-widget's:
// a plugin cannot draw something that looks like the Wi-Fi toggle, cannot
// cover the grid, and cannot animate. What it can do is say "I am on", put a
// glyph and a label on the tile, and be told when it was clicked.
//
// ── What a tile cannot do, and why that is not a gap ─────────────────────────
// It cannot flip a system switch. Not Wi-Fi, not Bluetooth, not brightness,
// not a power profile. Every one of those is a command, and "run a command" is
// the `system` permission, which is refused at load — see IMPLEMENTED_
// PERMISSIONS above for why granting it would make `network` and `files`
// decorative. So a plugin tile surfaces information and takes actions inside
// its own grants, and the honest description of the point is that: not "plugins
// can add quick settings", but "plugins can add a tile".
//
// `on` is compared with `=== true` rather than coerced. A plugin declaring
// `property bool on` hands over a real boolean and this is a no-op; a plugin
// declaring `property var on: "false"` would otherwise light the tile up,
// because Boolean("false") is true. Truthiness is the wrong tool where the
// value decides what a user is being shown about their own machine.
function quickTile(grant, raw) {
    if (!grant || grant.ok !== true) return null;
    if (grant.extensionPoint !== "quick-settings-tile") return null;
    if (!raw || typeof raw !== "object") return null;

    var label = _plain(raw.label, MAX_TILE_LABEL);
    if (label === "") label = _plain(grant.name, MAX_TILE_LABEL);
    if (label === "") return null;

    return {
        pluginId: grant.id,
        on:       raw.on === true,
        icon:     _plain(raw.icon, MAX_TILE_ICON),
        label:    label,
        sublabel: _plain(raw.sublabel, MAX_TILE_SUB)
    };
}

// ── curlArgv(url) ────────────────────────────────────────────────────────────
// How the HOST fetches an approved URL. The plugin never sees this and never
// spawns anything; it calls api.net.get() and the shell does the work.
//
// Three properties of this argv are load-bearing, and two of them are the kind
// that get "simplified" away by someone who does not know why they are there:
//
//   1. NO -L / --location, and --max-redirs 0. permitsUrl() checked the URL the
//      plugin asked for. If curl were allowed to follow a redirect, an approved
//      host could bounce the request to any host on the internet and the
//      allowlist would be decorative. This is the single easiest way to defeat
//      a URL allowlist and it is invisible in testing, because the redirect is
//      the server's choice and only a hostile server takes it.
//   2. --proto =https, so even a redirect that somehow happened could not
//      downgrade to http or slip into file:// or scp://.
//   3. --url, not a bare positional. A URL beginning with "-" would otherwise
//      be read by curl as a flag. permitsUrl() rejects those already; this is
//      the second lock on the same door.
//
// It is an ARRAY, and every caller must keep it one. The shell has an existing
// CI invariant about not splicing model data into a "bash -c" string — same
// bug, and here the data is a URL chosen by third-party code.
function curlArgv(url) {
    return [
        "curl",
        "--silent", "--show-error", "--fail",
        "--proto", "=https",
        "--max-redirs", "0",
        "--max-time", "15",
        "--max-filesize", "1048576",
        "--url", String(url)
    ];
}

// ── describeRefusal(r) ───────────────────────────────────────────────────────
// A refusal reason is a machine-readable code so tests can assert on it without
// matching English. This turns one into a line for the plugin list in Settings.
function describeRefusal(r) {
    if (!r || r.ok === true) return "";
    var d = r.detail ? " (" + r.detail + ")" : "";
    switch (r.reason) {
    case "manifest-unparseable":      return "plugin.json is not valid JSON" + d;
    case "manifest-not-object":       return "plugin.json is not a JSON object";
    case "missing-field":             return "plugin.json is missing a required field" + d;
    case "bad-id":                    return "the plugin id is not a valid identifier" + d;
    case "id-directory-mismatch":     return "the plugin id does not match its directory" + d;
    case "bad-name":                  return "the plugin name is unusable" + d;
    case "bad-version":               return "the plugin version is not a version" + d;
    case "bad-api-version":           return "apiVersion must look like \"1.0\"" + d;
    case "api-version-unsupported":   return "built for a different plugin API" + d;
    case "bad-entry":                 return "entry must be one .qml file in the plugin directory" + d;
    case "unknown-extension-point":   return "unknown extension point" + d;
    case "bad-permissions":           return "permissions must be a list of names" + d;
    case "unknown-permission":        return "not a permission this shell knows" + d;
    case "permission-not-implemented":return "this shell cannot enforce that permission yet, so it will not grant it" + d;
    case "bad-network-hosts":         return "network hosts must be plain hostnames" + d;
    case "network-without-hosts":     return "the network permission needs an explicit host list";
    case "hosts-without-network":     return "network hosts listed without the network permission";
    case "empty-source":              return "the entry file is empty";
    case "relative-import":           return "plugins may not import other files" + d;
    case "forbidden-import":          return "import not allowed for plugins" + d;
    case "forbidden-construct":       return "uses something plugins may not use" + d;
    case "extra-qml":                 return "a plugin is one .qml file" + d;
    case "entry-missing":             return "the entry file does not exist" + d;
    case "entry-outside-plugin":      return "the entry file resolves outside the plugin directory" + d;
    case "load-error":                return "the plugin failed to load" + d;
    case "no-grant":                  return "the plugin was never granted anything";
    case "permission-denied":         return "the plugin did not declare that permission" + d;
    case "bad-url":                   return "not a usable URL" + d;
    case "scheme-denied":             return "only https is allowed" + d;
    case "userinfo-denied":           return "URLs with credentials are refused" + d;
    case "port-denied":               return "only port 443 is allowed" + d;
    case "host-denied":               return "host is not in the plugin's declared list" + d;
    case "bad-path":                  return "not a path inside the plugin's own directory" + d;
    default:                          return r.reason + d;
    }
}

// Node (tests) sees `module`; the QML engine does not, and ignores this.
// Same arrangement as answer.js.
if (typeof module !== "undefined" && module.exports)
    module.exports = {
        API_VERSION: API_VERSION,
        PERMISSIONS: PERMISSIONS,
        IMPLEMENTED_PERMISSIONS: IMPLEMENTED_PERMISSIONS,
        EXTENSION_POINTS: EXTENSION_POINTS,
        ALLOWED_IMPORTS: ALLOWED_IMPORTS,
        MAX_LAUNCHER_RESULTS: MAX_LAUNCHER_RESULTS,
        MIN_PROVIDER_QUERY: MIN_PROVIDER_QUERY,
        launcherWantsProviders: launcherWantsProviders,
        launcherResults: launcherResults,
        quickTile: quickTile,
        validateManifest: validateManifest,
        apiCompatible: apiCompatible,
        scanSource: scanSource,
        parseUrl: parseUrl,
        permitsUrl: permitsUrl,
        permitsPath: permitsPath,
        validId: validId,
        curlArgv: curlArgv,
        stripCommentLines: stripCommentLines,
        describeRefusal: describeRefusal
    };
