#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
//  lid-test.js — what src/services/lid.js decides (roadmap P1-063).
//
//      node tests/lid-test.js
//
//  Drives the file the shell actually loads, not a copy of it.
//
//  ── Where the fixtures come from ────────────────────────────────────────────
//
//  tests/fixtures/lid/*.json is serde's own output from a real `apex lid`
//  binary, produced by tests/fixtures/lid/gen-lid-fixtures.sh. None of it was
//  written from memory, and that matters more here than usual: `apex lid
//  status --json` is nine nested objects deep and six of them are internally
//  tagged enums (`{"thermal":"celsius","c":…}`, `{"decision":"guard-suspend",
//  "guard":…}`). A hand-authored fixture would keep agreeing with a parser that
//  no longer matches the machine — a green suite over a blank page.
//
//  Two of the seven cases cannot be produced by the binary: under
//  `APEX_LID_ROOT` the driver logs rather than runs every external program, so
//  `busctl` never answers and `logind.docked` comes back null. The
//  undocked-and-acting cases are therefore DERIVED — `withLogind()` edits
//  `logind` on a real document and leaves every other field alone — rather than
//  authored, so the rest of the field names in them are still the machine's.
//
//  ── The assertion this file exists for ──────────────────────────────────────
//
//  `noNullsAnywhere` walks the entire returned shape, on every failure path,
//  and fails on a null or undefined at any depth. That is PrivacyPage's bug
//  stated as a test: `permissions.js` answered `session: null`, the page binds
//  `session.brokered.join(", ")` inside a section whose `visible` is false, and
//  A BINDING INSIDE AN INVISIBLE SECTION IS STILL EVALUATED. qmllint passed,
//  the node suite passed, the wiring checker passed, and the page threw on
//  every single load. This page has strictly more nested objects than that one.
//
//  The one deliberate exception is a tri-state: `actsOnLid`, `docked`,
//  `celsius`, `criticalC`, `percent`, `peakC`, `chargeCost` and `vpnHeld` are
//  null when the machine WOULD NOT SAY, which is a third answer and not the
//  same as false or zero. Those are listed by name in `TRISTATE` — a nulled
//  field that is not on that list is a defect, and adding one to the list is a
//  decision somebody has to make on purpose.
// ─────────────────────────────────────────────────────────────────────────────
"use strict";

const fs = require("fs");
const path = require("path");
const L = require(path.join(__dirname, "..", "src", "services", "lid.js"));

const FIX = path.join(__dirname, "fixtures", "lid");
const raw = (n) => fs.readFileSync(path.join(FIX, n), "utf8");
const doc = (n) => JSON.parse(raw(n));

let failed = 0;
function check(name, got, want) {
    if (JSON.stringify(got) === JSON.stringify(want)) {
        console.log(`ok   ${name}`);
    } else {
        failed++;
        console.error(`FAIL ${name}\n  got:  ${JSON.stringify(got)}\n  want: ${JSON.stringify(want)}`);
    }
}
const checkTrue = (n, g) => check(n, !!g, true);
function checkHas(name, hay, needle) {
    if (typeof hay === "string" && hay.indexOf(needle) >= 0) {
        console.log(`ok   ${name}`);
    } else {
        failed++;
        console.error(`FAIL ${name}\n  ${JSON.stringify(hay)}\n  does not contain ${JSON.stringify(needle)}`);
    }
}
function section(s) { console.log(`\n── ${s} ──`); }

// The fields allowed to be null, by full path. Everything else, at any depth,
// must be a value a binding can walk.
const TRISTATE = new Set([
    "actsOnLid", "docked",                      // logind would not say
    "celsius", "criticalC", "headroomC",        // no sensor, or no declared trip
    "percent",                                  // no battery, or it would not say
    "peakC", "chargeCost", "vpnHeld"            // not recorded during the period
]);

function noNullsAnywhere(name, obj) {
    const bad = [];
    (function walk(v, p) {
        if (v === null || v === undefined) {
            if (!TRISTATE.has(p.split(".").pop())) bad.push(p || "(root)");
            return;
        }
        if (Array.isArray(v)) { v.forEach((e, i) => walk(e, `${p}[${i}]`)); return; }
        if (typeof v === "object") {
            for (const k of Object.keys(v)) walk(v[k], p ? `${p}.${k}` : k);
        }
    })(obj, "");
    check(`${name}: nothing in the shape is null or undefined`, bad, []);
}

