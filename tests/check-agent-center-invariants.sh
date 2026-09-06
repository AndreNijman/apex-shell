#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-agent-center-invariants.sh — the Agent Center navigates, does not
#  decide, and stays lazy.
#
#  Lifted out of .github/workflows/ci.yml so it can be run and, more to the
#  point, MUTATION-TESTED. A check that only ever executes inside a CI runner
#  is a check nobody can prove still fails on the thing it was written for.
#
#  ── Why checks 1 and 2 had to be rewritten ──────────────────────────────────
#
#  Both were written as a bare grep for a word:
#
#      grep -rnE "request (approve|allow|deny)|\bsudo\b"  src/services/agents/
#      grep -rnE "control\.sock|apex-agentd/control"      src/services/
#
#  That was sound while no file in those directories could have a reason to
#  say either word. §43's help surfaces ended that. AgentHelpContent.qml is a
#  document whose whole job is explaining the privilege model to somebody who
#  has never seen it, so it necessarily prints
#
#      sudo apex request approve 3
#      $XDG_RUNTIME_DIR/apex-agentd/control.sock
#
#  as help text — and the invariant went red on the tip for six mentions of
#  `sudo` and one of `control.sock`, none of which is the thing it guards
#  against. A gate everybody knows to ignore is worse than no gate: the next
#  real failure hides behind it.
#
#  The distinction the check needs is MENTION versus USE. Naming a command in
#  a string is documentation; running it needs a way to run something. In QML
#  there are only a few of those — a `Process`, `execDetached`, a `Socket`, a
#  `command:` array, `Qt.createQmlObject`. So the rule is:
#
#      a file may name `sudo` / a privilege verb / the control socket
#      ONLY IF it declares no way to execute anything.
#
#  A pure document keeps its exemption. The moment somebody adds a `Process`
#  to it, the exemption is gone and every mention in it is a finding again —
#  which is exactly the transition worth catching, because that is what "the
#  Agent Center started approving things itself" looks like in a diff.
#
#  It is deliberately conservative in one direction: a file that legitimately
#  runs `apex agent list` may not also carry sudo prose. That costs a comment
#  (comments are stripped) or a move into the help content, and it means the
#  check can never be argued into ignoring a real call site.
#
#  Run from the repository root: ./tests/check-agent-center-invariants.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
set +e
cd "$(dirname "$0")/.." || exit 2

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

[ -d src/services ] || { echo "FATAL: no src/services directory" >&2; exit 2; }

# ── the vocabulary ───────────────────────────────────────────────────────────
#
# EXECUTES is the whole security argument, so it is written out rather than
# approximated. `running:` is deliberately NOT in it: it is the property that
# starts an animation and a BusyIndicator, and four Agent Center files carry
# one for that reason alone.
EXECUTES='Process[[:space:]]*\{|execDetached|Socket[[:space:]]*\{'
EXECUTES="$EXECUTES"'|SocketServer[[:space:]]*\{|command:[[:space:]]*\[|Qt\.createQmlObject'

PRIVILEGE='request (approve|allow|deny)|\bsudo\b'
SOCKET='control\.sock|apex-agentd/control'

# uncommented <file> <ERE> — matching lines with `// …` lines removed.
#
# No `| grep -q` anywhere in this file. `producer | grep -q` under pipefail
# reports the producer's SIGPIPE as an assertion failure; see
# tests/check-grep-pipelines.sh.
uncommented() {
    grep -nE "$2" "$1" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*//'
}

runs_code() { grep -qE "$EXECUTES" "$1" 2>/dev/null; }

# scan <ERE> <file…> — every file that both NAMES the thing and can RUN
# something. Prints `file:line:text` for each finding; silent when clean.
scan() {
    local pattern="$1"; shift
    local f hits
    for f in "$@"; do
        [ -f "$f" ] || continue
        hits="$(uncommented "$f" "$pattern")"
        [ -n "$hits" ] || continue
        runs_code "$f" || continue
        printf '%s\n' "$hits" | sed "s|^|$f:|"
    done
}

