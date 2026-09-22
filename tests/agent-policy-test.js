#!/usr/bin/env node
// Tests the Agent Settings logic (P0-016) against the file the shell actually
// loads (src/services/agentpolicy.js), not a copy of it.
//
//   node tests/agent-policy-test.js
//
// ── Where the fixtures come from ─────────────────────────────────────────────
//
// Every configuration shape below is a file apex itself would write or accept,
// transcribed from apex-os at 583698b (branch roadmap/v2.2, commit
// "feat(agent): split the six permission dimensions"):
//
//   apexd/apex-agent-core/src/config.rs   the six sibling keys, `extra`, and
//                                         `normalise` resetting all six when
//                                         `validate` fails
//   apexd/apex-agent-core/src/policy.rs   `AgentPolicy::validate`'s four arms
//                                         and `effective_network`
//   apexd/apex-agent-core/src/protocol.rs `SandboxPolicy` and the flattened
//                                         `SessionInfo` policy keys
//
// ── What this is really guarding ─────────────────────────────────────────────
//
// Three failures, each of which would ship looking like it worked:
//
//   1. the toggle writes `sandbox` and something else moves with it. Criterion
//      3 says the agent's own permission mode survives, and the only way to
//      assert that is over a file that HAS one set.
//   2. the toggle writes a default apex will throw away, because `normalise`
//      resets all six dimensions rather than the one it objected to. The page
//      then shows unrestricted, the sandbox is still project, and `native:
//      bypass` is gone. Two lies from one write.
//   3. authentication is asked for on the wrong transitions. Criterion 4 gates
//      arriving; criterion 5 says leaving is immediate. Asserted over the whole
//      3×3 product, not over three cases somebody picked.

"use strict";

const path = require("path");
const P = require(path.join(__dirname, "..", "src", "services", "agentpolicy.js"));

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
function checkTrue(name, got) { check(name, !!got, true); }

// ─── reading the file ────────────────────────────────────────────────────────

check("a missing file is the project sandbox",
      P.effectiveDefault(""), "project");
check("an empty object is the project sandbox",
      P.effectiveDefault("{}"), "project");
check("whitespace only is the project sandbox",
      P.effectiveDefault("   \n "), "project");
check("a stored unrestricted default is read as unrestricted",
      P.effectiveDefault('{"sandbox":"unrestricted"}'), "unrestricted");
check("a stored strict default is read as strict",
      P.effectiveDefault('{"sandbox":"strict"}'), "strict");

// serde refuses the whole file for an unknown enum value and `load_reporting`
// falls back to the defaults, so an unrecognised string means what an absent
// one means. Reporting it as-is would put a mode on screen that no session can
// have.
check("an unknown sandbox value reads as the default",
      P.effectiveDefault('{"sandbox":"yolo"}'), "project");
check("a corrupt file reads as the default",
      P.effectiveDefault('{ "sandbox": '), "project");
check("a JSON array is not a configuration file",
      P.parseConfig("[1,2]").ok, false);

// ─── validate()'s four arms, mirrored ────────────────────────────────────────

check("open network with any sandbox is enforceable",
      P.refusalFor({ sandbox: "unrestricted" }), null);
check("strict forces offline and strict is confined, so it is enforceable",
      P.refusalFor({ sandbox: "strict" }), null);
check("project with an explicit offline network is enforceable",
      P.refusalFor({ sandbox: "project", network: "offline" }), null);
checkTrue("unrestricted with an offline network is refused",
      P.refusalFor({ sandbox: "unrestricted", network: "offline" }) !== null);
checkTrue("an allowlist network is refused",
      P.refusalFor({ network: "allowlist" }) !== null);
checkTrue("a brokered network is refused",
      P.refusalFor({ network: "brokered" }) !== null);
// Dimension 3 used to be refused here, because P0-004 shipped the vocabulary
// with nothing behind it. P0-006 and P0-007 built the grant machinery, so
// `validate` accepts both — and a stored default of either is corrected to
// `none` by `normalise` before `validate` ever sees it, because §3.4 allows no
// remembered elevation. A correction is not a refusal and must not block a
// write that is about a different key; `storedElevationNote` is what says the
// file was not obeyed. See the block near the end of this file.
check("a stored session grant no longer refuses the file",
      P.refusalFor({ system: "session" }), null);
