#!/usr/bin/env node
// Tests §15's unified search and command surface against the file the shell
// actually loads (src/services/search.js), not a copy of it.
//
//   node tests/search-test.js
//
// ── What this suite is FOR ───────────────────────────────────────────────────
//
// No CI runner has a compositor, so every behavioural QML suite in this repo
// skips there. A launcher that can restart a service or install a package,
// reached by fuzzy match while typing, cannot have its safety rules checked
// only by something that skips. So the rules live in a .js file and this runs
// them directly.
//
// Three groups of assertion carry most of the weight, and they are the three
// worth reading first:
//
//   1. THE COMMIT RULE. Enumerated over its whole cross product, with one
//      assertion that no input where the previewed row and the selected row
//      differ can ever return "run" for an action that changes the system.
//      That is what makes the preview mandatory rather than merely available.
//
//   2. THE SCHEDULER, MEASURED. A fake clock and a spawn log, driving the same
//      reducer the shell drives. "Typing does not spawn a process per provider
//      per keystroke" is a counted number here, not a claim in a comment.
//      tests/measure-search-spawns.sh then does the same measurement with real
//      processes and a shim binary on PATH.
//
//   3. THE NETWORK BOUNDARY. Every provider that can reach the network,
//      checked against every scope, so a new provider cannot be added to a
//      plain query's fan-out without this going red.
//
// ── Where the fixtures come from ─────────────────────────────────────────────
//
// The `apex` output shapes below are transcribed from the OS side's own
// serialisers, not invented. `apex project list --json` prints
// serde_json::to_string_pretty of a Vec<Project> — an ARRAY — from
// apexd/apex/src/agent.rs, with the struct in apex-agent-core/src/project.rs.
// `apex host list --json` prints a serde_json::Map keyed by host name — an
// OBJECT — from apexd/apex/src/host.rs. Read on the apex-os branch p3/base.
//
// The array/object difference is the trap: the house pattern next door is
// `if (Array.isArray(fresh))`, AgentService does it twice, and writing that for
// the host registry leaves the device section permanently empty with nothing
// logged. §20's RemoteAgentService hit this and caught it; both shapes are
// asserted here so neither parser can be "fixed" into the other's shape.

"use strict";

const fs = require("fs");
const path = require("path");
const S = require(path.join(__dirname, "..", "src", "services", "search.js"));

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

const CTX = { shellDir: "/opt/apex-shell", home: "/home/andre" };

// ─────────────────────────────────────────────────────────────────────────────
//  QUERY PARSING
// ─────────────────────────────────────────────────────────────────────────────

check("an empty query has an empty term", S.parseQuery("").term, "");
check("a plain query is the ALL scope", S.parseQuery("firefox").scope, S.SCOPE.ALL);
check("leading and trailing space is not part of the term",
      S.parseQuery("  firefox  ").term, "firefox");
check("null is not a crash", S.parseQuery(null).scope, S.SCOPE.ALL);
check("undefined is not a crash", S.parseQuery(undefined).term, "");

check("? is the answer scope", S.parseQuery("?density of lead").scope, S.SCOPE.ANSWER);
check("? strips the sigil and the space after it",
      S.parseQuery("? density of lead").term, "density of lead");
check("= is the calculator scope", S.parseQuery("=2+2").scope, S.SCOPE.CALC);
check("> is the commands scope", S.parseQuery(">reboot").scope, S.SCOPE.COMMANDS);

check("a leading slash is a path", S.parseQuery("/etc/host").scope, S.SCOPE.FILES);
check("~/ is a path", S.parseQuery("~/Doc").scope, S.SCOPE.FILES);
check("a bare ~ is a path", S.parseQuery("~").scope, S.SCOPE.FILES);
check("./ is a path", S.parseQuery("./src").scope, S.SCOPE.FILES);
// "~x" is not a path, and a launcher that treated it as one would list a
// directory that does not exist instead of searching for what was typed.
check("~ followed by a letter is not a path", S.parseQuery("~xyz").scope, S.SCOPE.ALL);
check("a path keeps its whole term", S.parseQuery("~/Doc").term, "~/Doc");

check("install is a package verb", S.parseQuery("install blender").scope, S.SCOPE.PACKAGES);
check("install carries the install intent",
      S.parseQuery("install blender").intent, "install");
check("remove carries the remove intent",
      S.parseQuery("remove blender").intent, "remove");
check("uninstall is the same intent as remove",
      S.parseQuery("uninstall blender").intent, "remove");
check("search is a package verb with no side", S.parseQuery("search blender").intent, "search");
check("the verb is stripped from the term",
      S.parseQuery("install blender").term, "blender");
check("ssh is the hosts verb", S.parseQuery("ssh katana").scope, S.SCOPE.HOSTS);
check("open is the projects verb", S.parseQuery("open apex-os").scope, S.SCOPE.PROJECTS);
check("a verb is case-insensitive", S.parseQuery("INSTALL blender").scope, S.SCOPE.PACKAGES);

// The space is what makes a verb a verb. Without it "installer" would be read
// as `install` + "er" and a package search would fire for a word nobody typed.
check("a verb needs a space after it", S.parseQuery("installer").scope, S.SCOPE.ALL);
check("a verb with nothing after it is a plain query",
      S.parseQuery("install ").scope, S.SCOPE.ALL);
check("a verb with nothing after it keeps the whole word as the term",
      S.parseQuery("install ").term, "install");
// A word that merely CONTAINS a verb is not one.
check("a verb must be the first word", S.parseQuery("how to install blender").scope,
      S.SCOPE.ALL);

// ─────────────────────────────────────────────────────────────────────────────
//  THE PROVIDER GATE — and the network boundary
// ─────────────────────────────────────────────────────────────────────────────

check("every provider id has a descriptor",
      S.PROVIDER_IDS.every(id => S.PROVIDERS[id] !== undefined), true);
check("every provider descriptor is a provider id",
      Object.keys(S.PROVIDERS).sort().join(","), S.PROVIDER_IDS.slice().sort().join(","));

// Every key present on every row. A capability table with a hole in it grants
// things by accident: `undefined` is not false in enough places to matter.
check("every provider declares every key",
      S.PROVIDER_IDS.filter(id => {
          const p = S.PROVIDERS[id];
          return typeof p.order !== "number" || typeof p.min !== "number"
              || typeof p.spawns !== "boolean" || typeof p.constantArgv !== "boolean"
              || typeof p.net !== "boolean" || !Array.isArray(p.scopes);
      }), []);
check("provider order is unique",
      new Set(S.PROVIDER_IDS.map(id => S.PROVIDERS[id].order)).size,
      S.PROVIDER_IDS.length);

check("a plain query reaches the apps provider",
      S.providerWants("apps", S.parseQuery("fire")), true);
check("an empty query reaches nobody",
      S.PROVIDER_IDS.filter(id => S.providerWants(id, S.parseQuery(""))), []);

