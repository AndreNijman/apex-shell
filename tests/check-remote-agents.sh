#!/usr/bin/env bash
# Static invariants for §20's remote agent status (P2 phase 9.3).
#
# ── Why this exists next to the smoke test ───────────────────────────────────
# run-remote-agent-smoke.sh needs a Wayland session and an apex-os checkout and
# skips without either, so on a CI runner it proves nothing. Everything here is
# grep-able and runs headless, which matters: these invariants are each one
# careless edit away from regressing with no visible symptom. An ungated sweep
# timer spends battery and somebody else's bandwidth silently; a remote row
# that grows a Stop button kills a LOCAL agent and logs nothing.
#
# ── THREE WAYS A GREP-STYLE CHECK LIES, AND WHAT IS DONE ABOUT EACH ──────────
#
# 1. A COMMENT SATISFIES IT. This repo has shipped four checks in one day that
#    were satisfied by the prose in the very file they guarded. Every check
#    below therefore runs against comment-stripped input.
#
# 2. ANOTHER LINE OF REAL CODE SATISFIES IT. The subtler version, and the one
#    comment-stripping does nothing about: `root._queryProc.running = false`
#    appears in three different functions here, so a check that only asks
#    whether the file contains it would still pass after the kill was deleted
#    from the one function that needed it. Checks that care about WHERE a line
#    is are scoped to a function or block body by `fn_body` / `blk_body`, not
#    run against the whole file.
#
# 3. THE MUTANT NEVER APPLIED. A self-test that mutates a copy and watches it
#    go red proves nothing if the sed silently matched nothing — the copy is
#    then identical and the red (or green) is about the original. Every mutant
#    below is diffed against its source and the run aborts if it did not
#    actually change.
#
# The self-test at the bottom also records HOW MANY checks each mutant broke.
# A targeted mutant should break one or two; a mutant that breaks fifteen has
# damaged the copy rather than the invariant, which is a different failure and
# must not be read as success.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"

pass=0
fail=0
quiet=0
ok()  { [ "$quiet" -eq 1 ] || echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { [ "$quiet" -eq 1 ] || echo "  FAIL  $1"; fail=$((fail + 1)); }
# Deliberately not `cmd; check $?`: ShellCheck SC2319 is right that a $? read
# after a `[ ]` is a trap waiting for someone to insert a line between them.
# Same convention as check-compositor-backends.sh.
want() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

# ── comment-stripped views ───────────────────────────────────────────────────
# Whole-line comments only. A trailing comment on a real line of code is fine:
# the code is still there, which is what these checks ask about.
code()       { grep -vE '^[[:space:]]*//' "$1" 2>/dev/null; }
qmldircode() { grep -vE '^[[:space:]]*#'  "$1" 2>/dev/null; }

has()   {   code "$1" | grep -qE "$2"; }
lacks() { ! code "$1" | grep -qE "$2"; }

# The qmldir equivalent, and it is a FUNCTION for a reason that cost a real
# assertion here. Written inline as
#
#     want "…" qmldircode "$f" | grep -qE '…'
#
# the pipe binds to the whole `want` invocation, not to its arguments: `want`
# runs only `qmldircode`, which succeeds because the file exists, and greps the
# verdict into a pipe nobody reads. Two registration checks passed
# unconditionally that way, and it was the mutant harness's broken-count — an
# expected-red mutant coming out green with 0 broken — that found it, not
# review. Every check in this file goes through a helper for that reason.
qmldir_has() { qmldircode "$1" | grep -qE "$2"; }

# fn_body <file> <ERE matching the opening line> — that declaration's body,
# ending at the first closing brace indented the same as the opening line.
# Comment lines are stripped on the way out.
#
# This is what makes a "the kill happens in _standDown" check mean that,
# rather than "the string appears somewhere in the file".
fn_body() {
    # The pattern goes through the ENVIRONMENT, not -v. awk processes backslash
    # escapes in a -v assignment, so `function _beginSweep\(force\)` arrived as
    # `function _beginSweep(force)` — a regex with a GROUP round `force`, which
    # matches nothing. It cost three silently-failing checks, and the mutant
    # harness's broken-count is what pointed at it rather than at the code.
    FN_PAT="$2" awk '
        !inside && $0 ~ ENVIRON["FN_PAT"] { inside = 1; indent = match($0, /[^ ]/); print; next }
        inside {
            print
            if ($0 ~ /^[ ]*\}/ && match($0, /[^ ]/) == indent) exit
        }
    ' "$1" 2>/dev/null | grep -vE '^[[:space:]]*//'
}