// Derive a logind object onto a real document without touching anything else.
function withLogind(base, l) {
    const d = JSON.parse(JSON.stringify(base));
    d.logind = Object.assign({}, d.logind, l);
    return d;
}
const S = (d) => L.statusView(JSON.stringify(d), 0);

// ═════════════════════════════════════════════════════════════════════════════
section("the real machine: docked, releasing, with a policy it could not read");
// ═════════════════════════════════════════════════════════════════════════════
const l16 = doc("status-l16-docked.json");
const s16 = L.statusView(raw("status-l16-docked.json"), 0);

checkTrue("a document that parsed is ok", s16.ok);
noNullsAnywhere("the L16 capture", s16);

// Rule 3 in lid.js's header. This string is present on EVERY status read by an
// ordinary user on a machine where root has a live /run/user/0, because the OS
// side reports every policy candidate it could not read — deliberately, and
// correctly. A page that painted it in the danger tone would cry wolf on every
// load and teach its owner to ignore the one time it mattered.
checkHas("the unreadable root policy is carried", s16.policyNote, "Permission denied");
check("and it does not make the read a failure", s16.ok, true);
check("the policy source is still named", s16.policySource, "built-in defaults");

// The finding round 2 landed, and the reason the page leads with it.
check("logind is known not to act on the lid", s16.logind.actsOnLid, false);
check("and that it is known is itself recorded", s16.logind.actsKnown, true);
check("the machine reports itself docked", s16.logind.docked, true);
check("one external display is counted", s16.logind.externalDisplays, 1);
checkHas("the headline names the display, not the dock",
         s16.logind.headline, "1 external display connected");
checkHas("and the detail names the setting that beats the inhibitor",
         s16.logind.detail, "HandleLidSwitchDocked");
check("a docked machine is a warning, not an error and not a success",
      s16.logind.tone, "warn");
check("nothing is blocking handle-lid-switch here", s16.logind.lidBlocked, false);

// Three answers, never two.
check("the one-line answer refuses to claim credit",
      L.headline(s16), "This machine already ignores the lid, and APEX is not why");
check("and the tile says the same thing in four words",
      L.tileView(s16).sublabel, "docked — logind ignores the lid");

check("the decision is release", s16.decision.id, "release");
check("release is drawn dim, not active", s16.decision.tone, "dim");
check("release carries no guard", s16.decision.guard, "");
check("on mains is read as mains", s16.charge.kind, "ac");

// ═════════════════════════════════════════════════════════════════════════════
section("pinned on, lid open: keep-working");
// ═════════════════════════════════════════════════════════════════════════════
const ACTING = { docked: false, external_displays: 0, acts_on_lid: true,
                block_inhibited: "idle:handle-lid-switch" };

const keep = doc("status-keep-working.json");
const sk = S(keep);
// The same document on a machine logind WOULD act on. Under `APEX_LID_ROOT`
// busctl is never run, so the fixture's own logind is all-null — which is the
// honest answer for a fixture and the wrong frame for asserting a decision.
const skActing = S(withLogind(keep, ACTING));

noNullsAnywhere("keep-working", sk);
check("the pin is read back", sk.pin, "on");
check("the decision is keep-working", sk.decision.id, "keep-working");
check("keep-working is drawn active", sk.decision.tone, "active");
checkHas("and it says why in the machine's own words", sk.decision.why, "pinned");
check("keep-working is the arm that holds the inhibitor",
      sk.decision.holdsInhibitor, true);
check("the tile is lit by the PIN", L.tileView(sk).on, true);
check("and its sublabel says so rather than counting sessions",
      L.tileView(skActing).sublabel, "pinned on");
check("the headline is the answer to 'can I shut it now'",
      L.headline(skActing), "Shutting the lid now keeps the work running");

// Under a fixture root busctl is never run, so logind answers nothing. That is
// the third answer and it is not "it will act".
check("an unqueried logind is not a logind that acts", sk.logind.actsOnLid, null);
check("and the page knows it does not know", sk.logind.actsKnown, false);