// ── THE NETWORK BOUNDARY ────────────────────────────────────────────────────
// `apex search` runs `dnf5 search`, which may refresh repository metadata over
// the network. §15's constraint is that no provider may reach the network
// implicitly, so no scope a user can reach WITHOUT typing a package verb may
// consult it.
check("the package provider is the only one that can reach the network",
      S.networkProviders(), ["packages"]);
const IMPLICIT_QUERIES = ["blender", "b", "fire", "reboot", "?weather in perth",
                          "=2+2", ">restart", "~/Doc", "ssh katana",
                          "open apex-os", "install", "  ", "installer"];
check("no network provider is reachable from a query with no package verb",
      IMPLICIT_QUERIES.filter(q =>
          S.networkProviders().some(id => S.providerWants(id, S.parseQuery(q)))),
      []);
check("the package provider IS reachable once the verb is typed",
      S.providerWants("packages", S.parseQuery("install blender")), true);

// "?" is Wolfram's alone. A provider row appearing there would sit exactly
// where the calculator's answer goes, and manifest.js already refuses it for
// plugins; this is the built-in half of the same rule.
check("no provider is consulted for an answer query",
      S.PROVIDER_IDS.filter(id => S.providerWants(id, S.parseQuery("?anything"))), []);

// A one-character query costs no subprocess: on one character nearly every
// provider matches nearly everything.
check("nothing that spawns is consulted on one character",
      S.PROVIDER_IDS.filter(id => S.PROVIDERS[id].spawns
                                  && S.providerWants(id, S.parseQuery("a"))), []);
check("the sigil scopes reach only their own provider",
      [S.PROVIDER_IDS.filter(id => S.providerWants(id, S.parseQuery("=2+2"))),
       S.PROVIDER_IDS.filter(id => S.providerWants(id, S.parseQuery(">re")))],
      [["calc"], ["commands"]]);
check("a path query reaches only the files provider",
      S.PROVIDER_IDS.filter(id => S.providerWants(id, S.parseQuery("~/Doc"))), ["files"]);

// ─────────────────────────────────────────────────────────────────────────────
//  REQUEST ARGV — the complete list of what this feature can read
// ─────────────────────────────────────────────────────────────────────────────

check("a plain query reads the project list and the device registry",
      S.PROVIDER_IDS.map(id => S.requestArgv(id, S.parseQuery("apex"), CTX))
          .filter(a => a.length > 0),
      [["apex", "project", "list", "--json"], ["apex", "host", "list", "--json"]]);
check("the project argv does not depend on the query",
      JSON.stringify(S.requestArgv("projects", S.parseQuery("apex"), CTX))
          === JSON.stringify(S.requestArgv("projects", S.parseQuery("zzzz"), CTX)), true);
check("the package argv carries the term",
      S.requestArgv("packages", S.parseQuery("install blender"), CTX),
      ["apex", "search", "blender"]);
// A leading "-" is read as a flag by everything downstream. Refused rather
// than stripped: a search for "-x" that silently became a search for "x" is a
// search that lied.
check("a term beginning with a dash is refused, not stripped",
      S.requestArgv("packages", S.parseQuery("install -rf"), CTX), []);
check("the file argv is the directory, not the query",
      S.requestArgv("files", S.parseQuery("~/Doc/pro"), CTX),
      ["ls", "-1Ap", "--", "/home/andre/Doc/"]);
check("a file argv walking upward is refused",
      S.requestArgv("files", S.parseQuery("~/Doc/../../etc/x"), CTX), []);
check("with no home there is no file argv",
      S.requestArgv("files", S.parseQuery("~/Doc/x"), { shellDir: "/s" }), []);
check("nothing is read for an answer query",
      S.PROVIDER_IDS.map(id => S.requestArgv(id, S.parseQuery("?x"), CTX))
          .filter(a => a.length > 0), []);

// ─────────────────────────────────────────────────────────────────────────────
//  MATCHING
// ─────────────────────────────────────────────────────────────────────────────

check("an exact match is the top tier", S.score("Firefox", "firefox"), S.TIER.EXACT);
check("a prefix beats a word start",
      S.score("Firefox", "fire") > S.score("Mozilla Firefox", "fire"), true);
check("a word start beats a substring",
      S.score("VS Code", "code") > S.score("Barcode Scanner", "code"), true);
check("a substring beats a subsequence",
      S.score("Barcode", "code") > S.score("Cinnamon Desktop Editor", "code"), true);
check("no match is zero", S.score("Firefox", "zzz"), 0);
check("an empty term matches nothing", S.score("Firefox", ""), 0);
// The failure that makes a launcher feel broken: the thing you typed the start
// of has to come first.
check("the thing you typed the start of wins",
      S.score("Firefox", "fi") > S.score("Fractal Design Config", "fi"), true);
check("among equal tiers the shorter name wins",
      S.score("Terminal", "term") > S.score("Terminal Emulator Settings", "term"), true);
check("punctuation the user did not type is not required",
      S.score("Wi-Fi Settings", "wifi") > 0, true);

// A keyword hit is worth one tier less than the same hit on the visible name:
// matching something the user cannot see on the row must not outrank matching
// something they can.
check("a keyword match is demoted below a name match",
      S.scoreFields("Firefox", "web browser internet", "browser")
          < S.scoreFields("Browser", "", "browser"), true);
check("a keyword match still finds the app",
      S.scoreFields("Firefox", "web browser internet", "browser") > 0, true);

// ─────────────────────────────────────────────────────────────────────────────
//  ROW SANITISING
// ─────────────────────────────────────────────────────────────────────────────
//
// Window titles, clipboard contents, package summaries and file names are all
// attacker-influenceable. They go through the same treatment a plugin's strings
// do.

const BUILTIN = { id: "commands", kind: "command", builtin: true };
const FOREIGN = { id: "commands", kind: "command", builtin: false };

check("a row with no name is not a row",
      S.rowsFrom(BUILTIN, [{ name: "" }, { name: "   " }], "x"), []);
check("a non-array yields nothing",
      [S.rowsFrom(BUILTIN, null, "x"), S.rowsFrom(BUILTIN, "rows", "x"),
       S.rowsFrom(BUILTIN, {}, "x")], [[], [], []]);
check("an unknown provider yields nothing",
      S.rowsFrom({ id: "nope", kind: "command", builtin: true }, [{ name: "x" }], "x"), []);
check("an unknown kind yields nothing",
      S.rowsFrom({ id: "commands", kind: "wat", builtin: true }, [{ name: "x" }], "x"), []);

// A newline in a row draws over two lines and can impersonate the row beneath
// it. On a list where the next row might be "Restart", that is not cosmetic.
check("control characters are stripped from every string",
      S.rowsFrom(BUILTIN, [{ name: "two\nlines\r", detail: "a b" }], "two")[0].name,
      "twolines");
check("the detail is stripped too",
      S.rowsFrom(BUILTIN, [{ name: "x", detail: "a\nb" }], "x")[0].detail, "ab");
check("a very long name is capped",
      S.rowsFrom(BUILTIN, [{ name: "z".repeat(500) }], "z")[0].name.length, 120);
