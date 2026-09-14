#!/usr/bin/env node
// P1-044's firewall surface, tested against the file the shell actually loads
// (src/services/firewall.js), not a copy of it.
//
//   node tests/firewall-test.js
//
// ── Where the fixtures come from ─────────────────────────────────────────────
//
// tests/fixtures/firewall/*.txt and *.json, and NOTHING here is written by
// hand. Every one of them is the output of the shipped
// files/system/libexec/apex-firewall, run under an nft shim against a
// redirected exception directory by
//
//     tests/fixtures/firewall/gen-firewall-fixtures.sh [apex-os-dir]
//
// which also has a `--check` mode that re-captures into a temporary directory
// and diffs. Read that script's header before touching anything here: it says
// which two of the old inline fixtures had silently drifted away from the tool,
// and what each drift cost.
//
// The short version, because it is the reason this file was restructured:
// fixtures used to live inline under a header saying they had been CAPTURED.
// They had been. Nothing re-captured them, so the suite went on checking a
// shape the helper could no longer print — green the whole time, while the
// settings page told users the wrong thing about their firewall.
//
// The shapes are therefore the helper's, including the parts a hand-written
// fixture would have got wrong: the two `apex-firewall:` prefixed lines come
// BEFORE the first heading, the shared-links block is set off by blank lines
// on both sides, the exception list is sorted by filename rather than by the
// order they were added, the rejected row uses an em dash, and the catalogue's
// header row has no port column value to parse.
//
// ── The one that matters most ───────────────────────────────────────────────
//
// `systemctl is-active` was the first version of the unit read. On katana,
// whose image has no apex-firewall unit at all, it answers `inactive` — the
// same word it gives for a unit that exists and is stopped. The page would
// have told that user to run `systemctl enable --now apex-firewall`, which
// cannot work. The `absent` case below is that bug, kept as a test.

"use strict";

const path = require("path");
const fs = require("fs");
const F = require(path.join(__dirname, "..", "src", "services", "firewall.js"));

const FIX = path.join(__dirname, "fixtures", "firewall");

// A fixture that is missing reads as "" and makes every check against it pass
// for the wrong reason, so reading one is a hard failure rather than a default.
function fixture(name) {
    const p = path.join(FIX, name);
    let text;
    try { text = fs.readFileSync(p, "utf8"); }
    catch (e) {
        console.error(`FATAL: ${p} is missing. Regenerate with\n` +
                      `  tests/fixtures/firewall/gen-firewall-fixtures.sh <apex-os-dir>`);
        process.exit(2);
    }
    if (text.trim() === "") {
        console.error(`FATAL: ${p} is empty; a capture that produced nothing is not a fixture.`);
        process.exit(2);
    }
    return text;
}

let failed = 0;
function check(name, got, want) {
    const ok = JSON.stringify(got) === JSON.stringify(want);
    if (!ok) {
        failed++;
        console.error(`FAIL ${name}\n  got:  ${JSON.stringify(got)}\n  want: ${JSON.stringify(want)}`);
    } else {
        console.log(`ok   ${name}`);
    }
}

// Captured: the six policy states the helper can be in, each as prose and as
// JSON, plus the catalogue. See gen-firewall-fixtures.sh for what each one is.
const STATUS_NONE     = fixture("unreadable-none.txt");    // unprivileged, nothing opened
const STATUS_MIXED    = fixture("unreadable-mixed.txt");   // two working, one rejected
const STATUS_LOADED   = fixture("loaded-none.txt");        // root, policy loaded, nothing shared
const STATUS_HOTSPOT  = fixture("loaded-hotspot.txt");     // root, policy loaded, two shared links
const STATUS_NOTLOADED = fixture("notloaded.txt");
const STATUS_NFTGONE  = fixture("nft-absent.txt");
const LIST            = fixture("list.txt");

const J_NONE     = fixture("unreadable-none.json");
const J_MIXED    = fixture("unreadable-mixed.json");
const J_LOADED   = fixture("loaded-none.json");
const J_HOTSPOT  = fixture("loaded-hotspot.json");
const J_NOTLOADED = fixture("notloaded.json");
const J_NFTGONE  = fixture("nft-absent.json");

const ALWAYS = "established replies, loopback, ICMP, DHCP, mDNS/LLMNR, ssh";

// ── The unit ────────────────────────────────────────────────────────────────
console.log("\n-- the unit --");
check("a machine whose image has no firewall unit reads as absent, not inactive",
      F.parseUnit(0, "LoadState=not-found\nActiveState=inactive\nSubState=dead\n"), "absent");
check("a masked unit is absent too, because enabling it will not work",
      F.parseUnit(0, "LoadState=masked\nActiveState=inactive\n"), "absent");
