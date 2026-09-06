// Pure logic behind P1-049's Gaming settings page: reading `apex gaming --json`,
// reading `apex mode status`, and deciding what the page is allowed to claim.
//
// Kept out of the QML so tests/gaming-settings-test.js can exercise it under
// Node — the same file the shell loads, not a copy of it. Nothing here spawns a
// process or touches a file. No CI runner has a compositor, so a behavioural QML
// suite always skips there and a suite that skips proves nothing; this module is
// the half that can be proved anywhere.
//
// ── THE ONE THING THIS PAGE MUST NOT DO ──────────────────────────────────────
//
// Promise automation the OS refuses to perform. `apex mode set --auto` is
// documented one-shot — "APEX ships nothing that re-evaluates this on a timer",
// and `apex workload` repeats it — so a switch labelled "optimise games
// automatically" would describe a daemon that deliberately does not exist. The
// honest shape is an ACTION the user presses and a readout of the mode they are
// actually in, which is why this module exposes no "auto" boolean at all.
//
// ── AND THE ONE IT MUST NOT ASSUME ───────────────────────────────────────────
//
// That the tools are installed. Steam, gamescope and mangoapp are on-demand
// `apex install` packages and are absent from a fresh image; on the machine this
// was written against, all three were missing. `apex gaming --json` already
// reports each one with the reason it is looking, so the page reads that rather
// than probing PATH itself: a second opinion about what is installed is how a
// page starts disagreeing with the session launcher that actually fails.
// ──────────────────────────────────────────────────────────────────────────────

function _isObject(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v)
}

function _str(v) {
    return String(v === undefined || v === null ? "" : v)
}

// ── the on-demand packages, and what each one is for ────────────────────────
//
// Named here rather than rendered from the JSON keys, because "mangoapp: no" is
// not a sentence anybody can act on. The key is the CLI's; the words are for
// the reader. A check the CLI reports and this list does not name still shows
// up — see otherChecks() — so adding a probe on the OS side cannot silently
// vanish from the page.
var TOOLS = [
    { key: "steam",     label: "Steam",
      why: "the games and the Big Picture interface a controller drives" },
    { key: "gamescope", label: "gamescope",
      why: "the small compositor the games run inside, so nothing else draws over them" },
    { key: "mangoapp",  label: "The in-game overlay",
      why: "frames per second while you play, and the only place `apex perf` gets frame times" }
]

// The checks that are about the machine being set up rather than about a
// package being present. Split out because they are not fixed by installing
// anything, so offering an install line beside them would be wrong.
var SETUP = [
    { key: "session_desktop",  label: "Gaming Mode appears at the login screen" },
    { key: "session_launcher", label: "The Gaming Mode session script" },
    { key: "switch_helper",    label: "The Desktop-to-Gaming switch" },
    { key: "switch_sudoers",   label: "Permission for the power menu to switch sessions" },
    { key: "rtprio_limits",    label: "Permission for games to ask for priority" }
]

// ── reading `apex gaming --json` ────────────────────────────────────────────
//
// Read-only on the OS side and it exits non-zero when Gaming Mode would not
// start, so a non-zero exit is data and not a failure. The caller must not treat
// it as one — that is the difference between "your machine is not set up yet"
// and "the probe broke".
function readGaming(raw) {
    var text = _str(raw).trim()
    var empty = {
        ok: false, ready: false, bootsToGame: false, preselected: "",
        checks: {}, gamepads: [], blockers: [], warnings: [],
        installHint: "", error: ""
    }
    if (text === "") {
        empty.error = "apex gaming printed nothing"
        return empty
    }
    var obj
    try {
        obj = JSON.parse(text)
    } catch (e) {
        empty.error = "Could not read the gaming report: " + e
        return empty
    }
    if (!_isObject(obj)) {
        empty.error = "apex gaming did not return a report"
        return empty
    }
    return {
        ok: true,
        ready: obj.ready === true,
        bootsToGame: obj.boots_to_game === true,
        preselected: _str(obj.preselected_session),
        checks: _isObject(obj.checks) ? obj.checks : {},
        gamepads: Array.isArray(obj.gamepads) ? obj.gamepads : [],
        // Sentences written by the CLI, shown verbatim. Paraphrasing them here
        // would make this page a second, worse explanation that drifts from the
        // one the session launcher prints when it refuses to start.
        blockers: Array.isArray(obj.blockers) ? obj.blockers.map(_str) : [],
        warnings: Array.isArray(obj.warnings) ? obj.warnings.map(_str) : [],
        installHint: _str(obj.install_hint),
        error: ""
    }
}

// Did a named check pass? Unknown checks are NOT treated as passing: a page that
// read a missing key as true would report a machine ready on a build whose probe
// had been renamed.
function checkPassed(g, key) {
    if (!g || !g.ok || !_isObject(g.checks)) return false
    var c = g.checks[key]
    return _isObject(c) ? c.value === true : c === true
}

