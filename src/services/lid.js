// ─── lid.js ──────────────────────────────────────────────────────────────────
// Pure logic behind LidService, Config → Closing the Lid, and the Quick
// Settings tile (roadmap P1-063). Andre's request, in his words:
//
//   "if i close my laptop lid without shutting down, most things pause to save
//    battery, but all agents and whatever theyre using/doing or whatever can
//    stay running, also staying with the vpn — like if i close my laptop at
//    school and codex is running (which needs vpn to work) it keeps working."
//
// Everything here is data → data. It reads `apex lid status --json` and
// `apex lid report --json` and turns them into something a page can render
// without holding any of the reasoning itself, so tests/lid-test.js can drive
// THIS file — the one the shell loads — under node.
//
// ── THE RULE THIS FILE EXISTS TO ENFORCE ────────────────────────────────────
//
// **Every accessor returns a fully-populated object, on every path, including
// the failure paths.** `statusView("", 127)` returns a status whose `logind`,
// `work`, `thermal`, `charge`, `vpn` and `decision` are all objects with every
// field present; `reportView("", 1)` returns a `period` object with
// `present: false` rather than `period: null`.
//
// That is not defensive habit. It is the bug PrivacyPage shipped six weeks
// ago and the reason this file was written this way from the first line:
//
//     TypeError: Cannot read property 'brokered' of null
//
// `permissions.js` returned `session: null` for a report it could not read,
// PrivacyPage binds `session.brokered.join(", ")` inside a section whose
// `visible` is false — and **a binding inside an invisible section is still
// evaluated by the engine**. The page threw on every single load. qmllint
// parsed it, the node suite drove the parser without rendering a binding, and
// a static wiring checker read the wiring, which was correct. Only
// instantiating the page under a compositor could see it.
//
// This page has strictly more nested objects than that one did, so it has
// strictly more of that hazard. The defence is here, in the shape, rather than
// in `foo ? foo.bar : ""` at fifty binding sites — one of which would be
// forgotten.
//
// ── THE SECOND RULE: A FAILED READ IS NOT A CALM MACHINE ────────────────────
//
// `ok: false` with a reason is not the same answer as "the lid policy says
// release". A tile that rendered an unreadable machine as "nothing running,
// suspends normally" would tell an owner their laptop will behave at the exact
// moment it stopped being able to check.
//
// ── THE THIRD: `policy_error` IS A NOTE, NOT A FAILURE ──────────────────────
//
// `apex lid status --json` run by an ordinary user on a machine where root has
// a live `/run/user/0` ALWAYS carries
// `policy_error: "/root/.config/apex/lid.toml: Permission denied"`. The OS
// side reports every candidate policy file it could not read, deliberately and
// correctly — "permission denied is not absence", and a silently skipped pin
// is a machine doing the opposite of what its owner asked.
//
// But it is the normal state of a healthy machine, so a page that painted it
// in the danger tone would cry wolf on every load and teach the owner to
// ignore the one time it matters. `policyNote` carries it; `ok` is unaffected.

// ── the six decisions, in the OS side's own spelling ────────────────────────
//
// `keep-working`, `release` and `guard-suspend` are LidDecision's serde tags
// (`#[serde(tag = "decision", rename_all = "kebab-case")]`). They are matched
// as strings and an unrecognised one falls through to "unknown" rather than
// being treated as any of the three — a future fourth arm must not silently
// read as "release", which is the arm that lets the machine suspend.
var DECISION_LABEL = {
    "keep-working": "Keeps working",
    "release": "Suspends on a close",
    "guard-suspend": "A guard is about to suspend it"
};

var DECISION_TONE = {
    "keep-working": "active",
    "release": "dim",
    "guard-suspend": "danger"
};

// The five guards, in Guard::as_str's spelling. Three of them are "the machine
// would not say", and they are kept apart from the two that are a real reading
// because they mean different things to the owner: one is "your laptop is
// hot", the other is "your laptop cannot tell you whether it is hot", and the
// second is the one worth fixing.
var GUARD_LABEL = {
    "thermal": "too hot",
    "thermal-unreadable": "temperature unreadable",
    "thermal-no-sensor": "no temperature sensor",
    "battery": "battery floor",
    "battery-unreadable": "charge unreadable"
};

function guardLabel(g) {
    if (!g) return "";
    return Object.prototype.hasOwnProperty.call(GUARD_LABEL, g) ? GUARD_LABEL[g] : g;
}

