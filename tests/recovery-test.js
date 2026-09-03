#!/usr/bin/env node
// Tests §19's recovery surface logic against the file the shell actually
// loads (src/services/recovery.js), not a copy of it.
//
//   node tests/recovery-test.js
//
// ── Where the fixtures come from ─────────────────────────────────────────────
//
// Every payload below was CAPTURED, not invented: the `apex` binary was built
// from the apex-os worktree on branch `p3/base` and run read-only on this
// machine —
//
//   apex recover status --json          (exit 0; this machine has no attention)
//   apex doctor --json
//   apex recover reset --scope desktop --json    (a DRY RUN; --commit absent)
//   apex recover reset --scope user --json       (likewise)
//   apex recover repair --json                   (likewise)
//
// The shapes are therefore apexd's, including the parts a hand-written fixture
// would have got wrong: `action` is null on most rows rather than absent,
// `available` is null (not false) on `installer-media`, the doctor indents
// continuation lines by two spaces, and the reset plan lists targets that do
// NOT exist alongside ones that do.
//
// Two fixtures are edited, and both edits are labelled: a status payload with
// an `attention` row (this machine has none, and the attention path is the one
// the panel exists for) and one with an unknown state and an unknown row id.

"use strict";

const path = require("path");
const R = require(path.join(__dirname, "..", "src", "services", "recovery.js"));

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
function truthy(name, v) { check(name, !!v, true); }
function falsy(name, v)  { check(name, !!v, false); }

// ── captured: apex recover status --json ─────────────────────────────────────

const STATUS_ROWS = [
    { action: null, id: "current-deployment", label: "Current deployment",
      state: "verified", detail: "ostree 96351335ae0b — APEX-OS 43 daily" },
    { action: "sudo apex rollback", id: "previous-deployment",
      label: "Previous deployment", state: "available",
      detail: "2 deployments present, so there is one to go back to. Nothing has verified that it boots." },
    { action: null, id: "secure-boot", label: "Secure Boot",
      state: "verified", detail: "firmware reports Secure Boot enabled" },
    { action: null, id: "filesystem", label: "Filesystem",
      state: "verified", detail: "/usr is read-only on a overlay root, ostree-booted" },
    { action: null, id: "gpu-driver", label: "GPU driver",
      state: "verified", detail: "1 — AMD via amdgpu" },
    { action: null, id: "apex-shell", label: "APEX Shell",
      state: "verified", detail: "vendored in the image at /usr/share/apex-shell" },
    { action: null, id: "network", label: "Network",
      state: "available", detail: "a default route exists. Nothing was contacted." },
    { action: null, id: "package-extensions", label: "Package extensions",
      state: "verified", detail: "no user packages on this machine" }
];

const STATUS = JSON.stringify({
    bootloader: "grub",
    needsAttention: 0,
    rows: STATUS_ROWS,
    actions: [
        { id: "repair", label: "Repair automatically",
          command: "apex recover repair                  (dry run; --commit runs it)" },
        { id: "bootPrevious", label: "Boot previous deployment",
          command: "sudo apex rollback                   then reboot" },
        { id: "factoryReset", label: "Factory reset",
          command: "apex recover reset --scope desktop|user   (a dry run)" },
        { id: "diagnostics", label: "Hardware diagnostics",
          command: "apex doctor                          (--json for a UI)" }
    ],
    routes: [
        { id: "previous-deployment", available: true, how: "`sudo apex rollback` then reboot." },
        { id: "rescue-target", available: true, how: "at the grub menu, edit the entry." },
        { id: "boot-counting", available: false, how: "not in effect: this machine boots through GRUB." },
        { id: "disposable-environment", available: false, how: "`apex disposable run` gives you a throwaway userspace." },
        { id: "recovery-boot-entry", available: false, how: "APEX ships no recovery boot entry." },
        // The one that is genuinely unknown. A running system cannot tell.
        { id: "installer-media", available: null, how: "cannot be determined from a running system." }
    ],
    resetScopes: [
        { id: "desktop", summary: "APEX Shell's settings, keybinds and caches for this account" },
        { id: "user", summary: "everything under `desktop`, PLUS your blueprint…" }
    ]
});

