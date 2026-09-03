// ─────────────────────────────────────────────────────────────────────────────
// The APEX Shell plugin platform's decision logic (roadmap §16).
//
// Everything in this file answers one of four questions and nothing else:
//
//   validateManifest()  is this plugin.json loadable, and what did it ask for?
//   scanSource()        does this QML file stay inside the sanctioned API?
//   permitsUrl()        may this plugin fetch this URL?
//   curlArgv()          exactly how does the HOST fetch it?
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
var API_VERSION = "1.0";

// The closed permission vocabulary, straight from the roadmap: "Plugin
// permissions for filesystem, network, location, system controls and secrets."
var PERMISSIONS = ["network", "files", "system", "secrets", "location"];

// Of those, the ones apiVersion 1 can actually ENFORCE. The gap is deliberate
// and it is the reason this list is separate from the one above.
//
// `secrets` would need a broker holding credentials the plugin never sees —
// there is no secret store in the shell to broker. `location` would need a
// geolocation source and a user-facing precision control ("approximate", per
// the roadmap's weather example); the shell has neither.
//
// Shipping either as a manifest field that grants nothing would be a decorative
// permission: it would read, to a plugin author and to a user reviewing what a
// plugin asked for, as a capability that was reviewed and granted. So a
// manifest that declares one is REFUSED, with a reason that names it. The
// vocabulary keeps the word so that a later apiVersion can implement it without
// renaming anything.
var IMPLEMENTED_PERMISSIONS = ["network", "files", "system"];

// Extension points. Exactly one is real in apiVersion 1 — see the §16 notes in
// docs/plugins.md for why one end-to-end beats five stubs.
var EXTENSION_POINTS = ["bar-widget"];

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

// ── scanSource(text) ─────────────────────────────────────────────────────────
// The load-time check that defends the API's monopoly. Returns
// { ok: true } or { ok: false, reason, detail }.
//
// Re-read the header before trusting this further than it goes: it stops a
// plugin from casually reaching past the API, not a plugin written to beat it.
function scanSource(text) {
    var src = String(text === undefined || text === null ? "" : text);
    if (src.trim() === "")
        return _refuse("empty-source");

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
        validateManifest: validateManifest,
        apiCompatible: apiCompatible,
        scanSource: scanSource,
        parseUrl: parseUrl,
        permitsUrl: permitsUrl,
        curlArgv: curlArgv,
        describeRefusal: describeRefusal
    };
