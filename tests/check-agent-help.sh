#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-agent-help.sh — §43's guide says only things that are true, and reads
#  like a person wrote it.
#
#  ── Why a static check next to the functional one ───────────────────────────
#  tests/run-agent-center-smoke.sh drives the surfaces: it proves the entry is
#  built, the card appears once and a dismissal survives a restart. It cannot
#  read. A help page whose every button works and whose every command is
#  invented would sail through it, and the failure mode this task exists to fix
#  is a user typing a flag that does not exist.
#
#  So this reads the words:
#
#    1. every `apex …` command in the guide names a verb the CLI has;
#    2. the flags the roadmap only PLANS are marked as absent, not documented
#       as usable;
#    3. the six permission layers and the three invariants are all present;
#    4. the prose passes the stop-slop rules, with the allowlist explaining
#       every exemption.
#
#  ── Where the truth comes from ──────────────────────────────────────────────
#  The verb lists are read out of apex-os when a checkout is available
#  (APEX_OS_ROOT, or ../apex-os), so this cannot drift from the CLI it
#  describes. Without one, the check falls back to a vocabulary transcribed
#  from apexd/apex/src/agent.rs and says so, because a soft skip on the machine
#  where most people run tests would leave the check doing nothing.
#
#  PASS = the guide names no command the CLI lacks, marks every unbuilt feature
#         as unbuilt, states all six layers and all three invariants, and reads
#         clean.
#
#  Run from anywhere: ./tests/check-agent-help.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
set +e
cd "$(dirname "$0")/.." || exit 2

CONTENT="src/services/agents/AgentHelpContent.qml"
[ -f "$CONTENT" ] || { echo "FATAL: no $CONTENT" >&2; exit 2; }

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# ── 1. Every apex verb the guide names is a verb the CLI has ────────────────
osroot="${APEX_OS_ROOT:-$(cd ../apex-os 2>/dev/null && pwd)}"
src="$osroot/apexd/apex/src"

# Transcribed from agent.rs:26-134, project 227-309, request.rs:39, secret.rs.
# Used only when no checkout is around; the checkout wins whenever it exists.
AGENT_VERBS="run list attach pause resume kill logs status default adapters diff undo checkpoint event rm prune enable"
PROJECT_VERBS="list info worktrees checkpoints remove forget env switch layout"
REQUEST_VERBS="ask list pending show approve deny verbs grants revoke audit"
SECRET_VERBS="add list remove capabilities grant revoke grants use audit"
HOST_VERBS="add list show remove probe run describe path"

read_verbs() {
    # Clap subcommand names are the CamelCase variants of one enum. Read them
    # from the enum body rather than from the whole file, or `Run` in a doc
    # comment counts as a verb.
    local file="$1" name="$2"
    python3 - "$file" "$name" <<'PY' 2>/dev/null
import re, sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text(errors="replace")
m = re.search(r"pub enum %s \{(.*?)\n\}" % re.escape(sys.argv[2]), text, re.S)
if not m:
    sys.exit(1)
body = m.group(1)
# Strip nested braces so a variant's own fields cannot look like variants.
depth, out = 0, []
for ch in body:
    if ch == "{":
        depth += 1
    elif ch == "}":
        depth -= 1
    elif depth == 0:
        out.append(ch)
flat = "".join(out)
flat = re.sub(r"///[^\n]*", "", flat)
flat = re.sub(r"#\[[^\]]*\]", "", flat)
names = re.findall(r"^\s*([A-Z][A-Za-z0-9]*)\s*(?:\(|,|$)", flat, re.M)
def snake(n):
    return re.sub(r"(?<!^)([A-Z])", r"-\1", n).lower()
print(" ".join(sorted({snake(n) for n in names})))
PY
}