check("nor does a stored break-glass default",
      P.refusalFor({ system: "unsafe" }), null);
checkTrue("raw secret export is refused",
      P.refusalFor({ secrets: "export" }) !== null);
checkTrue("remote elevation is refused",
      P.refusalFor({ origin: "remote_elevation_allowed" }) !== null);

check("effective_network: strict overrides the stored network key",
      P.effectiveNetwork({ sandbox: "strict", network: "open" }), "offline");
check("effective_network: an unrestricted sandbox does not open the network",
      P.effectiveNetwork({ sandbox: "unrestricted", network: "offline" }), "offline");

// A file apex would reset wholesale is reported at the value apex will use,
// not at the value it contains.
check("a stored default apex would discard is reported as the default",
      P.effectiveDefault('{"sandbox":"unrestricted","network":"offline"}'), "project");

// ─── criterion 4 and 5: when a password is required ──────────────────────────
// The whole product, so a rule that happens to be right for three hand-picked
// pairs cannot pass.

const WANT_AUTH = {};
for (const from of P.SANDBOX_MODES)
    for (const to of P.SANDBOX_MODES)
        WANT_AUTH[from + "->" + to] = (to === "unrestricted" && from !== "unrestricted");

const GOT_AUTH = {};
for (const from of P.SANDBOX_MODES)
    for (const to of P.SANDBOX_MODES)
        GOT_AUTH[from + "->" + to] = P.requiresAuth(from, to);

check("authentication is required exactly on arriving at unrestricted",
      GOT_AUTH, WANT_AUTH);

// Named, so the two criteria are readable in the output and a future edit that
// inverts the rule fails on a line that says which criterion it broke.
check("criterion 4: project to unrestricted needs authentication",
      P.requiresAuth("project", "unrestricted"), true);
check("criterion 4: strict to unrestricted needs authentication",
      P.requiresAuth("strict", "unrestricted"), true);
check("criterion 5: unrestricted to project is immediate",
      P.requiresAuth("unrestricted", "project"), false);
check("criterion 5: unrestricted to strict is immediate",
      P.requiresAuth("unrestricted", "strict"), false);
check("re-asserting unrestricted is not a transition and does not prompt",
      P.requiresAuth("unrestricted", "unrestricted"), false);

// ─── criterion 3: the other five dimensions survive the write ────────────────

const WITH_BYPASS = JSON.stringify({
    default_agent: "claude",
    native: "bypass",
    sandbox: "project",
    secrets: "none",
    detach_key: "ctrl-]",
    auto_checkpoint: true,
    shell_layout: "grid",          // an `extra` key this build does not know
    future: { a: 1 }
}, null, 2) + "\n";

function keysExcept(text, drop) {
    const o = JSON.parse(text);
    delete o[drop];
    return o;
}

const on = P.nextConfig(WITH_BYPASS, true);
check("switching on succeeds on an ordinary file", on.ok, true);
check("switching on sets the sandbox to unrestricted",
      JSON.parse(on.text).sandbox, "unrestricted");
check("switching on leaves every other key exactly as it was",
      keysExcept(on.text, "sandbox"), keysExcept(WITH_BYPASS, "sandbox"));
check("switching on leaves the agent's own permission mode alone",
      JSON.parse(on.text).native, "bypass");

const off = P.nextConfig(on.text, false);
check("switching off succeeds", off.ok, true);
check("switching off restores the project sandbox",
      JSON.parse(off.text).sandbox, "project");
// Criterion 3 in one line: OFF restores the APEX default and dimension 1 is
// still where the user left it.
check("switching off leaves the agent's own permission mode alone",
      JSON.parse(off.text).native, "bypass");
check("switching off leaves every other key exactly as it was",
      keysExcept(off.text, "sandbox"), keysExcept(WITH_BYPASS, "sandbox"));

check("a round trip through on and off is the file we started with",
      JSON.parse(off.text), JSON.parse(WITH_BYPASS));