// ── safe defaults, one per nested object ────────────────────────────────────
//
// Each of these is what the corresponding binding sees before the first sweep
// returns AND after a sweep that failed. There is no other state.

function emptyLogind() {
    return {
        // `null` is a THIRD answer here and is not `false`. logind consults
        // HandleLidSwitchDocked (default `ignore`) BEFORE any inhibitor, so on
        // a docked machine the lid does nothing with or without APEX — and
        // "could not be established" is not "it will act".
        actsOnLid: null,
        actsKnown: false,
        docked: null,
        dockedKnown: false,
        externalDisplays: 0,
        blockInhibited: "",
        lidBlocked: false,
        headline: "Whether this machine acts on the lid could not be established",
        detail: "",
        tone: "dim"
    };
}

function emptyWork() {
    return { kind: "unknown", live: 0, why: "", text: "Live work could not be read", tone: "dim" };
}

function emptyThermal() {
    return { kind: "unknown", celsius: null, criticalC: null, sensor: "", headroomC: null,
             text: "Temperature could not be read", tone: "dim" };
}

function emptyCharge() {
    return { kind: "unknown", percent: null, why: "", text: "Charge could not be read", tone: "dim" };
}

function emptyVpn() {
    return { state: "unknown", name: "", text: "The VPN could not be read", tone: "dim" };
}

function emptyDecision() {
    return { id: "unknown", label: "Unknown", tone: "dim", why: "",
             guard: "", guardLabel: "", holdsInhibitor: false };
}

function emptyStatus() {
    return {
        ok: false,
        reason: "",
        pin: "auto",
        enabled: true,
        policySource: "",
        policyNote: "",
        holdsInhibitor: false,
        holders: [],
        holderError: "",
        batteryFloorPct: 0,
        lid: "unknown",
        logind: emptyLogind(),
        work: emptyWork(),
        thermal: emptyThermal(),
        charge: emptyCharge(),
        vpn: emptyVpn(),
        decision: emptyDecision()
    };
}

function emptyPeriod() {
    return {
        // `present` rather than a null period, for the reason at the top.
        present: false,
        closedAt: 0,
        openedAt: 0,
        stillClosed: false,
        durationSecs: 0,
        durationText: "",
        sessionsAtClose: 0,
        why: "",
        endedBy: "",
        endedByLabel: "",
        peakC: null,
        poweredDown: [],
        skipped: [],
        vpn: [],
        vpnHeld: null,
        vpnText: "",
        chargeCost: null,
        chargeText: "",
        summary: ""
    };
}

function emptyReport() {
    return { ok: false, reason: "", has: false, period: emptyPeriod() };
}

// ── small readers ───────────────────────────────────────────────────────────

function str(v) {
    return typeof v === "string" ? v : "";
}

function num(v) {
    return typeof v === "number" && isFinite(v) ? v : null;
}

function intOr(v, fallback) {
    return typeof v === "number" && isFinite(v) ? Math.round(v) : fallback;
}

function readJson(text, exitCode, what) {
    if (typeof text !== "string" || text.trim() === "") {
        return {
            doc: null,
            reason: exitCode === 127
                ? "apex is not on PATH, so the lid policy could not be read"
                : "`apex lid " + what + "` produced no output, so nothing could be read"
        };
    }
    var doc;
    try {
        doc = JSON.parse(text);
    } catch (e) {
        return { doc: null, reason: "`apex lid " + what + "` produced output this could not read" };
    }
    if (!doc || typeof doc !== "object") {
        return { doc: null, reason: "`apex lid " + what + "` produced no object" };
    }
    return { doc: doc, reason: "" };
}

/// "4m 12s", "12s", "2h 3m". Seconds are kept below an hour because the whole
/// point of a short period is telling 40s from 400s.
function duration(secs) {
    var s = Math.max(0, Math.round(typeof secs === "number" && isFinite(secs) ? secs : 0));
    var h = Math.floor(s / 3600);
    var m = Math.floor((s % 3600) / 60);
    var r = s % 60;
    if (h > 0) return h + "h " + m + "m";
    if (m > 0) return m + "m " + r + "s";
    return r + "s";
}

// ── the inputs, each into a sentence ────────────────────────────────────────