// ── 1. exit 1 is a REPORT, not a failure ─────────────────────────────────────
// `apex recover status` returns 1 when anything needs attention:
//     return if attention > 0 { 1 } else { 0 }
// A consumer that treated non-zero as failure would blank the panel on exactly
// the machines it exists for. This is the single most important assertion in
// this file.

const ATTENTION = JSON.stringify(Object.assign(JSON.parse(STATUS), {
    needsAttention: 2,
    // EDITED from the capture: this machine reports no attention, and the
    // attention path is the one the whole page is for.
    rows: STATUS_ROWS.map(r =>
        (r.id === "secure-boot" || r.id === "apex-shell")
            ? Object.assign({}, r, { state: "attention", action: "sudo apex update" })
            : r)
}));

const att = R.parseStatus(1, ATTENTION);
truthy("a status that exited 1 still parses", att.ok);
check("…with all eight rows", att.rows.length, 8);
check("…and its attention count", att.needsAttention, 2);
check("…and the rows really say attention",
      att.rows.filter(r => r.state === "attention").map(r => r.id),
      ["secure-boot", "apex-shell"]);

// The inverse: exit 0 with nothing on stdout is genuinely unavailable. That is
// the shape an `apex` predating `recover` produces.
falsy("empty stdout is not a status, whatever the exit code", R.parseStatus(0, "").ok);
falsy("an error message on stdout is not a status",
      R.parseStatus(2, "error: unrecognized subcommand 'recover'").ok);
falsy("truncated json is not a status", R.parseStatus(0, '{"rows": [').ok);
check("…and an unavailable status has no rows", R.parseStatus(1, "").rows, []);

// ── 2. the four states are four ──────────────────────────────────────────────
// docs/recovery.md: `available` means nothing verified it, and `unavailable` is
// NEVER a synonym for "fine". Neither may render green.

check("verified is the only state that earns the ok tone",
      ["verified", "available", "attention", "unavailable"].map(R.stateTone),
      ["ok", "neutral", "warn", "neutral"]);
check("available does not call itself available to the user",
      R.stateLabel("available"), "Unverified");
check("unavailable is not called fine", R.stateLabel("unavailable"), "Unknown");
check("attention names itself", R.stateLabel("attention"), "Needs attention");

// A state this build has never heard of must degrade to `unavailable`, never
// to `verified`. A future apexd row state rendering as a green tick is a lie
// that nothing else here would catch.
check("an unknown state degrades to unavailable", R.normalizeState("degraded"), "unavailable");
check("…and gets the neutral tone, not ok", R.stateTone(R.normalizeState("degraded")), "neutral");
check("an empty state degrades too", R.normalizeState(""), "unavailable");

// ── 3. rows: ordered, and never dropped ──────────────────────────────────────

const ordered = R.parseStatus(0, STATUS);
check("rows come out in §19's order", ordered.rows.map(r => r.id), R.ROW_ORDER);

// A row apexd grows that this build does not know about is APPENDED, not
// dropped. A row nobody rendered is the failure mode this page exists to end.
const EXTRA = JSON.stringify(Object.assign(JSON.parse(STATUS), {
    // EDITED: an id from a hypothetical later apexd, with a state to match.
    rows: STATUS_ROWS.concat([
        { id: "tpm-sealing", label: "TPM sealing", state: "degraded",
          detail: "invented for this test", action: null }
    ])
}));
const extra = R.parseStatus(0, EXTRA);
check("an unknown row id is appended, not dropped",
      extra.rows.map(r => r.id).slice(-1), ["tpm-sealing"]);
check("…and its unknown state is not a tick",
      extra.rows[extra.rows.length - 1].state, "unavailable");

// A row with no id cannot be keyed on, so it is not a row.
check("a row with no id is dropped",
      R.parseStatus(0, JSON.stringify({ rows: [{ label: "x", state: "verified" }] })).rows.length,
      0);

// `action` is null on most rows in the real payload. Normalised to "" so the
// view tests one thing rather than two.
check("a null action becomes the empty string", ordered.rows[0].action, "");
check("a real action survives", ordered.rows[1].action, "sudo apex rollback");

// needsAttention is recomputed when the key is missing rather than defaulted
// to 0 — 0 reads as "all fine", which is the wrong direction to guess in.
const NOCOUNT = JSON.stringify({ rows: STATUS_ROWS.map(r =>
    r.id === "network" ? Object.assign({}, r, { state: "attention" }) : r) });