source_note="transcribed vocabulary (no apex-os checkout found)"
if [ -n "$osroot" ] && [ -f "$src/agent.rs" ]; then
    a="$(read_verbs "$src/agent.rs" AgentCmd)"
    p="$(read_verbs "$src/agent.rs" ProjectCmd)"
    r="$(read_verbs "$src/request.rs" RequestCmd)"
    s="$(read_verbs "$src/secret.rs" SecretCmd)"
    h="$(read_verbs "$src/host.rs" HostCmd)"
    if [ -n "$a" ] && [ -n "$p" ]; then
        AGENT_VERBS="$a"; PROJECT_VERBS="$p"
        [ -n "$r" ] && REQUEST_VERBS="$r"
        [ -n "$s" ] && SECRET_VERBS="$s"
        [ -n "$h" ] && HOST_VERBS="$h"
        source_note="read from $src"
    fi
fi
echo "  verb source: $source_note"

# Pull `apex <group> <verb>` out of the guide's strings. The `\n` separators in
# a command block are literal two-character sequences in the QML source, so they
# are turned back into newlines first; without that, `apex agent pause 4\napex`
# hides the second command.
used="$(python3 - "$CONTENT" <<'PY'
import re, pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(errors="replace").replace("\\n", "\n")
for group in ("agent", "project", "request", "secret", "host"):
    for m in re.finditer(r"\bapex %s ([a-z][a-z-]*)" % group, text):
        print(group, m.group(1))
PY
)"

check_group() {
    local group="$1" allowed="$2" missing=""
    local verbs
    verbs="$(printf '%s\n' "$used" | awk -v g="$group" '$1 == g {print $2}' | sort -u)"
    for v in $verbs; do
        case " $allowed " in
            *" $v "*) ;;
            *) missing="$missing $v" ;;
        esac
    done
    if [ -z "$missing" ]; then
        ok "every \`apex $group\` verb the guide names exists ($(printf '%s' "$verbs" | tr '\n' ' '))"
    else
        bad "the guide names \`apex $group\` verbs the CLI does not have:$missing"
    fi
}
check_group agent   "$AGENT_VERBS"
check_group project "$PROJECT_VERBS"
check_group request "$REQUEST_VERBS"
check_group secret  "$SECRET_VERBS"
check_group host    "$HOST_VERBS"

# ── 2. Planned features are marked absent, not documented as usable ─────────
# Each of these appears in ROADMAP §3.4 and §4.4 and in NO shipped binary.
# Naming one without a `todo` block beside it is how a plan becomes a promise.
#
# §42.1's Always Unrestricted was on this list until P0-016 built it. It is now
# checked in the other direction, below: the guide has to say where the toggle
# is, and NO todo block may still claim it is missing. A stale "this build has
# no Config page for it" is the same defect as a premature promise, pointing
# the other way — it sends a user looking for a per-session flag when the
# setting they want is two clicks away.
todo_bodies="$(grep -o '{ k: "todo"[^}]*}' "$CONTENT")"
unbuilt_ok=1
for pair in '--unsafe-everything|--unsafe-everything' '--system-access|--system-access'; do
    name="${pair%%|*}"; marker="${pair##*|}"
    grep -q -- "$name" "$CONTENT" || { bad "the guide never mentions $name"; unbuilt_ok=0; continue; }
    grep -q -- "$marker" <<<"$todo_bodies" \
        || { bad "$name is described but no \"todo\" block says it is absent"; unbuilt_ok=0; }
done
[ "$unbuilt_ok" -eq 1 ] && ok "every unbuilt permission mode carries a NOT-IN-THIS-BUILD block"

# ── 2b. Always Unrestricted is documented as shipped, and located ────────────
# P0-016. Two halves, because either one alone can be true while the guide is
# still useless: a page nobody can find, or a name with a stale disclaimer.
if grep -q "Config → Agents" "$CONTENT"; then
    ok "the guide says where the Always Unrestricted toggle is"
else
    bad "Always Unrestricted is described but the guide never says which page carries it"
fi
if grep -qi "Config page" <<<"$todo_bodies"; then
    bad "a todo block still says this build has no Config page for Always Unrestricted"
else
    ok "no todo block claims the Always Unrestricted page is missing"
fi

# The Android client is roadmap P1-053..060 and ships nothing today.
if grep -q "phone client" <<<"$todo_bodies"; then
    ok "the Android remote is marked as not shipped"