// ═════════════════════════════════════════════════════════════════════════════
section("the guards, each naming itself");
// ═════════════════════════════════════════════════════════════════════════════
// NOT given an acting logind, deliberately. `guard-suspend` is the driver
// calling `systemctl suspend` ITSELF, after releasing the inhibitor — it is not
// a lid decision logind mediates, so it fires on a docked machine and on a
// machine whose lid handling could not be established, exactly as it fires on
// an undocked one. This suite found that `tileView` and `headline` had the
// docked frame in FRONT of the guard, which would have told an owner "docked —
// logind ignores the lid" while APEX was about to suspend their laptop.
const gt = S(doc("status-guard-thermal.json"));
noNullsAnywhere("thermal guard", gt);
check("a thermal guard is guard-suspend", gt.decision.id, "guard-suspend");
check("the guard is carried from inside the variant", gt.decision.guard, "thermal");
check("and turned into something an owner reads", gt.decision.guardLabel, "too hot");
check("a firing guard is the danger tone", gt.decision.tone, "danger");
check("the tile shows which guard, not that one fired",
      L.tileView(gt).sublabel, "too hot");
checkHas("the headline names it too", L.headline(gt), "too hot");
// The assertion the reordering exists for, stated over the DOCKED capture:
// this is the machine where the lid does nothing, and APEX suspends it anyway.
const dockedGuard = (() => {
    const d = JSON.parse(JSON.stringify(l16));
    d.decision = { decision: "guard-suspend", guard: "battery", why: "9% on battery" };
    return S(d);
})();
check("a guard on a DOCKED machine is not hidden behind the dock",
      L.tileView(dockedGuard).sublabel, "battery floor");
checkHas("and the headline says a suspend is coming, not that the lid is ignored",
         L.headline(dockedGuard), "A guard is about to suspend this machine");
const unknownGuard = S(withLogind((() => {
    const d = JSON.parse(JSON.stringify(l16));
    d.decision = { decision: "guard-suspend", guard: "thermal", why: "hot" };
    return d;
})(), { docked: null, external_displays: 0, acts_on_lid: null }));
check("nor behind 'lid behaviour unknown'",
      L.tileView(unknownGuard).sublabel, "too hot");
// A guard the page has no label for still says a guard is doing this.
const namelessGuard = (() => {
    const d = JSON.parse(JSON.stringify(l16));
    d.decision = { decision: "guard-suspend", why: "no guard named" };
    return S(d);
})();
check("a guard-suspend with no guard named still says one is suspending",
      L.tileView(namelessGuard).sublabel, "a guard is suspending");
check("99 °C against a 100 °C trip is 1 °C of headroom", gt.thermal.headroomC, 1);
check("and the temperature reads danger", gt.thermal.tone, "danger");

const gb = S(doc("status-guard-battery.json"));
noNullsAnywhere("battery guard", gb);
check("a battery guard names itself", gb.decision.guard, "battery");
check("and reads as the floor, not as 'flat'", gb.decision.guardLabel, "battery floor");
check("9% against a 20% floor is danger", gb.charge.tone, "danger");
checkHas("and the charge line names the floor", gb.charge.text, "floor 20%");

// The five guards, including the three that are 'the machine would not say'.
// Those are kept apart from the two that are a reading because they mean
// different things: one is "your laptop is hot", the other is "your laptop
// cannot tell you whether it is hot", and the second is the one worth fixing.
check("an unreadable sensor is not a hot machine",
      L.guardLabel("thermal-unreadable"), "temperature unreadable");
check("a machine with no sensor says so",
      L.guardLabel("thermal-no-sensor"), "no temperature sensor");
check("an unreadable charge is not a flat battery",
      L.guardLabel("battery-unreadable"), "charge unreadable");
check("a guard nobody has heard of is shown verbatim, not dropped",
      L.guardLabel("solar-flare"), "solar-flare");
check("and no guard at all is nothing at all", L.guardLabel(""), "");

// ═════════════════════════════════════════════════════════════════════════════
section("a machine with no lid, no sensor and no battery");
// ═════════════════════════════════════════════════════════════════════════════
const bare = S(doc("status-bare.json"));
noNullsAnywhere("the bare machine", bare);
check("no lid is its own state", bare.lid, "no-lid");
check("no sensor is not a cold machine", bare.thermal.kind, "no-sensor");
check("and it is a defect worth showing", bare.thermal.tone, "danger");
check("no battery is not a flat battery", bare.charge.kind, "no-battery");
check("and a desktop is not a danger", bare.charge.tone, "dim");
checkHas("it says what it is", bare.charge.text, "not a laptop");