# in_fn <file> <opening-line ERE> <ERE> — true when the body contains it.
in_fn() { fn_body "$1" "$2" | grep -qE "$3"; }

# Keys of a JS/QML object literal, comments excluded, sorted.
obj_keys() {
    sed -n "/$2/,/^\(}\|    })\)/p" "$1" 2>/dev/null \
        | grep -vE '^[[:space:]]*//' \
        | grep -oE '^[[:space:]]+[a-z_]+:' \
        | tr -d ' :' \
        | sort -u
}

check_tree() {
    local r="$1"
    local js="$r/src/services/remoteagents.js"
    local svc="$r/src/services/RemoteAgentService.qml"
    local hrow="$r/src/services/agents/RemoteHostRow.qml"
    local srow="$r/src/services/agents/RemoteSessionRow.qml"
    local centre="$r/src/services/agents/AgentCenter.qml"
    local qmldir="$r/src/services/qmldir"

    # ── the parts exist ──────────────────────────────────────────────────────
    # First and unconditionally. Every check below is a grep, and a grep
    # against a file that is not there finds nothing — which every `lacks`
    # check would happily read as a pass.
    for f in "$js" "$svc" "$hrow" "$srow" "$centre" "$qmldir"; do
        want "$(basename "$f") exists and is non-empty" test -s "$f"
    done

    # ── reachable from the Agent Center ──────────────────────────────────────
    # AgentCenter is loaded THROUGH src/services/qmldir, so its own directory
    # is not on the import path and implicit sibling resolution does not apply.
    # A dropped entry is "RemoteHostRow is not a type" at load, which takes the
    # whole shell down rather than just the page.
    want "RemoteAgentService is registered as a singleton" \
        qmldir_has "$qmldir" '^singleton RemoteAgentService .*RemoteAgentService\.qml$'
    for t in RemoteHostRow RemoteSessionRow; do
        want "$t is registered in src/services/qmldir" \
            qmldir_has "$qmldir" "^${t} agents/${t}\.qml$"
    done

    # ── the refcount convention ──────────────────────────────────────────────
    want "the service exposes refCount, so ServiceRef can hold it" \
        has "$svc" '^[[:space:]]*property int refCount:'
    want "the Agent Center holds a ServiceRef on it" \
        has "$centre" 'ServiceRef \{ service: RemoteAgentService'

    # ── IDLE MUST BE ZERO SSH CONNECTIONS ────────────────────────────────────
    # Not "slower at idle" — zero. Every query is a connection to somebody
    # else's machine, so unlike AgentService there is no slow tier here.
    #
    # Anchored to a property assignment at the start of a line, the way ci.yml
    # anchors its `layer.enabled` check, so prose about a timer cannot pass for
    # one.
    want "no timer in the service is force-started" \
        lacks "$svc" '^[[:space:]]*running:[[:space:]]*true[[:space:]]*$'

    # Scoped to the function, not the file: `_cooldown.restart()` also appears
    # in _beginSweep's guard path, so a file-wide grep would survive the guard
    # being deleted from here.
    want "the sweep is re-armed only while a ref is held" \
        in_fn "$svc" 'function _sweepDone\(\)' \
              '^[[:space:]]*if \(root\.refCount > 0\) root\._cooldown\.restart\(\)'
    want "the last ref being handed back stands the service down" \
        in_fn "$svc" 'onRefCountChanged:' 'root\._standDown\(\)'

    # `root._queryProc.running = false` appears in _next and in the watchdog as
    # well, so this MUST be scoped or it proves nothing about standing down.
    want "standing down kills the query in flight rather than letting it finish" \
        in_fn "$svc" 'function _standDown\(\)' '^[[:space:]]*root\._queryProc\.running = false'
    want "standing down also stops the cooldown, the step and the watchdog" \
        test "$(fn_body "$svc" 'function _standDown\(\)' \
                 | grep -cE '_(cooldown|advance|watchdog)\.stop\(\)')" -eq 3
    want "standing down forgets the rest of the queue" \
        in_fn "$svc" 'function _standDown\(\)' '^[[:space:]]*root\._queue = \[\]'
    # An abandoned host must go back to "not checked", not be recorded as
    # unreachable: we stopped asking, we did not learn anything about it.
    want "an abandoned host is not slandered as unreachable" \
        in_fn "$svc" 'function _standDown\(\)' 'Remote\.STATUS\.UNKNOWN'

    # ── refcount churn must not become one connection per toggle ─────────────
    want "a sweep is clamped on the age of the last one" \
        in_fn "$svc" 'function _beginSweep\(force\)' \
              'root\._lastSweepStart\) < root\.minSweepGap'
    want "the clamp is skipped only when the caller forces it" \
        in_fn "$svc" 'function _beginSweep\(force\)' 'if \(!force &&'
    want "only an explicit refresh forces a sweep" \
        has "$svc" '^[[:space:]]*function refresh\(\) \{ root\._beginSweep\(true\) \}'
    # All THREE clauses. `_pending` is "" for 60 ms between hosts, so a guard
    # that only tests the two slots reads "idle" mid-sweep — and a forced
    # refresh landing there delivered one host's exit code to another host's
    # slot. Spelled out as one regex so dropping any clause goes red.
    want "an in-flight sweep is recognised for its whole duration" \
        in_fn "$svc" 'function _beginSweep\(force\)' \
              'root\._listPending \|\| root\._pending !== "" \|\| root\._advance\.running'
    want "the busy flag does not blink off between hosts either" \
        has "$svc" '^[[:space:]]*\|\| root\._advance\.running$'

    # ── a hung host must not wedge the sweep ─────────────────────────────────
    # ConnectTimeout=8 bounds getting there and nothing bounds what happens
    # after, so a host that completes TCP and then stalls would leave the queue
    # stopped forever — not degraded, dead for the session.
    want "a per-query watchdog exists" \
        in_fn "$svc" 'property Timer _watchdog:' '^[[:space:]]*interval: root\.queryTimeout'
    want "the watchdog advances the queue rather than only reporting" \
        in_fn "$svc" 'property Timer _watchdog:' 'root\._advance\.restart\(\)'
    # Ordering, not mere presence: the slot has to be cleared BEFORE the kill,
    # or the SIGTERM's own exited() is delivered to the next host.
    want "the watchdog clears the slot before it kills" \
        test "$(fn_body "$svc" 'property Timer _watchdog:' \
                 | grep -nE 'root\._pending = ""' | cut -d: -f1 | head -1)" \
             -lt "$(fn_body "$svc" 'property Timer _watchdog:' \
                 | grep -nE 'root\._queryProc\.running = false' | cut -d: -f1 | head -1)"
    # Measured, not assumed: a binary that cannot exec emits neither exited nor
    # streamFinished, only runningChanged. Without this the first sweep would
    # hang forever on a machine with no `apex`.
    want "a binary that never starts is caught by a settle timer" \
        in_fn "$svc" 'property Timer _listSettle:' \
              'if \(root\._listPending\) root\._onRegistry\(false, ""\)'
    want "the settle timer is armed from runningChanged" \
        in_fn "$svc" 'property Process _listProc:' \
              'onRunningChanged: if \(!running\) root\._listSettle\.restart\(\)'

    # ── the CLI owns the ssh argv ────────────────────────────────────────────
    # `apex host run <name> -- <argv…>` passes the remote arguments with their
    # boundaries intact, which plain `ssh host cmd a b` does not: ssh joins them
    # with spaces and hands the string to the remote shell. Assembling that
    # here is also where an injection would land.
    want "the query goes through apex host run" \
        in_fn "$svc" 'function _next\(\)' '"apex", "host", "run", name,'
    want "the remote argv is separated by --" \
        in_fn "$svc" 'function _next\(\)' '"--", "apex", "agent", "list", "--all", "--json"'
    want "the service never builds a shell command line" \
        lacks "$svc" '"(ba)?sh", *"-c"'
    # The host name is passed as its own argv element and never concatenated
    # into anything. `+ name` would be the shape of that mistake.
    want "a host name is never spliced into a string" \
        lacks "$svc" '(command|_proc\.command) *= *\[?"[^"]*" *\+'

    # ── do not invent capability ─────────────────────────────────────────────
    # A device is queried only when a probe has SHOWN the runtime is installed.
    # caps === null is "we do not know", which is neither "yes" nor "no".
    want "only a demonstrated runtime is queried" \
        in_fn "$js" '^function queryTargets' 'hosts\[i\]\.agentd === true'
    want "an unprobed host is not treated as having no runtime" \
        in_fn "$js" '^function restingStatus' 'host\.probed !== true.*STATUS\.NOT_PROBED'
    want "a host with a runtime rests at unknown, not at unreachable" \
        in_fn "$js" '^function restingStatus' '^[[:space:]]*return STATUS\.UNKNOWN$'
    want "a boolean cap is read with === true, never for truthiness" \
        in_fn "$js" '^function normalizeCaps' '^[[:space:]]*out\[k\] = v === true$'
    want "caps null stays null rather than becoming an all-false record" \
        in_fn "$js" '^function normalizeCaps' '^[[:space:]]*return null$'
    want "the registry is read as an object, and an array is refused by name" \
        in_fn "$js" '^function parseHostList' 'reason: "array-not-object"'

    # ── every table key is explicit ──────────────────────────────────────────
    # A missing key yields `undefined`, which is truthy-adjacent in enough
    # checks that CompositorService carries its own comment about it. Both of
    # these compare EXTRACTED KEY SETS, so prose naming a key can neither
    # satisfy them nor break them.
    local labels icons capkeys
    labels="$(obj_keys "$js" 'var STATUS_LABELS = {')"
    icons="$(obj_keys "$svc" 'readonly property var statusIcons: ({')"
    if [ -n "$labels" ] && [ "$labels" = "$icons" ]; then
        ok "every status has both a label and an icon"
    else
        bad "the status label and icon tables disagree"
        [ "$quiet" -eq 1 ] || diff <(echo "$labels") <(echo "$icons") | sed 's/^/        /'
    fi

    capkeys="$(obj_keys "$js" 'var CAPS_SCHEMA = {')"
    want "the caps schema declares every HostCaps field apex host list prints" \
        test "$(echo "$capkeys" | tr '\n' ' ')" = \
             "accel agentd ai apex_version cpus free_mib gpus memory_mib os podman probed_at variant "

    # ── A REMOTE ROW MUST NOT ACT ────────────────────────────────────────────
    # The concrete defect this design avoids, so it gets a check and not just a
    # comment. A session id is issued by the runtime that owns it, so `#3` on
    # the desktop and `#3` here are different agents — and AgentService talks
    # to the LOCAL daemon. Reusing SessionRow would have made Stop kill an
    # unrelated local agent, with nothing logged.
    want "a remote session row calls no AgentService verb that takes an id" \
        lacks "$srow" 'AgentService\.(focusTerminal|reviewRequest|pause|resume|kill|refresh|_act)\('
    want "a remote session row has no interactive element at all" \
        lacks "$srow" '(MouseArea|TapHandler|SmallIconButton|Button)[[:space:]]*\{'
    want "a remote host row has no interactive element either" \
        lacks "$hrow" '(MouseArea|TapHandler|SmallIconButton|Button)[[:space:]]*\{'
    # The section's one control is a Refresh, and it must ask the service —
    # not reach into the queue or the Process itself.
    want "the only remote control on the page is a refresh" \
        test "$(fn_body "$centre" '// ── 4\. Remote devices' \
                 | grep -cE 'onActivated:')" -le 1

    # ── conditional appearance, at the level where it is free ────────────────
    # There is no bar indicator: knowing whether there is anything to show
    # costs an ssh, so an indicator that "appears when there is something to
    # show" would have to poll at idle. Registration IS free — a local file
    # read — so the section exists only when a device is registered.
    want "the remote section exists only when a device is registered" \
        has "$centre" '_hasRemote: RemoteAgentService\.hosts\.length > 0'
    want "no bar module or window reaches for the remote service" \
        test -z "$(grep -rl 'RemoteAgentService' "$r/src/modules" "$r/src/windows" 2>/dev/null)"

    # ── the delegate-recreation trap ─────────────────────────────────────────
    # `model: <JS array>` recreates every delegate whenever the array's
    # contents change — measured in this repo on Qt 6.10.3: created=6,
    # destroyed=3 after one content change on a 3-element model, which silently
    # stopped the workspace strip's Behaviours. A sweep rewrites these arrays
    # every fifteen seconds, so an array model would restart every animation on
    # every poll.
    want "the host list uses an integer count model" \
        has "$centre" '^[[:space:]]*model: RemoteAgentService\.hosts\.length$'
    want "a host's session list uses an integer count model" \
        has "$hrow" '^[[:space:]]*model: hrow\.sessionCount$'
}