check("a payload with no needsAttention key counts the rows instead",
      R.parseStatus(0, NOCOUNT).needsAttention, 1);

// ── 4. routes are tri-state ──────────────────────────────────────────────────
// `installer-media` is null: a running system cannot tell. Rendering null as
// false would claim there is no install medium, which nobody checked.

check("the route marks", ordered.routes.map(r => R.routeMark(r.available)),
      ["yes", "yes", "no", "no", "no", "unknown"]);
check("null is unknown, not no", R.routeMark(null), "unknown");
check("undefined is unknown too", R.routeMark(undefined), "unknown");
check("a route with a null available keeps it null",
      ordered.routes[5].available, null);

// ── 5. captured: apex doctor --json ──────────────────────────────────────────
// Note the two-space indent on the continuation lines. It is the only thing
// carrying "this belongs to the check above", so it is parsed rather than
// trimmed away and lost.

const DOCTOR = JSON.stringify({
    checks: [
        { check: "apexd running (owns org.apexos.Apexd1)", ok: true },
        { check: "cpufreq scaling driver present (amd-pstate-epp)", ok: true },
        { check: "touchpad: ELAN06DA:00 04F3:320B Touchpad", ok: true },
        { check: "  multitouch slots (ABS_MT_SLOT): present", ok: true },
        { check: "  button layout: clickpad (INPUT_PROP_BUTTONPAD)", ok: true },
        { check: "ACPI platform_profile present", ok: false },
        { check: "metrics endpoint reachable on 127.0.0.1:9723", ok: true }
    ],
    passed: 6, warned: 1, total: 7
});

const doc = R.parseDoctor(0, DOCTOR);
truthy("the doctor parses", doc.ok);
check("…every check", doc.total, 7);
check("…the pass count", doc.passed, 6);
check("…the warn count", doc.warned, 1);

// `apex doctor` ALWAYS exits 0, even with warnings — cmd_doctor ends `0`
// unconditionally. Reading its exit code as a health verdict would report
// every machine healthy, so the counts are the verdict and this proves it.
check("a doctor that exited 0 can still have warnings", R.parseDoctor(0, DOCTOR).warned, 1);
check("…and the summary says so", R.doctorSummary(doc), "6 of 7 pass, 1 to read");
check("an all-pass summary does not invent a warning",
      R.doctorSummary({ ok: true, total: 7, passed: 7, warned: 0 }), "7 checks, all pass");
check("a doctor that never ran says so", R.doctorSummary(R.parseDoctor(null, "")), "not run");

check("the indent that groups the touchpad block survives",
      doc.checks.map(c => c.depth), [0, 0, 0, 1, 1, 0, 0]);
check("…and the text itself is trimmed for rendering",
      doc.checks[3].check, "multitouch slots (ABS_MT_SLOT): present");

// `ok` must be a boolean. A string "false" coerced by !! is true, and that is
// the shape a schema change most plausibly takes.
check("a non-boolean ok is not a pass",
      R.parseDoctor(0, JSON.stringify({ checks: [{ check: "x", ok: "false" }] })).passed, 0);

falsy("a doctor payload with no checks array is not a doctor",
      R.parseDoctor(0, JSON.stringify({ passed: 3 })).ok);

// ── 6. captured: apex recover reset --scope desktop --json (DRY RUN) ─────────
// Nine targets, of which four exist. The token is `desktop:4:5d7f91ba` — and
// the 4 is exactly the number that exist, because apexd's `token_paths()`
// filters on the same thing `lossList` does.

