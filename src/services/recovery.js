// ─── recovery.js ─────────────────────────────────────────────────────────────
// Pure logic behind RecoveryService (roadmap §19, and §25's "make recovery and
// rollback part of normal UX, not expert documentation"): reading
// `apex recover status --json`, `apex doctor --json` and the factory reset's
// dry-run plan, and turning each into something a settings page can render
// without holding any of the reasoning itself.
//
// Kept out of the QML for the same reason src/services/remoteagents.js is:
// this is the part with edge cases, and tests/recovery-test.js exercises THIS
// file — the one the shell loads — rather than a copy of it. Nothing here does
// I/O, nothing here knows about Theme, and every function is data → data or
// data → plain string, so a node process can drive all of it.
//
// ── EXIT CODE 1 IS A REPORT, NOT A FAILURE ──────────────────────────────────
//
// `apex recover status` returns 1 when any component needs attention:
//
//     return if attention > 0 { 1 } else { 0 }        (apexd recover.rs)
//
// So the reflex `if (exitCode !== 0) return notAvailable` empties the panel on
// exactly the machines it exists for — the ones with something wrong. The
// stdout is complete and correct in that case. `parseStatus` therefore decides
// on the TEXT and lets the exit code inform only the "we could not run it at
// all" branch, where there is no text to decide on.
//
// `apex doctor` is the other way round: it always exits 0, even with warnings.
// Reading a doctor exit code as a health verdict would report every machine
// healthy. The counts in the payload are the verdict.
//
// ── THE FOUR STATES ARE FOUR, NOT TWO ───────────────────────────────────────
//
// docs/recovery.md is explicit and the mapping here obeys it:
//
//   verified     present and checked against something
//   available    present and USABLE, but nothing verified it. A rollback
//                target exists; nobody asserted that it boots. NOT green.
//   attention    present and wrong in a way a named action fixes
//   unavailable  could not be determined, or does not exist on this hardware.
//                NEVER a synonym for "fine" — so never green and never hidden.
//
// Collapsing `available` into `verified` is the specific lie this file refuses
// to tell: it would paint "nobody has checked your rollback target" as a tick.
//
// ── THE CONFIRM TOKEN IS EVIDENCE, NOT A PARAMETER ──────────────────────────
//
// `apex recover reset --commit` needs `--confirm <scope>:<count>:<hash>`, and
// the hash is computed over the paths the plan actually found. The OS side
// built it that way so a UI cannot commit a reset without having run the plan
// — and running the plan is the step that produces the loss list. So this file
// never constructs a token, never derives one from a scope, and offers no
// function that could: `commitArgv` takes the token it was given and refuses
// anything that is not the exact string a plan printed.
//
// Everything above is asserted in tests/recovery-test.js.
// ─────────────────────────────────────────────────────────────────────────────

// ── states ──────────────────────────────────────────────────────────────────

var STATE = {
    VERIFIED:    "verified",
    AVAILABLE:   "available",
    ATTENTION:   "attention",
    UNAVAILABLE: "unavailable"
};

// The one-word gloss shown beside a row. Deliberately not the raw state name
// for `available`: "available" alone reads as a tick to most people, and the
// whole point of the state is that nothing checked it.
var STATE_LABELS = {
    verified:    "Verified",
    available:   "Unverified",
    attention:   "Needs attention",
    unavailable: "Unknown"
};

// Which Theme colour role a state gets. A NAME, not a colour: this file is
// loaded by a node process that has no Theme, and the mapping is the thing
// worth testing. RecoveryService turns these into tokens.
//
//   ok      -> Theme.success   only `verified` earns it
//   neutral -> Theme.subtext   `available` and `unavailable`: no claim made
//   warn    -> Theme.warning   `attention`: named action exists
var STATE_TONES = {
    verified:    "ok",
    available:   "neutral",
    attention:   "warn",
    unavailable: "neutral"
};

function stateLabel(s) {
    return STATE_LABELS[s] || "Unknown";
}

function stateTone(s) {
    return STATE_TONES[s] || "neutral";
}

// An unrecognised state is `unavailable`, never `verified`. A future apexd row
// state this build has never heard of must not render as a tick.
function normalizeState(s) {
    return STATE_LABELS[s] ? s : STATE.UNAVAILABLE;
}

// ── json, defensively ───────────────────────────────────────────────────────

function parseJson(text) {
    if (typeof text !== "string")
        return null;
    var trimmed = text.trim();
    if (trimmed === "")
        return null;
    try {
        var v = JSON.parse(trimmed);
        return (v && typeof v === "object") ? v : null;
    } catch (e) {
        return null;
    }
}

function asArray(v) {
    return Array.isArray(v) ? v : [];
}

function asString(v) {
    return typeof v === "string" ? v : "";
}

// ── apex recover status --json ──────────────────────────────────────────────