# ─────────────────────────────────────────────────────────────────────────────
#  The real tree
# ─────────────────────────────────────────────────────────────────────────────
echo "── invariants ──"
check_tree "$repo"
real_fail=$fail
real_pass=$pass
echo
echo "passed=$real_pass failed=$real_fail"

# ─────────────────────────────────────────────────────────────────────────────
#  Self-test: do these checks have teeth, and can prose turn them red?
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "── self-test: mutants ──"

MUT="$(mktemp -d)"
trap 'rm -rf "$MUT"' EXIT INT TERM

FILES=(
    src/services/remoteagents.js
    src/services/RemoteAgentService.qml
    src/services/qmldir
    src/services/agents/RemoteHostRow.qml
    src/services/agents/RemoteSessionRow.qml
    src/services/agents/AgentCenter.qml
)

fresh_copy() {
    local dst="$1"
    rm -rf "$dst"
    mkdir -p "$dst/src/services/agents" "$dst/src/modules" "$dst/src/windows"
    local f
    for f in "${FILES[@]}"; do cp "$repo/$f" "$dst/$f"; done
}

# THE GUARD THE WHOLE SELF-TEST RESTS ON.
#
# A sed that matched nothing leaves the copy byte-identical, and then the
# verdict — red or green — is about the ORIGINAL file and means nothing. Every
# mutant is diffed against its source, and a mutant that did not apply is a
# hard failure of this script rather than a quiet pass.
mutated=0
unmutated=0
assert_changed() {
    local dst="$1" rel="$2"
    if cmp -s "$repo/$rel" "$dst/$rel"; then
        echo "  FAIL  the mutant did not apply — $rel is unchanged"
        unmutated=$((unmutated + 1))
        return 1
    fi
    mutated=$((mutated + 1))
    return 0
}