function checkSource(g, key) {
    if (!g || !g.ok || !_isObject(g.checks)) return ""
    var c = g.checks[key]
    return _isObject(c) ? _str(c.source) : ""
}

// The named packages that are not installed, in the order TOOLS lists them.
function missingTools(g) {
    var out = []
    if (!g || !g.ok) return out
    for (var i = 0; i < TOOLS.length; i++)
        if (!checkPassed(g, TOOLS[i].key)) out.push(TOOLS[i])
    return out
}

// Everything the CLI reported that neither list above names. Shown rather than
// dropped: a probe added on the OS side must appear somewhere, or the page
// quietly under-reports what is wrong with the machine.
function otherChecks(g) {
    var known = {}
    var i
    for (i = 0; i < TOOLS.length; i++) known[TOOLS[i].key] = true
    for (i = 0; i < SETUP.length; i++) known[SETUP[i].key] = true

    var out = []
    if (!g || !g.ok || !_isObject(g.checks)) return out
    for (var k in g.checks)
        if (!known[k]) out.push({ key: k, passed: checkPassed(g, k),
                                  source: checkSource(g, k) })
    return out
}

// The command that would fix the missing packages. The CLI's own hint when it
// sent one, because it knows which names its repositories carry; otherwise built
// from the keys, which is a guess and reads like one.
function installLine(g) {
    if (g && g.ok && g.installHint !== "") return g.installHint
    var missing = missingTools(g)
    if (missing.length === 0) return ""
    var names = []
    for (var i = 0; i < missing.length; i++) names.push(missing[i].key)
    return "sudo apex install " + names.join(" ")
}

// One sentence for the top of the page. Deliberately not "ready/not ready": a
// machine can be unable to boot to game and still perfectly able to run games on
// the desktop, and a page that led with a red NO would be telling somebody whose
// games work that they do not.
function readiness(g) {
    if (!g) return ""
    if (!g.ok) return g.error
    if (g.ready) return "This machine can start straight into Gaming Mode."
    var n = missingTools(g).length
    if (n > 0)
        return n === 1
            ? "Gaming Mode needs one more thing installed."
            : "Gaming Mode needs " + n + " more things installed."
    return "Gaming Mode is not ready yet."
}

// ── reading `apex mode status` ──────────────────────────────────────────────
//
// Text, not JSON: `apex mode status --json` is not a thing yet, and the four
// facts it prints are the ones criterion 6 asks to be visible. So this parses a
// report, which is the weakest link on the page and is written to fail loudly
// rather than confidently — an unparsed field comes back "" and the page says it
// could not read it, instead of rendering a default that looks like a reading.
//
// A `--json` on that subcommand would delete this function, and should.
function readModeStatus(raw) {
    var text = _str(raw)
    var out = { ok: false, tier: "", autoSwitch: "", gameMode: "", mode: "", error: "" }
    if (text.trim() === "") {
        out.error = "apex mode status printed nothing"
        return out
    }
    var lines = text.split("\n")
    var seen = {}
    for (var i = 0; i < lines.length; i++) {
        // `key : value`, where the key may hold a space ("game mode").
        var m = /^\s*([a-z][a-z -]*?)\s*:\s*(.+?)\s*$/.exec(lines[i])
        if (!m) continue
        seen[m[1]] = m[2]
    }
    out.tier       = _str(seen["tier"])
    out.autoSwitch = _str(seen["auto-switch"])
    out.gameMode   = _str(seen["game mode"])
    out.mode       = _str(seen["mode"])
    // The mode is the one field the page cannot do without: it is the answer to
    // "what policy am I in". Without it this is a failed read, however many of
    // the others parsed.
    if (out.mode === "") {
        out.error = "apex mode status did not report a mode"
        return out
    }
    out.ok = true
    return out
}

// Is the machine in the gaming policy right now? Compared against the mode id,
// not the label, and lower-cased because the page must not decide policy from
// capitalisation.
function inGamingMode(s) {
    return !!(s && s.ok && s.mode.toLowerCase().indexOf("gaming") === 0)
}

// What the readout says, as one line, or why there is no readout.
function policyLine(s) {
    if (!s) return ""
    if (!s.ok) return s.error
    var bits = ["Mode: " + s.mode]
    if (s.tier !== "")     bits.push("power tier: " + s.tier)
    if (s.gameMode !== "") bits.push("game mode: " + s.gameMode)
    return bits.join("   ·   ")
}

if (typeof module !== "undefined" && module.exports)
    module.exports = {
        TOOLS: TOOLS, SETUP: SETUP,
        readGaming: readGaming, checkPassed: checkPassed, checkSource: checkSource,
        missingTools: missingTools, otherChecks: otherChecks,
        installLine: installLine, readiness: readiness,
        readModeStatus: readModeStatus, inGamingMode: inGamingMode,
        policyLine: policyLine
    }