check("a very long argument is capped",
      S.rowsFrom(BUILTIN, [{ name: "x", arg: "z".repeat(500) }], "x")[0].arg.length, 200);

// An icon is an XDG NAME and never a path: the delegate turns a leading "/"
// into "file://" and hands it to an Image, which makes a path a file-existence
// oracle over the whole filesystem.
check("an icon path is dropped",
      S.rowsFrom(BUILTIN, [{ name: "x", icon: "/etc/shadow" }], "x")[0].icon, "");
check("an icon name survives",
      S.rowsFrom(BUILTIN, [{ name: "x", icon: "firefox" }], "x")[0].icon, "firefox");

// THE FIELD THAT IS THE CONTRACT EXTENSION. A built-in row may name an action
// from the closed table; nothing else may, and an id that is not in the table
// is no action rather than an action nobody checked.
check("a built-in row may name an action",
      S.rowsFrom(BUILTIN, [{ name: "x", action: "system.reboot" }], "x")[0].action,
      "system.reboot");
check("a non-built-in row may not",
      S.rowsFrom(FOREIGN, [{ name: "x", action: "system.reboot" }], "x")[0].action, "");
check("an unknown action id becomes no action",
      S.rowsFrom(BUILTIN, [{ name: "x", action: "rm.everything" }], "x")[0].action, "");
check("a row that names no action is safe",
      S.rowsFrom(BUILTIN, [{ name: "x" }], "x")[0].klass, S.KLASS.SAFE);
// The class comes from the ACTION, never from the row. A provider that could
// set its own class could label a reboot safe, which is the entire mechanism
// this file exists to prevent.
check("a row cannot choose its own class",
      S.rowsFrom(BUILTIN, [{ name: "x", action: "system.reboot", klass: "safe" }],
                 "x")[0].klass, S.KLASS.DESTRUCTIVE);
check("a row that lost its action is safe, not the action's class",
      S.rowsFrom(FOREIGN, [{ name: "x", action: "system.reboot", klass: "destructive" }],
                 "x")[0].klass, S.KLASS.SAFE);
// `kind` is what AppLauncher.activate() dispatches on, so a provider choosing
// its own would be choosing which branch runs.
check("a row cannot choose its own kind",
      S.rowsFrom(BUILTIN, [{ name: "x", kind: "app" }], "x")[0].kind, "command");
check("a row cannot claim another provider",
      S.rowsFrom(BUILTIN, [{ name: "x", provider: "apps" }], "x")[0].provider, "commands");

// AppLauncher.activate() dispatches on `entry` and falls through to `exec`.
// A row that reached either branch carrying one would be arbitrary execution.
const NASTY = { name: "innocent", exec: "poweroff", entry: 1, action: "system.reboot",
                command: ["sh", "-c", "boom"], value: "hidden" };
check("a command row carries no exec and no entry",
      Object.keys(S.rowsFrom(BUILTIN, [NASTY], "innocent")[0]).sort().join(","),
      "action,arg,detail,glyph,icon,index,kind,klass,name,payload,provider,score");
check("no sanitised row of any kind has an exec key",
      S.ROW_KINDS.filter(k =>
          S.rowsFrom({ id: "commands", kind: k, builtin: true }, [NASTY], "x")
              .some(r => "exec" in r)), []);
// The one exception, and it is keyed on the DESCRIPTOR rather than the row: an
// application is launched through DesktopEntry.execute(), which honours
// Terminal=, Path= and Exec field codes where pasting an Exec line into
// `bash -c` does not.
check("only the app kind may carry a DesktopEntry",
      S.ROW_KINDS.filter(k =>
          S.rowsFrom({ id: "apps", kind: k, builtin: true },
                     [{ name: "x", entry: { id: "e" } }], "x")
              .some(r => "entry" in r)), ["app"]);

check("the row's index is its position in the provider's own array",
      S.rowsFrom(BUILTIN, [{ name: "a" }, { name: "" }, { name: "c" }], "").map(r => r.index),
      [0, 2]);

// ─────────────────────────────────────────────────────────────────────────────
//  MERGE — total, and independent of arrival order
// ─────────────────────────────────────────────────────────────────────────────

function row(provider, name, score) {
    return { provider: provider, kind: "command", name: name, score: score,
             action: "", arg: "", payload: "", index: 0 };
}
const G1 = [row("apps", "Alpha", 800), row("apps", "Beta", 700)];
const G2 = [row("windows", "Gamma", 800), row("windows", "Delta", 900)];
const G3 = [row("hosts", "Zero", 0)];

check("higher scores come first",
      S.merge([G1, G2, G3]).map(r => r.name), ["Delta", "Alpha", "Gamma", "Beta"]);
// Results come back from subprocesses out of order. A list that reshuffled
// itself depending on which `apex` returned first would move the row under the
// user's finger between keystrokes.
check("the order does not depend on which group arrived first",
      S.merge([G2, G1, G3]).map(r => r.name), S.merge([G1, G2, G3]).map(r => r.name));
check("a zero score is not a result", S.merge([G3]), []);
check("a tie is broken by provider order, then by name",
      S.merge([[row("windows", "A", 500), row("apps", "B", 500),
                row("apps", "A", 500)]]).map(r => r.provider + ":" + r.name),
      ["apps:A", "apps:B", "windows:A"]);
check("the merge is capped",
      S.merge([Array.from({ length: 200 }, (_, i) => row("apps", "n" + i, 500))]).length, 60);
check("a malformed group is skipped, not fatal",
      S.merge([null, G1, "nope"]).length, 2);

// ─────────────────────────────────────────────────────────────────────────────
//  THE ACTION REGISTRY
// ─────────────────────────────────────────────────────────────────────────────

const KLASSES = [S.KLASS.SAFE, S.KLASS.CHANGES, S.KLASS.DESTRUCTIVE];
const PERMS = Object.keys(S.PERMISSION).map(k => S.PERMISSION[k]);

check("every action declares a known class",
      S.ACTION_IDS.filter(id => KLASSES.indexOf(S.ACTIONS[id].klass) < 0), []);
check("every action declares a permission from the closed vocabulary",
      S.ACTION_IDS.filter(id => PERMS.indexOf(S.ACTIONS[id].permission) < 0), []);
check("every action has a title, keywords and a description",
      S.ACTION_IDS.filter(id => {
          const a = S.ACTIONS[id];
          return a.title === "" || a.keywords === "" || a.what === "";
      }), []);
// A destructive action is exactly one that cannot say how to put it back. The
// correspondence is asserted rather than left to whoever classified each row.
check("destructive means, and only means, there is no way to undo it",
      S.ACTION_IDS.filter(id => {
          const a = S.ACTIONS[id];
          return (a.klass === S.KLASS.DESTRUCTIVE) !== (a.undoes === "");
      }), []);

// Every action either builds an argv or is a compositor operation. An action
// that could do neither would be a row that does nothing when committed.
check("every action builds an argv, or is a compositor action",
      S.ACTION_IDS.filter(id => {
          if (S.COMPOSITOR_ACTIONS.indexOf(id) >= 0) return false;
          const a = S.ACTIONS[id];
          return S.actionArgv(id, a.arg === "" ? "" : "sample", CTX) === null;
      }), []);