# verdict <dir> — echoes "green 0" or "red <n>", from a quiet run of the same
# checks. The count is what distinguishes "this mutant broke the invariant"
# from "this mutant broke the copy".
verdict() {
    local saved_pass=$pass saved_fail=$fail saved_quiet=$quiet
    pass=0; fail=0; quiet=1
    check_tree "$1"
    local n=$fail
    pass=$saved_pass; fail=$saved_fail; quiet=$saved_quiet
    if [ "$n" -eq 0 ]; then echo "green 0"; else echo "red $n"; fi
}

selfpass=0
selffail=0

# expect <desc> <dir> <green|red> [max-broken]
#
# For a red mutant, max-broken bounds how many checks it may break. A targeted
# mutant breaks one or two; one that breaks fifteen has damaged the copy, which
# is a different outcome and must not read as success.
expect() {
    local desc="$1" dir="$2" wanted="$3" maxbroken="${4:-3}"
    local got n
    read -r got n <<<"$(verdict "$dir")"
    if [ "$got" != "$wanted" ]; then
        echo "  FAIL  $desc (wanted $wanted, got $got with $n broken)"
        selffail=$((selffail + 1))
        return
    fi
    if [ "$wanted" = "red" ] && [ "$n" -gt "$maxbroken" ]; then
        echo "  FAIL  $desc (red, but broke $n checks — the copy is damaged, not the invariant)"
        selffail=$((selffail + 1))
        return
    fi
    if [ "$got" = "red" ]; then
        echo "  PASS  $desc (=> red, $n check(s) broken)"
    else
        echo "  PASS  $desc (=> green)"
    fi
    selfpass=$((selfpass + 1))
}

