// ─── agentpolicy.js ──────────────────────────────────────────────────────────
// Pure logic behind the Agent Settings page (P0-016, ROADMAP.md §42.1): what
// the APEX sandbox default currently is, what a change to it would do, and
// whether that change has to be authenticated first.
//
// Kept out of the QML for the same reason remoteagents.js is: this is the part
// with edge cases, and tests/agent-policy-test.js drives THIS file — the one
// the shell loads — rather than a copy. Nothing here does I/O and nothing here
// knows about Theme, so a node process can exercise all of it. In particular
// AUTHENTICATION IS NOT HERE. `requiresAuth` decides whether a transition needs
// a password; the pkcheck call that asks for one lives in AgentPolicyService,
// because a password prompt cannot be unit-tested and a policy decision must be.
//
// ── The file this reads and writes ──────────────────────────────────────────
//
// `$XDG_CONFIG_HOME/apex/agent.json`, the agent runtime's own configuration —
// apexd/apex-agent-core/src/paths.rs `config_file()`, parsed by that crate's
// config.rs into six sibling permission keys. It is the only file `apex agent
// run` consults for a default, so it is the only place a setting in the shell
// can change what a new session gets. A mirror in the shell's own settings
// would be read by nothing: `a` launches from a terminal that never asks the
// shell anything.
//
// Writing somebody else's configuration file means two obligations.
//
// FIRST, KEEP WHAT WE DO NOT UNDERSTAND. config.rs flattens unrecognised keys
// into `extra` and writes them back, so a round trip through apex is lossless.
// This does the same by editing the parsed object and reserialising it: one
// key changes and every other key, known or not, survives byte for byte in
// value and in order.
//
// SECOND, NEVER WRITE OVER SOMETHING WE COULD NOT PARSE. apex treats a corrupt
// file as the defaults, but it LEAVES THE FILE ALONE, so the user can still fix
// their stray comma. A settings page that silently replaced it with two keys
// would destroy hand-written configuration to fix its own display. `nextConfig`
// refuses instead, and the page says why.
//
// ── Why validate() is mirrored here ─────────────────────────────────────────
//
// `Config::normalise` runs `AgentPolicy::validate` on load, and when a stored
// default is one this build cannot enforce it does not correct that one key —
// it calls `set_policy(AgentPolicy::default())` and resets ALL SIX dimensions.
//
// That turns one plausible file into two lies at once. A user with
// `{"native":"bypass","network":"offline"}` who switches this toggle on gets a
// stored `sandbox: unrestricted` that apex refuses (offline needs a namespace
// and an unconfined session has none), so the next `apex agent run` is
// project-sandboxed AND back to `native: inherit` — the sandbox did not change
// and the agent's own permission mode was thrown away, which is exactly what
// criterion 3 exists to prevent.
//
// So `refusalFor` is validate()'s four arms, `nextConfig` runs it on the
// PROPOSED object and refuses rather than write a default apex will discard,
// and `effectiveDefault` runs it on the stored one so the page reports the
// sandbox sessions will actually get. Transcribed from
// apexd/apex-agent-core/src/policy.rs at 583698b; the reference is in the test.
// ─────────────────────────────────────────────────────────────────────────────

"use strict";

// Dimension 2 (`SandboxPolicy`), in the order policy.rs declares them.
var SANDBOX_MODES = ["unrestricted", "project", "strict"];

// `SandboxPolicy::default()`. Also what an absent key, an absent file and a
// file this cannot parse all mean.
var DEFAULT_SANDBOX = "project";

// The value the toggle writes when it is switched on.
var UNRESTRICTED = "unrestricted";

// Theme token NAMES per sandbox mode, looked up on Theme rather than switched
// on in QML — the idiom agentstate.js established, so one file decides what
// colour a mode is and the page, the row and the banner cannot disagree.
//
// Only `unrestricted` gets a tone of its own. `project` and `strict` are both
// confined and both ordinary, and giving strict a third colour would spend the
// reader's attention on a distinction that costs nothing to be wrong about.
var MODE_TOKENS = {
    unrestricted: "danger",
    project: "subtext",
    strict: "subtext"
};

