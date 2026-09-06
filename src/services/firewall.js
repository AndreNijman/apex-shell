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

// ── The exceptions ──────────────────────────────────────────────────────────
// The helper prints its own lines prefixed `apex-firewall: `; the two lists are
// unprefixed and follow their heading. Parsing the heading rather than the
// indentation means a future line added above cannot silently become an
// exception.
function parseStatus(exitCode, stdout) {
    var out = { ok: false, exceptions: [], alwaysAllowed: "", policy: "unknown" }
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
        if (trimmed === "") continue
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