const PLAN_DESKTOP = JSON.stringify({
    committed: false,
    confirmToken: "desktop:4:5d7f91ba",
    scope: "desktop",
    summary: "APEX Shell's settings, keybinds and caches for this account",
    provisioner: "/usr/libexec/apex-shell-firstrun",
    reprovision: true,
    preserved: [
        "every document, project, checkout and credential in your home directory",
        "~/.ssh, ~/.gnupg, ~/.aws and every browser profile"
    ],
    preservedLandmarks: [".ssh", ".gnupg"],
    targets: [
        { path: "/var/home/andre/.config/apex-shell/display.json", relative: ".config/apex-shell/display.json",
          disposition: "delete", kind: "file", exists: false, backedUp: true,
          what: "saved monitor layout, scale and refresh rate" },
        { path: "/var/home/andre/.config/apex-shell/input.json", relative: ".config/apex-shell/input.json",
          disposition: "delete", kind: "file", exists: false, backedUp: true,
          what: "keyboard, pointer and touchpad settings" },
        { path: "/var/home/andre/.config/apex-shell/ApexShellInput.kdl", relative: ".config/apex-shell/ApexShellInput.kdl",
          disposition: "delete", kind: "file", exists: false, backedUp: true,
          what: "the generated niri input block" },
        { path: "/var/home/andre/.config/apex-shell/ApexShellKeybinds.conf", relative: ".config/apex-shell/ApexShellKeybinds.conf",
          disposition: "delete", kind: "file", exists: true, backedUp: true,
          what: "the generated Hyprland keybinds" },
        { path: "/var/home/andre/.config/apex-shell/ApexShellKeybinds.kdl", relative: ".config/apex-shell/ApexShellKeybinds.kdl",
          disposition: "delete", kind: "file", exists: true, backedUp: true,
          what: "the generated niri keybinds" },
        { path: "/var/home/andre/.config/apex-shell/ApexShellKeybinds.lua", relative: ".config/apex-shell/ApexShellKeybinds.lua",
          disposition: "delete", kind: "file", exists: true, backedUp: true,
          what: "the generated labwc keybinds" },
        { path: "/var/home/andre/.cache/apex-shell", relative: ".cache/apex-shell",
          disposition: "delete", kind: "dir", exists: true, backedUp: false,
          what: "the shell's cache: generated colour scheme, thumbnails" },
        { path: "/var/home/andre/.config/hypr/apex-input.conf", relative: ".config/hypr/apex-input.conf",
          disposition: "truncate", kind: "file", exists: false, backedUp: true,
          what: "the generated Hyprland input overrides (emptied, not removed)" },
        { path: "/var/home/andre/.config/hypr/apex-display.conf", relative: ".config/hypr/apex-display.conf",
          disposition: "truncate", kind: "file", exists: false, backedUp: true,
          what: "the generated Hyprland monitor layout (emptied, not removed)" }
    ]
});

const plan = R.parseResetPlan(0, PLAN_DESKTOP);
truthy("the dry run parses", plan.ok);
check("…and the loss list is only what exists", plan.losses.length, 4);
check("…named", plan.losses.map(l => l.relative), [
    ".config/apex-shell/ApexShellKeybinds.conf",
    ".config/apex-shell/ApexShellKeybinds.kdl",
    ".config/apex-shell/ApexShellKeybinds.lua",
    ".cache/apex-shell"
]);

// THE assertion that makes "the token cannot be had without rendering the
// list" checkable rather than merely intended: apexd hashes the paths that
// exist, so the count in the token equals the number of rows a correct panel
// renders. If lossList's filter ever drifts from token_paths()'s, this breaks.
check("the token's count equals the number of rows rendered",
      R.tokenCount(plan.confirmToken), plan.losses.length);
check("the token's scope equals the plan's", R.tokenScope(plan.confirmToken), plan.scope);

// `truncate` is NOT a deletion. hyprland.conf `source=`s those two files and a
// missing source is FATAL, so they are emptied in place. Calling that
// "Deleted" would describe a reset that breaks the compositor.
check("truncate is not described as a deletion",
      R.dispositionVerb("truncate"), "Emptied, not removed");
check("delete is", R.dispositionVerb("delete"), "Deleted");
check("an unknown disposition is not silently a deletion",
      R.dispositionVerb("shred"), "shred");

// The cache is the one thing not copied aside, and the row must say so.
check("the un-backed-up target is flagged",
      plan.losses.filter(l => !l.backedUp).map(l => l.relative), [".cache/apex-shell"]);

check("the preserved list is carried through", plan.preserved.length, 2);
truthy("the provisioner is reported", plan.provisioner.length > 0);

// The wider scope, captured the same way: 14 targets, 5 of them present.
const plan5 = R.parseResetPlan(0, JSON.stringify({
    confirmToken: "user:5:ea0526cd", scope: "user", summary: "",
    targets: plan.losses.concat([{ path: "/var/home/andre/.local/state/apex",
        relative: ".local/state/apex", disposition: "delete", kind: "dir",
        exists: true, backedUp: true, what: "applied-blueprint record" }])
        .map(l => ({ path: l.path, relative: l.relative, disposition: l.disposition,
                     kind: l.kind, exists: true, backedUp: l.backedUp, what: l.what })),
    preserved: [], reprovision: true, provisioner: "/usr/libexec/apex-shell-firstrun"
}));
check("the user scope's token count matches its own list",
      R.tokenCount(plan5.confirmToken), plan5.losses.length);

