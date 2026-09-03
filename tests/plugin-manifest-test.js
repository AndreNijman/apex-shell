#!/usr/bin/env node
// Exercises the plugin platform's decision logic (roadmap §16) against the file
// the shell actually loads — src/services/plugins/manifest.js, not a copy.
//
//   node tests/plugin-manifest-test.js
//
// ── Why this suite carries the weight ────────────────────────────────────────
// The behavioural half (tests/run-plugin-host-test.sh) needs a Wayland session
// and skips on CI, because no runner has a compositor. This repo has already
// shipped assertions that passed because they never ran, three separate times.
// So everything security-critical about §16 — manifest validation, the API
// version policy, the source scan, and above all the network host allowlist —
// is decided in plain JavaScript and asserted here, where it runs on every
// push with nothing to skip.
//
// The URL section is the important one. Every case in it is a shape that has
// defeated a real allowlist somewhere: suffix matching, matching the whole URL
// instead of the parsed host, userinfo confusion, case, scheme downgrade, and
// redirects. If you are editing permitsUrl() or curlArgv(), these are the
// assertions that decide whether the permission model is real or decorative.

"use strict";

const path = require("path");
const M = require(path.join(__dirname, "..", "src", "services", "plugins", "manifest.js"));

let failed = 0;
let passed = 0;
function check(name, got, want) {
    const ok = JSON.stringify(got) === JSON.stringify(want);
    if (!ok) {
        failed++;
        console.error(`FAIL ${name}\n  got:  ${JSON.stringify(got)}\n  want: ${JSON.stringify(want)}`);
    } else {
        passed++;
        console.log(`ok   ${name}`);
    }
}

// A manifest that is valid in every respect, so each test below can change
// exactly one thing and attribute the refusal to that change.
const base = {
    id: "apex-sysmon",
    name: "System Monitor",
    version: "1.0.0",
    apiVersion: "1.0",
    entry: "Widget.qml",
    extensionPoint: "bar-widget",
    permissions: []
};
const withBase = (over) => Object.assign({}, base, over);

// Refusal reason for a manifest, or "ok".
const why = (over, dir) => {
    const r = M.validateManifest(withBase(over), dir === undefined ? "apex-sysmon" : dir);
    return r.ok ? "ok" : r.reason;
};

// ── The happy path ───────────────────────────────────────────────────────────
console.log("\n── manifest: accepted ──");
check("a complete manifest validates", why({}), "ok");
check("permissions may be omitted entirely",
      M.validateManifest({ id: "a", name: "A", version: "1.0", apiVersion: "1.0",
                           entry: "W.qml", extensionPoint: "bar-widget" }, "a").ok, true);
check("the grant carries the declared permissions",
      M.validateManifest(withBase({ permissions: ["network", "files"],
                                    network: ["api.github.com"] }), "apex-sysmon").permissions,
      ["network", "files"]);
check("duplicate permissions collapse",
      M.validateManifest(withBase({ permissions: ["files", "files"] }), "apex-sysmon").permissions,
      ["files"]);

// ── Required fields ──────────────────────────────────────────────────────────
console.log("\n── manifest: required fields ──");
for (const f of ["id", "name", "version", "apiVersion", "entry", "extensionPoint"]) {
    const over = {}; over[f] = undefined;
    check(`${f} is required`, why(over), "missing-field");
}
check("a non-object manifest is refused", M.validateManifest([], "a").reason, "manifest-not-object");
check("null is refused", M.validateManifest(null, "a").reason, "manifest-not-object");
check("malformed JSON is refused", M.validateManifest("{nope", "a").reason, "manifest-unparseable");
check("a JSON string parses", M.validateManifest(JSON.stringify(base), "apex-sysmon").ok, true);

// ── id: it becomes a path segment ────────────────────────────────────────────
console.log("\n── manifest: id ──");
check("id must match its directory",     why({}, "somewhere-else"), "id-directory-mismatch");
check("uppercase id refused",            why({ id: "Apex" }, "Apex"), "bad-id");
check("id with a slash refused",         why({ id: "a/b" }, "a/b"), "bad-id");
check("id of .. refused",                why({ id: ".." }, ".."), "bad-id");
check("id starting with a dash refused", why({ id: "-x" }, "-x"), "bad-id");
check("id with a dot refused",           why({ id: "a.b" }, "a.b"), "bad-id");
check("id with a space refused",         why({ id: "a b" }, "a b"), "bad-id");
check("dashes inside an id are fine",    why({ id: "apex-sys-mon" }, "apex-sys-mon"), "ok");