else
    bad "the guide describes the Android remote without saying it does not exist"
fi

# ── 3. The security model is stated in full ─────────────────────────────────
# Six layers, ROADMAP §3.1. Collapsing any two of them is the failure this
# guide exists to prevent, so all six must be named.
layers=0
for n in "1. The agent's own permission mode" \
         "2. The APEX filesystem and process sandbox" \
         "3. The APEX system and root capability layer" \
         "4. The APEX secret and cloud capability layer" \
         "5. The APEX network policy" \
         "6. The remote-origin policy"; do
    grep -qF "$n" "$CONTENT" && layers=$((layers + 1))
done
if [ "$layers" -eq 6 ]; then
    ok "all six permission layers are named separately (§3.1)"
else
    bad "only $layers of the six permission layers are named (§3.1)"
fi

# The three invariants, in the words that make them checkable rather than vague.
inv=0
grep -q "leaves the APEX sandbox switched on"          "$CONTENT" && inv=$((inv + 1))
grep -q "full user access does not give it root"       "$CONTENT" && inv=$((inv + 1))
grep -q "root does not hand over your stored tokens"   "$CONTENT" && inv=$((inv + 1))
if [ "$inv" -eq 3 ]; then
    ok "all three invariants are stated: bypass keeps the sandbox, unrestricted is not root, root is not secrets"
else
    bad "only $inv of the three security invariants are stated"
fi

# Each of the three sandbox modes gets its own entry, not one paragraph.
modes=0
for m in project strict unrestricted; do
    grep -q "{ k: \"kv\", t: \"$m\"" "$CONTENT" && modes=$((modes + 1))
done
if [ "$modes" -eq 3 ]; then
    ok "project, strict and unrestricted each get their own definition"
else
    bad "only $modes of the three sandbox modes are defined separately"
fi

# ── 4. The prose passes the stop-slop rules ─────────────────────────────────
slop="$HOME/.claude/skills/stop-slop/scripts/slopcheck.py"
if [ -f "$slop" ]; then
    out="$(python3 "$slop" --allow-file .slopcheck-allow "$CONTENT" 2>&1)"
    if grep -q "TOTAL: 0" <<<"$out"; then
        ok "the guide reads clean against the stop-slop rules"
    else
        printf '%s\n' "$out" | head -20
        bad "the guide trips the stop-slop rules"
    fi

    # An allowlist without reasons is a way to silence the check.
    if [ -s .slopcheck-allow ] && ! grep -q '^#' .slopcheck-allow; then
        bad ".slopcheck-allow carries entries with no comment explaining them"
    else
        ok ".slopcheck-allow explains every exemption it grants"
    fi
else
    echo "  skip stop-slop rules: $slop not installed"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  the self-test: prove each check can actually fail
#
#  Mutations run against a COPY and every one is diffed first. A mutant that
#  did not apply is a hard failure, never a pass: this repository has produced
#  exactly that false verdict before.
# ─────────────────────────────────────────────────────────────────────────────
printf '\n── self-test: can these checks fail? ──\n'
TMP="$(mktemp -d)" || exit 2
trap 'rm -rf "$TMP"' EXIT
cp "$CONTENT" "$TMP/content.qml"
applied=0; noapply=0

mutate() {
    local label="$1" from="$2" to="$3" verify="$4" before after
    before="$(cat "$TMP/content.qml")"
    python3 - "$TMP/content.qml" "$from" "$to" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace(sys.argv[2], sys.argv[3], 1))
PY
    after="$(cat "$TMP/content.qml")"
    if [ "$before" = "$after" ]; then
        noapply=$((noapply + 1))
        bad "self-test $label: the mutation did not apply, so its verdict is meaningless"
        return
    fi
    applied=$((applied + 1))
    if "$verify"; then ok "self-test $label: caught"
    else bad "self-test $label: SURVIVED — the check does not detect it"; fi
    printf '%s' "$before" > "$TMP/content.qml"
}