check("a compositor action deliberately builds no argv",
      S.COMPOSITOR_ACTIONS.filter(id => S.actionArgv(id, "sample", CTX) !== null), []);

// NO STRINGS. EVER. This repo already has a CI invariant about not splicing
// model data into a `bash -c` string; here the data is a package name typed
// into a search box.
check("every argv is an array of non-empty strings",
      S.ACTION_IDS.filter(id => {
          const argv = S.actionArgv(id, S.ACTIONS[id].arg === "" ? "" : "sample", CTX);
          if (argv === null) return S.COMPOSITOR_ACTIONS.indexOf(id) < 0;
          return !argv.every(x => typeof x === "string" && x !== "");
      }), []);
check("no argv element is a shell invocation carrying an inline script",
      S.ACTION_IDS.filter(id => {
          const argv = S.actionArgv(id, S.ACTIONS[id].arg === "" ? "" : "sample", CTX);
          if (argv === null) return false;
          return argv.indexOf("-c") >= 0;
      }), []);
// The argument lands in a slot of its own, never concatenated into another
// element.
check("the argument is its own argv element and appears nowhere else",
      S.ACTION_IDS.filter(id => {
          if (S.ACTIONS[id].arg === "") return false;
          const argv = S.actionArgv(id, "needle", CTX);
          if (argv === null) return S.COMPOSITOR_ACTIONS.indexOf(id) < 0;
          const exact = argv.filter(x => x === "needle").length;
          const containing = argv.filter(x => x.indexOf("needle") >= 0).length;
          return exact !== 1 || containing !== 1;
      }), []);

// An action returns null rather than a partial command for every reason it
// might fail. A caller that gets null must do nothing.
check("an unknown action builds nothing", S.actionArgv("nope", "", CTX), null);
check("an action that needs an argument refuses without one",
      S.actionArgv("pkg.install", "", CTX), null);
check("an action that takes no argument refuses one",
      S.actionArgv("system.reboot", "blender", CTX), null);
check("no shellDir means no command", S.actionArgv("system.reboot", "", {}), null);
check("a control character in the argument is stripped before it becomes argv",
      S.actionArgv("pkg.install", "blen\nder", CTX)[3], "blender");

check("installing goes through the script, with the name as its own argument",
      S.actionArgv("pkg.install", "blender", CTX),
      ["bash", "/opt/apex-shell/src/scripts/SearchRun.sh", "install", "blender"]);
check("restarting bluetooth names the unit, and the unit is not the user's",
      S.actionArgv("bluetooth.restart", "", CTX),
      ["bash", "/opt/apex-shell/src/scripts/SearchRun.sh", "unit-restart", "bluetooth"]);
check("power actions go through the same script the power menu uses",
      S.actionArgv("system.reboot", "", CTX),
      ["bash", "/opt/apex-shell/src/scripts/PowerControl.sh", "reboot"]);

// ── The preview ─────────────────────────────────────────────────────────────
const PREVIEW = S.actionPreview("pkg.install", "blender", CTX);
check("the preview names what will happen", PREVIEW.what.length > 20, true);
check("the preview names the privilege", PREVIEW.permission, S.PERMISSION.SUDO);
check("the preview names the row", PREVIEW.title, "Install blender");
// "We show you the command" is worth nothing if the shown command and the run
// command are built separately and can drift.
check("the shown command line is the argv that will run",
      PREVIEW.commandLine,
      S.actionArgv("pkg.install", "blender", CTX).join(" "));
check("an argument with a space in it reads as one argument",
      S.actionPreview("pkg.install", "some thing", CTX).commandLine.indexOf("'some thing'") > 0,
      true);
check("a non-safe action needs a commit",
      S.ACTION_IDS.filter(id =>
          S.actionPreview(id, S.ACTIONS[id].arg === "" ? "" : "s", CTX).needsCommit
              !== (S.ACTIONS[id].klass !== S.KLASS.SAFE)), []);
check("a destructive preview says so by having nothing to offer as an undo",
      S.actionPreview("system.reboot", "", CTX).undoes, "");

// THE HEADLINE NAMES THE TARGET. The first version rewrote the title with a
// regex over "a (package|device|session|project|path|window)", which fired for
// "Install a package" and for nothing else — so a destructive preview read
// "Stop an agent session" and never named the session, and the one test there
// was asserted only the case that worked. This is the general form.
check("every action that takes an argument names it in the preview headline",
      S.ACTION_IDS.filter(id => S.ACTIONS[id].arg !== ""
                                && S.actionPreview(id, "needle", CTX).title
                                       .indexOf("needle") < 0), []);
check("an action takes an argument exactly when it has a headline template",
      S.ACTION_IDS.filter(id => (S.ACTIONS[id].arg === "")
                                !== (S.ACTIONS[id].titleWith === "")), []);
check("every headline template has somewhere to put the argument",
      S.ACTION_IDS.filter(id => S.ACTIONS[id].titleWith !== ""
                                && S.ACTIONS[id].titleWith.indexOf("%s") < 0), []);
check("with no argument the headline is the action's plain title",
      S.actionPreview("system.reboot", "", CTX).title, S.ACTIONS["system.reboot"].title);
check("only the package actions resolve",
      S.ACTION_IDS.filter(id =>
          S.actionPreview(id, S.ACTIONS[id].arg === "" ? "" : "s", CTX).resolves),
      ["pkg.install", "pkg.remove"]);
check("resolve is read-only and needs no root",
      S.resolveArgv("blender"), ["apex", "resolve", "blender"]);
check("resolve refuses an empty name", S.resolveArgv(""), null);
check("an unknown action has no preview", S.actionPreview("nope", "", CTX), null);

// ─────────────────────────────────────────────────────────────────────────────
//  THE COMMIT RULE — enumerated over its whole cross product
// ─────────────────────────────────────────────────────────────────────────────

check("a safe row runs on Enter",
      S.commitDecision({ klass: S.KLASS.SAFE, key: "enter", ctrl: false,
                         previewedId: "", selectedId: "a" }), S.COMMIT.RUN);
check("a changing row previews on Enter",
      S.commitDecision({ klass: S.KLASS.CHANGES, key: "enter", ctrl: false,
                         previewedId: "", selectedId: "a" }), S.COMMIT.PREVIEW);
check("a destructive row previews on Enter",
      S.commitDecision({ klass: S.KLASS.DESTRUCTIVE, key: "enter", ctrl: false,
                         previewedId: "", selectedId: "a" }), S.COMMIT.PREVIEW);
check("Enter on a destructive row with its OWN preview open still only previews",
      S.commitDecision({ klass: S.KLASS.DESTRUCTIVE, key: "enter", ctrl: false,
                         previewedId: "a", selectedId: "a" }), S.COMMIT.PREVIEW);