// ── apiVersion: the compatibility policy ─────────────────────────────────────
console.log("\n── manifest: apiVersion policy ──");
check("same version loads",            M.apiCompatible("1.0", "1.0"), true);
check("older minor loads on newer host", M.apiCompatible("1.0", "1.4"), true);
check("newer minor refused on older host", M.apiCompatible("1.5", "1.0"), false);
check("different major refused",       M.apiCompatible("2.0", "1.0"), false);
check("older major refused too",       M.apiCompatible("0.9", "1.0"), false);
check("non-numeric refused",           M.apiCompatible("one.oh", "1.0"), false);
check("three components refused",      M.apiCompatible("1.0.0", "1.0"), false);
check("empty refused",                 M.apiCompatible("", "1.0"), false);
check("a forward-dated plugin is refused", why({ apiVersion: "1.9" }), "api-version-unsupported");
check("a next-major plugin is refused",    why({ apiVersion: "2.0" }), "api-version-unsupported");
check("a malformed apiVersion is refused", why({ apiVersion: "1" }), "bad-api-version");

// ── entry: one qml file, in the plugin directory ─────────────────────────────
console.log("\n── manifest: entry ──");
check("a bare filename is fine",     why({ entry: "Widget.qml" }), "ok");
check("a subdirectory is refused",   why({ entry: "ui/Widget.qml" }), "bad-entry");
check("an absolute path is refused", why({ entry: "/etc/passwd" }), "bad-entry");
check("traversal is refused",        why({ entry: "../../shell.qml" }), "bad-entry");
check("a backslash is refused",      why({ entry: "ui\\Widget.qml" }), "bad-entry");
check("a dotfile is refused",        why({ entry: ".Widget.qml" }), "bad-entry");
check("a non-qml entry is refused",  why({ entry: "widget.js" }), "bad-entry");
check("a bare .qml is refused",      why({ entry: ".qml" }), "bad-entry");

// ── permissions: the closed set, and the unimplemented half ──────────────────
console.log("\n── manifest: permissions ──");
check("an unknown permission is refused", why({ permissions: ["gpu"] }), "unknown-permission");
check("permissions must be an array",     why({ permissions: "network" }), "bad-permissions");
check("a non-string entry is refused",    why({ permissions: [7] }), "bad-permissions");
check("files is granted", why({ permissions: ["files"] }), "ok");
// The whole point of IMPLEMENTED_PERMISSIONS: these three are in the roadmap's
// vocabulary but this shell cannot enforce them, so it refuses rather than
// granting a permission that does nothing.
//
// `system` is the one to think about before "fixing" it. A permission meaning
// "run a command" subsumes every other permission — a plugin holding it can
// curl anything and read any file — so granting it would make the network and
// files gates decorative. It stays refused until there is an enumerable set of
// system actions to expose instead of a general escape hatch.
for (const p of ["system", "secrets", "location"]) {
    check(`${p} is refused as unimplemented`,
          why({ permissions: [p] }), "permission-not-implemented");
    check(`${p} is still in the vocabulary`, M.PERMISSIONS.includes(p), true);
    check(`${p} is not implemented`, M.IMPLEMENTED_PERMISSIONS.includes(p), false);
}
check("exactly two permissions are enforceable today",
      M.IMPLEMENTED_PERMISSIONS, ["network", "files"]);
check("every implemented permission is in the vocabulary",
      M.IMPLEMENTED_PERMISSIONS.every((p) => M.PERMISSIONS.includes(p)), true);

// ── network: the permission is host-scoped ───────────────────────────────────
console.log("\n── manifest: network hosts ──");
check("network without hosts is refused",
      why({ permissions: ["network"] }), "network-without-hosts");
check("hosts without the permission are refused",
      why({ network: ["api.github.com"] }), "hosts-without-network");
check("network with hosts validates",
      why({ permissions: ["network"], network: ["api.github.com"] }), "ok");
check("hosts are lowercased into the grant",
      M.validateManifest(withBase({ permissions: ["network"], network: ["API.GitHub.com"] }),
                         "apex-sysmon").networkHosts,
      ["api.github.com"]);
check("a wildcard host is refused",
      why({ permissions: ["network"], network: ["*.github.com"] }), "bad-network-hosts");
check("a URL where a host belongs is refused",
      why({ permissions: ["network"], network: ["https://api.github.com/"] }), "bad-network-hosts");
check("a bare label is refused",
      why({ permissions: ["network"], network: ["localhost"] }), "bad-network-hosts");
check("extensionPoint must be known",
      why({ extensionPoint: "quick-setting" }), "unknown-extension-point");