// ═════════════════════════════════════════════════════════════════════════════
section("undocked — the case this machine cannot produce, derived from one it can");
// ═════════════════════════════════════════════════════════════════════════════
const acting = S(withLogind(l16, {
    docked: false, external_displays: 0, acts_on_lid: true,
    block_inhibited: "idle:handle-lid-switch"
}));
noNullsAnywhere("undocked and held", acting);
check("an undocked machine acts on its lid", acting.logind.actsOnLid, true);
check("and then the inhibitor is what decides", acting.logind.tone, "active");
checkHas("the headline says so", acting.logind.headline, "the inhibitor is what decides");
check("handle-lid-switch inside BlockInhibited is the authoritative check",
      acting.logind.lidBlocked, true);
checkHas("and the detail says it is held now",
         acting.logind.detail, "is blocked right now");

const actingFree = S(withLogind(l16, {
    docked: false, external_displays: 0, acts_on_lid: true, block_inhibited: "idle"
}));
check("`idle` alone is NOT a lid block", actingFree.logind.lidBlocked, false);
checkHas("and the detail says it is not held",
         actingFree.logind.detail, "is not blocked right now");
// The substring is the whole of the check, so the near-miss has to be red.
check("`idle:sleep` is not a lid block either",
      S(withLogind(l16, { acts_on_lid: true, block_inhibited: "idle:sleep" })).logind.lidBlocked,
      false);

const twoScreens = S(withLogind(l16, { docked: true, external_displays: 2, acts_on_lid: false }));
checkHas("two displays are pluralised", twoScreens.logind.headline, "2 external displays");
const dockNoScreen = S(withLogind(l16, { docked: true, external_displays: 0, acts_on_lid: false }));
checkHas("a dock with no display says dock, not display",
         dockNoScreen.logind.headline, "reports this machine as docked");

const unknown = S(withLogind(l16, { docked: null, external_displays: 0, acts_on_lid: null }));
check("could-not-be-established is not false", unknown.logind.actsOnLid, null);
check("and it is not 'it acts'", unknown.logind.actsKnown, false);
check("the headline gives the third answer",
      L.headline(unknown), "Whether this machine acts on the lid could not be established");
check("and so does the tile", L.tileView(unknown).sublabel, "lid behaviour unknown");

// ═════════════════════════════════════════════════════════════════════════════
section("live work, which is measured and never a mode the owner remembers");
// ═════════════════════════════════════════════════════════════════════════════
const withWork = (w) => {
    const d = JSON.parse(JSON.stringify(l16));
    d.inputs.work = w;
    return S(d);
};
check("no session is no session", withWork({ work: "sessions", live: 0 }).work.text,
      "No agent session is running");
check("one is singular", withWork({ work: "sessions", live: 1 }).work.text,
      "1 live agent session");
check("three are plural", withWork({ work: "sessions", live: 3 }).work.text,
      "3 live agent sessions");
check("a live session is the active tone", withWork({ work: "sessions", live: 1 }).work.tone,
      "active");
// NOT folded into "zero sessions". The direction matters: a machine that cannot
// tell whether anything is running suspends, because a laptop that stays awake
// on an unanswered question cooks in a bag.
const unread = withWork({ work: "unreadable", why: "/run/user is empty" });
check("unreadable work is its own kind", unread.work.kind, "unreadable");
check("and never reads as zero sessions", unread.work.live, 0);
check("it is shown as a defect", unread.work.tone, "danger");
checkHas("with the reason the OS side gave", unread.work.text, "/run/user is empty");
check("a work reason nobody supplied still says something",
      withWork({ work: "unreadable" }).work.text,
      "Live work could not be read — no reason given");

// The tile counts sessions only when the pin is `auto` — see below.
const autoBusy = (() => {
    const d = withLogind(l16, ACTING);
    d.inputs.work = { work: "sessions", live: 2 };
    return S(d);
})();
check("on an acting machine the tile counts what is running",
      L.tileView(autoBusy).sublabel, "2 agent sessions");
const autoOne = (() => {
    const d = withLogind(l16, ACTING);
    d.inputs.work = { work: "sessions", live: 1 };
    return S(d);
})();
check("one session is singular on the tile too", L.tileView(autoOne).sublabel, "1 agent session");
const autoIdle = S(withLogind(l16, ACTING));
check("and nothing running says nothing running", L.tileView(autoIdle).sublabel, "nothing running");
const autoUnread = (() => {
    const d = withLogind(l16, ACTING);
    d.inputs.work = { work: "unreadable", why: "/run/user is empty" };
    return S(d);
})();
check("work that could not be read is not 'nothing running'",
      L.tileView(autoUnread).sublabel, "work unreadable");