check("an unknown key survives the write",
      JSON.parse(on.text).shell_layout, "grid");
check("a nested unknown value survives the write",
      JSON.parse(on.text).future, { a: 1 });

check("a file with no sandbox key gains one and keeps the rest",
      JSON.parse(P.nextConfig('{"default_agent":"codex"}', true).text),
      { default_agent: "codex", sandbox: "unrestricted" });

// ─── refusing rather than writing a default apex would discard ───────────────

const OFFLINE = '{"native":"bypass","network":"offline"}';
check("switching on is refused when apex would reset all six dimensions",
      P.nextConfig(OFFLINE, true).ok, false);
checkTrue("the refusal says the whole file would be discarded",
      /discard/.test(P.nextConfig(OFFLINE, true).reason));
checkTrue("enableRefused reports the same refusal in advance",
      P.enableRefused(OFFLINE) !== null);
check("enableRefused is null on a file that would take the change",
      P.enableRefused(WITH_BYPASS), null);

// Switching OFF an offline file is fine: project is confined, so the network
// dimension still has a namespace to unshare.
check("switching off is not refused on the same file",
      P.nextConfig(OFFLINE, false).ok, true);

// ─── never overwrite what we could not read ──────────────────────────────────

const CORRUPT = '{ "native": "bypass",, }';
check("a corrupt file is not overwritten when switching on",
      P.nextConfig(CORRUPT, true).ok, false);
check("a corrupt file is not overwritten when switching off either",
      P.nextConfig(CORRUPT, false).ok, false);
checkTrue("the refusal says the file will be left alone",
      /will not overwrite/.test(P.nextConfig(CORRUPT, true).reason));

// ─── pkcheck exit codes ──────────────────────────────────────────────────────
// Verified against polkit 126 rather than recalled: an unregistered action id
// exits 127 with "is not registered" on stderr, a challenge that cannot be
// answered exits 2, and a usage problem exits 126.

check("exit 0 is granted", P.authOutcome(0, ""), P.AUTH_GRANTED);
check("exit 1 is refused", P.authOutcome(1, ""), P.AUTH_REFUSED);
check("exit 2 is an authentication that did not complete",
      P.authOutcome(2, ""), P.AUTH_INCOMPLETE);
check("an unregistered action is not reported as a refusal",
      P.authOutcome(127, "GDBus.Error:...: Action org.apexos.shell.agent."
                       + "set-always-unrestricted is not registered"),
      P.AUTH_UNREGISTERED);
check("any other polkit error is an error", P.authOutcome(127, "boom"), P.AUTH_ERROR);
check("a usage failure is an error", P.authOutcome(126, ""), P.AUTH_ERROR);
check("granted has no message to show", P.authMessage(P.AUTH_GRANTED), "");
checkTrue("every other outcome has one",
      [P.AUTH_REFUSED, P.AUTH_INCOMPLETE, P.AUTH_UNREGISTERED, P.AUTH_ERROR]
          .every(o => P.authMessage(o).length > 0));

// ─── criterion 8: a running session reports its own mode ─────────────────────
// SessionInfo flattens the six dimensions the daemon normalised at fork time,
// so `sandbox` on a session record is that session's real mode.

const RUNNING = [
    { id: 1, sandbox: "project",      native: "inherit", exit_code: null, exit_signal: null },
    { id: 2, sandbox: "unrestricted", native: "bypass",  exit_code: null, exit_signal: null },
    { id: 3, sandbox: "strict",       native: "inherit", exit_code: null, exit_signal: null },
    { id: 4, sandbox: "unrestricted", native: "inherit", exit_code: 0,    exit_signal: null }
];

check("a session reports the sandbox it was started with",
      RUNNING.map(P.sessionSandbox),
      ["project", "unrestricted", "strict", "unrestricted"]);

// A record written before the dimensions were split has no `sandbox` key at
// all. `project` is what an absent field meant, and it is what SandboxPolicy
// defaults to, so an old session is not drawn as unrestricted.
check("a pre-split session record reads as project",
      P.sessionSandbox({ id: 9, exit_code: null, exit_signal: null }), "project");
