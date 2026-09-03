#!/usr/bin/env bash
# Static invariants for §20's remote agent status (P2 phase 9.3).
#
# ── Why this exists next to the smoke test ───────────────────────────────────
# run-remote-agent-smoke.sh needs a Wayland session and an apex-os checkout and
# skips without either, so on a CI runner it proves nothing. Everything here is
# grep-able and runs headless, which matters: the invariants below are all one
# careless edit away from regressing with no visible symptom. An ungated sweep
# timer costs battery and somebody else's bandwidth silently; a remote row that
# grows a Stop button kills a LOCAL agent and logs nothing.
#
# ── A COMMENT MUST NOT BE ABLE TO SATISFY ANY CHECK IN HERE ──────────────────
# This repo has shipped four grep-style checks in one day that were satisfied by
# the prose in the very file they were guarding. So every check below runs
# against comment-stripped input, and the script does not merely claim that —
# it proves it, by running itself against mutated copies at the bottom:
#
#   * an UNMUTATED copy must come out green, or a check that silently found no
#     file at all would make the comment mutant's green meaningless;
#   * five FORWARD mutants, each a plausible regression, must each come out
#     red — a check that cannot fail is not a check;
#   * one COMMENT-ONLY mutant, which adds prose that would trip every naive
#     version of these greps, must come out green — a check that a comment can
#     turn red is a check that punishes documentation.
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
want() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

# ── comment-stripped views ───────────────────────────────────────────────────
# Whole-line comments only. A trailing comment on a real line of code is fine:
# the code is still there, which is what the check is asking about.
code()    { grep -vE '^[[:space:]]*//' "$1" 2>/dev/null; }
qmldircode() { grep -vE '^[[:space:]]*#' "$1" 2>/dev/null; }

# has <file> <extended-regex> — true when the regex matches a line of CODE.
has()  { code "$1" | grep -qE "$2"; }
# lacks <file> <extended-regex> — true when NO line of code matches.
lacks() { ! code "$1" | grep -qE "$2"; }

