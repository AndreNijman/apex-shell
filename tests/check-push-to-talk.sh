#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Static wiring invariants for global push-to-talk (roadmap P1-023).
#
#  ── What this file is NOT ────────────────────────────────────────────────────
#  It is not a behavioural suite. The decision layer — when the microphone
#  opens, whose session the words go to, what closes it again — is
#  src/services/pushtotalk.js, and `node tests/push-to-talk-test.js` drives that
#  file directly: 51 assertions, 13 mutants, all caught. Repeating any of that
#  here as greps would be strictly weaker than the suite that already exists.
#
#  ── What it IS ───────────────────────────────────────────────────────────────
#  Everything the node suite structurally cannot see: whether the reducer is
#  actually REACHABLE. A perfect state machine nothing calls is a file, not a
#  feature, and every one of the four links below fails silently.
#
#  1. The keybind. P1-023's acceptance is "works in Hyprland, niri and
#     Floating", and the three artefacts are generated three different ways:
#     `_genLua()` writes Hyprland Lua, `_genKdl()` writes niri KDL, and
#     `_applyLabwc()` hands the model to apex-os's
#     /usr/libexec/apex-labwc-keybinds. The first two emit
#     `qs -p <shell> ipc call <action-id> toggle` for any entry with NO `type`
#     field. The labwc generator is an ALLOWLIST: an action id absent from its
#     VERBS dict and carrying no `type` is skipped, and its `exec` arm
#     substitutes only $terminal/$browser/$fileManager — so an entry written as
#     `type: "exec", command: "$qsIpc voice-ptt toggle"` reaches Hyprland and
#     niri and is DROPPED on labwc, satisfying two thirds of the criterion while
#     reading as if it satisfied all of it. The absence of a `type` field is
#     therefore load-bearing, which is why it is asserted rather than assumed.
#
#  2. The IPC handler. `qs ipc call voice-ptt toggle` needs an
#     `IpcHandler { target: "voice-ptt" }` with a `toggle()` function, and the
#     target string must equal the `_defaults` KEY exactly. A typo here is a
#     keybind that runs a command that exits non-zero into nobody's terminal.
#
#  3. The qmldir line, and there are two qmldirs. IpcManager.qml lives in
#     src/state/ and imports `"../"` — the src/ module, which resolves through
#     src/qmldir, NOT src/services/qmldir. A singleton missing from src/qmldir
#     is `PushToTalkService is not a type` at runtime, and no static gate and no
#     headless test would show it. It must also be in EXACTLY one qmldir: a
#     singleton declared in two modules is instantiated twice, one per module
#     (the reason src/qmldir already says so about AgentHelp), and two
#     push-to-talk services would disagree about whether the microphone is
#     currently open. For a microphone that is not a cosmetic disagreement.
#
#  4. The privacy contract. AgentHelpContent.qml:159 tells the user a sandboxed
#     session has "No camera and no microphone", and check-agent-help.sh asserts
#     on that document. ROADMAP.md §8.2 adds "no permanent microphone access to
#     all agents" as a requirement the 3-line yaml omits. So the recorder stays
#     shell-side and only TEXT crosses to a session: nothing under
#     src/services/agents/ may name a recorder or an audio API at all. Unlike
#     check-agent-center-invariants' mention-vs-use rule, a MENTION fails here
#     — the agent-facing code has no legitimate reason to name a microphone,
#     and "it was only in a comment" is how the first line of real code gets
#     written.
#
#  ── Matched against the CODE, never the prose ───────────────────────────────
#  Same rule as check-idle-inhibit.sh: every string checked below also appears
#  in the comment block above, so a whole-file grep would stay green after the
#  code was deleted. The `_defaults` entry is read by EVALUATING the real object
#  literal out of the real file with comment lines stripped, and the generator
#  arms are matched against their files with comments stripped too.
#
#  ── pipefail ────────────────────────────────────────────────────────────────
#  No `producer | grep -q` anywhere in this file, deliberately. Measured on this
#  machine: against a producer over the 64 KB pipe buffer, `grep -q` exits at
#  the first match, the producer takes SIGPIPE, and `pipefail` hands 141 to the
#  caller — 200/200 runs on a 183 KB input, 0/200 at 25 KB. It is not a flake,
#  it is size-dependent and then certain, and test inputs only grow. Every grep
#  here reads `< <(producer)` or `<<<"$var"`, both 0/200.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