// ── 7. the token is evidence, and cannot be manufactured ─────────────────────

truthy("a real token is well formed", R.looksLikeToken("desktop:4:5d7f91ba"));
falsy("a scope alone is not a token", R.looksLikeToken("desktop"));
falsy("a token with no hash is not a token", R.looksLikeToken("desktop:4:"));
falsy("a token with a non-hex hash is not a token", R.looksLikeToken("desktop:4:zzzz"));
falsy("a sentence is not a token", R.looksLikeToken("apex: nothing has been changed."));
falsy("an empty string is not a token", R.looksLikeToken(""));
falsy("a number is not a token", R.looksLikeToken(4));
check("an unparseable token has no count", R.tokenCount("nonsense"), -1);

// ── 8. commitArgv: every refusal, and the one acceptance ─────────────────────
// This is the function that can erase somebody's settings. Every branch that
// returns null is asserted individually, because a single "it refuses bad
// input" test passes while three of the four checks are missing.

const TOKEN = "desktop:4:5d7f91ba";

check("no plan, no argv", R.commitArgv(null, 4, TOKEN), null);
check("a plan that did not parse, no argv",
      R.commitArgv(R.parseResetPlan(0, "{}"), 4, TOKEN), null);
check("a token that is not this plan's, no argv",
      R.commitArgv(plan, 4, "desktop:4:00000000"), null);
check("a token constructed from the scope, no argv",
      R.commitArgv(plan, 4, "desktop:4:" ), null);
check("a well-formed token for a DIFFERENT scope, no argv",
      R.commitArgv(plan, 4, "user:4:5d7f91ba"), null);
// The one that matters most: the list on screen is shorter than the list the
// token covers. That is a panel that showed three of four things about to go.
check("a rendered count below the plan's, no argv", R.commitArgv(plan, 3, TOKEN), null);
check("a rendered count above the plan's, no argv", R.commitArgv(plan, 5, TOKEN), null);
check("nothing rendered at all, no argv", R.commitArgv(plan, 0, TOKEN), null);
check("the sentinel for 'never acknowledged', no argv", R.commitArgv(plan, -1, TOKEN), null);

check("the token and the rendered list agreeing is what produces an argv",
      R.commitArgv(plan, 4, TOKEN),
      ["apex", "recover", "reset", "--scope", "desktop", "--commit", "--confirm", TOKEN]);

// A plan whose token count disagrees with its own loss list — the shape a
// machine that changed between plan and render would produce — is refused even
// though the rendered count matches the plan.
const SKEWED = R.parseResetPlan(0, PLAN_DESKTOP.replace("desktop:4:", "desktop:9:"));
check("a token whose count disagrees with the plan it came with, no argv",
      R.commitArgv(SKEWED, SKEWED.losses.length, SKEWED.confirmToken), null);

// ── 9. planArgv can never commit ─────────────────────────────────────────────

check("the dry run's argv", R.planArgv("desktop"),
      ["apex", "recover", "reset", "--scope", "desktop", "--json"]);
falsy("the dry run's argv contains no --commit",
      R.planArgv("desktop").indexOf("--commit") >= 0);
falsy("…nor for the user scope",
      R.planArgv("user").indexOf("--commit") >= 0);
check("an invented scope gets no argv at all", R.planArgv("everything"), null);
check("an empty scope gets no argv", R.planArgv(""), null);
check("a scope that is a flag gets no argv", R.planArgv("--commit"), null);

// ── 10. reading a commit back ────────────────────────────────────────────────
// apexd exits 2 for both "--commit needs --confirm" and "the confirmation does
// not match this plan", and its message names both tokens. Swallowing that in
// favour of "failed" throws away the only sentence that says what to do.

check("exit 0 is done", R.readCommit(0, "Factory reset complete.", "").result, "ok");
check("exit 2 is stale, not a generic failure",
      R.readCommit(2, "", "apex: the confirmation does not match this plan.").result, "stale");
