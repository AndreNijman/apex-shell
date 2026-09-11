#!/usr/bin/env node
// Tests the APEX Remote pairing logic against the file the shell loads
// (src/services/remotepairing.js), not a copy of it.
//
//   node tests/remote-pairing-test.js
//
// ── Where the fixtures come from ─────────────────────────────────────────────
//
// The JSON below is transcribed from the OS side's own serialisation rather
// than invented. `apex remote devices --json` prints a serde array of
// apex_remote_core::device::Device (apexd/apex-remote-core/src/device.rs),
// whose optional fields carry `#[serde(default)]` and are therefore present as
// `null` rather than absent — which is why the null cases below are the normal
// shape and not a corner one. Read on the apex-os branch task/p1-052-relay at
// 4cc8cb0c.
//
// The `ago` boundaries are transcribed from apexd/apex/src/remote.rs::ago, and
// asserted to match it, because a person who runs the command and then opens
// the page should not have to work out whether two different readings mean the
// same thing.

"use strict";

const path = require("path");
const R = require(path.join(__dirname, "..", "src", "services", "remotepairing.js"));

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

const NOW = 1789155000000;

// ── the pairing payload ──────────────────────────────────────────────────────
// `apex remote pair` without --text wraps the payload in qr_block()'s prose.
// The service passes --text, but the parser refuses prose anyway: a QR drawn
// from a line of explanation is the exact failure `apex remote pair` refuses
// to risk, and "a phone scans it, fails, and the person concludes their camera
// is broken" is the reason it refuses.

const PAYLOAD = "apex-remote:eyJ2IjoxLCJtYWNoaW5lIjoibDE2In0";

check("the payload is taken from stdout as printed", R.payloadOf(PAYLOAD + "\n"), PAYLOAD);
check("surrounding whitespace is not part of the payload",
      R.payloadOf("  " + PAYLOAD + "  \n"), PAYLOAD);
check("the payload is found even when prose is printed around it",
      R.payloadOf(PAYLOAD + "\n\n(No QR code here yet: this terminal build does not\n" +
                  "vendor an encoder, and a wrong QR is worse than none.)\n"), PAYLOAD);
check("prose alone is not a payload",
      R.payloadOf("apex: the service is not running\n"), "");
check("a bare scheme with nothing after it is not a payload",
      R.payloadOf("apex-remote:"), "");
check("another scheme is not a payload",
      R.payloadOf("https://example.invalid/pair"), "");
check("empty stdout is not a payload", R.payloadOf(""), "");
check("no stdout at all is not a crash", R.payloadOf(null), "");
check("the scheme is the one apex-remote-core declares", R.SCHEME, "apex-remote:");

// ── the offer inside the payload ─────────────────────────────────────────────
// The expiry is read by decoding the payload, not by scraping `apex remote
// pair`'s stderr sentence ("It is good for N seconds"), which is prose and
// would break the countdown the first time somebody reworded it. Decoding is
// also the check that a truncated read is refused before a QR is drawn from
// it -- a half-read payload is exactly the "phone scans it, fails, blames its
// camera" failure the whole feature is built around avoiding.

// Built the way apex_remote_core::pairing writes it: compact JSON, base64url,
// no padding, behind the scheme.
function offerPayload(offer) {
    return R.SCHEME + Buffer.from(JSON.stringify(offer)).toString("base64url");
}
const OFFER = {
    v: 1, machine: "l16", key: "AAAA", token: "BBBB",
    lan: ["192.168.1.20:7717"], relay: null, expires_ms: NOW + 180000
};

check("the offer decodes out of the payload",
      R.decodeOffer(offerPayload(OFFER)).expires_ms, NOW + 180000);
check("the machine's name survives the decode",
      R.decodeOffer(offerPayload(OFFER)).machine, "l16");
check("a machine named in something other than ascii is not mojibake",
      R.decodeOffer(offerPayload({ machine: "l16-café-日本", expires_ms: 1 })).machine,
      "l16-café-日本");
check("a payload that is not base64url is refused, not half-decoded",
      R.decodeOffer("apex-remote:!!! not base64 !!!"), null);
check("a truncated payload is refused rather than parsed as much as fits",
      R.decodeOffer(R.SCHEME + Buffer.from('{"v":1,').toString("base64url")), null);
check("an offer with no expiry is not an offer",
      R.decodeOffer(R.SCHEME + Buffer.from('{"v":1}').toString("base64url")), null);
check("a payload without the scheme is not an offer",
      R.decodeOffer("eyJ2IjoxfQ"), null);
check("base64url's two extra characters are the url-safe pair, not + and /",
      [R.fromBase64Url("--__") !== null, R.fromBase64Url("++//")], [true, null]);

// ── the offer's three minutes ────────────────────────────────────────────────

check("the countdown is what is left, in whole seconds",
      R.secondsLeft(NOW + 179000, NOW), 179);