check("a loaded, running unit is active",
      F.parseUnit(0, "LoadState=loaded\nActiveState=active\nSubState=running\n"), "active");
check("a loaded, stopped unit is inactive",
      F.parseUnit(0, "LoadState=loaded\nActiveState=inactive\n"), "inactive");
check("a unit that failed to start says so",
      F.parseUnit(0, "LoadState=loaded\nActiveState=failed\n"), "failed");
check("no systemctl at all is unknown, not inactive",
      F.parseUnit(127, ""), "unknown");

// Two sentences that must differ, because they ask for different things.
console.log("\n-- and what each one tells the user --");
check("absent does not offer a command that cannot work",
      F.statusLine("absent", null).indexOf("predates") >= 0, true);
check("inactive does",
      F.statusLine("inactive", null).indexOf("Not running") >= 0, true);
check("absent is muted rather than alarming, because nothing can be pressed",
      F.statusTone("absent"), "muted");
check("inactive warns", F.statusTone("inactive"), "warn");
check("active is the only green", F.statusTone("active"), "ok");

// ── The exception list, from --json ─────────────────────────────────────────
// This is the path the page takes. The prose one below it is the fallback.
console.log("\n-- the exceptions, from --json --");
const jnone = F.parseStatusJson(0, J_NONE);
check("nothing opened is an empty list, not a row saying (none)", jnone.exceptions, []);
check("an unprivileged read says the ruleset was unreadable", jnone.policy, "unreadable");
check("the always-allowed sentence comes through verbatim", jnone.alwaysAllowed, ALWAYS);
check("a caller who could not read the ruleset is told nothing about sharing",
      jnone.hotspotLinks, null);

const jloaded = F.parseStatusJson(0, J_LOADED);
check("a root read with the policy loaded says loaded", jloaded.policy, "loaded");
// The distinction the helper went to trouble to keep, and the one a careless
// reader collapses: [] is "sharing nothing", null is "could not look".
check("a readable ruleset sharing nothing is an EMPTY list, not null",
      jloaded.hotspotLinks, []);
check("and the always-allowed sentence is still the traffic the policy never drops",
      jloaded.alwaysAllowed, ALWAYS);

const jhot = F.parseStatusJson(0, J_HOTSPOT);
check("two shared links come through as two names", jhot.hotspotLinks, ["apexhost", "wlan0"]);
check("the shared-links block does not become the always-allowed sentence",
      jhot.alwaysAllowed, ALWAYS);
check("and the page has a sentence for it",
      F.hotspotLine(jhot),
      "Sharing this machine's connection on apexhost, wlan0. DHCP and DNS are open on those links only.");
check("sharing nothing is not a sentence at all", F.hotspotLine(jloaded), "");
check("and neither is a read that could not look", F.hotspotLine(jnone), "");

const jmixed = F.parseStatusJson(0, J_MIXED);
check("three exceptions are found", jmixed.exceptions.length, 3);
check("a working exception carries its protocol and port",
      jmixed.exceptions[2], { name: "syncthing", proto: "tcp", port: "22000", rejected: false, detail: "" });
check("a rejected exception is marked rejected and keeps its reason",
      jmixed.exceptions[0], { name: "broken", proto: "", port: "", rejected: true, detail: "tcp notaport" });

check("no policy loaded at all is notloaded, not unreadable",
      F.parseStatusJson(0, J_NOTLOADED).policy, "notloaded");
check("and it has not learned anything about sharing either",
      F.parseStatusJson(0, J_NOTLOADED).hotspotLinks, null);
check("a machine with no nft says absent", F.parseStatusJson(0, J_NFTGONE).policy, "absent");

// ── The shape, and what happens when it drifts ──────────────────────────────
//
// The whole reason this surface is JSON is that a document has a shape a
// sentence does not. That only buys anything if the shape is CHECKED: a reader
// that does `JSON.parse(x).always_allowed` and renders the result is the same
// prose coupling in a new costume, because a renamed key gives `undefined`,
// which renders as nothing, which is silent.
console.log("\n-- a document that is not the contract --");
function mutated(f) { const d = JSON.parse(J_MIXED); f(d); return JSON.stringify(d); }

check("prose fed to the JSON reader is a read that did not answer",
      F.parseStatusJson(0, STATUS_MIXED).ok, false);
check("empty output is not a machine with nothing open, it is a read that failed",
      F.parseStatusJson(0, "").ok, false);
check("a truncated document is not half-read",
      F.parseStatusJson(0, J_MIXED.slice(0, J_MIXED.length / 2)).ok, false);
check("a JSON array is not a status document",
      F.parseStatusJson(0, "[]").ok, false);
check("null is not a status document", F.parseStatusJson(0, "null").ok, false);
check("a policy word outside the four the helper can print is refused",
      F.parseStatusJson(0, mutated(d => { d.policy = "enforcing"; })).ok, false);