check("…and the message survives verbatim",
      R.readCommit(2, "", "apex: the confirmation does not match this plan.").message,
      "apex: the confirmation does not match this plan.");
check("exit 1 is a refusal", R.readCommit(1, "", "apex: refusing this reset").result, "refused");
check("a process that never ran is not a refusal",
      R.readCommit(null, "", "").result, "not_run");

// ── 11. apex recover repair --json ───────────────────────────────────────────
// Captured on this machine, which needs nothing: `{"committed": false,
// "domain": "user", "steps": []}`. A button that proposes work on a healthy
// machine is one people learn to ignore, so an empty list must stay empty.

const repairNone = R.parseRepair(0, JSON.stringify({ committed: false, domain: "user", steps: [] }));
truthy("an empty repair plan still parses", repairNone.ok);
check("…with no steps", repairNone.steps.length, 0);

const REPAIR = JSON.stringify({ committed: false, domain: "user", steps: [
    { id: "reprovision-desktop", domain: "user", what: "re-run the APEX Shell provisioner",
      whySafe: "idempotent; writes only files it owns", runnableHere: true,
      command: ["/usr/libexec/apex-shell-firstrun"] },
    { id: "rebuild-package-extension", domain: "system", what: "rebuild the package extension",
      whySafe: "removes nothing", runnableHere: false,
      command: ["/usr/libexec/apex-pkg", "rebuild"] }
]});
const repair = R.parseRepair(0, REPAIR);
check("both steps parse", repair.steps.map(s => s.id),
      ["reprovision-desktop", "rebuild-package-extension"]);
check("runnableHere is apexd's answer, not a guess",
      repair.steps.map(s => s.runnableHere), [true, false]);
// The wrong direction on this runs a system step as the user and reports
// success at doing nothing, so anything that is not an explicit true is false.
check("a missing runnableHere is not runnable here",
      R.parseRepair(0, JSON.stringify({ steps: [{ id: "x", what: "y" }] })).steps[0].runnableHere,
      false);
check("the argv is joined for display, not executed",
      repair.steps[0].command, "/usr/libexec/apex-shell-firstrun");
falsy("a repair payload with no steps array is not a repair plan",
      R.parseRepair(0, JSON.stringify({ domain: "user" })).ok);

// ── 12. rollback is shown, and its hint comes from the row ───────────────────

check("the rollback command is the one docs/recovery.md names",
      R.ROLLBACK_COMMAND, "sudo apex rollback");
check("and the pin command", R.PIN_COMMAND, "sudo apex pin");
check("the hint is the previous-deployment row's own detail",
      R.rollbackHint(ordered.rows), ordered.rows[1].detail);
check("a machine with no such row says so, rather than inventing advice",
      R.rollbackHint([]), "No previous deployment was reported.");
check("an unavailable previous deployment says there is nothing to go back to",
      R.rollbackHint([{ id: "previous-deployment", state: "unavailable", detail: "x" }]),
      "Nothing to roll back to on this machine.");

// ── 13. nothing here throws on rubbish ───────────────────────────────────────
// Each of these is a shape a broken `apex`, a truncated read or a future
// schema could produce. A throw inside a QML binding is a silently dead panel.

const RUBBISH = [null, undefined, "", "   ", "null", "[]", "42", '"a string"',
                 "{", '{"rows": null}', '{"rows": [null]}', '{"checks": [null]}',
                 '{"targets": [null]}', '{"routes": [null]}', '{"steps": [null]}'];
let threw = 0;
for (const t of RUBBISH) {
    try {
        R.parseStatus(0, t); R.parseDoctor(0, t);
        R.parseResetPlan(0, t); R.parseRepair(0, t);
    } catch (e) { threw++; console.error("  threw on: " + JSON.stringify(t) + " — " + e); }
}
check("no parser throws on any of the rubbish shapes", threw, 0);
check("…and a null rows entry does not become a row",
      R.parseStatus(0, '{"rows": [null]}').rows.length, 0);
check("…and a null target does not become a loss",
      R.parseResetPlan(0, '{"confirmToken":"desktop:0:aa","scope":"desktop","targets":[null]}').losses.length, 0);

if (failed > 0) {
    console.error(`\n${failed} assertion(s) failed`);
    process.exit(1);
}
console.log("\nall assertions passed");