check("Ctrl+Enter commits the row whose preview is open",
      S.commitDecision({ klass: S.KLASS.DESTRUCTIVE, key: "commit", ctrl: true,
                         previewedId: "a", selectedId: "a" }), S.COMMIT.RUN);

// ── THE HOLE THIS RULE EXISTS TO CLOSE ──────────────────────────────────────
// "Enter previews, Ctrl+Enter commits" is not enough on its own: Ctrl+Enter is
// muscle-memory "send" in half the applications on this machine, and nothing in
// that rule stops it being pressed straight from the list with no preview ever
// shown. The preview would then be optional, and an optional preview does not
// meet §15's fourth bullet.
check("Ctrl+Enter with no preview open does nothing",
      S.commitDecision({ klass: S.KLASS.DESTRUCTIVE, key: "commit", ctrl: true,
                         previewedId: "", selectedId: "a" }), S.COMMIT.REFUSE);
check("Ctrl+Enter with the preview pointing at another row does nothing",
      S.commitDecision({ klass: S.KLASS.DESTRUCTIVE, key: "commit", ctrl: true,
                         previewedId: "b", selectedId: "a" }), S.COMMIT.REFUSE);
check("a commit key that arrived without the modifier does nothing",
      S.commitDecision({ klass: S.KLASS.DESTRUCTIVE, key: "commit", ctrl: false,
                         previewedId: "a", selectedId: "a" }), S.COMMIT.REFUSE);
check("nothing is selected, so nothing happens",
      S.commitDecision({ klass: S.KLASS.SAFE, key: "enter", ctrl: false,
                         previewedId: "", selectedId: "" }), S.COMMIT.REFUSE);
check("a row with a class nobody recognises is refused outright",
      S.commitDecision({ klass: "mostly-safe", key: "enter", ctrl: false,
                         previewedId: "", selectedId: "a" }), S.COMMIT.REFUSE);
check("an unknown key does nothing",
      S.commitDecision({ klass: S.KLASS.SAFE, key: "space", ctrl: false,
                         previewedId: "", selectedId: "a" }), S.COMMIT.REFUSE);
check("no arguments at all is not a crash", S.commitDecision(), S.COMMIT.REFUSE);
check("the mouse and touch path commits its own open preview",
      S.commitDecision({ klass: S.KLASS.DESTRUCTIVE, key: "button", ctrl: false,
                         previewedId: "a", selectedId: "a" }), S.COMMIT.RUN);
check("the mouse path cannot commit a preview of another row",
      S.commitDecision({ klass: S.KLASS.DESTRUCTIVE, key: "button", ctrl: false,
                         previewedId: "b", selectedId: "a" }), S.COMMIT.REFUSE);

// ── The whole cross product, and the one assertion that matters most ────────
const KEYS = ["enter", "commit", "button", "space", "", null, undefined];
const CTRLS = [true, false, undefined, "yes", 1, 0];
const IDS = ["", "a", "b"];
const ALL = [];
for (const klass of KLASSES.concat(["", null, "safe ", "SAFE", undefined]))
    for (const key of KEYS)
        for (const ctrl of CTRLS)
            for (const previewedId of IDS)
                for (const selectedId of IDS)
                    ALL.push({ klass, key, ctrl, previewedId, selectedId });

check("the cross product is fully enumerated", ALL.length, 8 * 7 * 6 * 3 * 3);
check("every verdict is one of the three",
      ALL.filter(o => [S.COMMIT.RUN, S.COMMIT.PREVIEW, S.COMMIT.REFUSE]
                          .indexOf(S.commitDecision(o)) < 0).length, 0);

// THE ASSERTION. Whatever else changes about this rule, a system-changing
// action must never run from an input where the preview is not open on exactly
// the row that is selected.
check("NO input where the previewed row differs from the selected row can run "
      + "a system-changing action",
      ALL.filter(o => o.klass !== S.KLASS.SAFE
                      && S.commitDecision(o) === S.COMMIT.RUN
                      && !(o.previewedId !== "" && o.previewedId === o.selectedId)).length,
      0);
check("no input with an empty preview can run a system-changing action",
      ALL.filter(o => o.klass !== S.KLASS.SAFE
                      && o.previewedId === ""
                      && S.commitDecision(o) === S.COMMIT.RUN).length, 0);
// The second half of the same guarantee: plain Enter never runs one either,
// whatever is on screen.
check("plain Enter never runs a system-changing action",
      ALL.filter(o => o.klass !== S.KLASS.SAFE && o.key === "enter"
                      && S.commitDecision(o) === S.COMMIT.RUN).length, 0);
check("a non-boolean ctrl is not a held modifier",
      ALL.filter(o => o.ctrl !== true && o.key === "commit"
                      && S.commitDecision(o) === S.COMMIT.RUN).length, 0);

// ── Row identity ────────────────────────────────────────────────────────────
check("two rows differing only in action have different ids",
      S.rowId({ provider: "commands", kind: "command", name: "X", action: "system.reboot" })
          !== S.rowId({ provider: "commands", kind: "command", name: "X",
                        action: "system.shutdown" }), true);
check("two rows differing only in argument have different ids",
      S.rowId({ provider: "packages", kind: "package", name: "X", arg: "a" })
          !== S.rowId({ provider: "packages", kind: "package", name: "X", arg: "b" }), true);
check("the same row produced twice has the same id",
      S.rowId({ provider: "apps", kind: "app", name: "Firefox", payload: "firefox" }),
      S.rowId({ provider: "apps", kind: "app", name: "Firefox", payload: "firefox" }));
check("a nameless row has no identity, so nothing can commit it",
      [S.rowId(null), S.rowId({}), S.rowId({ name: "" })], ["", "", ""]);

// ── The identity has to survive an INSERTION, which is the case that bites ──
// merge() is order-independent w.r.t. which provider answered first, which is
// tested above. It is not stable against rows being inserted, and they are:
// `apex project list` lands about 160 ms after typing stops. A selection held
// as an integer index then points one row further down than the user is
// looking at. AppLauncher re-anchors by id; this is the property that makes
// that possible.
(function () {
    function mk(provider, name, score) {
        return { provider: provider, kind: "app", name: name, score: score,
                 action: "", arg: "", payload: name, index: 0 };
    }
    const apps = [mk("apps", "Alpha", 900), mk("apps", "Beta", 800)];
    const before = S.merge([apps]);
    const anchor = S.rowId(before[1]);
    const after = S.merge([apps, [mk("projects", "apex-os", 850)]]);

    check("an arriving answer really can move the row under the selection",
          [before[1].name, after[1].name], ["Beta", "apex-os"]);
    check("but the row's identity is unchanged by other rows arriving",
          after.map(r => S.rowId(r)).indexOf(anchor), 2);
    check("so the anchor finds it again",
          after[after.map(r => S.rowId(r)).indexOf(anchor)].name, "Beta");
})();

// ─────────────────────────────────────────────────────────────────────────────
//  THE SCHEDULER, MEASURED
// ─────────────────────────────────────────────────────────────────────────────
//
// A fake clock and a spawn log, driving the same reducer the shell drives.
// Every number below is counted rather than asserted.