function workView(raw) {
    var out = emptyWork();
    if (!raw || typeof raw !== "object") return out;
    if (raw.work === "sessions") {
        out.kind = "sessions";
        out.live = intOr(raw.live, 0);
        out.tone = out.live > 0 ? "active" : "dim";
        out.text = out.live === 0
            ? "No agent session is running"
            : out.live + " live agent session" + (out.live === 1 ? "" : "s");
        return out;
    }
    if (raw.work === "unreadable") {
        // NOT folded into "zero sessions", and the direction matters: a machine
        // that cannot tell whether anything is running suspends, because a
        // laptop that stays awake on an unanswered question cooks in a bag.
        out.kind = "unreadable";
        out.why = str(raw.why);
        out.tone = "danger";
        out.text = "Live work could not be read — " + (out.why || "no reason given");
    }
    return out;
}

function thermalView(raw, ceilingC, headroomC) {
    var out = emptyThermal();
    if (!raw || typeof raw !== "object") return out;
    if (raw.thermal === "celsius") {
        out.kind = "celsius";
        out.celsius = num(raw.c);
        out.criticalC = num(raw.critical_c);
        out.sensor = str(raw.sensor);
        out.tone = "active";
        if (out.celsius === null) {
            out.text = "The sensor gave no reading";
            out.tone = "dim";
            return out;
        }
        var now = out.celsius.toFixed(1) + " °C";
        if (out.criticalC !== null) {
            out.headroomC = out.criticalC - out.celsius;
            out.text = (out.sensor ? out.sensor + " " : "") + now + ", "
                + out.headroomC.toFixed(1) + " °C below its own "
                + out.criticalC.toFixed(1) + " °C critical trip";
            if (typeof headroomC === "number" && out.headroomC <= headroomC) out.tone = "danger";
        } else {
            out.text = (out.sensor ? out.sensor + " " : "") + now
                + ", no declared critical trip"
                + (typeof ceilingC === "number" ? " (backstop " + ceilingC.toFixed(1) + " °C)" : "");
            if (typeof ceilingC === "number" && out.celsius >= ceilingC) out.tone = "danger";
        }
        return out;
    }
    if (raw.thermal === "no-sensor") {
        out.kind = "no-sensor";
        out.text = "This machine reports no temperature at all";
        out.tone = "danger";
        return out;
    }
    if (raw.thermal === "unreadable") {
        out.kind = "unreadable";
        out.text = "A sensor is there and would not say — " + (str(raw.why) || "no reason given");
        out.tone = "danger";
    }
    return out;
}

function chargeView(raw, floorPct) {
    var out = emptyCharge();
    if (!raw || typeof raw !== "object") return out;
    if (raw.charge === "ac") {
        out.kind = "ac";
        out.text = "On mains";
        out.tone = "active";
        return out;
    }
    if (raw.charge === "battery") {
        out.kind = "battery";
        out.percent = intOr(raw.percent, null);
        out.text = (out.percent === null ? "On battery" : out.percent + "% on battery")
            + (typeof floorPct === "number" && floorPct > 0 ? " (floor " + floorPct + "%)" : "");
        out.tone = (out.percent !== null && typeof floorPct === "number" && out.percent <= floorPct)
            ? "danger" : "active";
        return out;
    }
    if (raw.charge === "no-battery") {
        out.kind = "no-battery";
        out.text = "No battery — this is not a laptop";
        out.tone = "dim";
        return out;
    }
    if (raw.charge === "unreadable") {
        out.kind = "unreadable";
        out.why = str(raw.why);
        out.text = "Charge could not be read — " + (out.why || "no reason given");
        out.tone = "danger";
    }
    return out;
}

function vpnView(raw) {
    var out = emptyVpn();
    if (!raw || typeof raw !== "object") return out;
    var state = raw.state && typeof raw.state === "object" ? str(raw.state.vpn) : "";
    out.name = str(raw.name);
    if (state === "up") {
        out.state = "up";
        out.tone = "active";
        out.text = out.name ? "Up (" + out.name + ")" : "Up";
    } else if (state === "down") {
        // The answer the whole criterion exists to catch.
        out.state = "down";
        out.tone = "danger";
        out.text = out.name ? "DOWN (" + out.name + ")" : "DOWN";
    } else if (state === "none") {
        out.state = "none";
        out.tone = "dim";
        out.text = "No tunnel is up";
    } else if (state === "unreadable") {
        out.state = "unknown";
        out.tone = "danger";
        out.text = "The VPN could not be read — "
            + (str(raw.state.why) || "no reason given");
    }
    return out;
}