keybinds="$root/src/services/config_tab/KeybindService.qml"
ipc="$root/src/state/IpcManager.qml"
srcqmldir="$root/src/qmldir"
svcqmldir="$root/src/services/qmldir"
reducer="$root/src/services/pushtotalk.js"
service="$root/src/services/PushToTalkService.qml"
agentsdir="$root/src/services/agents"

# The action id, in one place. Everything else is checked against THIS.
action="voice-ptt"
want_mods="SUPER + ALT"
want_key="V"

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
want() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

# ── The files exist ──────────────────────────────────────────────────────────
for f in "$keybinds" "$ipc" "$srcqmldir" "$svcqmldir" "$reducer" "$service"; do
    want "${f#"$root"/} exists and is non-empty" test -s "$f"
done

# ─────────────────────────────────────────────────────────────────────────────
#  1. The keybind entry, read as DATA and not as a line of text
# ─────────────────────────────────────────────────────────────────────────────
# The `_defaults` object literal is plain JavaScript, so it is extracted and
# evaluated rather than grepped. That buys two things a grep cannot: the
# ABSENCE of a `type` field is checkable (a negative grep on a line is fooled by
# reformatting), and every combo in the table can be compared against every
# other, which is what `_comboMap` does in the live shell and nothing does here.
#
# `root._shellDir` appears in two of the commands, so it is stubbed. The stub is
# never asserted on; it only has to make the literal evaluate.
defaults_js() {
    awk '/readonly property var _defaults: \(\{/ {inb=1; next}
         inb && /^[[:space:]]*\}\)[[:space:]]*$/ {exit}
         inb {print}' "$keybinds" \
        | grep -vE '^[[:space:]]*//'
}

report="$(defaults_js | node -e '
var root = { _shellDir: "/stub/shell-dir" };
var src = require("fs").readFileSync(0, "utf8");
var D;
try { D = eval("({" + src + "})"); }
catch (e) { console.log("PARSE-FAILED " + e.message); process.exit(0); }
console.log("PARSE-OK");

var action = process.argv[1];
var ks = Object.keys(D);
console.log("COUNT " + ks.length);

var e = D[action];
console.log("ENTRY " + (e ? "present" : "absent"));
if (e) {
    console.log("MODS " + JSON.stringify(e.mods === undefined ? null : e.mods));
    console.log("KEY " + JSON.stringify(e.key === undefined ? null : e.key));
    console.log("LABEL " + JSON.stringify(e.label === undefined ? null : e.label));
    console.log("GROUP " + JSON.stringify(e.group === undefined ? null : e.group));
    // The three fields that would route it away from the shell IPC arm.
    console.log("FIELD-type " + ("type" in e ? "present" : "absent"));
    console.log("FIELD-command " + ("command" in e ? "present" : "absent"));
    console.log("FIELD-dispatcher " + ("dispatcher" in e ? "present" : "absent"));
}

// Every combo against every other. A duplicate is two compositor binds racing
// for one key, and which one wins depends on generator ordering.
var seen = {}, dupes = [];
for (var i = 0; i < ks.length; i++) {
    var b = D[ks[i]];
    if (!b || !b.key) continue;
    var combo = (b.mods || "") + " | " + b.key;
    if (seen[combo] !== undefined) dupes.push(combo + " (" + seen[combo] + " and " + ks[i] + ")");
    seen[combo] = ks[i];
}
console.log("DUPES " + (dupes.length ? dupes.join("; ") : "none"));
' -- "$action")"

want "the _defaults object literal still parses as JavaScript" \
    grep -qx "PARSE-OK" <<<"$report"

want "_defaults has a \"$action\" entry" \
    grep -qx "ENTRY present" <<<"$report"