function Driver() {
    this.state = S.initialState();
    this.now = 0;
    this.deadline = null;
    this.spawns = [];       // every argv ever started, in order
    this.cancels = [];
    this.inflight = {};
    this.wants = [];
}
Driver.prototype._apply = function (p) {
    this.state = p.state;
    for (const id of p.cancel) { this.cancels.push(id); delete this.inflight[id]; }
    for (const s of p.start) {
        this.spawns.push(s.id + ": " + s.argv.join(" "));
        this.inflight[s.id] = { seq: s.seq, argv: s.argv };
    }
    if (p.armMs > 0) this.deadline = this.now + p.armMs;
    else if (p.armMs === 0) this.deadline = null;
};
Driver.prototype.demand = function (on) {
    this._apply(S.plan(this.state, { type: "demand", on: on }));
};
Driver.prototype.type = function (text) {
    this.wants = S.PROVIDER_IDS
        .map(id => ({ id: id, argv: S.requestArgv(id, S.parseQuery(text), CTX) }))
        .filter(w => w.argv.length > 0);
    this._apply(S.plan(this.state, { type: "query", wants: this.wants }));
};
Driver.prototype.tick = function (ms) {
    this.now += ms;
    if (this.deadline !== null && this.now >= this.deadline) {
        this.deadline = null;
        this._apply(S.plan(this.state, { type: "deadline", wants: this.wants }));
    }
};
Driver.prototype.finish = function (id, ok, text) {
    const f = this.inflight[id];
    if (f === undefined) return false;
    delete this.inflight[id];
    this._apply(S.plan(this.state, { type: "result", id: id, seq: f.seq,
                                     ok: ok, text: text }));
    return true;
};
// A result arriving for a request that was already cancelled — the process was
// killed but its exit had already been queued.
Driver.prototype.finishStale = function (id, seq, text) {
    this._apply(S.plan(this.state, { type: "result", id: id, seq: seq,
                                     ok: true, text: text }));
};

// ── Idle costs nothing ──────────────────────────────────────────────────────
let d = new Driver();
for (const t of ["blender", "install blender", "~/Documents/x", "ssh katana"])
    d.type(t);
for (let i = 0; i < 100; i++) d.tick(100);
check("MEASURED: with nothing holding demand, ten seconds of queries spawn nothing",
      d.spawns.length, 0);
check("MEASURED: and arm no timer", d.deadline, null);

// ── A typing burst ──────────────────────────────────────────────────────────
d = new Driver();
d.demand(true);
const WORD = "install blender";
for (let i = 1; i <= WORD.length; i++) { d.type(WORD.slice(0, i)); d.tick(20); }
check("MEASURED: fifteen keystrokes at 20 ms apart spawn nothing at all",
      d.spawns.length, 0);
d.tick(S.DEBOUNCE_MS);
check("MEASURED: one process after the typing stops", d.spawns.length, 1);
check("and it is the package search the user asked for",
      d.spawns[0], "packages: apex search blender");

// ── Typing more, once an answer is in ───────────────────────────────────────
d.finish("packages", true, "── repository packages ──\nblender.x86_64 : 3D suite\n");
d.type("install blender");
d.tick(1000);
check("MEASURED: re-typing the same query spawns nothing (cache hit)",
      d.spawns.length, 1);

// ── Backspacing to something already fetched ────────────────────────────────
d.type("install blend");
d.tick(1000);
d.finish("packages", true, "blender.x86_64 : 3D suite\n");
const afterBackspace = d.spawns.length;
d.type("install blender");
d.tick(1000);
check("MEASURED: backspacing and retyping is a cache hit, not a second process",
      d.spawns.length, afterBackspace);

// ── The two constant-argv providers ─────────────────────────────────────────
d = new Driver();
d.demand(true);
for (const t of ["a", "ap", "ape", "apex", "apex-", "apex-o", "apex-os"]) {
    d.type(t);
    d.tick(20);
}
d.tick(S.DEBOUNCE_MS);
check("MEASURED: seven keystrokes of a plain query cost two processes, not fourteen",
      d.spawns.length, 2);
check("and they are the project list and the device registry",
      d.spawns.slice().sort(),
      ["hosts: apex host list --json", "projects: apex project list --json"]);
d.finish("projects", true, "[]");
d.finish("hosts", true, "{}");
for (const t of ["apex-os ", "apex-os x", "apex-os xy"]) { d.type(t); d.tick(200); }
check("MEASURED: typing on costs nothing more — the argv did not change",
      d.spawns.length, 2);

// ── Walking a directory ─────────────────────────────────────────────────────
d = new Driver();
d.demand(true);
for (const t of ["~/D", "~/Do", "~/Doc", "~/Docu"]) { d.type(t); d.tick(20); }
d.tick(S.DEBOUNCE_MS);
check("MEASURED: typing a file name inside one directory is one listing",
      d.spawns.length, 1);
check("and the listing is of the directory, not of the query",
      d.spawns[0], "files: ls -1Ap -- /home/andre/");
d.finish("files", true, "Documents/\nDownloads/\n");
d.type("~/Documents/");
d.tick(S.DEBOUNCE_MS);
check("MEASURED: descending into a directory costs exactly one more listing",
      d.spawns.length, 2);

// ── Supersession and out-of-order arrival ───────────────────────────────────
d = new Driver();
d.demand(true);
d.type("install alpha");
d.tick(S.DEBOUNCE_MS);
const staleSeq = d.state.pending["packages"].seq;
d.type("install beta");
check("a superseded request is cancelled", d.cancels, ["packages"]);
d.tick(S.DEBOUNCE_MS);
check("MEASURED: and the new one is started", d.spawns.length, 2);
d.finishStale("packages", staleSeq, "ALPHA RESULT");
check("the cancelled request's answer is dropped, not cached",
      S.cached(d.state, "packages", ["apex", "search", "alpha"]), null);
d.finish("packages", true, "BETA RESULT");
check("the current request's answer is kept",
      S.cached(d.state, "packages", ["apex", "search", "beta"]).text, "BETA RESULT");

// Two providers answering in the reverse order they were started.
d = new Driver();
d.demand(true);
d.type("apex");
d.tick(S.DEBOUNCE_MS);
d.finish("hosts", true, "{}");
d.finish("projects", true, "[]");
check("out-of-order answers both land",
      [S.cached(d.state, "projects", ["apex", "project", "list", "--json"]).text,
       S.cached(d.state, "hosts", ["apex", "host", "list", "--json"]).text],
      ["[]", "{}"]);

// ── Demand going away ───────────────────────────────────────────────────────
d = new Driver();
d.demand(true);
d.type("install blender");
d.tick(S.DEBOUNCE_MS);
d.cancels = [];
d.demand(false);
check("closing the launcher cancels what is in flight", d.cancels, ["packages"]);
check("and stops the timer", d.deadline, null);
check("and drops the cache, so a stale answer cannot survive a close",
      S.cached(d.state, "packages", ["apex", "search", "blender"]), null);