privilege_findings() {
    local r="${1:-.}"
    scan "$PRIVILEGE" "$r"/src/services/agents/*.qml "$r"/src/services/AgentService.qml
}

socket_findings() {
    local r="${1:-.}"
    local files=()
    while IFS= read -r f; do files+=("$f"); done < <(find "$r/src/services" -name '*.qml' | sort)
    [ "${#files[@]}" -gt 0 ] || return 0
    scan "$SOCKET" "${files[@]}"
}

# ── 1. The shell must NEVER approve a privilege request itself ───────────────
#
# Approving performs the operation with the user's own root, so it belongs in
# a terminal where the prompt and the sudo authentication are both visible. An
# [Allow] button in a status list would be one unconfirmed click from an OS
# change, judged from a two-line summary. The Agent Center therefore navigates
# to a terminal and decides nothing.
found="$(privilege_findings)"
if [ -z "$found" ]; then
    ok "no Agent Center surface that can run something also names sudo or a privilege verb"
else
    printf '%s\n' "$found" | head -20
    bad "the Agent Center decides privilege requests; it must only navigate"
fi

# ── 2. It must go through the `apex` CLI, not the control socket ────────────
#
# The CLI already handles an absent daemon and a protocol-version mismatch. A
# second implementation of the socket protocol in QML is a second thing to
# keep in step with every protocol change, and it would drift silently.
found="$(socket_findings)"
if [ -z "$found" ]; then
    ok "no QML that can open a socket or run a command names the agentd control socket"
else
    printf '%s\n' "$found" | head -20
    bad "QML talks to the agentd socket directly; use the apex CLI"
fi

# The exemption must not be free. If AgentHelpContent.qml ever stops being the
# document that explains these commands, checks 1 and 2 are passing over an
# empty set and are proving nothing — say so rather than reporting a green.
helpdoc=src/services/agents/AgentHelpContent.qml
if [ -n "$(uncommented "$helpdoc" "$PRIVILEGE")" ] && [ -n "$(uncommented "$helpdoc" "$SOCKET")" ]; then
    ok "the help document still explains sudo and the control socket, so the exemption is load-bearing"
else
    bad "$helpdoc no longer documents these commands — checks 1 and 2 now guard nothing"
fi

# ── 3. The Agent Center's parts must stay registered ────────────────────────
#
# AgentCenter is loaded THROUGH src/services/qmldir, so its own directory is
# not on the import path and implicit sibling resolution does not apply.
# Dropping an entry gives "RequestRow is not a type" at load, which takes the
# whole shell down — not just the page. RemoteHostRow and RemoteSessionRow are
# in this loop rather than only in check-remote-agents.sh because the failure
# is identical.
missing=""
for t in AgentCenter RequestRow SessionRow SectionHeading SmallIconButton \
         RemoteHostRow RemoteSessionRow; do
    grep -qE "^${t} agents/${t}\.qml$" src/services/qmldir || missing="$missing $t"
done
for svc in AgentService RemoteAgentService; do
    grep -q "^singleton ${svc} " src/services/qmldir || missing="$missing $svc"
done
if [ -z "$missing" ]; then
    ok "every Agent Center type and singleton is registered in src/services/qmldir"
else
    bad "not registered in src/services/qmldir:$missing"
fi

# ── 4. The page must be lazy and refcounted like every other one ────────────
lazy=0
grep -q "ServiceRef" src/services/agents/AgentCenter.qml \
    || { echo "    the Agent Center does not hold a ServiceRef"; lazy=1; }
grep -q "refCount" src/services/AgentService.qml \
    || { echo "    AgentService has no refCount"; lazy=1; }
grep -q 'shown: root.page === "agents"' src/popups/Dashboard.qml \
    || { echo "    the Agents tab is not lazily built"; lazy=1; }
if [ "$lazy" -eq 0 ]; then
    ok "the Agents tab is lazily built and the service is refcounted"
else
    bad "the Agent Center is not lazy/refcounted like every other page"
fi

# ── 5. AgentService's poll has two tiers ────────────────────────────────────
#
# The timer is deliberately always running — it slows to 15s with no refs
# rather than stopping, because a notification has to arrive when nothing is
# on screen. Assert the SLOW tier exists, so "always running" cannot quietly
# become "always running fast".
if grep -qE "refCount > 0 \? [0-9]+ : [0-9]+" src/services/AgentService.qml; then
    ok "AgentService keeps a two-tier poll interval"
else
    bad "AgentService has no two-tier poll interval"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  self-test: can checks 1 and 2 still fail on the thing they were written for?
#
#  This is the half the ci.yml version could never have. Every mutation is
#  applied to a COPY and verified to have changed the file before its verdict
#  is believed — a mutation that silently failed to apply would otherwise be
#  reported as "caught", which is a false green this repository has produced
#  before.
# ─────────────────────────────────────────────────────────────────────────────
printf '\n── self-test: can these checks fail? ──\n'
TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; return 0; }
trap cleanup EXIT INT TERM
mkdir -p "$TMP/m/src"
cp -r src/services "$TMP/m/src/services"

# mutate <label> <file under $TMP/m> <python-expression appending text>
apply_mutant() {
    local target="$TMP/m/$1" text="$2" before after
    [ -f "$target" ] || { bad "self-test: no such file $1"; return 1; }
    # Byte-exact, via cp. `$(cat …)` drops the trailing newline, and restoring
    # from one put the next mutant's first line on the end of the file's last
    # one — where a leading `//` is no longer at the start of a line and the
    # comment filter stops seeing it. That is a self-test lying about the
    # check, which is the failure this whole file exists to avoid.
    cp "$target" "$TMP/restore"
    before="$(cat "$target")"
    printf '%s\n' "$text" >> "$target"
    after="$(cat "$target")"
    if [ "$before" = "$after" ]; then
        bad "self-test: the mutation did not apply to $1, so its verdict is meaningless"
        return 1
    fi
    return 0
}
restore_mutant() { cp "$TMP/restore" "$TMP/m/$1"; }

expect() {
    local label="$1" want="$2" got="$3"
    if [ "$want" = red ] && [ -n "$got" ]; then ok "self-test $label: caught"
    elif [ "$want" = green ] && [ -z "$got" ]; then ok "self-test $label: not a false failure"
    elif [ "$want" = red ]; then bad "self-test $label: SURVIVED — the check does not detect it"
    else printf '%s\n' "$got" | head -5; bad "self-test $label: FALSE FAILURE"
    fi
}

# The baseline. The whole point of the rewrite is that today's tree is green.
expect "baseline privilege" green "$(privilege_findings "$TMP/m")"
expect "baseline socket"    green "$(socket_findings    "$TMP/m")"

# M1 — the exact regression the check exists for: the help document stops
# being a document and starts running the command it describes.
if apply_mutant src/services/agents/AgentHelpContent.qml \
    'Process { command: ["sudo", "apex", "request", "approve", "3"] }'; then
    expect "help content gains a Process that runs sudo" red "$(privilege_findings "$TMP/m")"
    restore_mutant src/services/agents/AgentHelpContent.qml
fi

# M2 — the other direction: a file that already runs something starts naming
# sudo. AgentHelp.qml holds a real Process, so its exemption never applied.
if apply_mutant src/services/agents/AgentHelp.qml \
    '// legitimate comment
    property string hint: "run sudo apex request approve"'; then
    expect "a file that runs code gains sudo prose" red "$(privilege_findings "$TMP/m")"
    restore_mutant src/services/agents/AgentHelp.qml
fi

# M3 — inverse: a COMMENT naming sudo in a file that runs code must not fail.
# Without this the check could be passing on prose alone.
if apply_mutant src/services/agents/AgentHelp.qml \
    '    // the terminal is where sudo apex request approve belongs'; then
    expect "a comment naming sudo" green "$(privilege_findings "$TMP/m")"
    restore_mutant src/services/agents/AgentHelp.qml
fi

# M4 — a QML file opens the control socket itself.
if apply_mutant src/services/agents/AgentCenter.qml \
    'Socket { path: Quickshell.env("XDG_RUNTIME_DIR") + "/apex-agentd/control.sock" }'; then
    expect "QML opens the control socket" red "$(socket_findings "$TMP/m")"
    restore_mutant src/services/agents/AgentCenter.qml
fi

# M5 — a document naming the socket, with no way to open one, stays exempt.
if apply_mutant src/services/agents/AgentHelpContent.qml \
    '{ k: "kv", t: "$XDG_RUNTIME_DIR/apex-agentd/control.sock", d: "the control socket" },'; then
    expect "a second mention of the socket in the document" green "$(socket_findings "$TMP/m")"
    restore_mutant src/services/agents/AgentHelpContent.qml
fi

# M6 — the registration check, which used to live inline and was never proved
# able to fail either.
sed -i 's|^RequestRow agents/RequestRow\.qml$|RequestRowX agents/RequestRow.qml|' \
    "$TMP/m/src/services/qmldir"
if grep -qE "^RequestRow agents/RequestRow\.qml$" "$TMP/m/src/services/qmldir"; then
    bad "self-test: the qmldir mutation did not apply"
else
    ok "self-test dropped qmldir entry: caught"
fi

printf '\ncheck-agent-center-invariants: passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