want "$action is bound to $want_mods + $want_key" \
    bash -c '[ "$(grep -m1 "^MODS " <<<"$1" | cut -d" " -f2-)" = "\"$2\"" ] \
          && [ "$(grep -m1 "^KEY " <<<"$1" | cut -d" " -f2-)" = "\"$3\"" ]' \
    -- "$report" "$want_mods" "$want_key"

want "$action has a label and a group, so it appears on the Keybinds page" \
    bash -c 'grep -qE "^LABEL \"..+\"$" <<<"$1" && grep -qE "^GROUP \"..+\"$" <<<"$1"' \
    -- "$report"

# The load-bearing negative. See point 1 in the header.
want "$action carries NO type field, so labwc's allowlist can translate it" \
    grep -qx "FIELD-type absent" <<<"$report"
want "$action carries no command field (\$qsIpc is not substituted on labwc)" \
    grep -qx "FIELD-command absent" <<<"$report"
want "$action carries no dispatcher field (it is not a compositor action)" \
    grep -qx "FIELD-dispatcher absent" <<<"$report"

want "no two _defaults entries claim the same combo" \
    grep -qx "DUPES none" <<<"$report"

# ─────────────────────────────────────────────────────────────────────────────
#  2. The generator arms that make "no type" mean "shell IPC toggle"
# ─────────────────────────────────────────────────────────────────────────────
# Asserting the entry has no `type` is only meaningful while the untyped arm of
# each generator still emits an ipc call. Delete either arm and the entry
# becomes a bind to nothing, with the _defaults check still green.
#
# Both arms are matched in two halves, because both are written across two
# source lines: the expression that says "an ipc call", and the interpolation
# that says WHICH action. Half of each is what a plausible mistake leaves
# behind — an arm that calls `ipc call` on a hardcoded id, or one that
# interpolates the id into something that is no longer an ipc call.
keybind_code() { grep -vE '^[[:space:]]*//' "$keybinds"; }

lua_call='exec_cmd(\"qs -p \" .. shell .. \" ipc call "'
lua_key='+ e.k + " toggle\")"'
kdl_call='"qs" "-p" "'
kdl_key='" "ipc" "call" "'\'' + _kdlStr(e.k) + '\''" "toggle";'

want "_genLua's untyped arm still builds a qs ipc call" \
    grep -qF "$lua_call" < <(keybind_code)
want "_genLua's untyped arm still interpolates the action id it toggles" \
    grep -qF "$lua_key" < <(keybind_code)

want "_genKdl's untyped arm still spawns qs" \
    grep -qF "$kdl_call" < <(keybind_code)
want "_genKdl's untyped arm still spawns ipc call <action> toggle" \
    grep -qF "$kdl_key" < <(keybind_code)

want "_applyLabwc still hands the model to apex-labwc-keybinds" \
    grep -qF 'apex-labwc-keybinds' < <(keybind_code)

# ─────────────────────────────────────────────────────────────────────────────
#  3. The IPC handler
# ─────────────────────────────────────────────────────────────────────────────
# Read as the handler BLOCK, not the whole file: `grep -q voice-ptt` over
# IpcManager.qml would pass on a comment mentioning it, and the handler's own
# comment does mention it.
handler_code() {
    awk -v t="target: \"$action\"" '
        index($0, t) {inb=1}
        inb {
            print
            if (/^[[:space:]]*\}[[:space:]]*$/) exit
        }' "$ipc" \
        | grep -vE '^[[:space:]]*//'
}
hcode="$(handler_code)"

want "IpcManager.qml has an IpcHandler with target: \"$action\"" \
    test -n "$hcode"

want "that handler exposes a toggle() function, which is what the bind calls" \
    grep -qE '^[[:space:]]*function toggle\(' <<<"$hcode"

want "the handler's toggle() reaches PushToTalkService rather than stubbing" \
    grep -qF 'PushToTalkService' <<<"$hcode"

# The bind and the handler are two halves of one string. This is the check that
# a rename cannot half-apply.
want "the IpcHandler target string is exactly the _defaults key" \
    grep -qF "target: \"$action\"" < <(grep -vE '^[[:space:]]*//' "$ipc")