// ═════════════════════════════════════════════════════════════════════════════
section("the VPN — the load-bearing half of the request");
// ═════════════════════════════════════════════════════════════════════════════
const withVpn = (v) => {
    const d = JSON.parse(JSON.stringify(l16));
    d.vpn = v;
    return S(d).vpn;
};
check("a tunnel that is up is named",
      withVpn({ name: "school", state: { vpn: "up" } }).text, "Up (school)");
check("an unnamed tunnel is still up", withVpn({ name: null, state: { vpn: "up" } }).text, "Up");
// The answer the whole criterion exists to catch, and the one round 2 made
// reachable at all: before it, VpnState::Down could not be produced.
check("a tunnel that DROPPED is shouted",
      withVpn({ name: "school", state: { vpn: "down" } }).text, "DOWN (school)");
check("and it is the danger tone",
      withVpn({ name: "school", state: { vpn: "down" } }).tone, "danger");
check("no tunnel is not a dropped tunnel",
      withVpn({ name: null, state: { vpn: "none" } }).text, "No tunnel is up");
check("and no tunnel is not a defect", withVpn({ name: null, state: { vpn: "none" } }).tone, "dim");
check("an unreadable tunnel is neither of those",
      withVpn({ name: null, state: { vpn: "unreadable", why: "nmcli is missing" } }).state,
      "unknown");
checkHas("and says what stopped it being read",
         withVpn({ name: null, state: { vpn: "unreadable", why: "nmcli is missing" } }).text,
         "nmcli is missing");

// ═════════════════════════════════════════════════════════════════════════════
section("an unrecognised decision must not read as the one that suspends");
// ═════════════════════════════════════════════════════════════════════════════
const future = withLogind(l16, ACTING);
future.decision = { decision: "hibernate-instead", why: "a fourth arm somebody added" };
const sf = S(future);
noNullsAnywhere("a fourth decision arm", sf);
check("a fourth arm is not release", sf.decision.id, "hibernate-instead");
check("it is not drawn as success", sf.decision.tone, "dim");
check("it does not claim the inhibitor", sf.decision.holdsInhibitor, false);
check("and the headline refuses to guess",
      L.headline(sf), "What the lid would do could not be established");

// `decision.holdsInhibitor` is derived from the tag; `holds_inhibitor` is a
// sibling the OS side computes. Two implementations of one rule is how they
// come to disagree, so every fixture is made to prove they do not.
section("the derived inhibitor flag agrees with the one the OS side sent");
for (const f of ["status-l16-docked.json", "status-keep-working.json",
                 "status-guard-thermal.json", "status-guard-battery.json",
                 "status-bare.json"]) {
    const d = doc(f);
    check(`${f}: holds_inhibitor matches the decision tag`,
          L.statusView(raw(f), 0).decision.holdsInhibitor, d.holds_inhibitor);
}

// ═════════════════════════════════════════════════════════════════════════════
section("a failed read is not a calm machine");
// ═════════════════════════════════════════════════════════════════════════════
const gone = L.statusView("", 127);
noNullsAnywhere("apex not on PATH", gone);
check("a missing binary is not ok", gone.ok, false);
checkHas("and it says which binary", gone.reason, "apex is not on PATH");
check("it is never rendered as 'suspends normally'",
      L.headline(gone), "The lid policy could not be read");
check("the tile says unreadable rather than going dark quietly",
      L.tileView(gone).sublabel, "unreadable");
check("and an unreadable machine does not light the tile", L.tileView(gone).on, false);

const empty = L.statusView("", 1);
checkHas("no output at all is its own reason", empty.reason, "produced no output");
const garbage = L.statusView("not json at all", 0);
noNullsAnywhere("unparseable output", garbage);
check("unparseable output is not ok", garbage.ok, false);
checkHas("and says so", garbage.reason, "could not read");
const notObject = L.statusView("[1,2,3]", 0);
check("a JSON array is not a status document", notObject.ok, false);
const nully = L.statusView("null", 0);
check("the literal null is not a status document", nully.ok, false);
noNullsAnywhere("the literal null", nully);

