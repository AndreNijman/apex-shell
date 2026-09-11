// ─── remotepairing.js ────────────────────────────────────────────────────────
// What `apex remote` says, turned into what the two APEX Remote pages show:
// the pairing payload, the paired-device list, and what each device's state
// looks like.
//
// Nothing here does I/O, holds a colour, or knows about Theme or Quickshell.
// Data in, data out, so `node` drives all of it — the same arrangement as
// remoteagents.js and firewall.js, and for the same reason: this is the half
// with the edge cases in it.
//
// ── Why the state→appearance mapping is HERE and not in a row ────────────────
//
// tests/check-color-tokens.sh states the rule and the incident behind it. The
// Agent Center decided a state's colour inline, as a three-branch ternary, in
// two different row files. Every colour in it was a theme token, so the
// colour-literal check passed, and it was still wrong: seven runtime states
// collapsed onto three values, two of which were the palette's foreground.
// That shipped, and was reported as "APEX agents display only in white".
//
// So a device row does not decide what a state looks like. This file does,
// once, and tests/remote-pairing-test.js measures the result.
//
// ── The weight is not decoration ────────────────────────────────────────────
//
// Every state carries a WEIGHT as well as a token, and agentstate.js's
// reasoning applies unchanged: around one man in twelve cannot use hue to
// separate red from green, and the pair that costs the most to confuse here is
// `revoked` against `connected` — "this device can reach my machine" against
// "this device cannot". Hue alone does not tell those two apart for a
// deuteranope. The weight changes the badge's shape and ink rather than its
// colour, so the distinction survives without hue.
//
// The token names are looked up on Theme by the row (`Theme[token(state)]`),
// which is what keeps this file free of colours while still deciding them.
//
// ── `requires_user_verification` is a claim, not a fact ─────────────────────
//
// The desktop cannot see a fingerprint. What the flag records is that the
// device SAID its key is held behind a biometric or device lock, and
// apex-remote-core/src/device.rs says so at length: "recorded as a requirement
// the owner set and not as a fact about the device". `apex remote devices`
// prints it as a sentence at the end rather than a column, on the stated
// grounds that "a tick in a table would read as a fact this machine had
// verified".
//
// This file therefore offers `verificationNote()`, which produces that
// sentence, and offers nothing that would render as a per-row tick. That is a
// deliberate absence, and tests/remote-pairing-test.js asserts the absence.

"use strict"

// apex_remote_core::pairing::SCHEME. A payload that does not start with this
// is not a pairing offer, and encoding it would produce a QR code that a phone
// scans, fails to understand, and blames itself for.
var SCHEME = "apex-remote:"

// ── the pairing payload ──────────────────────────────────────────────────────

// `apex remote pair --text` prints the payload alone on stdout; the sentences
// for the person go to stderr. Without --text it prints qr_block()'s prose as
// well, which is why the service passes --text and why this refuses anything
// that is not one clean payload line.
//
// Returns "" for anything that is not a pairing offer. The caller shows the
// error it got instead — a QR code drawn from a truncated or prose-wrapped
// payload is exactly the failure `apex remote pair` refuses to risk.
function payloadOf(stdout) {
    if (!stdout) return ""
    var lines = String(stdout).split("\n")
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim()
        if (line.indexOf(SCHEME) === 0 && line.length > SCHEME.length) return line
    }
    return ""
}

// base64url, no padding -- what apex_remote_core::pairing writes. Hand-rolled
// because QML's JS engine has no `atob`, and because a 20-line decoder is a
// better trade than a dependency in a tree that vendors no JavaScript.
// Returns null for anything that is not valid base64url, so a truncated
// payload is a failure the page can report rather than half an offer.
var B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

function fromBase64Url(text) {
    var bits = 0, acc = 0, out = []
    for (var i = 0; i < text.length; i++) {
        var v = B64.indexOf(text.charAt(i))
        if (v < 0) return null
        acc = (acc << 6) | v
        bits += 6
        if (bits >= 8) {
            bits -= 8
            out.push((acc >> bits) & 0xff)
        }
    }
    // UTF-8 back to text. The offer is ASCII except possibly the machine name.
    var s = "", j = 0
    while (j < out.length) {
        var c = out[j++]
        if (c < 0x80) { s += String.fromCharCode(c); continue }
        var extra = c >= 0xf0 ? 3 : c >= 0xe0 ? 2 : 1
        var cp = c & (extra === 1 ? 0x1f : extra === 2 ? 0x0f : 0x07)
        for (var k = 0; k < extra && j < out.length; k++) cp = (cp << 6) | (out[j++] & 0x3f)
        if (cp > 0xffff) {
            cp -= 0x10000
            s += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff))
        } else {
            s += String.fromCharCode(cp)
        }
    }
    return s
}