function decisionView(raw) {
    var out = emptyDecision();
    if (!raw || typeof raw !== "object") return out;
    var id = str(raw.decision);
    if (!id) return out;
    out.id = id;
    out.why = str(raw.why);
    out.guard = str(raw.guard);
    out.guardLabel = guardLabel(out.guard);
    out.label = Object.prototype.hasOwnProperty.call(DECISION_LABEL, id)
        ? DECISION_LABEL[id] : id;
    out.tone = Object.prototype.hasOwnProperty.call(DECISION_TONE, id)
        ? DECISION_TONE[id] : "dim";
    out.holdsInhibitor = id === "keep-working";
    return out;
}

/// The frame every other line on the page sits inside.
///
/// This is the finding round 2 landed and the reason the page leads with it:
/// **the L16 is docked**, `Docked=true` with `card1-DP-1 connected`, and logind
/// consults `HandleLidSwitchDocked` — default `ignore` — BEFORE it consults any
/// inhibitor. So on this machine the lid already does nothing, with or without
/// APEX holding the lock, and a page that said "keeps working" without saying
/// that would be claiming credit for somebody else's behaviour.
function logindView(raw) {
    var out = emptyLogind();
    if (!raw || typeof raw !== "object") return out;
    out.externalDisplays = intOr(raw.external_displays, 0);
    out.blockInhibited = str(raw.block_inhibited);
    out.lidBlocked = out.blockInhibited.indexOf("handle-lid-switch") >= 0;
    if (typeof raw.docked === "boolean") {
        out.docked = raw.docked;
        out.dockedKnown = true;
    }
    if (typeof raw.acts_on_lid === "boolean") {
        out.actsOnLid = raw.acts_on_lid;
        out.actsKnown = true;
    }
    if (!out.actsKnown) return out;
    if (out.actsOnLid) {
        out.tone = "active";
        out.headline = "This machine acts on the lid, so the inhibitor is what decides";
        out.detail = out.lidBlocked
            ? "handle-lid-switch is blocked right now"
            : "handle-lid-switch is not blocked right now";
        return out;
    }
    out.tone = "warn";
    out.headline = out.externalDisplays > 0
        ? "logind will not act on the lid — " + out.externalDisplays
          + " external display" + (out.externalDisplays === 1 ? "" : "s") + " connected"
        : "logind will not act on the lid — it reports this machine as docked";
    out.detail = "HandleLidSwitchDocked (default `ignore`) is consulted before any "
        + "inhibitor, so this machine already stays awake with the lid shut and APEX "
        + "is not what is doing it. Unplug the display and this becomes APEX's job again."
        + (out.lidBlocked ? " The lid inhibitor is held as well." : "");
    return out;
}

// ── `apex lid status --json` ────────────────────────────────────────────────

function statusView(text, exitCode) {
    var out = emptyStatus();
    var read = readJson(text, exitCode, "status");
    if (!read.doc) {
        out.reason = read.reason;
        return out;
    }
    var doc = read.doc;
    out.ok = true;
    out.pin = str(doc.pin) || "auto";
    out.enabled = doc.enabled !== false;
    out.policySource = str(doc.policy_source);
    // A note, never a failure. See the header.
    out.policyNote = str(doc.policy_error);
    out.holdsInhibitor = doc.holds_inhibitor === true;
    out.holders = Array.isArray(doc.inhibitor_holders) ? doc.inhibitor_holders.map(str) : [];
    out.holderError = str(doc.inhibitor_error);
    out.batteryFloorPct = intOr(doc.battery_floor_pct, 0);

    var inputs = doc.inputs && typeof doc.inputs === "object" ? doc.inputs : {};
    out.lid = (inputs.lid && typeof inputs.lid === "object") ? (str(inputs.lid.state) || "unknown")
                                                            : "unknown";
    out.logind = logindView(doc.logind);
    out.work = workView(inputs.work);
    out.thermal = thermalView(inputs.thermal, num(doc.thermal_ceiling_c), num(doc.thermal_headroom_c));
    out.charge = chargeView(inputs.charge, out.batteryFloorPct);
    out.vpn = vpnView(doc.vpn);
    out.decision = decisionView(doc.decision);
    return out;
}

// ── `apex lid report --json` ────────────────────────────────────────────────
//
// Andre's sixth sentence: "after reopening, the machine says what happened —
// how long it stayed up, what ran, whether the VPN held, what the battery cost
// was". Four things, and all four are asserted separately below, because a
// summary line that named three of them would read fine and answer less.