# Keys of a JS/QML object literal between two anchors, comments excluded.
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
    # First, and unconditionally: every check below is a grep, and a grep
    # against a file that is not there finds nothing, which several of the
    # `lacks` checks would happily read as a pass.
    for f in "$js" "$svc" "$hrow" "$srow" "$centre" "$qmldir"; do
        want "$(basename "$f") exists and is non-empty" test -s "$f"
    done

    # ── reachable from the Agent Center ──────────────────────────────────────
    # AgentCenter is loaded THROUGH src/services/qmldir, so its own directory is
    # not on the import path and implicit sibling resolution does not apply.
    # A dropped entry is "RemoteHostRow is not a type" at load, which takes the
    # whole shell down rather than just the page.
    want "RemoteAgentService is registered as a singleton" \
        qmldircode "$qmldir" | grep -qE '^singleton RemoteAgentService .*RemoteAgentService\.qml$'
    for t in RemoteHostRow RemoteSessionRow; do
        want "$t is registered in src/services/qmldir" \
            qmldircode "$qmldir" | grep -qE "^${t} agents/${t}\.qml$"
    done

    # ── the refcount convention ──────────────────────────────────────────────
    want "the service exposes refCount, so ServiceRef can hold it" \
        has "$svc" '^[[:space:]]*property int refCount:'
    want "the Agent Center holds a ServiceRef on it" \
        has "$centre" 'ServiceRef \{ service: RemoteAgentService'

    # ── IDLE MUST BE ZERO SSH CONNECTIONS ────────────────────────────────────
    # Not "slower at idle" — zero. Every query is a connection to somebody
    # else's machine, so unlike AgentService there is no slow tier here, and
    # these three are what make that true.
    #
    # Anchored to a property assignment at the start of a line, the way ci.yml
    # anchors its `layer.enabled` check, so prose about a timer cannot pass for
    # one.
    want "no timer in the service is force-started" \
        lacks "$svc" '^[[:space:]]*running:[[:space:]]*true[[:space:]]*$'
    want "the sweep is re-armed only while a ref is held" \
        has "$svc" '^[[:space:]]*if \(root\.refCount > 0\) root\._cooldown\.restart\(\)'
    want "losing the last ref stands the service down" \
        has "$svc" '^[[:space:]]*else[[:space:]]+root\._standDown\(\)'
    want "standing down kills the query in flight rather than letting it finish" \
        has "$svc" '^[[:space:]]*root\._queryProc\.running = false'

    # ── refcount churn must not become one connection per toggle ─────────────
    want "a sweep is clamped on the age of the last one" \
        has "$svc" 'root\._lastSweepStart\) < root\.minSweepGap'
    want "only an explicit refresh bypasses the clamp" \
        has "$svc" '^[[:space:]]*function refresh\(\) \{ root\._beginSweep\(true\) \}'

    # ── a hung host must not wedge the sweep ─────────────────────────────────
    # ConnectTimeout=8 bounds getting there and nothing bounds what happens
    # after, so a host that completes TCP and then stalls would leave the queue
    # stopped forever — not degraded, dead for the session.
    want "a per-query watchdog exists" \
        has "$svc" '^[[:space:]]*interval: root\.queryTimeout'
    want "the watchdog clears the slot before killing, so the kill's exit is ignored" \
        code "$svc" | grep -A2 'root\._pending = ""[[:space:]]*//' \
                    | grep -qE 'root\._queryProc\.running = false'
    want "a binary that never starts is caught by a settle timer" \
        has "$svc" 'if \(root\._listPending\) root\._onRegistry\(false, ""\)'

    # ── the CLI owns the ssh argv ────────────────────────────────────────────
    # `apex host run <name> -- <argv…>` passes the remote arguments with their
    # boundaries intact, which plain `ssh host cmd a b` does not: ssh joins them
    # with spaces and hands the string to the remote shell. Assembling that
    # here would also be where an injection landed.
    want "the query goes through apex host run with a -- separator" \
        has "$svc" '"apex", "host", "run", name,[[:space:]]*$'
    want "the remote command is asked for machine-readable output" \
        has "$svc" '"apex", "agent", "list", "--all", "--json"'
    want "the service never builds a shell command line" \
        lacks "$svc" '"(ba)?sh", *"-c"'

    # ── do not invent capability ─────────────────────────────────────────────
    # A device is queried only when a probe has SHOWN it has the runtime.
    # caps === null is "we do not know", which is not "yes" and not "no".
    want "only a demonstrated runtime is queried" \
        has "$js" '^[[:space:]]*if \(hosts\[i\] && hosts\[i\]\.agentd === true\)'
    want "an unprobed host is not treated as having no runtime" \
        has "$js" '^[[:space:]]*if \(host\.probed !== true\)[[:space:]]*return STATUS\.NOT_PROBED'
    want "a boolean cap is read with === true, never for truthiness" \
        has "$js" '^[[:space:]]*out\[k\] = v === true$'
    want "caps null stays null rather than becoming an all-false record" \
        has "$js" '^[[:space:]]*return null$'
    want "the registry is read as an object, and an array is refused by name" \
        has "$js" 'reason: "array-not-object"'

    # ── every table key is explicit ──────────────────────────────────────────
    # A missing key yields `undefined`, which is truthy-adjacent in enough
    # checks that CompositorService has its own comment about it. Both of these
    # compare EXTRACTED KEY SETS, so neither can be satisfied by prose naming a
    # key — and neither can be broken by prose either, because comment lines
    # are stripped out of the extraction.
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
    want "the caps schema declares agentd" \
        grep -qx 'agentd' <<<"$capkeys"
    want "the caps schema declares every HostCaps field apex host list can print" \
        test "$(echo "$capkeys" | tr '\n' ' ')" = \
             "accel agentd ai apex_version cpus free_mib gpus memory_mib os podman probed_at variant "

    # ── A REMOTE ROW MUST NOT ACT ────────────────────────────────────────────
    # This is the concrete defect the design avoids, so it gets a check rather
    # than a comment. A session id is issued by the runtime that owns it, so
    # `#3` on the desktop and `#3` here are different agents — and AgentService
    # talks to the LOCAL daemon. Reusing SessionRow would have made Stop kill an
    # unrelated local agent, with nothing logged.
    want "a remote session row calls no AgentService verb that takes an id" \
        lacks "$srow" 'AgentService\.(focusTerminal|reviewRequest|pause|resume|kill|refresh|_act)\('
    want "a remote session row has no interactive element at all" \
        lacks "$srow" '(MouseArea|TapHandler|SmallIconButton|Button)[[:space:]]*\{'
    want "a remote host row has no interactive element either" \
        lacks "$hrow" '(MouseArea|TapHandler|SmallIconButton|Button)[[:space:]]*\{'

    # ── conditional appearance, at the level where it is free ────────────────
    # There is no bar indicator: knowing whether there is anything to show costs
    # an ssh, so an indicator that "appears when there is something to show"
    # would have to poll at idle. Registration IS free — it is a local file
    # read — so the section exists only when a device is registered.
    want "the remote section exists only when a device is registered" \
        has "$centre" '_hasRemote: RemoteAgentService\.hosts\.length > 0'
    want "no bar module reaches for the remote service" \
        test -z "$(grep -rl 'RemoteAgentService' "$r/src/modules" "$r/src/windows" 2>/dev/null)"

    # ── the delegate-recreation trap ─────────────────────────────────────────
    # `model: <JS array>` recreates every delegate whenever the array's contents
    # change — measured in this repo on Qt 6.10.3: created=6, destroyed=3 after
    # one content change on a 3-element model, which silently stopped the
    # workspace strip's Behaviours. A sweep rewrites these arrays every fifteen
    # seconds, so an array model would restart every animation on every poll.
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
echo
echo "passed=$pass failed=$fail"

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
    for f in "${FILES[@]}"; do cp "$repo/$f" "$dst/$f"; done
}

