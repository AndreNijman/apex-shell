"use strict";
// ─── permissions-test.js ─────────────────────────────────────────────────────
// The honesty rules of Config → Privacy & Permissions (roadmap P1-061), held
// against a fixture captured from `apex permissions show … --json` on a real
// APEX machine: a Flatpak that goes through the portal, a Flatpak whose
// manifest carries `devices=all`, and a native program.
//
// It exercises src/services/permissions.js — the file the shell actually
// loads — rather than a copy.
//
// ── What is being asserted, and why each one is separate ────────────────────
//
// 1. A Flatpak with `devices=all` and a native binary produce the SAME
//    sentence about the camera, because they have the same enforcer: the ACL
//    on /dev/video0. The control case is in the same test — a Flatpak WITHOUT
//    `devices=all` must differ — or the assertion would pass on a build that
//    said the same thing about everything.
// 2. Nothing unrevokable is ever given a control. Not a disabled one either:
//    the list is empty, and the page draws a sentence in its place.
// 3. `revokeArgv` refuses a row that offers no control even when it is called
//    directly, so a button wired to the wrong handler cannot assemble a
//    revoke for something the machine cannot do.
// 4. Never-asked, denied and no-primitive stay three answers. They are counted
//    into three different buckets and read as three different sentences.
// 5. A failed read is not an empty machine. `parseList` on no output, on
//    unparseable output and on a document with no grants returns ok:false with
//    a reason — a page that rendered all three as an empty list would tell an
//    owner their machine is clean at the moment it stopped being able to look.

const fs = require("fs");
const path = require("path");
const Perm = require(path.join(__dirname, "..", "src", "services", "permissions.js"));

const FIXTURE = fs.readFileSync(
    path.join(__dirname, "fixtures", "permissions-list.json"),
    "utf8"
);

let passed = 0;
let failed = 0;

function check(name, got, want) {
    const g = JSON.stringify(got);
    const w = JSON.stringify(want);
    if (g === w) {
        passed++;
        console.log("  PASS  " + name);
    } else {
        failed++;
        console.log("  FAIL  " + name + "\n        got  " + g + "\n        want " + w);
    }
}

function ok(name, cond, detail) {
    check(name, cond === true ? true : (detail === undefined ? cond : detail), true);
}

const parsed = Perm.parseList(FIXTURE, 0);

function app(id) {
    return parsed.apps.filter(function (a) { return a.id === id; })[0];
}
function row(id, capability) {
    return app(id).rows.filter(function (r) { return r.capability === capability; })[0];
}

// ── 1. the same enforcer reads the same, and the control case differs ────────
const SPOTIFY = "com.spotify.Client";
const RAWDEV = "io.github.cosmic_utils.camera";
const NATIVE = "zed";

check("the fixture parsed", parsed.ok, true);
check("three subjects", parsed.apps.length, 3);

check(
    "a devices=all Flatpak reads exactly like a native binary",
    row(RAWDEV, "camera").headline,
    row(NATIVE, "camera").headline
);
check(
    "…and both name the ACL as the enforcer",
    [row(RAWDEV, "camera").enforcer, row(NATIVE, "camera").enforcer],
    ["logind_acl", "logind_acl"]
);
check(
    "…while a Flatpak WITHOUT devices=all is brokered instead",
    row(SPOTIFY, "camera").enforcer,
    "portal_store"
);
ok(
    "…and that is the only one of the three with a control",
    row(SPOTIFY, "camera").offersControl === true &&
        row(RAWDEV, "camera").offersControl === false &&
        row(NATIVE, "camera").offersControl === false
);

// ── 2. no control is ever drawn for something unrevokable ───────────────────
let offered = 0;
let unrevokable = 0;
parsed.apps.forEach(function (a) {
    a.rows.forEach(function (r) {
        const c = Perm.controlsFor(r);
        if (c.length > 0) {
            offered++;
            if (!r.offersControl) {
                failed++;
                console.log("  FAIL  a control was offered for " + a.id + "/" + r.capability);
            }
        } else if (!r.offersControl) {
            unrevokable++;
        }
    });
});
ok("at least one row does offer a control", offered > 0, offered);
ok("and at least one does not", unrevokable > 0, unrevokable);
check(
    "no native row offers a control",
    app(NATIVE).rows.filter(function (r) { return Perm.controlsFor(r).length > 0; }).length,
    0
);