check("an expired offer has no time left, never a negative one",
      R.secondsLeft(NOW - 5000, NOW), 0);
check("no offer has no time left", R.secondsLeft(0, NOW), 0);
check("the countdown reads as time, not as a count of seconds",
      [R.countdown(179), R.countdown(60), R.countdown(9), R.countdown(0)],
      ["2:59", "1:00", "0:09", "0:00"]);

// ── the device list ──────────────────────────────────────────────────────────

const DEVICES = JSON.stringify([
    {
        id: "AAAAAQIDBAUGBwgJ", name: "Pixel 8", public_key: "AAAAAQIDBAUGBwgJCgsMDQ4P",
        paired_ms: NOW - 86400000, last_seen_ms: NOW - 120000, revoked_ms: null,
        requires_user_verification: true, last_path: "lan"
    },
    {
        id: "BBBBAQIDBAUGBwgJ", name: "Old phone", public_key: "BBBBAQIDBAUGBwgJCgsMDQ4P",
        paired_ms: NOW - 8640000000, last_seen_ms: NOW - 8600000000,
        revoked_ms: NOW - 3600000, requires_user_verification: false, last_path: "relay"
    },
    {
        id: "CCCCAQIDBAUGBwgJ", name: "Tablet", public_key: "CCCCAQIDBAUGBwgJCgsMDQ4P",
        paired_ms: NOW - 600000, last_seen_ms: null, revoked_ms: null,
        requires_user_verification: false, last_path: null
    }
]);

const parsed = R.parseDevices(DEVICES);
check("every device in the listing is parsed", parsed.length, 3);
check("the fields the page renders survive parsing",
      [parsed[0].id, parsed[0].name, parsed[0].lastPath, parsed[0].requiresUserVerification],
      ["AAAAAQIDBAUGBwgJ", "Pixel 8", "lan", true]);
check("a null last_seen_ms stays null and does not become zero",
      parsed[2].lastSeenMs, null);
check("a null last_path is an empty string, not the word null",
      parsed[2].lastPath, "");
check("a device with no name falls back to its id, not to blank",
      R.parseDevices('[{"id":"ZZZZ","paired_ms":1}]')[0].name, "ZZZZ");

check("a daemon that is not running does not raise", R.parseDevices(""), []);
check("unparseable output does not raise",
      R.parseDevices("apex: could not reach the service"), []);
check("output that is not an array does not raise",
      R.parseDevices('{"reply":"error"}'), []);
check("an entry with no id is dropped rather than rendered as a blank row",
      R.parseDevices('[{"name":"nameless"},{"id":"OK","name":"kept"}]').length, 1);

// ── revoked is decided by revoked_ms alone, as the daemon decides it ─────────
// Device::is_active() in apex-remote-core reads this field and nothing else.
// A page that disagreed would offer a revoke button for a device that is
// already gone, or withhold one from a device that can still connect.

check("a device with no revoked_ms is active", R.isActive(parsed[0]), true);
check("a device with a revoked_ms is not", R.isActive(parsed[1]), false);
check("a device that never connected is still active", R.isActive(parsed[2]), true);

// ── the four states ──────────────────────────────────────────────────────────

check("a device with a connection open right now is connected",
      R.deviceState(parsed[0], ["AAAAAQIDBAUGBwgJ"]), "connected");
check("the same device with no connection open is merely paired",
      R.deviceState(parsed[0], []), "paired");
check("a revoked device is revoked even while a connection is listed",
      R.deviceState(parsed[1], ["BBBBAQIDBAUGBwgJ"]), "revoked");
check("a device that has never completed a handshake says so",
      R.deviceState(parsed[2], []), "never");
check("connections are read from status, never guessed from last seen",
      // Seen four seconds ago and not in the connection list: idle, not live.
      R.deviceState({ id: "X", lastSeenMs: NOW - 4000, revokedMs: null }, []), "paired");
check("there are exactly four states", R.STATES.length, 4);

// ── the appearance of a state, and the non-hue channel ───────────────────────
// The rule tests/check-color-tokens.sh states: a row does not decide what a
// state looks like. These assertions are what make that checkable.

check("every state has a distinct theme token",
      new Set(R.STATES.map(R.token)).size, 4);
check("no two states share both a token and a weight",
      new Set(R.STATES.map(s => R.token(s) + "/" + R.weight(s))).size, 4);
check("the pair that costs most to confuse differs in weight, not only hue",
      R.weight("connected") !== R.weight("revoked"), true);
check("revoked is the only state carrying the danger token",
      R.STATES.filter(s => R.token(s) === "danger"), ["revoked"]);
check("every state has a label a person can read",
      R.STATES.map(R.label),
      ["connected", "paired", "never connected", "revoked"]);
check("an unknown state degrades to the quiet one rather than throwing",
      [R.token("nonsense"), R.weight("nonsense")], ["subtext", "plain"]);

