#!/usr/bin/env node
// P1-044's firewall surface, tested against the file the shell actually loads
// (src/services/firewall.js), not a copy of it.
//
//   node tests/firewall-test.js
//
// ── Where the fixtures come from ─────────────────────────────────────────────
//
// Every payload below was CAPTURED, not invented: the helper from the apex-os
// worktree on branch `task/p1-044-firewall-live` was run on the katana build
// box against a bind-mounted exception directory —
//
//   apex firewall status     (no exceptions)
//   apex firewall status     (two working exceptions and one rejected)
//   apex firewall list
//   systemctl show apex-firewall.service -p LoadState -p ActiveState
//                            (on a machine whose image predates the firewall)
//   systemctl show sshd.service -p LoadState -p ActiveState
//
// Re-captured since, from the policy actually loaded in katana's kernel with
// the unit installed and started, which is the one reading the first pass
// could not take: `status` as root reporting "incoming dropped by default"
// with one working and one rejected exception, and LoadState/ActiveState off
// the real apex-firewall.service in all three of its states rather than off
// sshd standing in for the running one. Every fixture below survived being
// replayed against that output; the sentences and the em dash are the
// helper's own.
//
// The shapes are therefore the helper's, including the parts a hand-written
// fixture would have got wrong: the two `apex-firewall:` prefixed lines come
// BEFORE the first heading, the exception list is sorted by filename rather
// than by the order they were added, the rejected row uses an em dash, and the
// catalogue's header row has no port column value to parse.
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
const F = require(path.join(__dirname, "..", "src", "services", "firewall.js"));

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

// ── Captured: `apex firewall status`, unprivileged, nothing opened ──────────
const STATUS_NONE = `apex-firewall: policy: cannot read the ruleset; reading it needs root
apex-firewall:   try: sudo apex firewall status

always allowed, and not removable here:
  established replies, loopback, ICMP, DHCP, mDNS/LLMNR, ssh

exceptions you have added:
  (none)
`;

// ── Captured: two working exceptions and one the reload rejected ────────────
const STATUS_MIXED = `apex-firewall: policy: cannot read the ruleset; reading it needs root
apex-firewall:   try: sudo apex firewall status

always allowed, and not removable here:
  established replies, loopback, ICMP, DHCP, mDNS/LLMNR, ssh

exceptions you have added:
  broken        could not be applied — rejected: tcp notaport
  mdns          udp 5353
  syncthing     tcp 22000
`;

// ── Captured: the same helper run as root with the policy loaded ────────────
const STATUS_LOADED = `apex-firewall: policy: incoming dropped by default, outgoing allowed

always allowed, and not removable here:
  established replies, loopback, ICMP, DHCP, mDNS/LLMNR, ssh

exceptions you have added:
  (none)
`;

// ── Captured: `apex firewall list` ─────────────────────────────────────────
const LIST = `NAME          PROTO PORT   DESCRIPTION
ssh           tcp   22     Remote shell, and how APEX remote agents and \`apex host run\` reach this machine
http          tcp   80     A web server you are running
https         tcp   443    A web server you are running, over TLS
mdns          udp   5353   Local name discovery, for printers and \`apex host\`
samba         tcp   445    Windows file sharing
nfs           tcp   2049   NFS file sharing
ipp           tcp   631    Sharing a printer attached to this machine
steam-remote  udp   27036  Steam Remote Play from another machine on this network
sunshine      tcp   47989  Sunshine game streaming host
ollama        tcp   11434  A local model server, reachable from other machines
syncthing     tcp   22000  Syncthing peer connections
`;

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

// ── The exception list ──────────────────────────────────────────────────────
console.log("\n-- the exceptions --");
const none = F.parseStatus(0, STATUS_NONE);
check("nothing opened is an empty list, not a row saying (none)", none.exceptions, []);
check("an unprivileged read says the ruleset was unreadable", none.policy, "unreadable");
check("the always-allowed line is carried through verbatim",
      none.alwaysAllowed, "established replies, loopback, ICMP, DHCP, mDNS/LLMNR, ssh");
check("a root read with the policy loaded says loaded",
      F.parseStatus(0, STATUS_LOADED).policy, "loaded");
check("empty output is not a machine with nothing open, it is a read that failed",
      F.parseStatus(0, "").ok, false);

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

// ── The catalogue ───────────────────────────────────────────────────────────
console.log("\n-- the catalogue --");
const cat = F.parseCatalogue(0, LIST);
check("every service is read and the header is not one of them", cat.length, 11);
check("a service keeps its description, spaces and backticks and all",
      cat[0], { name: "ssh", proto: "tcp", port: "22",
                description: "Remote shell, and how APEX remote agents and `apex host run` reach this machine" });
check("what is already open is not offered again",
      F.unopened(cat, mixed.exceptions).map(r => r.name),
      ["ssh", "http", "https", "samba", "nfs", "ipp", "steam-remote", "sunshine", "ollama"]);
check("with nothing open, everything is offered",
      F.unopened(cat, []).length, 11);

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
const READ_OK = { ok: true, exceptions: [], alwaysAllowed: "", policy: "loaded" };
const READ_NO = F.parseStatus(2, "");   // katana today: `unrecognized subcommand`
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
check("an unrecognised subcommand parses as a read that did not answer",
      READ_NO.ok, false);

console.log(failed === 0 ? "\nfirewall: all checks passed" : `\nfirewall: ${failed} FAILED`);
process.exit(failed === 0 ? 0 : 1);