function reportView(text, exitCode) {
    var out = emptyReport();
    var read = readJson(text, exitCode, "report");
    if (!read.doc) {
        out.reason = read.reason;
        return out;
    }
    out.ok = true;
    // An explicit refusal from the OS side — a record that exists and could not
    // be read — is NOT "nothing has happened yet".
    if (str(read.doc.error) !== "") {
        out.ok = false;
        out.reason = str(read.doc.error);
        return out;
    }
    var p = read.doc.period;
    if (!p || typeof p !== "object") {
        // A real, readable "no period yet". `has` stays false and `period` is
        // still an object every binding can walk.
        return out;
    }
    out.has = true;
    out.period = periodView(p, read.doc);
    return out;
}

function periodView(p, doc) {
    var out = emptyPeriod();
    out.present = true;
    out.closedAt = intOr(p.closed_at, 0);
    out.openedAt = intOr(p.opened_at, 0);
    out.stillClosed = out.openedAt === 0;
    var last = intOr(p.last_seen, out.closedAt);
    out.durationSecs = Math.max(0, (out.openedAt > 0 ? out.openedAt : last) - out.closedAt);
    out.durationText = duration(out.durationSecs);
    out.sessionsAtClose = intOr(p.sessions_at_close, 0);
    out.why = str(p.why);
    out.endedBy = str(p.ended_by);
    out.endedByLabel = guardLabel(out.endedBy);
    out.peakC = num(p.peak_c);
    out.poweredDown = Array.isArray(p.powered_down) ? p.powered_down.map(str) : [];
    out.skipped = Array.isArray(p.skipped) ? p.skipped.map(function (s) {
        return { what: str(s && s.what), why: str(s && s.why) };
    }) : [];
    out.vpn = Array.isArray(p.vpn) ? p.vpn.map(function (s) {
        var state = (s && s.state && typeof s.state === "object") ? str(s.state.vpn) : "";
        return {
            at: intOr(s && s.at, 0),
            offsetSecs: Math.max(0, intOr(s && s.at, 0) - out.closedAt),
            name: str(s && s.name),
            state: state || "unknown"
        };
    }) : [];

    // `vpn_held` comes from the OS side, which reads the timeline IN ORDER —
    // and that ordering is the whole of the defect round 2 fixed: `read_vpn`
    // has no memory, a tunnel that went away answers `none`, and a set-wise
    // reading of Up, Up, None, None printed "the VPN held" about a VPN that
    // dropped. It is taken from there rather than recomputed here, because two
    // implementations of that rule is how they come to disagree.
    out.vpnHeld = (doc && typeof doc.vpn_held === "boolean") ? doc.vpn_held : null;
    out.vpnText = out.vpnHeld === true ? "The VPN held for the whole period"
                : out.vpnHeld === false ? "The VPN DROPPED during the period"
                : "No VPN state to report";

    out.chargeCost = chargeCost(p);
    out.chargeText = out.chargeCost === null ? "Battery cost not recorded"
                   : out.chargeCost > 0 ? out.chargeCost + "% of battery used"
                   : "No battery used";

    out.summary = str(doc && doc.summary) || composeSummary(out);
    return out;
}

function chargeCost(p) {
    var a = intOr(p.charge_at_close, null);
    var b = intOr(p.charge_last, null);
    if (a === null || b === null) return null;
    return a - b;
}

/// The fallback sentence, for a record written by a driver that did not send
/// one. Same four facts in the same order as `ClosedPeriod::summary`.
function composeSummary(v) {
    var s = v.sessionsAtClose === 1 ? "session" : "sessions";
    var out = "Lid closed for " + v.durationText + " with " + v.sessionsAtClose
        + " agent " + s + " still running";
    if (v.vpnHeld === true) out += "; the VPN held";
    else if (v.vpnHeld === false) out += "; the VPN DROPPED";
    else out += "; no VPN state to report";
    if (v.chargeCost !== null) {
        out += v.chargeCost > 0 ? "; " + v.chargeCost + "% of battery" : "; no battery used";
    }
    if (v.endedBy) out += "; ended by the " + v.endedBy + " guard";
    return out;
}

// ── the pin, which is the only thing this surface writes ────────────────────

var PINS = ["auto", "on", "off"];