// "Never" and "Ask again" are two different intentions, and a page with one
// button for both answers a question the owner did not ask.
check(
    "a store-backed row offers refuse AND ask-again, in that order",
    Perm.controlsFor(row(SPOTIFY, "camera")).map(function (c) { return c.verb; }),
    ["deny", "forget"]
);
check(
    "a sandbox row offers one control and says when it lands",
    Perm.controlsFor(row(SPOTIFY, "network")).map(function (c) { return [c.verb, c.note]; }),
    [["context", "takes effect the next time the app starts"]]
);
check(
    "a portal row says it lands at the next request, not immediately",
    row(SPOTIFY, "camera").timingLabel,
    "takes effect the next time the app asks"
);

// ── 3. the argv builder refuses on its own ──────────────────────────────────
check(
    "revokeArgv refuses a row with no control, even asked directly",
    Perm.revokeArgv(row(NATIVE, "camera"), "deny"),
    null
);
check(
    "revokeArgv names a native subject with its prefix when it ever could",
    Perm.revokeArgv(row(SPOTIFY, "camera"), "deny"),
    ["apex", "permissions", "revoke", "com.spotify.Client", "camera"]
);
check(
    "…and --forget is the other verb, not another command",
    Perm.revokeArgv(row(SPOTIFY, "camera"), "forget"),
    ["apex", "permissions", "revoke", "com.spotify.Client", "camera", "--forget"]
);
check(
    "the native subject carries the prefix the CLI expects",
    row(NATIVE, "camera").revokeId,
    "native:zed"
);

// ── 4. three answers stay three ─────────────────────────────────────────────
const never = row(SPOTIFY, "camera");
const denied = row(SPOTIFY, "sensitive-directories");
const absent = row(SPOTIFY, "usb-device");
check("never-asked, denied and no-primitive are three states",
    [never.state, denied.state, absent.state],
    ["never_asked", "denied", "no_primitive"]);
ok("…and three different sentences",
    never.headline !== denied.headline &&
        denied.headline !== absent.headline &&
        never.headline !== absent.headline);
check("no-primitive is counted apart from unenforceable",
    [app(SPOTIFY).unavailable > 0, app(SPOTIFY).unenforceable > 0],
    [true, true]);
check("the summary says all three numbers",
    Perm.summaryFor(6, 3, 1),
    "6 you can change · 3 nothing can withdraw · 1 not available in this session");

// The page reads the real controls before the explanations.
check("rows are ordered strongest enforcer first",
    app(SPOTIFY).rows[0].enforcer,
    "portal_store");
check("…and the unenforced ones last",
    app(SPOTIFY).rows[app(SPOTIFY).rows.length - 1].enforcer,
    "nothing");

check("a native subject is flagged from the payload, not from its name",
    [app(NATIVE).native, app(SPOTIFY).native],
    [true, false]);

// ── 5. a failed read is not an empty machine ────────────────────────────────
[
    ["no output at all", Perm.parseList("", 1)],
    ["apex not on PATH", Perm.parseList("", 127)],
    ["output that is not JSON", Perm.parseList("Permission denied\n", 1)],
    ["JSON with no grants", Perm.parseList('{"session":{}}', 0)]
].forEach(function (pair) {
    const name = pair[0];
    const got = pair[1];
    check(name + " is a reason, not an empty list", [got.ok, got.reason !== ""], [false, true]);
});
check("…and 127 says specifically that apex is missing",
    Perm.parseList("", 127).reason.indexOf("PATH") >= 0,
    true);

// ── the session header ──────────────────────────────────────────────────────
const sess = Perm.sessionView(JSON.parse(FIXTURE).session);
check("the session names the desktop", sess.desktop, "Hyprland");
ok("…and does not claim a portal it did not see",
    sess.brokered.indexOf("Usb") === -1 && sess.brokered.indexOf("Camera") >= 0);
check("a session that could not be read says so, rather than reading as none",
    Perm.sessionView(null).summary,
    "could not read what this session brokers");

console.log("\npassed=" + passed + " failed=" + failed);
if (failed > 0) {
    process.exit(1);
}