// ── reading ──────────────────────────────────────────────────────────────────

/// Parse `agent.json`. Returns `{ok: true, config}` or `{ok: false, reason}`.
///
/// An empty string is `{}`: a missing file is the defaults, not a fault, and it
/// is the normal state until somebody has changed a setting. A JSON document
/// that is not an object IS a fault — an array or a bare number where the
/// runtime expects a struct means the file is not what we think it is, and
/// editing it would be guessing.
function parseConfig(text) {
    var raw = String(text === null || text === undefined ? "" : text).trim();
    if (raw === "")
        return { ok: true, config: {} };
    var parsed;
    try {
        parsed = JSON.parse(raw);
    } catch (e) {
        return { ok: false, reason: "not valid JSON (" + String(e.message || e) + ")" };
    }
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed))
        return { ok: false, reason: "not a JSON object" };
    return { ok: true, config: parsed };
}

/// The `sandbox` key as stored, or the default when it is absent or unknown.
///
/// `Config::normalise` does not correct an unknown sandbox string — serde
/// refuses the whole file and `load_reporting` falls back to the defaults — so
/// an unrecognised value here means the same thing an absent one does.
function storedSandbox(config) {
    var v = config ? config.sandbox : null;
    return SANDBOX_MODES.indexOf(v) >= 0 ? v : DEFAULT_SANDBOX;
}

/// `AgentPolicy::effective_network`: `strict` forces the network dimension to
/// offline. The one derivation between dimensions, and it only tightens.
function effectiveNetwork(config) {
    if (storedSandbox(config) === "strict")
        return "offline";
    var n = config ? config.network : null;
    return typeof n === "string" && n !== "" ? n : "open";
}

/// `AgentPolicy::validate`, as a reason or null.
///
/// Four arms, in policy.rs's order. Each message says what apex would do with
/// the file rather than naming the Rust variant, because the reader is looking
/// at a toggle and not at a stack trace.
function refusalFor(config) {
    var network = effectiveNetwork(config);
    var sandbox = storedSandbox(config);
    if (network === "offline" && sandbox === "unrestricted")
        return "an offline session needs a network namespace, and an unrestricted "
             + "session has none";
    if (network !== "open" && network !== "offline")
        return "the network mode " + network + " has nothing enforcing it in this build";
    var system = config && config.system ? config.system : "none";
    if (system !== "none")
        return "the system-access mode " + system + " has no grant machinery in this build";
    if (config && config.secrets === "export")
        return "raw secret export has no route in this build";
    if (config && config.origin === "remote_elevation_allowed")
        return "elevation from a remote origin has no route in this build";
    return null;
}

/// The sandbox a new session actually gets, given the file's text.
///
/// Not `storedSandbox`. A file `Config::normalise` refuses is reset to all six
/// defaults before any session reads it, so what is written in it is not what
/// runs — and a settings page that showed the stored value would report a
/// protection the user does not have, or an exposure they do not have either.
function effectiveDefault(text) {
    var parsed = parseConfig(text);
    if (!parsed.ok)
        return DEFAULT_SANDBOX;
    if (refusalFor(parsed.config) !== null)
        return DEFAULT_SANDBOX;
    return storedSandbox(parsed.config);
}

/// Whether the toggle reads as on, for the file's text.
function alwaysUnrestricted(text) {
    return effectiveDefault(text) === UNRESTRICTED;
}

// ── deciding ─────────────────────────────────────────────────────────────────