// The row ids docs/recovery.md declares a compatibility surface. Kept here so
// a renamed id shows up as a missing row rather than as a silently shorter
// list, and so the page can order rows the way §19 lists them regardless of
// what order apexd emits.
var ROW_ORDER = [
    "current-deployment",
    "previous-deployment",
    "secure-boot",
    "filesystem",
    "gpu-driver",
    "apex-shell",
    "network",
    "package-extensions"
];

var EMPTY_STATUS = {
    ok: false,
    bootloader: "",
    rows: [],
    actions: [],
    routes: [],
    resetScopes: [],
    needsAttention: 0
};

// `ran` is "the process produced output", not "the process exited 0". See the
// header: a status exit of 1 is a report of attention, with a complete payload.
function parseStatus(exitCode, text) {
    var doc = parseJson(text);
    if (!doc)
        return EMPTY_STATUS;

    var rows = asArray(doc.rows).map(function (r) {
        r = r || {};
        return {
            id:     asString(r.id),
            label:  asString(r.label),
            state:  normalizeState(asString(r.state)),
            detail: asString(r.detail),
            // `action` is null on most rows. An empty string is the "no action"
            // marker throughout the shell, so it is normalised here rather than
            // leaving the view to test for null AND for "".
            action: asString(r.action)
        };
    }).filter(function (r) { return r.id !== ""; });

    // §19's order, then anything apexd grew that this build does not know
    // about — appended rather than dropped, because a row nobody rendered is
    // the failure mode this whole page exists to end.
    var known = [];
    var seen = {};
    for (var i = 0; i < ROW_ORDER.length; i++) {
        for (var j = 0; j < rows.length; j++) {
            if (rows[j].id === ROW_ORDER[i]) {
                known.push(rows[j]);
                seen[rows[j].id] = true;
                break;
            }
        }
    }
    for (var k = 0; k < rows.length; k++)
        if (!seen[rows[k].id])
            known.push(rows[k]);

    return {
        ok: true,
        bootloader: asString(doc.bootloader),
        rows: known,
        actions: asArray(doc.actions).map(function (a) {
            a = a || {};
            return {
                id: asString(a.id),
                label: asString(a.label),
                command: asString(a.command).replace(/\s+/g, " ").trim()
            };
        }),
        routes: asArray(doc.routes).map(function (r) {
            r = r || {};
            return {
                id: asString(r.id),
                // Tri-state on purpose. `installer-media` is null — a running
                // system cannot tell — and rendering null as `false` would
                // claim there is no install medium, which nobody checked.
                available: (r.available === true || r.available === false)
                    ? r.available : null,
                how: asString(r.how)
            };
        }),
        resetScopes: asArray(doc.resetScopes).map(function (s) {
            s = s || {};
            return { id: asString(s.id), summary: asString(s.summary) };
        }),
        needsAttention: typeof doc.needsAttention === "number"
            ? doc.needsAttention
            // Recomputed rather than defaulted to 0: a payload without the key
            // still has the rows, and 0 would read as "all fine".
            : known.filter(function (r) { return r.state === STATE.ATTENTION; }).length
    };
}

// "yes" / "no" / "unknown", the three the route table actually has.
function routeMark(available) {
    if (available === true)  return "yes";
    if (available === false) return "no";
    return "unknown";
}

// ── apex doctor --json ──────────────────────────────────────────────────────

// The doctor prints continuation lines indented by two spaces — the touchpad
// check has four of them under it. They are one check each as far as the JSON
// is concerned, so the indent is the only thing carrying the relationship, and
// dropping it turns a readable block into eight sentences in a row.
function checkDepth(what) {
    var m = /^( +)/.exec(asString(what));
    return m ? Math.floor(m[1].length / 2) : 0;
}

var EMPTY_DOCTOR = { ok: false, checks: [], passed: 0, warned: 0, total: 0 };

function parseDoctor(exitCode, text) {
    var doc = parseJson(text);
    if (!doc || !Array.isArray(doc.checks))
        return EMPTY_DOCTOR;

    var checks = doc.checks.map(function (c) {
        c = c || {};
        var what = asString(c.check);
        return {
            // `ok` is a boolean in the payload; anything else is NOT a pass.
            // `undefined` coerced by `!!` would have been false anyway, but a
            // string "false" would not, and that is the shape a future schema
            // change most plausibly takes.
            ok: c.ok === true,
            check: what.trim(),
            depth: checkDepth(what)
        };
    }).filter(function (c) { return c.check !== ""; });

    var passed = checks.filter(function (c) { return c.ok; }).length;
    return {
        ok: true,
        checks: checks,
        passed: passed,
        warned: checks.length - passed,
        total: checks.length
    };
}