/// The argv for a pin change, or null for anything that is not one of the three.
///
/// `apex lid pin` writes `~/.config/apex/lid.toml` and needs no privilege by
/// design — the inhibitor itself is `allow_active=yes` for an ordinary session,
/// so the only thing a root-owned pin would buy is a password prompt every time
/// this tile is tapped. A polkit prompt appearing anywhere on this surface is a
/// defect, not an inconvenience.
function pinArgv(state) {
    if (PINS.indexOf(state) < 0) return null;
    return ["apex", "lid", "pin", state];
}

/// What a TAP on the Quick Settings tile means.
///
/// **on ↔ auto, never off.** `off` means "always suspend on a close, whatever
/// is running", which is a deliberate choice with a real consequence — an agent
/// mid-build dies at the next lid close — and it is not something a fingertip
/// on a two-state tile should be able to select by accident. `off` is reachable
/// from the page, where it sits next to the sentence explaining it.
function tileToggle(pin) {
    return pin === "on" ? "auto" : "on";
}

function pinLabel(pin) {
    if (pin === "on") return "Always keep working";
    if (pin === "off") return "Always suspend";
    return "Follow live work";
}

/// The Quick Settings tile, decided here so node can assert it.
///
/// `on` is the PIN and not the decision, and that distinction is the whole
/// design: a tile lit because an agent happens to be running would go dark when
/// the agent finished, and an owner would read that as their setting having
/// been forgotten. The pin is what they chose; the decision is what the machine
/// is doing about it, and it goes in the sublabel.
function tileView(status) {
    var s = status && typeof status === "object" ? status : emptyStatus();
    var out = { on: s.pin === "on", icon: "󰶐", label: "Lid stays awake", sublabel: "" };
    if (!s.ok) {
        out.sublabel = "unreadable";
        return out;
    }
    if (s.logind.actsKnown && !s.logind.actsOnLid) {
        // Said on the tile, not only on the page: this machine's lid does
        // nothing whatever this control says, and the tile is where somebody
        // looks before they trust it.
        out.sublabel = "docked — logind ignores the lid";
        return out;
    }
    if (!s.logind.actsKnown) {
        out.sublabel = "lid behaviour unknown";
        return out;
    }
    if (s.pin === "off") {
        out.sublabel = "pinned: always suspend";
        return out;
    }
    if (s.decision.id === "guard-suspend") {
        out.sublabel = s.decision.guardLabel || "a guard fired";
        return out;
    }
    if (s.pin === "on") {
        out.sublabel = "pinned on";
        return out;
    }
    out.sublabel = s.work.kind === "sessions" && s.work.live > 0
        ? s.work.live + " agent session" + (s.work.live === 1 ? "" : "s")
        : s.work.kind === "unreadable" ? "work unreadable"
        : "nothing running";
    return out;
}

/// The one-line answer to "will my laptop keep working if I shut it now?"
///
/// Three answers, never two. "Could not be established" is not "yes", and the
/// docked case is neither — the machine stays awake and APEX is not the reason.
function headline(status) {
    var s = status && typeof status === "object" ? status : emptyStatus();
    if (!s.ok) return "The lid policy could not be read";
    if (!s.enabled) return "Lid handling is switched off in the policy file";
    if (s.logind.actsKnown && !s.logind.actsOnLid) {
        return "This machine already ignores the lid, and APEX is not why";
    }
    if (!s.logind.actsKnown) return "Whether this machine acts on the lid could not be established";
    if (s.decision.id === "keep-working") return "Shutting the lid now keeps the work running";
    if (s.decision.id === "guard-suspend") {
        return "A guard is about to suspend this machine"
            + (s.decision.guardLabel ? " — " + s.decision.guardLabel : "");
    }
    if (s.decision.id === "release") return "Shutting the lid now suspends, as it always did";
    return "What the lid would do could not be established";
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        statusView: statusView,
        reportView: reportView,
        periodView: periodView,
        emptyStatus: emptyStatus,
        emptyReport: emptyReport,
        emptyPeriod: emptyPeriod,
        workView: workView,
        thermalView: thermalView,
        chargeView: chargeView,
        vpnView: vpnView,
        decisionView: decisionView,
        logindView: logindView,
        tileView: tileView,
        tileToggle: tileToggle,
        pinArgv: pinArgv,
        pinLabel: pinLabel,
        headline: headline,
        guardLabel: guardLabel,
        duration: duration
    };
}