/// Whether moving the sandbox default from `from` to `to` has to be
/// authenticated first (criteria 4 and 5).
///
/// The whole authentication policy, in one expression, on purpose. Criterion 4
/// gates ARRIVING at unrestricted and criterion 5 says leaving it is immediate,
/// so the question is only ever "is unrestricted where we are going, and is it
/// not where we already are". A no-op is not a transition and must not prompt:
/// a page that re-asserted the same value would train the user to type their
/// password at a dialog they did not ask for.
///
/// This is the function the tests drive, and it is separate from the prompt
/// deliberately — a pkcheck call cannot be unit-tested, and the rule about when
/// to make one must be.
function requiresAuth(from, to) {
    return to === UNRESTRICTED && from !== UNRESTRICTED;
}

/// The file's next text, or a refusal.
///
/// Returns `{ok: true, text}` or `{ok: false, reason}`. Only `sandbox` moves:
/// every other key is carried across untouched, which is criterion 3 at the
/// only layer that can enforce it — turning the sandbox off must not disturb
/// dimension 1, so a Claude profile in `bypassPermissions` keeps it.
function nextConfig(text, on) {
    var parsed = parseConfig(text);
    if (!parsed.ok)
        return {
            ok: false,
            reason: "the agent configuration file is " + parsed.reason
                  + ", so this will not overwrite it"
        };

    var next = {};
    for (var k in parsed.config)
        if (Object.prototype.hasOwnProperty.call(parsed.config, k))
            next[k] = parsed.config[k];
    next.sandbox = on ? UNRESTRICTED : DEFAULT_SANDBOX;

    var refusal = refusalFor(next);
    if (refusal !== null)
        return {
            ok: false,
            reason: "apex would discard every permission setting in the file, because "
                  + refusal
        };

    // Two-space pretty-printing and a trailing newline, matching what
    // `Config::save` writes with `serde_json::to_string_pretty`, so the file
    // does not reformat under the user depending on who last wrote it.
    return { ok: true, text: JSON.stringify(next, null, 2) + "\n" };
}

/// Why the toggle cannot be switched on right now, or null.
///
/// The same refusal `nextConfig` would return, asked in advance so the page can
/// disable the control and say the reason instead of accepting a click and
/// failing.
function enableRefused(text) {
    var r = nextConfig(text, true);
    return r.ok ? null : r.reason;
}

// ── what pkcheck said ────────────────────────────────────────────────────────

// pkcheck's exit codes, verified against polkit 126 on this machine rather than
// recalled: 0 authorized; 1 not authorized; 2 authentication was required and
// could not be obtained; 126 the subject or the arguments were unusable; 127 a
// polkit error, which is what an unregistered action id comes back as.
//
// Exit 2 is reported as "not completed" rather than as a missing authentication
// agent. Both a session with no agent registered and a dialog the user closed
// can land there, and telling them apart would take raising a real prompt.
var AUTH_GRANTED = "granted";
var AUTH_REFUSED = "refused";
var AUTH_INCOMPLETE = "incomplete";
var AUTH_UNREGISTERED = "unregistered";
var AUTH_ERROR = "error";

/// Turn one pkcheck exit into an outcome the page can render.
///
/// `unregistered` is broken out because it is the first thing a machine without
/// the action file installed will hit, and "not authorized" would be a
/// misleading way to report it: nothing was refused, there was nothing to ask.
function authOutcome(exitCode, stderr) {
    var err = String(stderr || "");
    if (exitCode === 0) return AUTH_GRANTED;
    if (exitCode === 1) return AUTH_REFUSED;
    if (exitCode === 2) return AUTH_INCOMPLETE;
    if (/is not registered/.test(err)) return AUTH_UNREGISTERED;
    return AUTH_ERROR;
}

var AUTH_MESSAGES = {
    granted: "",
    refused: "Authentication was refused, so nothing changed.",
    // Deliberately not "no authentication agent". pkcheck exits 2 when the
    // authentication could not be obtained, and this build cannot tell a
    // session with no agent registered from a dialog the user closed without
    // raising a real prompt to find out. Naming one of the two would be a
    // guess printed as a diagnosis.
    incomplete: "Authentication was not completed, so nothing changed.",
    unregistered: "This machine has no polkit action for the setting, so it "
                + "cannot be authenticated. Install "
                + "dots-extra/polkit/org.apexos.shell.agent.policy.",
    error: "The authentication check failed, so nothing changed."
};