# verdict <dir> — "green" or "red", from a quiet run of the same checks.
verdict() {
    local saved_pass=$pass saved_fail=$fail saved_quiet=$quiet
    pass=0; fail=0; quiet=1
    check_tree "$1"
    local v="green"
    [ "$fail" -eq 0 ] || v="red"
    pass=$saved_pass; fail=$saved_fail; quiet=$saved_quiet
    echo "$v"
}

selfpass=0
selffail=0
expect() {
    local desc="$1" dir="$2" wanted="$3"
    local got
    got="$(verdict "$dir")"
    if [ "$got" = "$wanted" ]; then
        echo "  PASS  $desc (=> $got)"
        selfpass=$((selfpass + 1))
    else
        echo "  FAIL  $desc (wanted $wanted, got $got)"
        selffail=$((selffail + 1))
    fi
}

# ── 0. the baseline ──────────────────────────────────────────────────────────
# Without this, a mutant that came out red because the copy was EMPTY would
# look like a working check, and the comment mutant's green would mean nothing.
fresh_copy "$MUT/base"
expect "an unmutated copy is green" "$MUT/base" green

# ── 1..5. forward mutants: each a regression somebody could plausibly write ──
fresh_copy "$MUT/m1"
sed -i 's|^\( *\)interval: root.sweepInterval$|\1interval: root.sweepInterval\n\1running: true|' \
    "$MUT/m1/src/services/RemoteAgentService.qml"
expect "an always-running sweep timer is caught" "$MUT/m1" red

fresh_copy "$MUT/m2"
sed -i 's|if (root.refCount > 0) root._cooldown.restart()|root._cooldown.restart()|' \
    "$MUT/m2/src/services/RemoteAgentService.qml"
expect "re-arming the sweep without a ref is caught" "$MUT/m2" red

fresh_copy "$MUT/m3"
sed -i '/^        unreachable: "󰅛",$/d' "$MUT/m3/src/services/RemoteAgentService.qml"
expect "a status with a label but no icon is caught" "$MUT/m3" red

fresh_copy "$MUT/m4"
sed -i 's|^\( *\)required property var session$|\1required property var session\n\1TapHandler { onTapped: AgentService.kill(srow.session.id) }|' \
    "$MUT/m4/src/services/agents/RemoteSessionRow.qml"
expect "a remote row that acts on a session id is caught" "$MUT/m4" red

fresh_copy "$MUT/m5"
sed -i '/^RemoteHostRow agents\/RemoteHostRow.qml$/d' "$MUT/m5/src/services/qmldir"
expect "an unregistered component is caught" "$MUT/m5" red

fresh_copy "$MUT/m6"
sed -i 's|out\[k\] = v === true|out[k] = !!v|' "$MUT/m6/src/services/remoteagents.js"
expect "reading a capability for truthiness is caught" "$MUT/m6" red

# ── 6. the inverse mutant ────────────────────────────────────────────────────
# Prose that would trip a naive version of every check above. It must NOT turn
# anything red: a check a comment can break is a check that punishes people for
# explaining themselves, and this repo has shipped the opposite mistake — a
# check a comment could SATISFY — four times in one day.
fresh_copy "$MUT/c1"
{
    echo '// The old version had `running: true` on the sweep timer, and'
    echo '//     root._cooldown.restart()'
    echo '// with no refCount guard, so it polled forever. It also used'
    echo '//     command: ["sh", "-c", "ssh " + name + " apex agent list"]'
    echo '// which spliced a host name into a shell line, and read caps with'
    echo '//     out[k] = !!v'
    echo '// so a missing key came back truthy. None of that is here now.'
    echo '// MouseArea { onClicked: AgentService.kill(session.id) }   <- never again'
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
    echo '// A previous draft dropped `agentd` from the schema, so a missing'
    echo '// key read as undefined:  agentd: undefined'
} >> "$MUT/c1/src/services/remoteagents.js"
{
    echo '# RemoteHostRow agents/RemoteHostRow.qml   <- was commented out once'
} >> "$MUT/c1/src/services/qmldir"
expect "prose describing every one of these bugs stays green" "$MUT/c1" green

echo
echo "self-test passed=$selfpass failed=$selffail"

[ "$real_fail" -eq 0 ] && [ "$selffail" -eq 0 ]