// Every nested object survives a document with nothing in it.
const bareObj = L.statusView("{}", 0);
noNullsAnywhere("an empty object", bareObj);
check("an empty object still parses", bareObj.ok, true);
check("with the pin defaulted, never undefined", bareObj.pin, "auto");
check("and every input reading as unknown", 
      [bareObj.work.kind, bareObj.thermal.kind, bareObj.charge.kind,
       bareObj.vpn.state, bareObj.decision.id, bareObj.lid],
      ["unknown", "unknown", "unknown", "unknown", "unknown", "unknown"]);
check("enabled defaults to true, because the OS side ships it enabled",
      bareObj.enabled, true);
check("but an explicit false is honoured",
      L.statusView('{"enabled":false}', 0).enabled, false);
checkHas("and a disabled policy is the headline",
         L.headline(L.statusView('{"enabled":false}', 0)), "switched off in the policy file");

// ═════════════════════════════════════════════════════════════════════════════
section("the report — the four things Andre asked to be told after reopening");
// ═════════════════════════════════════════════════════════════════════════════
const rEmpty = L.reportView(raw("report-empty.json"), 0);
noNullsAnywhere("no period yet", rEmpty);
check("a readable 'nothing has happened' is still a readable answer", rEmpty.ok, true);
check("and has nothing to show", rEmpty.has, false);
check("but period is an object a binding can walk", typeof rEmpty.period, "object");
check("flagged not present rather than being null", rEmpty.period.present, false);

const rp = L.reportView(raw("report-period.json"), 0);
noNullsAnywhere("a real period", rp);
check("a real period is present", rp.has, true);
check("and knows it", rp.period.present, true);
// (1) how long it stayed up
checkTrue("the duration is a string a person reads",
          typeof rp.period.durationText === "string" && rp.period.durationText.length > 0);
check("a period with no opened_at is still closed", rp.period.stillClosed, true);
// (2) what ran
check("the sessions at close are carried", rp.period.sessionsAtClose, 0);
// (3) whether the VPN held
check("a fixture-root run has no VPN state to report", rp.period.vpnHeld, null);
check("and says that rather than 'it held'", rp.period.vpnText, "No VPN state to report");
// (4) what it cost
check("80% to 80% is no battery used", rp.period.chargeCost, 0);
check("and is said in words", rp.period.chargeText, "No battery used");
// and what was actually powered down, which is criterion 3's visible half
checkTrue("the power-down is listed", rp.period.poweredDown.length >= 3);
checkHas("including the keyboard backlight, which round 2 found was never zeroed",
         rp.period.poweredDown.join(" | "), "keyboard backlight");
checkTrue("and what was SKIPPED is listed separately", rp.period.skipped.length > 0);
checkTrue("each skip says what and why",
          rp.period.skipped.every((s) => s.what !== "" && s.why !== ""));
checkHas("the summary comes from the OS side", rp.period.summary, "lid closed for");

// The three VPN verdicts, over the period the OS side scored.
const mkReport = (over) => {
    const d = JSON.parse(raw("report-period.json"));
    Object.assign(d, over);
    return L.reportView(JSON.stringify(d), 0).period;
};
check("a VPN that held says so", mkReport({ vpn_held: true }).vpnText,
      "The VPN held for the whole period");
check("a VPN that dropped is shouted", mkReport({ vpn_held: false }).vpnText,
      "The VPN DROPPED during the period");

// A record that EXISTS and could not be read is not a machine that never slept.
const refused = L.reportView('{"period":null,"error":"/var/lib/apex/lid/last.json: Permission denied"}', 0);
noNullsAnywhere("a refused record", refused);
check("an explicit refusal is not ok", refused.ok, false);
checkHas("and carries the refusal verbatim", refused.reason, "Permission denied");
check("it is NOT 'nothing has happened yet'", refused.has, false);

const rGone = L.reportView("", 127);
noNullsAnywhere("no report binary", rGone);
check("an unreadable report is not an empty one", rGone.ok, false);
const rJunk = L.reportView("{{{", 0);
noNullsAnywhere("unparseable report", rJunk);
check("unparseable report output is not ok", rJunk.ok, false);

// ═════════════════════════════════════════════════════════════════════════════
section("durations, which exist to tell 40s from 400s");
// ═════════════════════════════════════════════════════════════════════════════
check("seconds under a minute", L.duration(42), "42s");
check("minutes carry their seconds", L.duration(252), "4m 12s");
check("hours drop them", L.duration(7380), "2h 3m");
check("zero is zero, not blank", L.duration(0), "0s");
check("a negative duration is clamped, not printed", L.duration(-5), "0s");
check("a duration that is not a number is zero", L.duration("soon"), "0s");