// The PairingOffer inside the payload, or null.
//
// The expiry is read from here rather than scraped out of `apex remote pair`'s
// stderr sentence ("good for N seconds"), which is prose and would break the
// countdown the first time somebody reworded it. Decoding also proves the
// payload is a well-formed offer before a QR is drawn from it -- which is the
// check that stops the page rendering a truncated read as a scannable code.
function decodeOffer(payload) {
    if (!payload || payload.indexOf(SCHEME) !== 0) return null
    var json = fromBase64Url(payload.slice(SCHEME.length))
    if (json === null) return null
    var offer
    try {
        offer = JSON.parse(json)
    } catch (e) {
        return null
    }
    if (!offer || typeof offer !== "object" || typeof offer.expires_ms !== "number") return null
    return offer
}

// Seconds until the offer stops being accepted, floored at zero. The daemon
// mints an offer good for three minutes and pairing exactly one device, so a
// page showing a stale code is showing something that cannot work.
function secondsLeft(expiresMs, nowMs) {
    if (!expiresMs) return 0
    var left = Math.floor((expiresMs - nowMs) / 1000)
    return left > 0 ? left : 0
}

// "2:59". Minutes and seconds because three minutes is the whole window, and
// "179 seconds" is not a number anybody reads as time.
function countdown(seconds) {
    var s = Math.max(0, Math.floor(seconds))
    return Math.floor(s / 60) + ":" + (s % 60 < 10 ? "0" : "") + (s % 60)
}

// ── the device list ──────────────────────────────────────────────────────────

// `apex remote devices --json` prints a JSON array of
// apex_remote_core::device::Device. Anything else — a daemon that is not
// running, a version that predates the command, a partial read — is an empty
// list rather than a throw, because a settings page that raises does not
// render at all.
function parseDevices(text) {
    var parsed
    try {
        parsed = JSON.parse(text)
    } catch (e) {
        return []
    }
    if (!Array.isArray(parsed)) return []
    var out = []
    for (var i = 0; i < parsed.length; i++) {
        var d = parsed[i]
        if (!d || typeof d !== "object" || !d.id) continue
        out.push({
            id: String(d.id),
            // A device with no name is not an error: the name is chosen on the
            // phone and is display-only. Falling back to the id keeps the row
            // identifiable rather than blank.
            name: d.name ? String(d.name) : String(d.id),
            pairedMs: Number(d.paired_ms) || 0,
            lastSeenMs: d.last_seen_ms === null || d.last_seen_ms === undefined
                ? null : Number(d.last_seen_ms),
            revokedMs: d.revoked_ms === null || d.revoked_ms === undefined
                ? null : Number(d.revoked_ms),
            requiresUserVerification: !!d.requires_user_verification,
            lastPath: d.last_path ? String(d.last_path) : ""
        })
    }
    return out
}

// Device::is_active(): revoked_ms alone decides it. Mirrored rather than
// re-derived from anything else, because the daemon enforces on this field and
// a page that disagreed would offer a revoke button for a device that is gone
// or hide one for a device that can still connect.
function isActive(device) {
    return !!device && (device.revokedMs === null || device.revokedMs === undefined)
}

// The four states a row can be in. `connected` is not a field on Device — it
// comes from `apex remote status --json`, which lists the connections open
// right now — so it is passed in rather than guessed from lastSeenMs. A device
// seen four seconds ago is not necessarily connected now.
var STATES = ["connected", "paired", "never", "revoked"]

function deviceState(device, connectedIds) {
    if (!isActive(device)) return "revoked"
    var ids = connectedIds || []
    for (var i = 0; i < ids.length; i++) {
        if (ids[i] === device.id) return "connected"
    }
    // Paired and never once completed a handshake. Worth telling apart from
    // "paired and idle": it usually means the phone has not been able to reach
    // this machine at all, which is a different problem from a phone that is
    // merely asleep.
    if (device.lastSeenMs === null || device.lastSeenMs === undefined) return "never"
    return "paired"
}

// token → a NAME on Theme, looked up by the row rather than switched on, so
// this file stays the only one that decides which token a state gets.
// weight → the redundant, non-hue channel. See the header.
var TONES = {
    connected: { token: "success", weight: "tint",    label: "connected" },
    paired:    { token: "subtext", weight: "plain",   label: "paired" },
    never:     { token: "warning", weight: "outline", label: "never connected" },
    revoked:   { token: "danger",  weight: "solid",   label: "revoked" }
}