function authMessage(outcome) {
    return AUTH_MESSAGES[outcome] !== undefined
        ? AUTH_MESSAGES[outcome]
        : AUTH_MESSAGES.error;
}

// ── describing a session that is already running ─────────────────────────────

/// The sandbox one running session actually has (criterion 8).
///
/// Reads the session's OWN record and nothing else. `SessionInfo` flattens the
/// six dimensions the daemon normalised when it forked the session, so this is
/// the mode that session was started with, not the mode a new one would get.
/// The default is deliberately not a parameter: a function that could see it
/// could accidentally return it, and the whole criterion is that changing the
/// default must not relabel work already in flight.
function sessionSandbox(session) {
    var v = session ? session.sandbox : null;
    return SANDBOX_MODES.indexOf(v) >= 0 ? v : DEFAULT_SANDBOX;
}

/// The session's own permission mode (dimension 1), or "inherit".
///
/// Shown only when it is not `inherit`, because `inherit` means APEX passed no
/// flag and the agent's own profile decided — reporting that as a mode would
/// claim knowledge of a file the runtime never read.
function sessionNative(session) {
    var v = session ? session.native : null;
    return v === "ask" || v === "bypass" ? v : "inherit";
}

function isLive(session) {
    return !!session
        && (session.exit_code === null || session.exit_code === undefined)
        && (session.exit_signal === null || session.exit_signal === undefined);
}

/// Live sessions whose recorded sandbox is not the one a new session would get.
///
/// What the page says out loud, so a user who has just switched the toggle can
/// see that the four things already running did not move.
function sessionsOnOtherModes(sessions, currentDefault) {
    var list = Array.isArray(sessions) ? sessions : [];
    var out = [];
    for (var i = 0; i < list.length; i++)
        if (isLive(list[i]) && sessionSandbox(list[i]) !== currentDefault)
            out.push(list[i]);
    return out;
}

/// Live sessions running with no APEX sandbox, whenever they started.
function unrestrictedSessions(sessions) {
    var list = Array.isArray(sessions) ? sessions : [];
    var out = [];
    for (var i = 0; i < list.length; i++)
        if (isLive(list[i]) && sessionSandbox(list[i]) === UNRESTRICTED)
            out.push(list[i]);
    return out;
}

/// The Theme token name for a sandbox mode.
function modeToken(mode) {
    return MODE_TOKENS[mode] !== undefined ? MODE_TOKENS[mode] : "subtext";
}

if (typeof module !== "undefined" && module.exports)
    module.exports = {
        SANDBOX_MODES: SANDBOX_MODES,
        DEFAULT_SANDBOX: DEFAULT_SANDBOX,
        UNRESTRICTED: UNRESTRICTED,
        MODE_TOKENS: MODE_TOKENS,
        AUTH_GRANTED: AUTH_GRANTED,
        AUTH_REFUSED: AUTH_REFUSED,
        AUTH_INCOMPLETE: AUTH_INCOMPLETE,
        AUTH_UNREGISTERED: AUTH_UNREGISTERED,
        AUTH_ERROR: AUTH_ERROR,
        parseConfig: parseConfig,
        storedSandbox: storedSandbox,
        effectiveNetwork: effectiveNetwork,
        refusalFor: refusalFor,
        effectiveDefault: effectiveDefault,
        alwaysUnrestricted: alwaysUnrestricted,
        requiresAuth: requiresAuth,
        nextConfig: nextConfig,
        enableRefused: enableRefused,
        authOutcome: authOutcome,
        authMessage: authMessage,
        sessionSandbox: sessionSandbox,
        sessionNative: sessionNative,
        isLive: isLive,
        sessionsOnOtherModes: sessionsOnOtherModes,
        unrestrictedSessions: unrestrictedSessions,
        modeToken: modeToken
    };