# (a) an invented verb, which is the failure the whole file guards against
recheck_verb() {
    local u
    u="$(python3 - "$TMP/content.qml" <<'PY'
import re, pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(errors="replace").replace("\\n", "\n")
print("\n".join(sorted({m.group(1) for m in re.finditer(r"\bapex agent ([a-z][a-z-]*)", text)})))
PY
)"
    for v in $u; do
        case " $AGENT_VERBS " in *" $v "*) ;; *) return 0 ;; esac
    done
    return 1
}
mutate "a verb the CLI does not have" \
    "apex agent adapters" "apex agent profiles" recheck_verb

# (b) an unbuilt flag documented as if it worked
recheck_todo() {
    grep -q -- "--unsafe-everything" < <(grep -o '{ k: "todo"[^}]*}' "$TMP/content.qml") && return 1
    return 0
}
mutate "the break-glass flag losing its NOT-IN-THIS-BUILD block" \
    '{ k: "todo", t: "This build has no --unsafe-everything flag and no --ttl flag." },' \
    '{ k: "p", t: "Reach for it when you need it." },' recheck_todo

# (b2) the shipped Always Unrestricted toggle losing its address. P0-016 built
# the page; a guide that names the setting and not the page it is on is the
# same dead end as a flag that does not exist.
recheck_located() { ! grep -q "Config → Agents" "$TMP/content.qml"; }
mutate "the Always Unrestricted toggle losing the page it is on" \
    "Config → Agents carries one toggle" "There is a toggle" recheck_located

# (b3) a stale disclaimer surviving the feature that answered it.
recheck_stale() { grep -qi "Config page" < <(grep -o '{ k: "todo"[^}]*}' "$TMP/content.qml"); }
mutate "a stale todo claiming there is no Config page for it" \
    '{ k: "kv", t: "What the toggle writes"' \
    '{ k: "todo", t: "This build has no Config page for it." }, { k: "kv", t: "What the toggle writes"' \
    recheck_stale

# (c) two permission layers collapsed into one
recheck_layers() {
    local n=0
    for x in "2. The APEX filesystem and process sandbox" \
             "3. The APEX system and root capability layer"; do
        grep -qF "$x" "$TMP/content.qml" && n=$((n + 1))
    done
    [ "$n" -lt 2 ]
}
mutate "two permission layers collapsed together" \
    '{ k: "kv", t: "3. The APEX system and root capability layer"' \
    '{ k: "kv", t: "3. Part of the sandbox above"' recheck_layers

# (d) an invariant softened into a vague reassurance, which §43 forbids by name
recheck_invariant() {
    ! grep -q "full user access does not give it root" "$TMP/content.qml"
}
mutate "an invariant replaced by vague security wording" \
    "Giving a session your full user access does not give it root." \
    "Your data stays safe and secure at all times." recheck_invariant

# (e) slop reintroduced
if [ -f "$slop" ]; then
    recheck_slop() {
        ! grep -q "TOTAL: 0" < <(python3 "$slop" --allow-file .slopcheck-allow "$TMP/content.qml" 2>&1)
    }
    mutate "an em dash and an adverb in the prose" \
        "There is nothing to create and nothing to register." \
        "There is genuinely nothing to create — and nothing to register." recheck_slop
fi

# ── the inverse mutant: the checks must read the guide, not this file ───────
# Every string this file greps for also appears in the prose above it. If the
# checks were matching their own header the mutants would still pass, so point
# them at a file that contains the header's words and none of the guide's.
sed -n '1,40p' "$0" > "$TMP/header-only.qml"
inv_layers=0
for n in "1. The agent's own permission mode" "6. The remote-origin policy"; do
    grep -qF "$n" "$TMP/header-only.qml" && inv_layers=$((inv_layers + 1))
done
if [ "$inv_layers" -eq 0 ]; then
    ok "self-test inverse: this file's own prose satisfies none of its checks"
else
    bad "self-test inverse: $inv_layers checks are satisfied by this script's header"
fi

printf '\nself-test: mutants applied=%d, failed-to-apply=%d\n' "$applied" "$noapply"
printf 'check-agent-help: passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