function token(state) { return (TONES[state] || TONES.paired).token }
function weight(state) { return (TONES[state] || TONES.paired).weight }
function label(state) { return (TONES[state] || TONES.paired).label }

// ── time ─────────────────────────────────────────────────────────────────────

// The same units and the same boundaries as `apex remote devices` prints in a
// terminal (apexd/apex/src/remote.rs::ago). Deliberately identical: a person
// who runs the command and then opens the page should not have to work out
// whether "2m ago" and "a couple of minutes ago" are the same reading.
function ago(ms, nowMs) {
    if (ms === null || ms === undefined) return "never"
    var secs = Math.floor(Math.max(0, nowMs - ms) / 1000)
    if (secs < 60) return secs + "s ago"
    if (secs < 3600) return Math.floor(secs / 60) + "m ago"
    if (secs < 86400) return Math.floor(secs / 3600) + "h ago"
    return Math.floor(secs / 86400) + "d ago"
}

// ── what the page says about the list as a whole ─────────────────────────────

// Counts only what can still connect. A revoked device is kept in the store so
// the listing can show that it WAS revoked, and counting it as "paired" would
// tell the owner their machine is reachable by a phone they took away.
function summary(devices, checked) {
    if (!checked) return ""
    var active = 0
    for (var i = 0; i < devices.length; i++) if (isActive(devices[i])) active++
    if (active === 0) return "No devices paired."
    return active === 1 ? "1 device paired." : active + " devices paired."
}

// The sentence `apex remote devices` prints, for the same reason and in the
// same shape. "" when no active device claims it, so the page draws nothing
// rather than an empty reassurance.
function verificationNote(devices) {
    var names = []
    for (var i = 0; i < devices.length; i++) {
        var d = devices[i]
        if (d.requiresUserVerification && isActive(d)) names.push(d.name)
    }
    if (names.length === 0) return ""
    return names.join(", ") + " said its key is held behind a biometric or " +
        "device lock. That is the device's own claim; this machine cannot verify it."
}

// ── `apex remote status --json` ──────────────────────────────────────────────

// Only the parts the two pages need: whether the service answered at all, and
// which device ids have a connection open right now.
function parseStatus(text) {
    var s
    try {
        s = JSON.parse(text)
    } catch (e) {
        return { ok: false, connections: [], connectedIds: [], relay: "", lan: [] }
    }
    if (!s || typeof s !== "object") {
        return { ok: false, connections: [], connectedIds: [], relay: "", lan: [] }
    }
    var conns = Array.isArray(s.connections) ? s.connections : []
    var ids = []
    for (var i = 0; i < conns.length; i++) {
        if (conns[i] && conns[i].device) ids.push(String(conns[i].device))
    }
    return {
        ok: true,
        connections: conns,
        connectedIds: ids,
        relay: s.relay ? String(s.relay) : "",
        lan: Array.isArray(s.lan) ? s.lan : []
    }
}

// ── the argv the service runs ────────────────────────────────────────────────
//
// Named here so tests/check-remote-pairing.sh can assert what the page is able
// to run, rather than reading it out of QML. Everything goes through the
// `apex` CLI: it is the stability surface that already handles an absent
// daemon and a version mismatch, and — the part that matters under test — it
// is what `headless_begin` stubs. A page that opened the control socket
// directly would walk straight past the stub and mint a real pairing token on
// whatever machine the suite ran on.
var PAIR_COMMAND = ["apex", "remote", "pair", "--text"]
var DEVICES_COMMAND = ["apex", "remote", "devices", "--json"]
var STATUS_COMMAND = ["apex", "remote", "status", "--json"]

function revokeCommand(id) {
    return ["apex", "remote", "revoke", String(id)]
}

// Node (tests) sees `module`; the QML engine does not, and ignores this.
if (typeof module !== "undefined" && module.exports)
    module.exports = {
        SCHEME: SCHEME,
        STATES: STATES,
        TONES: TONES,
        PAIR_COMMAND: PAIR_COMMAND,
        DEVICES_COMMAND: DEVICES_COMMAND,
        STATUS_COMMAND: STATUS_COMMAND,
        payloadOf: payloadOf,
        fromBase64Url: fromBase64Url,
        decodeOffer: decodeOffer,
        secondsLeft: secondsLeft,
        countdown: countdown,
        parseDevices: parseDevices,
        isActive: isActive,
        deviceState: deviceState,
        token: token,
        weight: weight,
        label: label,
        ago: ago,
        summary: summary,
        verificationNote: verificationNote,
        parseStatus: parseStatus,
        revokeCommand: revokeCommand
    }