// The one the advisor of this change named: rename it upstream and a key-reader
// silently hides the row instead of saying it could not read the machine.
check("always_allowed renamed upstream is a failed read, not an empty sentence",
      F.parseStatusJson(0, mutated(d => { d.allowed = d.always_allowed; delete d.always_allowed; })).ok,
      false);
check("policy missing altogether is refused",
      F.parseStatusJson(0, mutated(d => { delete d.policy; })).ok, false);
check("exceptions missing altogether is refused",
      F.parseStatusJson(0, mutated(d => { delete d.exceptions; })).ok, false);
check("hotspot_links as a string is refused",
      F.parseStatusJson(0, mutated(d => { d.hotspot_links = "apexhost"; })).ok, false);
// "missing" and "null" are identical in JavaScript and opposite here: one is a
// key that got renamed, the other is the helper saying nobody could look. A
// reader that defaults a missing key to null reports "not sharing" forever and
// never goes red, which is the drift this file exists to make loud.
check("hotspot_links missing altogether is refused, not read as null",
      F.parseStatusJson(0, mutated(d => { d.shared_links = d.hotspot_links; delete d.hotspot_links; })).ok,
      false);
check("hotspot_links explicitly null is still a good document",
      F.parseStatusJson(0, mutated(d => { d.hotspot_links = null; })).hotspotLinks, null);
check("one exception row missing its name makes the whole document unreadable",
      F.parseStatusJson(0, mutated(d => { delete d.exceptions[1].name; })).ok, false);
check("rejected as the string \"false\" is not a boolean and is refused",
      F.parseStatusJson(0, mutated(d => { d.exceptions[0].rejected = "false"; })).ok, false);
// Additive, not a rename: a field this shell has never heard of must not blank
// the page on every machine that has not updated in lockstep.
check("a field this reader does not know about is ignored, not fatal",
      F.parseStatusJson(0, mutated(d => { d.zones = ["home"]; })).ok, true);
// Defence in depth: the port belongs to apex-os's contract, but "that port is
// open" about a port the reload refused is the one answer this page must never
// give, so it is dropped here too.
check("a rejected row arriving WITH a port does not get to show one",
      F.parseStatusJson(0, mutated(d => { d.exceptions[0].port = "443"; d.exceptions[0].proto = "tcp"; })).exceptions[0],
      { name: "broken", proto: "", port: "", rejected: true, detail: "tcp notaport" });

// ── The exception list, from the prose fallback ─────────────────────────────
// Still reachable: an `apex` that predates `--json`. Everything here used to be
// the only path.
console.log("\n-- the exceptions, from the prose fallback --");
const none = F.parseStatus(0, STATUS_NONE);
check("nothing opened is an empty list, not a row saying (none)", none.exceptions, []);
check("an unprivileged read says the ruleset was unreadable", none.policy, "unreadable");
check("the always-allowed line is carried through verbatim", none.alwaysAllowed, ALWAYS);
check("a root read with the policy loaded says loaded",
      F.parseStatus(0, STATUS_LOADED).policy, "loaded");
check("empty output is not a machine with nothing open, it is a read that failed",
      F.parseStatus(0, "").ok, false);

// ── The regression this whole change exists for ─────────────────────────────
//
// apex-os c7a28f2c added a shared-links block to the status screen, set off by
// blank lines, between the always-allowed heading and the exceptions heading.
// The parser treated a blank line as nothing at all, so those lines were still
// "under" the always-allowed heading and the last one won. On a root session
// with the policy loaded the page reported, as the traffic its firewall never
// drops:
//
//     DHCP and DNS are open on those links only
//
// Both fixtures below now contain that block, because both are captures of a
// helper that prints it.
console.log("\n-- a paragraph after a list does not join the list --");
check("with nothing shared, the always-allowed sentence survives the block",
      F.parseStatus(0, STATUS_LOADED).alwaysAllowed, ALWAYS);
check("with two links shared, it survives a two-line block",
      F.parseStatus(0, STATUS_HOTSPOT).alwaysAllowed, ALWAYS);
check("and the shared links do not become exceptions the user added",
      F.parseStatus(0, STATUS_HOTSPOT).exceptions.map(e => e.name), ["broken", "mdns"]);
check("the prose path does not claim to know what is shared",
      F.parseStatus(0, STATUS_HOTSPOT).hotspotLinks, null);
check("a helper whose nft is missing reads as absent through the prose too",
      F.parseStatus(0, STATUS_NFTGONE).policy, "absent");
check("and one whose policy is not loaded says notloaded",
      F.parseStatus(0, STATUS_NOTLOADED).policy, "notloaded");

