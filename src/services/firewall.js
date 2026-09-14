// ─── firewall.js ─────────────────────────────────────────────────────────────
// Pure logic behind FirewallService (roadmap P1-044): reading what
// `apex firewall status`, `apex firewall list` and `systemctl is-active` say,
// and turning it into something a settings page can render without holding any
// of the reasoning itself.
//
// Kept out of the QML for the same reason src/services/recovery.js is: this is
// the part with edge cases, and tests/firewall-test.js exercises THIS file —
// the one the shell loads — rather than a copy of it. Nothing here does I/O,
// nothing knows about Theme, and every function is data → data, so a node
// process can drive all of it.
//
// ── WHY THE PAGE READS TWO SOURCES AND NOT ONE ──────────────────────────────
//
// `nft list` needs CAP_NET_ADMIN. Run as the user the shell runs as,
// `apex firewall status` answers "cannot read the ruleset" — correctly, and
// that is the whole point of it saying so rather than reporting an empty one.
// But a settings page that says "cannot look" every time it is opened has told
// the user nothing, on a screen that exists to tell them something.
//
// So the two halves come from where each is actually readable:
//
//   is it enforcing   `systemctl show apex-firewall.service` — no privilege,
//                     and it is the unit that owns the ruleset
//   what is open      /etc/apex/firewall.d, which is world-readable precisely
//                     so this question can be answered without root
//
// The unit being active is a PROXY for the ruleset being loaded, not the same
// claim: someone with root can flush the table behind it. statusLine() says
// "running" rather than "enforcing" for that reason, and the page offers
// `sudo apex firewall status` as the command that reads the live ruleset.
//
// ── WHY NOTHING HERE CHANGES ANYTHING ───────────────────────────────────────
//
// `allow` and `deny` need root. The shell's route to root is polkit, and
// P0-016 is the roadmap item where that stops being guesswork. Until then this
// surface shows the commands rather than running them — the same choice
// RecoveryPage makes for rollback, and for the same reason: a button that
// raises an authentication dialog nobody tested is worse than a line of text
// that works.

// ── The unit ────────────────────────────────────────────────────────────────
//
// NOT `systemctl is-active`, which was the first version. Measured on an APEX
// machine whose image predates this firewall:
//
//     systemctl is-active apex-firewall.service   →  inactive   (exit 4)
//
// The same word it gives for a unit that exists and is stopped. A page reading
// that would have told a user whose image has no such unit to run
// `systemctl enable --now apex-firewall`, which cannot work — an instruction
// that fails is worse than no instruction, because it sends them looking for
// the fault in the wrong place.
//
// `systemctl show` answers both questions in one read: LoadState=not-found is
// "this machine has no such unit", and it is a different sentence.
//
// The exit code is not consulted. `systemctl show` exits 0 for a unit that
// does not exist, so there is nothing in it to read.
function parseUnit(exitCode, stdout) {
    var load = "", active = ""
    var lines = (stdout || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
        var kv = lines[i].trim().split("=")
        if (kv.length < 2) continue
        if (kv[0] === "LoadState")   load = kv[1]
        if (kv[0] === "ActiveState") active = kv[1]
    }
    if (load === "" && active === "") return "unknown"   // no systemctl at all
    if (load === "not-found" || load === "masked") return "absent"
    switch (active) {
        case "active":
        case "inactive":
        case "failed":
        case "activating":
        case "deactivating":
            return active
        default:
            return "unknown"
    }
}