const beforeClosedBurst = d.spawns.length;
for (let i = 0; i < 50; i++) { d.type("install thing" + i); d.tick(1000); }
check("MEASURED: fifty queries with the launcher closed spawn nothing",
      d.spawns.length, beforeClosedBurst);

// ── The cache is bounded ────────────────────────────────────────────────────
d = new Driver();
d.demand(true);
for (let i = 0; i < S.CACHE_PER_PROVIDER + 4; i++) {
    d.type("install p" + i);
    d.tick(S.DEBOUNCE_MS);
    d.finish("packages", true, "answer " + i);
}
check("the cache does not grow without bound",
      d.state.cache["packages"].length, S.CACHE_PER_PROVIDER);
check("the oldest entry is the one dropped",
      S.cached(d.state, "packages", ["apex", "search", "p0"]), null);
check("the newest is kept",
      S.cached(d.state, "packages", ["apex", "search", "p11"]).text, "answer 11");

// A failed read is remembered as a failure rather than retried on every
// keystroke: `apex host list` does not exist on today's installed apex, and a
// launcher that retried it per keystroke would spawn one doomed process per
// character.
d = new Driver();
d.demand(true);
d.type("apex");
d.tick(S.DEBOUNCE_MS);
d.finish("hosts", false, "");
d.finish("projects", false, "");
const afterFailure = d.spawns.length;
for (const t of ["apex-", "apex-o", "apex-os"]) { d.type(t); d.tick(1000); }
check("MEASURED: a command that does not exist is not retried on every keystroke",
      d.spawns.length, afterFailure);

// ─────────────────────────────────────────────────────────────────────────────
//  READING WHAT THE CLI SAID
// ─────────────────────────────────────────────────────────────────────────────

// An ARRAY. From apexd/apex/src/agent.rs's ProjectCmd::List { json: true }.
const PROJECTS = JSON.stringify([
    { root: "/home/andre/Projects/apex/apex-os", name: "apex-os", slug: "apex-os",
      languages: ["rust", "shell"], last_opened: 1756900000, capsule: null },
    // Written before capsules existed: the key is simply absent, which
    // #[serde(default)] makes normal rather than a parse failure.
    { root: "/home/andre/Projects/lush", name: "LushLyrics", slug: "lushlyrics",
      languages: [], last_opened: 1756000000 }
]);
const proj = S.parseProjectList(PROJECTS);
check("the project list parses", [proj.ok, proj.projects.length], [true, 2]);
check("a project carries its slug, root and toolchains",
      [proj.projects[0].slug, proj.projects[0].languages], ["apex-os", ["rust", "shell"]]);
check("a missing capsule key is no binding, not a failure",
      proj.projects[1].capsule, "");
check("a null capsule is no binding either", proj.projects[0].capsule, "");
check("an OBJECT is refused where an array was promised",
      S.parseProjectList("{}").reason, "not-an-array");
check("unparsable project output yields nothing",
      S.parseProjectList("no projects yet").ok, false);
check("empty project output yields nothing", S.parseProjectList("").reason, "empty");
check("a nameless project record is skipped",
      S.parseProjectList('[{"root":"/x"}]').projects, []);

// An OBJECT KEYED BY HOST NAME. From apexd/apex/src/host.rs's
// HostCmd::List { json: true }, which builds a serde_json::Map.
const HOSTS = JSON.stringify({
    katana: { ssh: "katana", port: null, note: "build box",
              caps: { probed_at: 1000000, agentd: true, ai: true, podman: true } },
    fileserver: { ssh: "andre@10.0.0.9", port: 2222, note: null,
                  caps: { probed_at: 1000000, agentd: false, podman: true } },
    // Registered with --no-probe. Nothing is known and nothing may be guessed.
    laptop: { ssh: "laptop", port: null, note: null, caps: null }
});
const reg = S.parseHostRegistry(HOSTS);
check("the host registry parses", [reg.ok, reg.hosts.length], [true, 3]);
check("hosts come back sorted by name",
      reg.hosts.map(h => h.name), ["fileserver", "katana", "laptop"]);
check("a never-probed host is not presented as anything else",
      [reg.hosts[2].probed, reg.hosts[2].apex], [false, false]);
check("a probed host without the runtime is probed but not APEX",
      [reg.hosts[0].probed, reg.hosts[0].apex], [true, false]);
check("a probed host with the runtime says so",
      [reg.hosts[1].probed, reg.hosts[1].apex], [true, true]);
check("a host with no ssh field falls back to its name",
      S.parseHostRegistry('{"box":{"caps":null}}').hosts[0].ssh, "box");
check("a null note is an empty note, not the string null",
      reg.hosts[1].note, "build box");

// THE TRAP. The house pattern next door is `if (Array.isArray(fresh))`;
// writing that here leaves the device section permanently empty with nothing
// logged. A top-level array is refused BY NAME so a change of shape fails
// loudly instead of quietly.
check("a top-level ARRAY is refused by name",
      S.parseHostRegistry("[]").reason, "array-not-object");
check("unparsable registry output yields nothing",
      S.parseHostRegistry("error: unrecognized subcommand 'host'").ok, false);
check("an empty registry is a valid, empty registry",
      [S.parseHostRegistry("{}").ok, S.parseHostRegistry("{}").hosts], [true, []]);
// A hand-edited cache holding the string "false" is truthy, and this decides
// what a user is told about their own machine.
check("a capability is read for identity, never for truthiness",
      S.parseHostRegistry('{"b":{"caps":{"agentd":"false"}}}').hosts[0].apex, false);

// ── CAPTURED, NOT RECONSTRUCTED ─────────────────────────────────────────────
// `apex search` output. Two human-readable sections; there is no --json, so
// this reads the human form and the fixture has to be the real bytes.
//
// These lines were captured from dnf5 5.2.18.0 and flatpak on Fedora 43 with
// `cat -A`, which is how the bug they now guard was found: the first version
// of parsePackageSearch was written from memory of dnf4's " : " separator.
// dnf5 uses a TAB and a leading space and repeats its "Matched fields:" header
// between groups, so the regex matched NOTHING — "install blender" offered the
// Flatpak and never the RPM that `apex install` uses for a bare name, silently,
// because "a parser that fails yields no rows" is exactly what it did.
const SEARCH_OUT = [
    "── repository packages ─────────────────────────────────────────────",
    "Matched fields: name (exact)",
    " blender.x86_64\t3D modeling, animation, rendering and post-production",
    "Matched fields: name, summary",
    " YafaRay-blender.x86_64\tBlender integration scripts for YafaRay",
    " blender-luxcorerender.x86_64\tBlender export plugin to luxcorerender",
    " blender-rpm-macros.noarch\tRPM macros for third-party blender addons",
    "",
    "── Flatpak applications ────────────────────────────────────────────",
    "org.blender.Blender\tBlender\tfedora,flathub",
    "org.upbge.UPBGE\tUPBGE\tflathub",
    "de.bforartists.Bforartists\tBforartists\tflathub",
    "",
    "apex resolve <name>  shows which source APEX would use, and why"
].join("\n");
const pkgs = S.parsePackageSearch(SEARCH_OUT);