// The doctor's own comment says a WARN is information rather than a fault, so
// this never says "unhealthy". It says how many warned, which is what the
// counts mean.
function doctorSummary(d) {
    if (!d || !d.ok)          return "not run";
    if (d.total === 0)        return "no checks";
    if (d.warned === 0)       return d.passed + " checks, all pass";
    return d.passed + " of " + d.total + " pass, " + d.warned + " to read";
}

// ── apex recover repair --json ──────────────────────────────────────────────

var EMPTY_REPAIR = { ok: false, domain: "", committed: false, steps: [] };

// A step is offered only where apexd diagnosed it, and `runnableHere` is
// apexd's own answer about the privilege domain — not something recomputed
// here. Repair converges the domain it is already in and reports the other,
// so a step with `runnableHere: false` is a command to show, never a button.
function parseRepair(exitCode, text) {
    var doc = parseJson(text);
    if (!doc || !Array.isArray(doc.steps))
        return EMPTY_REPAIR;
    return {
        ok: true,
        domain: asString(doc.domain),
        committed: doc.committed === true,
        steps: doc.steps.map(function (s) {
            s = s || {};
            return {
                id: asString(s.id),
                domain: asString(s.domain),
                what: asString(s.what),
                whySafe: asString(s.whySafe),
                command: asArray(s.command).join(" "),
                // Anything that is not an explicit true is NOT runnable here.
                // The wrong direction on this one runs a system step as the
                // user and reports success at doing nothing.
                runnableHere: s.runnableHere === true
            };
        }).filter(function (s) { return s.id !== ""; })
    };
}

// ── apex recover reset --json (the dry run) ─────────────────────────────────

// What the plan's disposition means where a person can read it. `truncate` is
// NOT a deletion: hyprland.conf `source=`s those two files and a missing
// source is fatal, so they are emptied and left in place. Printing "Deleted"
// there would describe a reset that would break the compositor.
var DISPOSITION_VERBS = {
    delete:   "Deleted",
    truncate: "Emptied, not removed"
};

function dispositionVerb(d) {
    return DISPOSITION_VERBS[d] || String(d || "changed");
}

var EMPTY_PLAN = {
    ok: false,
    scope: "",
    summary: "",
    confirmToken: "",
    committed: false,
    losses: [],
    preserved: [],
    reprovision: false,
    provisioner: ""
};

// The confirm token's shape, as apexd builds it: `<scope>:<count>:<hash>`.
// Validated rather than trusted so a truncated read or an error message on
// stdout cannot be handed to `--commit` as if it were a token.
var TOKEN_RE = /^[a-z]+:[0-9]+:[0-9a-f]+$/;

function looksLikeToken(t) {
    return typeof t === "string" && TOKEN_RE.test(t);
}

// Only what will actually change. `exists: false` targets are in the payload
// because the table is static, and listing a path that is not there as a loss
// is how a loss list stops being believed.
//
// This filter is deliberately the same one apexd's `token_paths()` applies
// when it derives the token, so the count in `<scope>:<count>:<hash>` equals
// the number of rows rendered here. tests/recovery-test.js asserts that
// equality against a real payload — it is what makes "the token cannot be had
// without rendering the list" checkable rather than merely intended.
function lossList(doc) {
    return asArray(doc && doc.targets)
        .filter(function (t) { return t && t.exists === true; })
        .map(function (t) {
            return {
                path: asString(t.path),
                relative: asString(t.relative),
                what: asString(t.what),
                kind: t.kind === "dir" ? "dir" : "file",
                disposition: asString(t.disposition),
                verb: dispositionVerb(t.disposition),
                // Caches are not backed up, and saying so on the row is the
                // difference between "recoverable" and "gone".
                backedUp: t.backedUp === true
            };
        });
}

function parseResetPlan(exitCode, text) {
    var doc = parseJson(text);
    if (!doc)
        return EMPTY_PLAN;

    var token = asString(doc.confirmToken);
    var losses = lossList(doc);

    // A plan whose token does not parse is not a plan this UI will act on. It
    // still renders — knowing what would be lost is useful on its own — but
    // `ok` gates the commit control, and `commitArgv` refuses the token
    // independently.
    return {
        ok: looksLikeToken(token),
        scope: asString(doc.scope),
        summary: asString(doc.summary),
        confirmToken: token,
        committed: doc.committed === true,
        losses: losses,
        preserved: asArray(doc.preserved).filter(function (p) {
            return typeof p === "string" && p !== "";
        }),
        // The reset refuses to start if the provisioner is missing, because it
        // could not put back what it removed. Surfaced so the panel can say so
        // BEFORE the button is pressed rather than after.
        reprovision: doc.reprovision === true,
        provisioner: asString(doc.provisioner)
    };
}