check("exactly one extension point is implemented", M.EXTENSION_POINTS, ["bar-widget"]);

// ── scanSource: the API's monopoly ───────────────────────────────────────────
console.log("\n── source scan ──");
const scan = (src) => { const r = M.scanSource(src); return r.ok ? "ok" : r.reason; };
const widget = 'import QtQuick\nItem { Text { text: "hi" } }\n';

check("a plain QtQuick widget passes", scan(widget), "ok");
check("the allowed layout import passes",
      scan('import QtQuick\nimport QtQuick.Layouts\nItem {}'), "ok");
check("an empty file is refused", scan(""), "empty-source");

check("Quickshell.Io is refused",       scan('import Quickshell.Io\nItem {}'), "forbidden-import");
check("Quickshell itself is refused",   scan('import Quickshell\nItem {}'), "forbidden-import");
check("an indented import is still seen",
      scan('   import Quickshell.Io\nItem {}'), "forbidden-import");
check("a versioned forbidden import is seen",
      scan('import Quickshell.Io 1.0\nItem {}'), "forbidden-import");
check("an aliased forbidden import is seen",
      scan('import Quickshell.Io as Io\nItem {}'), "forbidden-import");
check("a relative import is refused",   scan('import "../../"\nItem {}'), "relative-import");
check("a sibling js import is refused", scan("import 'helper.js' as H\nItem {}"), "relative-import");

check("XMLHttpRequest is refused",
      scan('import QtQuick\nItem { Component.onCompleted: new XMLHttpRequest() }'),
      "forbidden-construct");
check("Qt.createQmlObject is refused",
      scan('import QtQuick\nItem { Component.onCompleted: Qt.createQmlObject("x", this) }'),
      "forbidden-construct");
check("spaced Qt . createQmlObject is refused",
      scan('import QtQuick\nItem { Component.onCompleted: Qt . createQmlObject("x", this) }'),
      "forbidden-construct");
check("Qt.createComponent is refused",
      scan('import QtQuick\nItem { Component.onCompleted: Qt.createComponent("x") }'),
      "forbidden-construct");
check("Qt.openUrlExternally is refused",
      scan('import QtQuick\nItem { Component.onCompleted: Qt.openUrlExternally("http://x") }'),
      "forbidden-construct");
check("Qt.quit is refused",
      scan('import QtQuick\nItem { Component.onCompleted: Qt.quit() }'), "forbidden-construct");
check("eval is refused",
      scan('import QtQuick\nItem { Component.onCompleted: eval("1") }'), "forbidden-construct");
check("new Function is refused",
      scan('import QtQuick\nItem { Component.onCompleted: new Function("return 1") }'),
      "forbidden-construct");
check("Loader is refused",
      scan('import QtQuick\nItem { Loader { source: "x.qml" } }'), "forbidden-construct");
check("parent.parent walking is refused",
      scan('import QtQuick\nItem { Component.onCompleted: { var r = parent.parent } }'),
      "forbidden-construct");
// A bare `parent` is how anchors are written; refusing it would refuse every
// legitimate widget, and the second hop is the one with no honest use.
check("a bare parent is allowed",
      scan('import QtQuick\nItem { anchors.fill: parent }'), "ok");

// ── comment handling, and the bypass it must not become ──────────────────────
console.log("\n── comment lines ──");
// A plugin must be able to DOCUMENT what plugins may not do. The reference
// plugin does exactly that, and an earlier version of the scan refused it for
// the crime of explaining itself.
check("a comment line may name a forbidden construct",
      scan('import QtQuick\n// this plugin does not use eval or XMLHttpRequest\nItem {}'), "ok");
check("an indented comment line counts too",
      scan('import QtQuick\nItem {\n    // no Loader here\n}'), "ok");
check("a comment line may name a forbidden import",
      scan('import QtQuick\n// we do not import Quickshell.Io\nItem {}'), "ok");

// THE case that makes whole-line stripping the only safe rule. If the stripper
// removed from any `//` to end of line, the `//` inside this string literal
// would swallow the eval that follows it — hiding a forbidden construct from
// the scan while leaving it in the file QML executes.
check("a // inside a string cannot hide code after it",
      scan('import QtQuick\nItem { property string u: "a//b"; property var z: eval("1") }'),
      "forbidden-construct");
check("a // inside a string is otherwise harmless",
      scan('import QtQuick\nItem { property string u: "https://example.com" }'), "ok");
// Documented limitations: trailing comments and block comments are not
// stripped, so prose about forbidden constructs goes on its own line.
check("a trailing comment is not stripped",
      scan('import QtQuick\nItem { property int x: 1 } // XMLHttpRequest is banned'),
      "forbidden-construct");