# ─────────────────────────────────────────────────────────────────────────────
#  4. The qmldir line, in exactly one qmldir, and the right one
# ─────────────────────────────────────────────────────────────────────────────
qmldir_decls() { grep -vE '^[[:space:]]*#' "$1" | grep -E '(^|[[:space:]])PushToTalkService([[:space:]]|$)'; }

want "src/qmldir declares PushToTalkService as a singleton (IpcManager imports \"../\")" \
    grep -qE '^singleton[[:space:]]+PushToTalkService[[:space:]]' < <(qmldir_decls "$srcqmldir")

want "src/services/qmldir does NOT also declare it (one module, one instance)" \
    bash -c '[ -z "$(grep -vE "^[[:space:]]*#" "$1" | grep -E "(^|[[:space:]])PushToTalkService([[:space:]]|$)")" ]' \
    -- "$svcqmldir"

want "src/qmldir points at the file that exists" \
    bash -c 'p="$(grep -E "^singleton[[:space:]]+PushToTalkService[[:space:]]" "$1" | awk "{print \$NF}")"; \
             [ -n "$p" ] && [ -s "$2/$p" ]' \
    -- "$srcqmldir" "$root/src"

# ─────────────────────────────────────────────────────────────────────────────
#  5. The decision layer is USED, not re-implemented
# ─────────────────────────────────────────────────────────────────────────────
# A QML copy of the state machine would pass the node suite (which drives the
# .js file) while shipping different behaviour. So the service must import the
# reducer, and must not carry its own copy of the cap.
service_code() { grep -vE '^[[:space:]]*//' "$service"; }

want "PushToTalkService imports pushtotalk.js" \
    grep -qE '^import[[:space:]]+"pushtotalk\.js"[[:space:]]+as[[:space:]]' < <(service_code)

want "PushToTalkService calls the reducer's reduce(), not its own switch" \
    grep -qE '\.reduce\(' < <(service_code)

want "PushToTalkService does not carry a second copy of the 90 s cap" \
    bash -c '! grep -qE "\b90000\b" < <(grep -vE "^[[:space:]]*//" "$1")' -- "$service"

want "the cap lives in the reducer, where the node suite can drive it" \
    grep -qE '^var MAX_MS = [0-9]+;' < <(grep -vE '^[[:space:]]*//' "$reducer")

# The recorder runs exactly when the reducer says the microphone is open. A
# `running: true` here is a hot microphone, and nothing else in the tree would
# say so.
recorder_code() {
    awk '/property var _recorder: Process \{/ {inb=1}
         inb {
             print
             if (/^[[:space:]]*\}[[:space:]]*$/) exit
         }' "$service" \
        | grep -vE '^[[:space:]]*//'
}
rcode="$(recorder_code)"

want "PushToTalkService has a _recorder Process block" \
    test -n "$rcode"

want "the recorder's running: is bound to the reducer's micOpen, not to true" \
    grep -qE '^[[:space:]]*running:[[:space:]]+root\.micOpen[[:space:]]*$' <<<"$rcode"

# ─────────────────────────────────────────────────────────────────────────────
#  6. No agent ever gets the microphone
# ─────────────────────────────────────────────────────────────────────────────
# §8.2's fourth requirement, and the one the yaml omits. A mention fails here on
# purpose — see point 4 in the header.
mic_names='parecord|arecord|pw-record|pw-cat|wpctl[[:space:]]|Quickshell\.Services\.Pipewire|[Pp]ipe[Ww]ire|defaultAudioSource|AudioSource'

agents_mic_hits() {
    grep -rInE "$mic_names" "$agentsdir" 2>/dev/null || true
}
hits="$(agents_mic_hits)"

want "nothing under src/services/agents/ names a recorder or an audio source" \
    test -z "$hits"
[ -n "$hits" ] && sed 's/^/          /' <<<"$hits"

# The recorder that DOES exist is shell-side, and this is where it lives.
want "the recorder is in PushToTalkService, outside src/services/agents/" \
    grep -qE 'parecord|arecord|wpctl' < <(service_code)