# ── 0. the baseline ──────────────────────────────────────────────────────────
# Without this, a mutant that came out red because the copy was EMPTY would
# look like a working check, and the comment mutant's green would mean nothing.
fresh_copy "$MUT/base"
expect "an unmutated copy is green" "$MUT/base" green

# ── forward mutants: each a regression somebody could plausibly write ────────
fresh_copy "$MUT/m1"
sed -i 's|^\( *\)interval: root.sweepInterval$|\1interval: root.sweepInterval\n\1running: true|' \
    "$MUT/m1/src/services/RemoteAgentService.qml"
assert_changed "$MUT/m1" src/services/RemoteAgentService.qml \
    && expect "an always-running sweep timer is caught" "$MUT/m1" red

fresh_copy "$MUT/m2"
sed -i 's|if (root.refCount > 0) root._cooldown.restart()|root._cooldown.restart()|' \
    "$MUT/m2/src/services/RemoteAgentService.qml"
assert_changed "$MUT/m2" src/services/RemoteAgentService.qml \
    && expect "re-arming the sweep without a ref is caught" "$MUT/m2" red

# The mutant that motivates the whole scoping exercise. The kill is deleted
# from _standDown only — the identical line still exists in _next and in the
# watchdog, so a file-wide grep would still find it and pass.
fresh_copy "$MUT/m3"
python3 - "$MUT/m3/src/services/RemoteAgentService.qml" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
i = s.index("function _standDown()")
j = s.index("\n    }", i)
body = s[i:j]
open(p, "w").write(s[:i] + body.replace(
    "            root._queryProc.running = false\n", "") + s[j:])