check("a block comment is not stripped",
      scan('import QtQuick\n/* XMLHttpRequest is banned */\nItem {}'), "forbidden-construct");
check("stripping keeps the line count",
      M.stripCommentLines("a\n// b\nc").split("\n").length, 3);
check("stripping blanks only the comment line",
      M.stripCommentLines("a\n// b\nc"), "a\n\nc");

// ── permitsUrl: the gate ─────────────────────────────────────────────────────
console.log("\n── network gate ──");
// Two fixtures, differing only in whether they asked for the network. This
// pair is the §16 requirement in one place: a plugin that did not declare
// `network` must not be able to make a network call.
const granted = M.validateManifest(
    withBase({ id: "netty", permissions: ["network"], network: ["api.github.com"] }), "netty");
const ungranted = M.validateManifest(withBase({ id: "quiet" }), "quiet");

check("the granted fixture is valid",   granted.ok, true);
check("the ungranted fixture is valid", ungranted.ok, true);

const gate = (g, url) => { const r = M.permitsUrl(g, url); return r.ok ? "ok" : r.reason; };

check("a plugin WITHOUT the network permission is refused",
      gate(ungranted, "https://api.github.com/x"), "permission-denied");
check("a plugin WITH it reaches its declared host",
      gate(granted, "https://api.github.com/user"), "ok");
check("a refused manifest grants nothing",
      gate({ ok: false }, "https://api.github.com/"), "no-grant");

// Suffix matching — the classic. "api.github.com.evil.com" ENDS WITH the
// allowed host, and an endsWith check would let it through.
check("a suffix-extended host is refused",
      gate(granted, "https://api.github.com.evil.com/"), "host-denied");
check("a prefixed host is refused",
      gate(granted, "https://notapi.github.com/"), "host-denied");
check("the parent domain is refused",
      gate(granted, "https://github.com/"), "host-denied");
check("a subdomain of the allowed host is refused",
      gate(granted, "https://x.api.github.com/"), "host-denied");
// Matching the whole URL string instead of the parsed host.
check("the host in a query string does not count",
      gate(granted, "https://evil.com/?x=api.github.com"), "host-denied");
check("the host in a fragment does not count",
      gate(granted, "https://evil.com/#api.github.com"), "host-denied");
check("the host in a path does not count",
      gate(granted, "https://evil.com/api.github.com"), "host-denied");
// Userinfo: reads as one host to a person, resolves as another.
check("userinfo is refused outright",
      gate(granted, "https://api.github.com@evil.com/"), "userinfo-denied");
check("userinfo with a password is refused",
      gate(granted, "https://user:pw@api.github.com/"), "userinfo-denied");
// Case.
check("an uppercase host still matches",
      gate(granted, "https://API.GitHub.COM/user"), "ok");
// Scheme and port.
check("http is refused",       gate(granted, "http://api.github.com/"), "scheme-denied");
check("file:// is refused",    gate(granted, "file:///etc/passwd"), "scheme-denied");
check("ftp is refused",        gate(granted, "ftp://api.github.com/"), "scheme-denied");
check("a schemeless URL is refused", gate(granted, "api.github.com/x"), "bad-url");
check("an empty URL is refused",     gate(granted, ""), "bad-url");
check("a non-string URL is refused", gate(granted, null), "bad-url");
check("port 443 is allowed",   gate(granted, "https://api.github.com:443/x"), "ok");
check("another port is refused", gate(granted, "https://api.github.com:8080/x"), "port-denied");
check("an IPv6 literal is refused", gate(granted, "https://[::1]/x"), "bad-url");
check("a newline in the URL is refused",
      gate(granted, "https://api.github.com/x\nHost: evil.com"), "bad-url");
check("a leading-dash URL is refused", gate(granted, "-x"), "bad-url");

// ── curlArgv: where the redirect hole would be ───────────────────────────────
console.log("\n── curl argv ──");
const argv = M.curlArgv("https://api.github.com/user");
check("the argv is an array", Array.isArray(argv), true);
check("curl is argv[0]", argv[0], "curl");
// permitsUrl() checked the URL the plugin asked for. If curl followed
// redirects, an approved host could bounce the request anywhere and the
// allowlist would be decorative — and it would only ever happen against a
// hostile server, so no amount of ordinary testing would reveal it.
check("redirects are not followed", argv.includes("--max-redirs") &&
      argv[argv.indexOf("--max-redirs") + 1] === "0", true);