# ─────────────────────────────────────────────────────────────────────────────
#  7. The indicator is on screen, and it names the target
# ─────────────────────────────────────────────────────────────────────────────
# "Microphone indicator visible" is an acceptance criterion and
# PushToTalkService.indicatorLabel satisfies it only if something renders it.
# A service property nothing reads is the same failure as a reducer nothing
# calls, one layer up.
#
# The carousel in CenterContent.qml is where the screen recorder's indicator
# lives, so it is where this one lives too. Three things are checked and each
# one can break without the other two: the item is PUSHED into the list, the
# delegate RENDERS the reducer's label, and an open microphone OVERRIDES
# whatever the user last scrolled to.
notch="$root/src/modules/Center/CenterContent.qml"
notch_code() { grep -vE '^[[:space:]]*//' "$notch"; }

want "src/modules/Center/CenterContent.qml exists and is non-empty" test -s "$notch"

want "the notch carousel gains an item while push-to-talk is not idle" \
    grep -qE 'PushToTalkService\.indicatorLabel !== ""\) list\.push\("voice"\)' \
    < <(notch_code)

want "the indicator renders the reducer's label, not its own phase table" \
    grep -qE '^[[:space:]]*text:[[:space:]]+PushToTalkService\.indicatorLabel[[:space:]]*$' \
    < <(notch_code)

# The label already contains "Listening → <session>", so rendering it IS the
# explicit-target half. What must not happen is a delegate that shows a phase
# and drops the name.
want "nothing in the notch rebuilds a phase string of its own" \
    bash -c '! grep -qE "\"(Listening|Transcribing|Sending)" < <(grep -vE "^[[:space:]]*//" "$1")' \
    -- "$notch"

want "an open microphone force-scrolls the carousel to itself" \
    bash -c 'grep -qE "PushToTalkService\.micOpen\) root\._forceScrollTo\(\"voice\"\)" < <(grep -vE "^[[:space:]]*//" "$1") \
          && grep -qE "autoScrollType === \"voice\"" < <(grep -vE "^[[:space:]]*//" "$1")' \
    -- "$notch"

want "the tally light pulses on micOpen rather than on a constant" \
    grep -qE '^[[:space:]]*running: PushToTalkService\.micOpen[[:space:]]*$' < <(notch_code)

# ─────────────────────────────────────────────────────────────────────────────
#  8. A refusal is allowed to go away, and only a refusal
# ─────────────────────────────────────────────────────────────────────────────
# "error" is the only phase that does not end by itself, and an unset
# speech-to-text hook is the normal state of a fresh install — so one press
# would pin that message into the top bar permanently. The service dismisses it
# on a timer. The DANGEROUS version of that timer is one that can fire on any
# other phase: it would drop a live microphone or discard words already spoken.
# The reducer refuses a dismiss anywhere but "error", which is what makes the
# timer's condition non-load-bearing, and that guard is asserted here.
want "the reducer only accepts a dismiss from the error phase" \
    grep -qE 'if \(st\.phase !== "error"\) return st;' < <(grep -vE '^[[:space:]]*//' "$reducer")

# The `< <(...)` here is not decoration. The header above says this file has no
# `producer | grep -q` in it; the first draft of this assertion had one, hidden
# inside a `bash -c` string. That form is measured SAFE from a pipefail parent
# (a child bash does not inherit pipefail, because SHELLOPTS is not exported:
# 0/200 on a 915 KB input, against 200/200 for the same pipeline in-shell), so
# it was not a live failure. It was worse than one: a counter-example sitting in
# the file that documents the rule, which is how the rule gets un-learned.
timer_block() {
    awk '/property var _errorTimer: Timer \{/ {inb=1}
         inb {print; if (/^[[:space:]]*\}[[:space:]]*$/) exit}' "$service" \
        | grep -vE '^[[:space:]]*//'
}
want "the service's dismiss timer runs only while the phase is error" \
    grep -qE '^[[:space:]]*running: root\.phase === "error"[[:space:]]*$' \
    < <(timer_block)

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