PY
assert_changed "$MUT/m3" src/services/RemoteAgentService.qml \
    && expect "deleting the kill from _standDown ONLY is still caught" "$MUT/m3" red

# Ordering, not presence: the kill moved above the slot clear. Both lines are
# still there, so only an order-aware check sees it.
fresh_copy "$MUT/m4"
python3 - "$MUT/m4/src/services/RemoteAgentService.qml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """            const name = root._pending
            root._pending = ""          // cleared BEFORE the kill, so the
            root._queryProc.running = false   // resulting exited() is ignored"""
new = """            const name = root._pending
            root._queryProc.running = false
            root._pending = ""
"""
assert old in s, "watchdog anchor not found"
open(p, "w").write(s.replace(old, new))
PY
assert_changed "$MUT/m4" src/services/RemoteAgentService.qml \
    && expect "killing before clearing the slot is caught" "$MUT/m4" red

fresh_copy "$MUT/m5"
sed -i '/^        unreachable: "󰅛",$/d' "$MUT/m5/src/services/RemoteAgentService.qml"
assert_changed "$MUT/m5" src/services/RemoteAgentService.qml \
    && expect "a status with a label but no icon is caught" "$MUT/m5" red

fresh_copy "$MUT/m6"
sed -i 's|^\( *\)required property var session$|\1required property var session\n\1TapHandler { onTapped: AgentService.kill(srow.session.id) }|' \
    "$MUT/m6/src/services/agents/RemoteSessionRow.qml"
assert_changed "$MUT/m6" src/services/agents/RemoteSessionRow.qml \
    && expect "a remote row that acts on a session id is caught" "$MUT/m6" red

fresh_copy "$MUT/m7"
sed -i '/^RemoteHostRow agents\/RemoteHostRow.qml$/d' "$MUT/m7/src/services/qmldir"
assert_changed "$MUT/m7" src/services/qmldir \
    && expect "an unregistered component is caught" "$MUT/m7" red

fresh_copy "$MUT/m8"
sed -i 's|out\[k\] = v === true|out[k] = !!v|' "$MUT/m8/src/services/remoteagents.js"
assert_changed "$MUT/m8" src/services/remoteagents.js \
    && expect "reading a capability for truthiness is caught" "$MUT/m8" red

fresh_copy "$MUT/m9"
sed -i 's|if (hosts\[i\] && hosts\[i\].agentd === true)|if (hosts[i])|' \
    "$MUT/m9/src/services/remoteagents.js"