check("no -L flag", argv.includes("-L") || argv.includes("--location"), false);
check("the protocol is pinned to https",
      argv[argv.indexOf("--proto") + 1], "=https");
check("the URL is passed behind --url, never as a bare positional",
      argv[argv.length - 2], "--url");
check("the URL is the last argument", argv[argv.length - 1], "https://api.github.com/user");
check("there is a timeout", argv.includes("--max-time"), true);
check("there is a size cap", argv.includes("--max-filesize"), true);
// No element may be a shell fragment: the URL comes from third-party code, and
// this repo already carries a CI invariant about not splicing model data into
// a `bash -c` string.
check("nothing is run through a shell",
      argv.some((a) => a === "sh" || a === "bash" || a === "-c"), false);

// ── validId: used before any manifest exists ─────────────────────────────────
console.log("\n── directory-name guard ──");
// PluginService interpolates an enumerated directory name into a path before it
// can read the manifest inside it, so the name is checked on its own first.
check("a normal id is valid",        M.validId("apex-sysmon"), true);
check("traversal is not an id",      M.validId(".."), false);
check("a dot is not an id",          M.validId("."), false);
check("a slash is not an id",        M.validId("a/b"), false);
check("a leading slash is not an id", M.validId("/etc"), false);
check("uppercase is not an id",      M.validId("Apex"), false);
check("empty is not an id",          M.validId(""), false);
check("a non-string is not an id",   M.validId(null), false);
check("a newline is not an id",      M.validId("a\nb"), false);

// ── permitsPath: the files gate ──────────────────────────────────────────────
console.log("\n── files gate ──");
const filesGranted   = M.validateManifest(withBase({ id: "fs", permissions: ["files"] }), "fs");
const filesUngranted = M.validateManifest(withBase({ id: "nofs" }), "nofs");
const fgate = (g, n) => { const r = M.permitsPath(g, n); return r.ok ? "ok" : r.reason; };

check("a plugin WITHOUT the files permission is refused",
      fgate(filesUngranted, "config.json"), "permission-denied");
check("a plugin WITH it reads its own directory",
      fgate(filesGranted, "config.json"), "ok");
check("a nested path inside the plugin is fine",
      fgate(filesGranted, "data/cities.json"), "ok");
check("traversal is refused",         fgate(filesGranted, "../../.ssh/id_rsa"), "bad-path");
check("a traversal component is refused", fgate(filesGranted, "data/../../x"), "bad-path");
check("an absolute path is refused",  fgate(filesGranted, "/etc/passwd"), "bad-path");
check("a dotfile is refused",         fgate(filesGranted, ".git/config"), "bad-path");
check("a nested dotfile is refused",  fgate(filesGranted, "data/.secret"), "bad-path");
check("a double slash is refused",    fgate(filesGranted, "data//x"), "bad-path");
check("a backslash is refused",       fgate(filesGranted, "data\\x"), "bad-path");
check("an empty path is refused",     fgate(filesGranted, ""), "bad-path");
check("a control character is refused", fgate(filesGranted, "a\nb"), "bad-path");
check("a refused manifest grants no files", fgate({ ok: false }, "x"), "no-grant");

// ── describeRefusal ──────────────────────────────────────────────────────────
console.log("\n── refusal messages ──");
check("every refusal reason has a human message", (() => {
    const reasons = [
        "manifest-unparseable", "manifest-not-object", "missing-field", "bad-id",
        "id-directory-mismatch", "bad-name", "bad-version", "bad-api-version",
        "api-version-unsupported", "bad-entry", "unknown-extension-point",
        "bad-permissions", "unknown-permission", "permission-not-implemented",
        "bad-network-hosts", "network-without-hosts", "hosts-without-network", "bad-path",
        "empty-source", "relative-import", "forbidden-import", "forbidden-construct",
        "extra-qml", "entry-missing", "entry-outside-plugin", "load-error",
        "no-grant", "permission-denied", "bad-url", "scheme-denied",
        "userinfo-denied", "port-denied", "host-denied"
    ];
    return reasons.filter((r) => M.describeRefusal({ ok: false, reason: r, detail: "" }) === r);
})(), []);
check("a granted result describes as empty", M.describeRefusal({ ok: true }), "");
check("the unimplemented-permission message says it will not grant",
      /will not grant/.test(M.describeRefusal({ ok: false, reason: "permission-not-implemented", detail: "secrets" })),
      true);

console.log(`\npassed=${passed} failed=${failed}`);
if (failed > 0) {
    console.error(`${failed} assertion(s) failed`);
    process.exit(1);
}
console.log("all assertions passed");