const mixed = F.parseStatus(0, STATUS_MIXED);
check("three exceptions are found", mixed.exceptions.length, 3);
check("a working exception carries its protocol and port",
      mixed.exceptions[2], { name: "syncthing", proto: "tcp", port: "22000", rejected: false, detail: "" });
// The row that must never be drawn like the others: the user believes this
// port is open and it is closed.
check("a rejected exception is marked rejected and keeps its reason",
      mixed.exceptions[0], { name: "broken", proto: "", port: "", rejected: true, detail: "tcp notaport" });
check("a line in neither shape is shown as unreadable rather than dropped",
      F.parseExceptionLine("weird"), { name: "weird", proto: "", port: "", rejected: true, detail: "unrecognised" });

// The two readers describe one machine. A captured pair is the only way to ask
// this: both fixtures came out of the same helper run against the same
// exception directory, seconds apart.
console.log("\n-- prose and JSON describe the same machine --");
check("the same exceptions, in the same order",
      F.parseStatus(0, STATUS_MIXED).exceptions,
      F.parseStatusJson(0, J_MIXED).exceptions);
check("the same always-allowed sentence",
      F.parseStatus(0, STATUS_HOTSPOT).alwaysAllowed,
      F.parseStatusJson(0, J_HOTSPOT).alwaysAllowed);
check("the same policy word, in all four states",
      [STATUS_NONE, STATUS_LOADED, STATUS_NOTLOADED, STATUS_NFTGONE].map(t => F.parseStatus(0, t).policy),
      [J_NONE, J_LOADED, J_NOTLOADED, J_NFTGONE].map(t => F.parseStatusJson(0, t).policy));

// ── The catalogue ───────────────────────────────────────────────────────────
// Counted from the fixture rather than written down: the old inline copy said
// eleven, and the shipped catalogue had grown to twelve with `apex-remote`
// months before anyone noticed the suite was describing an older image.
console.log("\n-- the catalogue --");
const cat = F.parseCatalogue(0, LIST);
const listRows = LIST.trim().split("\n").length - 1;   // every line but the header
check("every service is read and the header is not one of them", cat.length, listRows);
check("a service keeps its description, spaces and backticks and all",
      cat[0], { name: "ssh", proto: "tcp", port: "22",
                description: "Remote shell, and how APEX remote agents and `apex host run` reach this machine" });
check("apex-remote is in the shipped catalogue, hyphen and all",
      cat.filter(r => r.name === "apex-remote").map(r => r.port), ["7717"]);
check("what is already open is not offered again",
      F.unopened(cat, mixed.exceptions).map(r => r.name).indexOf("mdns"), -1);
check("and what is not open still is",
      F.unopened(cat, mixed.exceptions).length, cat.length - 2);   // mdns and syncthing
check("with nothing open, everything is offered", F.unopened(cat, []).length, cat.length);

// ── The commands ────────────────────────────────────────────────────────────
console.log("\n-- the commands the page shows --");
check("allow", F.allowCommand("mdns"), "sudo apex firewall allow mdns");
check("deny",  F.denyCommand("mdns"),  "sudo apex firewall deny mdns");
check("the read command is the one that needs root", F.READ_COMMAND, "sudo apex firewall status");

// ── "nothing is open" is three different facts ──────────────────────────────
// An empty exception list comes back from a machine with nothing open, from a
// machine whose status read failed, and from a machine with no firewall
// running. The reassuring sentence belongs to one of them.
console.log("\n-- an empty exception list --");
const READ_OK = { ok: true, exceptions: [], alwaysAllowed: "", policy: "loaded", hotspotLinks: [] };
// This laptop today: `apex` has no `firewall` subcommand at all, so clap writes
// its usage to stderr, leaves stdout empty and exits 2. Measured 2026-09-14.
const READ_NO = F.parseStatusJson(2, "");
check("before the first sweep the page says nothing at all",
      F.emptyLine(false, "active", READ_OK), "");
check("a status read that failed is not reported as nothing being open",
      /unknown rather than nothing/.test(F.emptyLine(true, "active", READ_NO)), true);
check("and it does not claim the ports are reachable only locally",
      /only\s+from this machine/.test(F.emptyLine(true, "active", READ_NO)), false);
check("with no unit running, an empty list does not read as protection",
      /reachable from the network/.test(F.emptyLine(true, "absent", READ_OK)), true);
check("the reassuring sentence needs the unit running AND the read answering",
      F.emptyLine(true, "active", READ_OK),
      "Nothing. Every port a program on this machine has open is reachable only from this machine itself.");
check("an apex with no firewall verb parses as a read that did not answer",
      READ_NO.ok, false);

console.log(failed === 0 ? "\nfirewall: all checks passed" : `\nfirewall: ${failed} FAILED`);
process.exit(failed === 0 ? 0 : 1);