// ── The exceptions, from the helper's PROSE ─────────────────────────────────
//
// THIS IS THE FALLBACK PATH, not the one the page normally takes. See
// parseStatusJson below: `apex firewall status --json` is the shape this page
// reads, and prose is what is left on a machine whose `apex` predates the flag.
// The two are kept side by side rather than one being deleted, because the
// machine this shell is being written on today — an L16 whose image predates
// the firewall entirely — answers `unrecognized subcommand 'firewall'`, and a
// page that only knows how to read the new surface would have nothing to say
// on the machines where it most needs to say something.
//
// The helper prints its own lines prefixed `apex-firewall: `; the two lists are
// unprefixed and follow their heading. Parsing the heading rather than the
// indentation means a future line added above cannot silently become an
// exception.
//
// ── A BLANK LINE ENDS A SECTION ─────────────────────────────────────────────
//
// It did not, and that was the bug this whole change exists to close. apex-os
// `c7a28f2c` added a shared-links block to the status screen, set off by blank
// lines on both sides and sitting between the "always allowed" heading and the
// "exceptions you have added" heading:
//
//     always allowed, and not removable here:
//       established replies, loopback, ICMP, DHCP, mDNS/LLMNR, ssh
//
//       sharing this machine's connection on: apexhost, wlan0
//         DHCP and DNS are open on those links only
//
//     exceptions you have added:
//
// A heading is not the only thing that ends a list. With `continue` on a blank
// line, both of those lines were still "under" the always-allowed heading and
// the last one won, so the page told the user that what its firewall never
// drops is "DHCP and DNS are open on those links only". The helper never
// changed a heading; it added a paragraph, and a paragraph was enough.
//
// The fixture that should have caught it had been captured before the line
// existed. tests/fixtures/firewall/ is re-capturable now, and the generator's
// header says why.
function parseStatus(exitCode, stdout) {
    var out = { ok: false, exceptions: [], alwaysAllowed: "", policy: "unknown",
                // Deliberately not read from the prose. The shared-links line
                // is exactly the coupling that broke; re-deriving it from a
                // sentence here would be re-introducing it one function down.
                // A caller that needs this asks for --json, which has a shape.
                hotspotLinks: null }
    var text = stdout || ""
    if (text.trim() === "") return out
    out.ok = true

    var lines = text.split("\n")
    var section = ""
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i]
        var trimmed = line.trim()

        if (trimmed.indexOf("apex-firewall: policy:") === 0) {
            var rest = trimmed.slice("apex-firewall: policy:".length).trim()
            if (rest.indexOf("NOT LOADED") === 0)                 out.policy = "notloaded"
            else if (rest.indexOf("cannot read") === 0)           out.policy = "unreadable"
            else if (rest.indexOf("incoming dropped") === 0)      out.policy = "loaded"
            continue
        }
        if (trimmed.indexOf("apex-firewall: nft is not installed") === 0) {
            out.policy = "absent"
            continue
        }
        if (trimmed === "always allowed, and not removable here:") { section = "always"; continue }
        if (trimmed === "exceptions you have added:")              { section = "exceptions"; continue }
        // A blank line ends the list. See the note above — this one line is
        // the difference between reading the always-allowed sentence and
        // reading whatever paragraph the helper printed after it.
        if (trimmed === "") { section = ""; continue }
        // Anything else the helper says about itself belongs to no list.
        if (trimmed.indexOf("apex-firewall:") === 0) continue

        if (section === "always") {
            out.alwaysAllowed = trimmed
        } else if (section === "exceptions") {
            if (trimmed === "(none)") continue
            out.exceptions.push(parseExceptionLine(trimmed))
        }
    }
    return out
}

// `  syncthing     tcp 22000`  or  `  broken   could not be applied — rejected: tcp notaport`
//
// The rejected form matters more than the accepted one. A tool that listed a
// rejected exception the same way it lists a working one would be telling the
// user a port is open when it is closed, which is the single worst answer this
// surface can give.
function parseExceptionLine(line) {
    var m = line.match(/^(\S+)\s+(tcp|udp)\s+(\S+)$/)
    if (m) return { name: m[1], proto: m[2], port: m[3], rejected: false, detail: "" }
    var r = line.match(/^(\S+)\s+could not be applied\s*[—-]\s*rejected:\s*(.*)$/)
    if (r) return { name: r[1], proto: "", port: "", rejected: true, detail: r[2].trim() }
    // Neither shape. Show the name and say it could not be read, rather than
    // dropping the row: a exception the page cannot parse is still a file the
    // user wrote, and hiding it is how it stays broken.
    var n = line.match(/^(\S+)/)
    return { name: n ? n[1] : line, proto: "", port: "", rejected: true, detail: "unrecognised" }
}