assert_changed "$MUT/m9" src/services/remoteagents.js \
    && expect "querying a host whose runtime was never demonstrated is caught" "$MUT/m9" red

fresh_copy "$MUT/m10"
sed -i 's|_hasRemote: RemoteAgentService.hosts.length > 0|_hasRemote: true|' \
    "$MUT/m10/src/services/agents/AgentCenter.qml"
assert_changed "$MUT/m10" src/services/agents/AgentCenter.qml \
    && expect "an unconditional remote section is caught" "$MUT/m10" red

# The guard clause with no test behind it until now. Dropping it from
# _beginSweep leaves the identical text in `busy` two dozen lines up, so a
# file-wide grep would still find it — this is the third mutant that only a
# function-scoped check can catch.
fresh_copy "$MUT/m11"
python3 - "$MUT/m11/src/services/RemoteAgentService.qml" <<'M11'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''        if (root._listPending || root._pending !== "" || root._advance.running)
            return'''
new = '''        if (root._listPending || root._pending !== "")
            return'''
assert old in s, "beginSweep guard anchor not found"
open(p, "w").write(s.replace(old, new))
M11
assert_changed "$MUT/m11" src/services/RemoteAgentService.qml \
    && expect "dropping the mid-sweep clause from the guard ONLY is caught" "$MUT/m11" red

# ── the inverse mutant ───────────────────────────────────────────────────────
# Prose that would trip a naive version of every check above, including prose
# that quotes the exact strings the greps look for. It must NOT turn anything
# red: a check a comment can break is a check that punishes people for
# explaining themselves, and this repo has shipped the opposite mistake — a
# check a comment could SATISFY — four times in one day.
fresh_copy "$MUT/c1"
{
    echo '// The first draft had `running: true` on the sweep timer, and'
    echo '//     root._cooldown.restart()'
    echo '// with no refCount guard, so it polled forever. It also did'
    echo '//     command: ["sh", "-c", "ssh " + name + " apex agent list"]'
    echo '// splicing a host name into a shell line, and read caps with'
    echo '//     out[k] = !!v'
    echo '// so a missing key came back truthy. It killed the query AFTER'
    echo '// clearing the slot in the watchdog:'
    echo '//     root._queryProc.running = false'
    echo '//     root._pending = ""'
    echo '// MouseArea { onClicked: AgentService.kill(session.id) }  <- never again'
    echo '// and its in-flight guard was only'
    echo '//     if (root._listPending || root._pending !== "")'
    echo '// which read as idle for 60ms between hosts.'
    echo '// None of that is here now.'
} >> "$MUT/c1/src/services/RemoteAgentService.qml"
{
    echo '// This used to be a SessionRow, which meant:'
    echo '//     TapHandler { onTapped: AgentService.focusTerminal(session.id) }'
    echo '//     SmallIconButton { onActivated: AgentService.kill(session.id) }'
    echo '// on a session id that belongs to another machine. See the header.'
    echo '// MouseArea {'
    echo '// Button {'
} >> "$MUT/c1/src/services/agents/RemoteSessionRow.qml"
{
    echo '// An earlier draft dropped `agentd` from the schema, so a missing'
    echo '// key read as undefined:  agentd: undefined'
    echo '// and queryTargets said  if (hosts[i])  with no capability test.'
} >> "$MUT/c1/src/services/remoteagents.js"
{
    echo '// _hasRemote: true   <- was hardcoded during bring-up'
    echo '// MouseArea { onClicked: RemoteAgentService.refresh() }'
} >> "$MUT/c1/src/services/agents/AgentCenter.qml"
{
    echo '# RemoteHostRow agents/RemoteHostRow.qml   <- was commented out once'
} >> "$MUT/c1/src/services/qmldir"
assert_changed "$MUT/c1" src/services/RemoteAgentService.qml \
    && expect "prose quoting every one of these bugs stays green" "$MUT/c1" green

echo
echo "self-test: mutants applied=$mutated, failed-to-apply=$unmutated"
echo "self-test passed=$selfpass failed=$selffail"

[ "$real_fail" -eq 0 ] && [ "$selffail" -eq 0 ] && [ "$unmutated" -eq 0 ]