// A period whose opened_at is set measures to the reopen, not to last_seen.
const openedPeriod = (() => {
    const d = JSON.parse(raw("report-period.json"));
    d.period.closed_at = 1000;
    d.period.last_seen = 1200;
    d.period.opened_at = 1180;
    return L.reportView(JSON.stringify(d), 0).period;
})();
check("a reopened period measures to the reopen", openedPeriod.durationSecs, 180);
check("and is no longer still closed", openedPeriod.stillClosed, false);
check("a still-closed period measures to the last poll", rp.period.durationSecs, 0);

// ═════════════════════════════════════════════════════════════════════════════
section("the pin, which is the only thing this surface writes");
// ═════════════════════════════════════════════════════════════════════════════
check("auto is a pin", L.pinArgv("auto"), ["apex", "lid", "pin", "auto"]);
check("on is a pin", L.pinArgv("on"), ["apex", "lid", "pin", "on"]);
check("off is a pin", L.pinArgv("off"), ["apex", "lid", "pin", "off"]);
// A page that assembled an argv from a value it had not checked is how a
// control comes to run something nobody wrote down.
check("anything else is not a pin, and is refused rather than escaped",
      L.pinArgv("on; rm -rf ~"), null);
check("an empty pin is refused", L.pinArgv(""), null);
check("a missing pin is refused", L.pinArgv(undefined), null);
// No `sudo`, no `pkexec`, ever: `apex lid pin` writes the owner's own
// ~/.config/apex/lid.toml, and the inhibitor is allow_active=yes for an
// ordinary session. A prompt on this surface would be a defect, not a nuisance.
check("a pin is never elevated",
      ["auto", "on", "off"].every((p) => L.pinArgv(p).indexOf("sudo") < 0
                                      && L.pinArgv(p).indexOf("pkexec") < 0), true);

// on ↔ auto, never off. `off` means "suspend on a close whatever is running",
// which kills an agent mid-build, and a fingertip on a two-state tile must not
// be able to select it by accident.
check("tapping an unpinned tile pins it on", L.tileToggle("auto"), "on");
check("tapping a pinned tile hands it back to auto", L.tileToggle("on"), "auto");
check("tapping a tile pinned OFF does not leave it off", L.tileToggle("off"), "on");
check("and the tile can never reach off",
      ["auto", "on", "off", "", undefined].map(L.tileToggle).indexOf("off"), -1);
check("auto reads as following the work", L.pinLabel("auto"), "Follow live work");
check("on reads as a promise", L.pinLabel("on"), "Always keep working");
check("off reads as the consequence", L.pinLabel("off"), "Always suspend");

// A machine pinned off must say so even when a guard would have fired anyway.
const pinnedOff = (() => {
    const d = JSON.parse(JSON.stringify(l16));
    d.pin = "off";
    d.logind = { docked: false, external_displays: 0, acts_on_lid: true, block_inhibited: "idle" };
    return S(d);
})();
check("a tile pinned off is not lit", L.tileView(pinnedOff).on, false);
check("and says which pin, not 'nothing running'",
      L.tileView(pinnedOff).sublabel, "pinned: always suspend");

// The tile is lit by the PIN and not by the decision: one lit because an agent
// happens to be running would go dark when the agent finished, and its owner
// would read that as their setting having been forgotten.
const pinnedOnReleasing = (() => {
    const d = JSON.parse(JSON.stringify(l16));
    d.pin = "on";
    d.decision = { decision: "release", why: "something else decided" };
    d.logind = { docked: false, external_displays: 0, acts_on_lid: true, block_inhibited: "idle" };
    return S(d);
})();
check("the tile follows the pin, not the decision", L.tileView(pinnedOnReleasing).on, true);

// ── and the tile never throws on a shape it was not given ───────────────────
check("no status at all still produces a tile",
      Object.keys(L.tileView(undefined)).sort(),
      ["icon", "label", "on", "sublabel"]);
check("and a headline", typeof L.headline(undefined), "string");
noNullsAnywhere("the default status", L.emptyStatus());
noNullsAnywhere("the default report", L.emptyReport());
noNullsAnywhere("the default period", L.emptyPeriod());

// ─────────────────────────────────────────────────────────────────────────────
if (failed) {
    console.error(`\n${failed} check(s) failed`);
    process.exit(1);
}
console.log("\nall checks passed");