// ── The exceptions, from `apex firewall status --json` ──────────────────────
//
//  WHY THERE IS A SECOND READER AT ALL.
//
//  The page used to read the helper's prose and nothing else, and that broke
//  the way prose coupling always breaks: silently, with both suites green. A
//  sentence has no shape to fail against — a line that moves is still a line,
//  so the parser assigns it to a field and the page renders it. The user is
//  told something false about their firewall and nothing anywhere goes red.
//
//  apex-os `3ab3b6ce` gave the helper a surface with a shape. The contract is
//  written where the helper is (`cmd_status_json` in
//  files/system/libexec/apex-firewall); this is the half that reads it.
//
//  ── WHY THIS VALIDATES INSTEAD OF JUST READING KEYS ────────────────────────
//
//  `JSON.parse(...).always_allowed` is the same defect in a new costume. Rename
//  that key on the apex-os side and this gets `undefined`, which becomes "",
//  which makes the page hide the row — silently, with both suites green again.
//  The coupling would have moved from sentences to key names and drifted just
//  as quietly.
//
//  So a document is only accepted when it has the shape the contract promises,
//  and anything else is `ok: false` — which the page already knows how to say
//  ("Could not be read … so what is open here is unknown rather than
//  nothing"). Drift is LOUD: it costs the page its content, and nobody ships
//  a blank settings page without noticing.
//
//  Required, not exhaustive: the four keys must be present with the right
//  types, and extra keys are ignored. Rejecting a document for carrying a
//  field this shell has not heard of would make any additive change on the
//  apex-os side blank the page on every machine that had not updated in
//  lockstep, and an addition is not the failure mode — a rename or a removal
//  is, and those are caught by requiring presence.
var POLICIES = ["absent", "notloaded", "unreadable", "loaded"]

function _isStr(v)  { return typeof v === "string" }
function _isObj(v)  { return v !== null && typeof v === "object" && !Array.isArray(v) }

// One {name, proto, port, rejected, detail}, or null if it is not one.
function _exceptionOf(e) {
    if (!_isObj(e)) return null
    if (!_isStr(e.name) || !_isStr(e.proto) || !_isStr(e.port) || !_isStr(e.detail)) return null
    if (typeof e.rejected !== "boolean") return null
    // A rejected exception is a port the user believes is open and that the
    // reload refused. Showing a port next to that is the single worst answer
    // this surface can give, so proto/port are dropped here rather than
    // trusted: the helper's contract says a rejected entry carries neither,
    // apex-os's own suite mutation-proves it, and this page does not need to
    // be the second place that is true.
    if (e.rejected) return { name: e.name, proto: "", port: "", rejected: true, detail: e.detail }
    return { name: e.name, proto: e.proto, port: e.port, rejected: false, detail: e.detail }
}

// The exit code is not consulted. The helper answers 0 in every policy state
// on purpose — "the ruleset could not be read" is an answer, not a failure —
// and the case that matters, an `apex` with no `--json` and no `firewall` verb
// at all, writes its usage to stderr and leaves stdout EMPTY. So the document
// is the test, and there is nothing in the code to read.
function parseStatusJson(exitCode, stdout) {
    var bad = { ok: false, exceptions: [], alwaysAllowed: "", policy: "unknown", hotspotLinks: null }
    var text = stdout || ""
    if (text.trim() === "") return bad

    var d
    try { d = JSON.parse(text) } catch (e) { return bad }
    if (!_isObj(d)) return bad

    if (!_isStr(d.policy) || POLICIES.indexOf(d.policy) < 0) return bad
    if (!_isStr(d.always_allowed)) return bad

    // PRESENT, and only then null-or-array. Absent is refused for the same
    // reason a renamed always_allowed is: rename this key to `shared_links`
    // upstream and a reader that treats "missing" as "null" accepts the
    // document, reports null forever, never draws the row, and nothing
    // anywhere goes red. "Missing" and "null" look identical in JavaScript and
    // mean opposite things here — one is a key that moved, the other is the
    // helper saying nobody could look.
    if (!("hotspot_links" in d)) return bad

    // null and [] are different answers and the contract says so: [] means
    // "this machine is sharing its connection on nothing", and a caller who
    // could not read the ruleset has not learned that. Collapsing them here
    // would throw away the distinction the helper went to the trouble of
    // keeping.
    var links = null
    if (d.hotspot_links !== null) {
        if (!Array.isArray(d.hotspot_links)) return bad
        links = []
        for (var k = 0; k < d.hotspot_links.length; k++) {
            if (!_isStr(d.hotspot_links[k])) return bad
            links.push(d.hotspot_links[k])
        }
    }

    if (!Array.isArray(d.exceptions)) return bad
    var out = []
    for (var i = 0; i < d.exceptions.length; i++) {
        var row = _exceptionOf(d.exceptions[i])
        if (row === null) return bad     // one malformed row is a malformed document
        out.push(row)
    }

    return { ok: true, exceptions: out, alwaysAllowed: d.always_allowed,
             policy: d.policy, hotspotLinks: links }
}

// What the page says about a shared connection, or "" for nothing to say.
// Only ever from the JSON path: `hotspotLinks` is null on every prose read.
function hotspotLine(status) {
    if (!status || !status.ok) return ""
    var l = status.hotspotLinks
    if (!l || l.length === 0) return ""
    return "Sharing this machine's connection on " + l.join(", ")
         + ". DHCP and DNS are open on those links only."
}