check("an unknown recorded mode reads as project rather than as itself",
      P.sessionSandbox({ sandbox: "yolo" }), "project");

check("dimension 1 is read from the session too",
      RUNNING.map(P.sessionNative),
      ["inherit", "bypass", "inherit", "inherit"]);
check("a session with no native key reads as inherit",
      P.sessionNative({ id: 9 }), "inherit");

// The point of the criterion: the default is not an input. Whatever it is, the
// same four sessions come back with the same four modes.
for (const def of P.SANDBOX_MODES)
    check(`sessions keep their own mode when the default is ${def}`,
          RUNNING.map(P.sessionSandbox),
          ["project", "unrestricted", "strict", "unrestricted"]);

check("live sessions on another mode are named, finished ones are not",
      P.sessionsOnOtherModes(RUNNING, "unrestricted").map(s => s.id), [1, 3]);
check("nothing disagrees when every live session matches",
      P.sessionsOnOtherModes(
          [{ id: 1, sandbox: "project", exit_code: null, exit_signal: null }],
          "project").length, 0);
check("live unconfined sessions are found whatever the default is",
      P.unrestrictedSessions(RUNNING).map(s => s.id), [2]);
check("a session that exited is not counted as running unconfined",
      P.unrestrictedSessions(
          [{ id: 4, sandbox: "unrestricted", exit_code: 0, exit_signal: null }]).length, 0);
check("a signalled session is not live either",
      P.unrestrictedSessions(
          [{ id: 5, sandbox: "unrestricted", exit_code: null, exit_signal: 9 }]).length, 0);

// ─── tones ───────────────────────────────────────────────────────────────────

check("only the unconfined mode gets a tone of its own",
      P.SANDBOX_MODES.map(P.modeToken), ["danger", "subtext", "subtext"]);
check("an unknown mode is drawn subdued rather than as a warning",
      P.modeToken("yolo"), "subtext");

// ─── dimension 1, as the agent reports it (P0-005 criterion 3) ──────────────
//
// The trap this is really guarding. `session.native` says what APEX DID, and
// for the case that matters APEX did nothing: Andre runs Claude in
// `bypassPermissions` as a profile default, §4.1 says APEX must not override
// it, so `native` is `inherit`. A chip showing "inherit" beside a session
// running with confirmations off satisfies the criterion's words and answers
// none of its question.
//
// `native_observed` is what apex-agentd records from Claude's own hook
// payloads. Fixtures transcribed from apex-os `apexd/apex-agent-core/src/`
// `protocol.rs` (`SessionInfo.native_observed`) and `hook.rs` (`native_mode`).

check("the agent's own report is what the chip shows",
      P.sessionNativeLabel({ native: "inherit", native_observed: "bypassPermissions" }),
      "bypassPermissions");
check("and it beats APEX's own flag, because it is the current one",
      P.sessionNativeLabel({ native: "bypass", native_observed: "plan" }), "plan");
check("with nothing reported, a mode APEX selected is still worth saying",
      P.sessionNativeLabel({ native: "bypass" }), "bypass");
check("but inherit with nothing reported says nothing at all",
      P.sessionNativeLabel({ native: "inherit" }), "");
check("and so does a session record from before the field existed",
      P.sessionNativeLabel({}), "");
check("an empty report is not a mode",
      P.sessionNativeLabel({ native: "inherit", native_observed: "" }), "");
check("a page can tell a report from a flag",
      [P.sessionNativeIsReported({ native: "bypass" }),
       P.sessionNativeIsReported({ native_observed: "acceptEdits" })],
      [false, true]);
// Claude's four, passed through rather than mapped: three of them have no APEX
// vocabulary, and folding them into "not ask" would answer "what mode is this
// agent in" with a summary of what APEX did about it.
check("claude's own words survive unmapped",
      ["default", "acceptEdits", "plan", "bypassPermissions"]
          .map(m => P.sessionNativeLabel({ native: "inherit", native_observed: m })),
      ["default", "acceptEdits", "plan", "bypassPermissions"]);