// The RPM first, because it is the source `apex install` uses for a bare name.
check("package search finds the repository packages before the Flatpaks",
      pkgs.map(p => p.name),
      ["blender", "YafaRay-blender", "blender-luxcorerender", "blender-rpm-macros",
       "org.blender.Blender", "org.upbge.UPBGE", "de.bforartists.Bforartists"]);
// THE REGRESSION. Zero repository rows is what the dnf4-shaped regex produced,
// and it looked exactly like "nothing matched".
check("§15's flagship example finds the RPM, not only the Flatpak",
      pkgs.filter(p => p.source === "rpm").length > 0, true);
check("the architecture is not part of the package name", pkgs[0].name, "blender");
check("the source is recorded",
      pkgs.map(p => p.source),
      ["rpm", "rpm", "rpm", "rpm", "flatpak", "flatpak", "flatpak"]);
check("the summary comes along",
      pkgs[0].summary, "3D modeling, animation, rendering and post-production");
check("dnf5's repeated group header is not a package",
      pkgs.filter(p => /Matched/.test(p.name)), []);
check("the rules and the trailing hint are not packages",
      pkgs.filter(p => p.name.indexOf("─") >= 0 || p.name.indexOf("apex") === 0), []);
// dnf4's separator still works: apex-pkg calls whichever dnf5 is installed, and
// the output of a tool is not a contract.
check("the older ' : ' separator is still read",
      S.parsePackageSearch("gimp.x86_64 : GNU Image Manipulation Program")
          .map(p => p.name), ["gimp"]);
check("empty output is no packages", S.parsePackageSearch(""), []);
check("a package is listed once even if it matched twice",
      S.parsePackageSearch("a.x86_64 : one\na.noarch : two").length, 1);

// A directory listing from `ls -1Ap`.
check("a directory listing separates folders from files",
      S.parseDirListing("Documents/\n.bashrc\nnotes.txt\n"),
      [{ name: "Documents", dir: true }, { name: ".bashrc", dir: false },
       { name: "notes.txt", dir: false }]);
// A launcher that offered ".." would be offering a way to walk to / one Enter
// at a time.
check("dot and dot-dot are never offered",
      S.parseDirListing("./\n../\nx\n").map(e => e.name), ["x"]);

check("a path splits at the last slash",
      S.splitPath("~/Doc/pro"), { dir: "~/Doc/", leaf: "pro" });
check("a path with no slash is all leaf-less directory",
      S.splitPath("~"), { dir: "~", leaf: "" });
check("a trailing slash means no leaf",
      S.splitPath("~/Doc/"), { dir: "~/Doc/", leaf: "" });

// Handing a path with a "~" in it to a shell is how a path becomes a command;
// it is expanded here, from a home the host supplied.
check("~ is expanded by us, never by a shell",
      S.expandHome("~/Doc/", "/home/andre"), "/home/andre/Doc/");
check("a bare ~ is the home directory", S.expandHome("~", "/home/andre"), "/home/andre");
check("an absolute path is left alone", S.expandHome("/etc/", "/home/andre"), "/etc/");
check("without a home there is nothing to expand", S.expandHome("~/x", ""), "");
check("the directory goes after -- so a leading dash is not a flag",
      S.listDirArgv("/-rf/", "").indexOf("--") + 1,
      S.listDirArgv("/-rf/", "").indexOf("/-rf/"));
check("a relative path is refused", S.listDirArgv("Doc/", ""), null);

// ─────────────────────────────────────────────────────────────────────────────
//  CALCULATOR AND UNIT CONVERSION
// ─────────────────────────────────────────────────────────────────────────────

check("§15's own example", S.convert("2.5 GB -> MB").formatted, "2500 MB");
check("to reads the same as ->", S.convert("2.5 GB to MB").formatted, "2500 MB");
check("in reads the same as ->", S.convert("2.5 GB in MB").formatted, "2500 MB");
// GB is 10^9 and GiB is 2^30. A converter that quietly picks one is wrong half
// the time, so both spellings exist and neither is an alias for the other.
check("GiB is not GB", S.convert("1 GiB -> MB").formatted, "1073.741824 MB");
check("length converts", S.convert("100 cm to m").formatted, "1 m");
check("imperial length converts", S.convert("1 mi to km").formatted, "1.609344 km");
check("mass converts", S.convert("1 lb to g").formatted, "453.59237 g");
check("time converts", S.convert("90 min to h").formatted, "1.5 h");
// Temperature is affine, not a scale factor, so it cannot live in the unit
// table and is handled separately rather than approximated into it.
check("temperature is affine, not scaled", S.convert("100 C to F").formatted, "212 F");
check("and the other way", S.convert("32 F to C").formatted, "0 C");
check("and through kelvin", S.convert("0 C to K").formatted, "273.15 K");
check("mismatched dimensions are not a conversion", S.convert("1 kg to m").valid, false);
check("an unknown unit is not a conversion", S.convert("1 foo to bar").valid, false);
check("plain text is not a conversion", S.convert("firefox").valid, false);
check("an empty string is not a conversion", S.convert("").valid, false);
check("a bare number is not a conversion", S.convert("42").valid, false);

// ─────────────────────────────────────────────────────────────────────────────
//  THE SETTINGS INDEX
// ─────────────────────────────────────────────────────────────────────────────
//
// A table entry naming a page that no longer exists would produce a row that
// opens nothing. PageRegistry is QML, so the ids are read out of the file
// itself rather than duplicated here — a copy would drift on the first rename,
// which is exactly the failure being checked for.

const registrySrc = fs.readFileSync(
    path.join(__dirname, "..", "src", "nexus", "PageRegistry.qml"), "utf8");
const pageIds = (registrySrc.match(/"id":\s*"([a-z]+)"/g) || [])
    .map(m => m.replace(/.*"([a-z]+)"$/, "$1"));
check("PageRegistry's ids were actually found", pageIds.length > 4, true);
check("every settings entry names a page that exists",
      S.SETTINGS.filter(s => pageIds.indexOf(s.page) < 0).map(s => s.page), []);
check("every settings entry has a name and keywords",
      S.SETTINGS.filter(s => !s.name || !s.keywords), []);
// §15's own example is a search for a VALUE. Nothing in PageRegistry contains
// the string "144 Hz" — the page is called "Display" — so this is the assertion
// that the index earns its existence.
check("§15's own example finds a settings row",
      S.SETTINGS.filter(s => S.scoreFields(s.name, s.keywords, "144 hz") > 0)
          .map(s => s.page), ["display"]);
check("a plain word finds its page",
      S.SETTINGS.filter(s => S.scoreFields(s.name, s.keywords, "touchpad") > 0)
          .map(s => s.page), ["input"]);

// ─────────────────────────────────────────────────────────────────────────────

console.log("");
console.log(`passed=${passed} failed=${failed}`);
if (failed > 0) {
    console.error(`\n${failed} assertion(s) failed`);
    process.exit(1);
}
console.log("all assertions passed");