// ── The catalogue ───────────────────────────────────────────────────────────
function parseCatalogue(exitCode, stdout) {
    var rows = []
    var lines = (stdout || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i]
        if (line.trim() === "") continue
        var m = line.match(/^(\S+)\s+(tcp|udp)\s+(\d+)\s+(.*)$/)
        if (!m) continue          // the NAME/PROTO/PORT header, and nothing else
        rows.push({ name: m[1], proto: m[2], port: m[3], description: m[4].trim() })
    }
    return rows
}

// ── What the page says at the top ───────────────────────────────────────────
// Written here so the wording is decided once. "running" and not "enforcing":
// see the note at the top of this file about what the unit state does and does
// not prove.
function statusLine(unit, status) {
    switch (unit) {
        case "active":
            return "Incoming connections are dropped unless something below opened them."
        case "activating":
            return "Starting."
        case "inactive":
            return "Not running. Every port a program on this machine has open is reachable from the network."
        case "failed":
            return "The firewall unit failed to start. Nothing is filtering incoming connections."
        case "absent":
            return "This machine's image has no firewall unit — it predates the default policy. Nothing is filtering incoming connections."
        default:
            if (status && status.policy === "absent")
                return "nftables is not installed on this machine, so nothing can filter incoming connections."
            return "The firewall unit could not be read on this machine."
    }
}

// Green only for the one state that is actually protecting the machine.
// `absent` is muted rather than red: an older image is not this machine's
// fault and there is nothing the user can press about it, and a page that
// alarms about something unactionable teaches people to ignore its alarms.
function statusTone(unit) {
    switch (unit) {
        case "active":     return "ok"
        case "activating": return "busy"
        case "inactive":   return "warn"
        case "failed":     return "bad"
        default:           return "muted"
    }
}

// ── "Ports you have opened: nothing" is three different facts ───────────────
//
// The page had one sentence for an empty exception list — "Nothing. Every port
// a program on this machine has open is reachable only from this machine
// itself." — and it was shown whenever a sweep had returned and the list came
// back empty. A read that FAILED comes back empty too, and so does a machine
// with no firewall running, so the reassuring half of that sentence was
// printed on the two machines where it is false.
//
// On katana, whose image predates `apex firewall`, the status verb exits
// non-zero with "unrecognized subcommand" and nothing on stdout. The page said
// the machine's ports were reachable only from itself, three lines under a
// headline saying nothing was filtering them at all.
//
// So the sentence is chosen from what is actually known: the read either
// answered or it did not, and the unit either owns a loaded ruleset or does
// not. Returning "" means the page has nothing to say yet and draws nothing —
// which is not the same as saying nothing is open.
function emptyLine(checked, unit, status) {
    if (!checked) return ""
    if (!status || !status.ok)
        return "Could not be read. `apex firewall status` did not answer on this machine, "
             + "so what is open here is unknown rather than nothing."
    if (unit !== "active")
        return "Nothing opened here — and nothing is filtering either, so every port a "
             + "program on this machine has open is reachable from the network."
    return "Nothing. Every port a program on this machine has open is reachable only "
         + "from this machine itself."
}

function allowCommand(name) { return "sudo apex firewall allow " + name }
function denyCommand(name)  { return "sudo apex firewall deny " + name }
var READ_COMMAND  = "sudo apex firewall status"
var START_COMMAND = "sudo systemctl enable --now apex-firewall"

// Which catalogue entries are not currently open, so the page can offer them
// without repeating what is already on.
function unopened(catalogue, exceptions) {
    var open = {}
    for (var i = 0; i < (exceptions || []).length; i++) open[exceptions[i].name] = true
    var out = []
    for (var j = 0; j < (catalogue || []).length; j++)
        if (!open[catalogue[j].name]) out.push(catalogue[j])
    return out
}

if (typeof module !== "undefined" && module.exports)
    module.exports = {
        parseUnit: parseUnit,
        parseStatus: parseStatus,
        parseStatusJson: parseStatusJson,
        hotspotLine: hotspotLine,
        parseExceptionLine: parseExceptionLine,
        parseCatalogue: parseCatalogue,
        statusLine: statusLine,
        statusTone: statusTone,
        emptyLine: emptyLine,
        allowCommand: allowCommand,
        denyCommand: denyCommand,
        unopened: unopened,
        READ_COMMAND: READ_COMMAND,
        START_COMMAND: START_COMMAND
    }