// The count the token binds to, read back out of the token itself. Compared
// against the number of rows rendered: if they disagree, the list on screen is
// not the list the token covers, and the commit must not go out.
function tokenCount(token) {
    if (!looksLikeToken(token))
        return -1;
    return parseInt(token.split(":")[1], 10);
}

function tokenScope(token) {
    if (!looksLikeToken(token))
        return "";
    return token.split(":")[0];
}

// ── the commit argv ─────────────────────────────────────────────────────────

// Built here, not in QML, so it is testable — and so there is exactly one
// place that can produce a `--commit`.
//
// Every refusal is a null return with no argv at all. There is no "best
// effort" branch: a factory reset assembled from a token this file could not
// verify is the one outcome worth crashing into a no-op instead.
function commitArgv(plan, renderedCount, token) {
    if (!plan || !plan.ok)                    return null;
    if (!looksLikeToken(token))               return null;
    // The token must be the one THIS plan printed. Not merely a well-formed
    // one, and never one recomputed from the scope: apexd's whole design is
    // that the token cannot be constructed without running the plan.
    if (token !== plan.confirmToken)          return null;
    if (tokenScope(token) !== plan.scope)     return null;
    // The list on screen must be the list the token covers. This is the check
    // that makes "the panel showed what will be lost" a precondition of the
    // commit rather than a promise about the order things happen in.
    if (renderedCount !== plan.losses.length) return null;
    if (renderedCount !== tokenCount(token))  return null;

    return ["apex", "recover", "reset",
            "--scope", plan.scope,
            "--commit",
            "--confirm", token];
}

// The dry run. Never `--commit`, and asserted so by the static check.
function planArgv(scope) {
    if (scope !== "desktop" && scope !== "user")
        return null;
    return ["apex", "recover", "reset", "--scope", scope, "--json"];
}

// ── reading a commit back ───────────────────────────────────────────────────

// apexd refuses a stale token with a message naming both, and swallowing that
// in favour of a generic "failed" throws away the only sentence that explains
// what to do. So the message is carried through, and only the classification
// is done here.
var COMMIT = {
    OK:       "ok",
    STALE:    "stale",
    REFUSED:  "refused",
    NOT_RUN:  "not_run"
};

function readCommit(exitCode, stdoutText, stderrText) {
    var err = asString(stderrText);
    if (exitCode === 0)
        return { result: COMMIT.OK, message: asString(stdoutText).trim() };
    // exitCode 2 is apexd's "the confirmation does not match this plan" and
    // "--commit needs --confirm". Both mean: re-plan, do not retry.
    if (exitCode === 2)
        return { result: COMMIT.STALE, message: err.trim() };
    if (exitCode === null || exitCode === undefined)
        return { result: COMMIT.NOT_RUN, message: "`apex` did not run" };
    return { result: COMMIT.REFUSED, message: err.trim() };
}

// ── rollback, which is the other half of §25 ────────────────────────────────
//
// There is no `apex recover previous`; docs/recovery.md is explicit that
// adding one would be a second name for `apex rollback`. So the panel shows
// the command rather than running it — the verb needs root, and this shell
// raises no authentication prompt of its own. See RecoveryService's header.
var ROLLBACK_COMMAND = "sudo apex rollback";
var PIN_COMMAND      = "sudo apex pin";

// The advice the previous-deployment row carries, split out so the page can
// show it beside the rollback command instead of burying it in a detail
// paragraph. bootc keeps booted+previous only.
function rollbackHint(statusRows) {
    var row = null;
    for (var i = 0; i < asArray(statusRows).length; i++)
        if (statusRows[i].id === "previous-deployment")
            row = statusRows[i];
    if (!row)
        return "No previous deployment was reported.";
    if (row.state === STATE.UNAVAILABLE)
        return "Nothing to roll back to on this machine.";
    return row.detail;
}

if (typeof module !== "undefined" && module.exports)
    module.exports = {
        STATE: STATE,
        STATE_LABELS: STATE_LABELS,
        STATE_TONES: STATE_TONES,
        ROW_ORDER: ROW_ORDER,
        COMMIT: COMMIT,
        ROLLBACK_COMMAND: ROLLBACK_COMMAND,
        PIN_COMMAND: PIN_COMMAND,
        stateLabel: stateLabel,
        stateTone: stateTone,
        normalizeState: normalizeState,
        parseStatus: parseStatus,
        routeMark: routeMark,
        checkDepth: checkDepth,
        parseDoctor: parseDoctor,
        doctorSummary: doctorSummary,
        parseRepair: parseRepair,
        dispositionVerb: dispositionVerb,
        looksLikeToken: looksLikeToken,
        tokenCount: tokenCount,
        tokenScope: tokenScope,
        lossList: lossList,
        parseResetPlan: parseResetPlan,
        commitArgv: commitArgv,
        planArgv: planArgv,
        readCommit: readCommit,
        rollbackHint: rollbackHint
    };