// ── time, in the units the terminal already uses ─────────────────────────────
// Transcribed from apexd/apex/src/remote.rs::ago -- 0..=59 seconds, 60..=3599
// minutes, 3600..=86399 hours, then days. Both sides of every boundary.

check("a device never seen says never, not 'a long time ago'",
      R.ago(null, NOW), "never");
check("seconds, right up to the minute boundary",
      [R.ago(NOW, NOW), R.ago(NOW - 59000, NOW)], ["0s ago", "59s ago"]);
check("the minute boundary is 60 seconds, as the terminal has it",
      [R.ago(NOW - 60000, NOW), R.ago(NOW - 3599000, NOW)], ["1m ago", "59m ago"]);
check("the hour boundary is 3600 seconds, as the terminal has it",
      [R.ago(NOW - 3600000, NOW), R.ago(NOW - 86399000, NOW)], ["1h ago", "23h ago"]);
check("the day boundary is 86400 seconds, as the terminal has it",
      R.ago(NOW - 86400000, NOW), "1d ago");
check("a clock that went backwards reads as now rather than as the future",
      R.ago(NOW + 5000, NOW), "0s ago");

// ── the summary line ─────────────────────────────────────────────────────────

check("before the first answer the page says nothing rather than 'none'",
      R.summary([], false), "");
check("no devices, once actually asked", R.summary([], true), "No devices paired.");
check("one device is not pluralised",
      R.summary([parsed[0]], true), "1 device paired.");
check("a revoked device is not counted as paired",
      R.summary(parsed, true), "2 devices paired.");

// ── the verification claim, as a sentence and never as a tick ────────────────
// apex-remote-core: "recorded as a requirement the owner set and not as a fact
// about the device". The CLI prints it once at the end rather than as a column
// because "a tick in a table would read as a fact this machine had verified".

const note = R.verificationNote(parsed);
check("the device claiming a biometric lock is named", note.indexOf("Pixel 8"), 0);
check("the sentence says whose claim it is", note.includes("device's own claim"), true);
check("the sentence says this machine cannot check it",
      note.includes("cannot verify it"), true);
check("a revoked device's claim is not repeated back",
      R.verificationNote([parsed[1]]), "");
check("no claim means no sentence, not an empty reassurance",
      R.verificationNote([parsed[2]]), "");

// The absence is the assertion. Nothing exported turns the flag into a
// per-device string or badge, so a row CANNOT render it as a tick without
// adding a function here first -- which is where this test would see it.
check("the flag is exposed only as the sentence, never per device",
      Object.keys(R).filter(k => /verif/i.test(k)), ["verificationNote"]);

// ── status ───────────────────────────────────────────────────────────────────

check("a status reply names the devices connected right now",
      R.parseStatus(JSON.stringify({
          version: 1, machine: "l16", lan: ["192.168.1.20:7717"], relay: null,
          connections: [{ device: "AAAAAQIDBAUGBwgJ", path: "lan", rtt_ms: 12 }]
      })).connectedIds, ["AAAAAQIDBAUGBwgJ"]);
check("a daemon too old to report connections is not an error",
      R.parseStatus(JSON.stringify({ version: 1, machine: "l16" })).connectedIds, []);
check("a service that did not answer is marked not ok",
      R.parseStatus("").ok, false);
check("a service that did answer is marked ok",
      R.parseStatus('{"version":1}').ok, true);

// ── the argv the pages can run ───────────────────────────────────────────────
// Everything through the `apex` CLI. That is the stability surface which
// already handles an absent daemon and a version mismatch, and -- the part
// that matters under test -- it is what headless_begin stubs. A page that
// opened the control socket would walk past the stub and mint a real pairing
// token on whatever machine the suite ran on.

check("every command goes through the apex CLI",
      [R.PAIR_COMMAND[0], R.DEVICES_COMMAND[0], R.STATUS_COMMAND[0],
       R.revokeCommand("x")[0]], ["apex", "apex", "apex", "apex"]);
check("pairing asks for the payload alone, not for qr_block's prose",
      R.PAIR_COMMAND, ["apex", "remote", "pair", "--text"]);
check("the device list is read as json rather than scraped from the table",
      R.DEVICES_COMMAND, ["apex", "remote", "devices", "--json"]);
check("status is read as json", R.STATUS_COMMAND, ["apex", "remote", "status", "--json"]);
check("revoke names the device by id", R.revokeCommand("AAAA"),
      ["apex", "remote", "revoke", "AAAA"]);
check("revoke is the only command that changes anything",
      [R.PAIR_COMMAND, R.DEVICES_COMMAND, R.STATUS_COMMAND]
          .filter(c => /revoke|remove|delete|reset/.test(c.join(" "))), []);

if (failed > 0) {
    console.error(`\n${failed} assertion(s) failed`);
    process.exit(1);
}
console.log("\nall assertions passed");