// ─── break-glass (P0-006 criterion 3) ───────────────────────────────────────
//
// §3.4 asks for a "prominent red indicator" and for "revocation control always
// visible". Both need one question answered the same way everywhere: is THIS
// session break-glass, and how long is left.

const BREAK_GLASS = {
    id: 3, sandbox: "unrestricted", system: "unsafe",
    grant: 7, grant_expires_ms: 1000 + 900000,
    exit_code: null, exit_signal: null
};

check("break-glass is the mode that clears no_new_privs, and it is one",
      P.isBreakGlass(BREAK_GLASS), true);
check("a session grant is NOT break-glass, so it does not go red",
      P.isBreakGlass({ system: "session", grant: 8 }), false);
check("nor is an ordinary session, however unconfined",
      P.isBreakGlass({ sandbox: "unrestricted", system: "none" }), false);
// Both halves required: the daemon refuses `unsafe` without a grant, so a
// session claiming one without the other is a record to distrust rather than
// the loudest thing in the interface.
check("unsafe with no grant is not drawn as break-glass",
      P.isBreakGlass({ system: "unsafe" }), false);
check("a grant with no mode is not either",
      P.isBreakGlass({ grant: 7 }), false);
check("and neither is a session record from before grants existed",
      P.isBreakGlass({ sandbox: "project" }), false);

check("the revoke control knows which grant to end",
      P.sessionGrant(BREAK_GLASS), 7);
check("and there is nothing to end when there is no grant",
      P.sessionGrant({ sandbox: "project" }), null);

// The countdown. Mirrors `grant::format_ms` in apex-agent-core so the shell
// and `apex agent grants` do not describe one window two ways.
check("a window reads the way a person would say it",
      [900000, 5400000, 3600000, 90000, 45000].map(P.formatRemaining),
      ["15m", "1h 30m", "1h", "1m", "45s"]);
check("a window that has run out is 0s and not blank",
      P.formatRemaining(0), "0s");
check("time left is clamped rather than shown negative",
      P.grantRemainingMs({ grant_expires_ms: 1000 }, 9000), 0);
check("a session with no grant has no countdown to show",
      P.grantRemainingMs({ sandbox: "project" }, 9000), null);

check("the indicator says what it is and how long is left",
      P.breakGlassLabel(BREAK_GLASS, 1000), "BREAK-GLASS · 15m");
check("and says it is ending rather than showing a window of nothing",
      P.breakGlassLabel(BREAK_GLASS, 1000 + 900000), "BREAK-GLASS · ending");
check("a session that is not break-glass gets no indicator",
      P.breakGlassLabel({ system: "session", grant: 2 }, 0), "");

// ─── the correction that is not a refusal ───────────────────────────────────
//
// §3.4 allows no remembered elevation, so `Config::normalise` resets a stored
// dimension-3 default to `none` — ONE key, with the other five left alone. It
// used to be a `validate` refusal that reset all six, which is why this file
// asserted the toggle refused to write over such a file.

check("a stored elevation no longer blocks the toggle",
      P.refusalFor({ system: "unsafe", sandbox: "project" }), null);
check("because apex corrects that one key rather than refusing the file",
      P.storedElevationNote({ system: "unsafe" }) !== null, true);
check("and the note says how to ask for it properly",
      P.storedElevationNote({ system: "session" }).indexOf("--ttl") >= 0, true);
check("a file with no stored elevation has nothing to say about it",
      P.storedElevationNote({ sandbox: "project" }), null);
// The toggle still carries dimension 1 across untouched, which is P0-016
// criterion 3 and now has a second dimension in the file to survive alongside.
check("turning the sandbox off leaves a stored bypass alone",
      JSON.parse(P.nextConfig(
          JSON.stringify({ native: "bypass", system: "unsafe", sandbox: "project" }),
          true).text),
      { native: "bypass", system: "unsafe", sandbox: "unrestricted" });

// ─────────────────────────────────────────────────────────────────────────────

if (failed) {
    console.error(`\n${failed} check(s) failed`);
    process.exit(1);
}
console.log("\nall checks passed");
