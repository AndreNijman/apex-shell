#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-agent-settings.sh — the Always Unrestricted toggle's invariants
#  (ROADMAP.md §42.1, P0-016), as static facts about the tree.
#
#  ── Why static, next to a node test that already passes ─────────────────────
#
#  tests/agent-policy-test.js drives the pure logic: when a password is
#  required, which keys a write may move, what a session's own mode is. It
#  cannot see the wiring, and the wiring is where this feature fails
#  dangerously rather than visibly:
#
#    * the OFF path growing a password prompt, or the ON path losing one;
#    * pkexec or sudo appearing anywhere near a setting that grants no root;
#    * the polkit action drifting to auth_admin, which asks the wrong
#      question, or to auth_self_keep, which caches the answer;
#    * a session row reading the DEFAULT instead of its own recorded mode,
#      which relabels running agents the moment somebody moves the toggle;
#    * the config path drifting from the one apex-agent-core resolves, so the
#      page reports a setting no session will ever read.
#
#  Every one of those ships green. None of them is visible until it matters.
#
#  ── The three ways a grep-style check lies ──────────────────────────────────
#
#  Taken from tests/check-remote-agents.sh, which learned them the hard way:
#
#  1. A COMMENT SATISFIES IT. Every check runs against comment-stripped input,
#     and the inverse mutant at the bottom quotes each bug in prose and must
#     stay green.
#  2. ANOTHER LINE OF REAL CODE SATISFIES IT. `_write(` appears twice in the
#     service, so "the OFF path writes without a prompt" is scoped to
#     setAlwaysUnrestricted's body with fn_body, and the pkcheck ordering is
#     asserted as an ORDER within that body rather than as a presence.
#  3. THE MUTANT NEVER APPLIED. Every mutant is diffed against its source and
#     a mutant that did not change anything is a hard failure.
#
#  PASS = the toggle asks for a password on the way in and not on the way out,
#         at an action that authenticates the user rather than an admin, never
#         through a root helper, writing one key of a file resolved the way
#         apex resolves it, while every row reports its own session's mode.
#
#  Run from anywhere: ./tests/check-agent-settings.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"

pass=0
fail=0
quiet=0
ok()  { [ "$quiet" -eq 1 ] || echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { [ "$quiet" -eq 1 ] || echo "  FAIL  $1"; fail=$((fail + 1)); }
want() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

# ── comment-stripped views ───────────────────────────────────────────────────
code()       { grep -vE '^[[:space:]]*//' "$1" 2>/dev/null; }
qmldircode() { grep -vE '^[[:space:]]*#'  "$1" 2>/dev/null; }
xmlcode()    { perl -0777 -pe 's/<!--.*?-->//gs' "$1" 2>/dev/null; }

has()   {   code "$1" | grep -qE "$2"; }
lacks() { ! code "$1" | grep -qE "$2"; }
qmldir_has() { qmldircode "$1" | grep -qE "$2"; }
xml_has()    { xmlcode "$1" | grep -qE "$2"; }
xml_lacks()  { ! xmlcode "$1" | grep -qE "$2"; }

# fn_body <file> <ERE matching the opening line> — that declaration's body,
# ending at the first closing brace indented the same as the opening line.
fn_body() {
    FN_PAT="$2" awk '
        !inside && $0 ~ ENVIRON["FN_PAT"] { inside = 1; indent = match($0, /[^ ]/); print; next }
        inside {
            print
            if ($0 ~ /^[ ]*\}/ && match($0, /[^ ]/) == indent) exit
        }
    ' "$1" 2>/dev/null | grep -vE '^[[:space:]]*//'
}
in_fn()    {   fn_body "$1" "$2" | grep -qE "$3"; }
notin_fn() { ! fn_body "$1" "$2" | grep -qE "$3"; }

# between_in_fn <file> <fn ERE> <start ERE> <stop ERE> <needle ERE>
#
# True when, inside that function, a line matching <needle> appears between the
# first line matching <start> and the first line matching <stop> after it.
#
# This is the shape criterion 5 needs, and three simpler checks cannot express
# it. `return` is in the function; `requiresAuth` is in the function; the prompt
# is in the function; and every one of those is still true after the `return` is
# deleted from the guard, which is exactly the edit that makes switching OFF ask
# for a password. What must hold is that nothing reaches the prompt once the
# guard has decided none is needed, and that is a statement about what sits
# BETWEEN two lines.
#
# The three env assignments sit in front of AWK and not in front of fn_body,
# which is not a style choice. Written the other way they are set for fn_body's
# environment, and awk on the far side of the pipe runs without them — so every
# `$0 ~ ENVIRON[...]` is a match against the empty string, every line matches,
# and the check is green for any input at all. It shipped that way for one run
# and the baseline mutant is what caught it.
between_in_fn() {
    fn_body "$1" "$2" | START="$3" STOP="$4" NEEDLE="$5" awk '
        !started && $0 ~ ENVIRON["START"] { started = 1; next }
        started && !stopped {
            if ($0 ~ ENVIRON["STOP"]) { stopped = 1; next }
            if ($0 ~ ENVIRON["NEEDLE"]) found = 1
        }
        END { exit (started && found) ? 0 : 1 }
    '
}

# The user-visible copy, and only that.
#
# Every double-quoted literal in the comment-stripped source that carries a
# space and four letters, which on these two files is the sentences and nothing
# else. Two earlier versions of this got it wrong in opposite directions and
# both are worth remembering, because the checks below are only as honest as
# what they are handed.
#
# It keyed off `text:` and `description:` first, which silently dropped both
# halves of every ternary — so the string a reader sees most of the time was
# the one string the slop gate never looked at. The mutant that rewrites a
# description to say "sandboxed and secure" is what found that.
#
# Then it took each literal on its own, which split a sentence written as three
# concatenated lines into three "sentences" of nearly equal length and tripped
# the rhythm rule on prose that reads as one line on screen. A run of literals
# joined by `+` is ONE string to the reader, so it is joined here too.
extract_copy() {
    python3 - "$@" <<'PYCOPY'
import re, sys, pathlib
LIT = r'"(?:[^"\\\n]|\\.)*"'
RUN = re.compile("(?:" + LIT + r")(?:\s*\+\s*(?:" + LIT + "))*")
out = []
for f in sys.argv[1:]:
    src = pathlib.Path(f).read_text(errors="replace")
    src = re.sub(r"^[ \t]*//.*$", "", src, flags=re.M)
    for m in RUN.finditer(src):
        s = "".join(x[1:-1] for x in re.findall(LIT, m.group(0)))
        if " " in s and len(re.findall(r"[A-Za-z]", s)) >= 4:
            out.append(s)
print("\n\n".join(out))
PYCOPY
}

check_tree() {
    local r="$1"
    local js="$r/src/services/agentpolicy.js"
    local svc="$r/src/services/AgentPolicyService.qml"
    local page="$r/src/services/config_tab/pages/AgentsPage.qml"
    local banner="$r/src/services/agents/UnrestrictedBanner.qml"
    local srow="$r/src/services/agents/SessionRow.qml"
    local centre="$r/src/services/agents/AgentCenter.qml"
    local qmldir="$r/src/services/qmldir"
    local registry="$r/src/nexus/PageRegistry.qml"
    local policy="$r/dots-extra/polkit/org.apexos.shell.agent.policy"
    local installer="$r/dots-extra/install-arch.sh"

    # ── the parts exist ──────────────────────────────────────────────────────
    # First and unconditionally: a `lacks` check against a missing file passes.
    local f
    for f in "$js" "$svc" "$page" "$banner" "$srow" "$centre" "$qmldir" \
             "$registry" "$policy" "$installer"; do
        want "$(basename "$f") exists and is non-empty" test -s "$f"
    done

    # ── criterion 1: the page exists and is reachable ────────────────────────
    # Both settings surfaces read PageRegistry, so one entry is what makes the
    # page appear in the dashboard tab AND in the Nexus window. The qmldir
    # entries matter for a different reason: AgentCenter and the pages are
    # loaded THROUGH src/services/qmldir, so an unregistered sibling is
    # "AgentsPage is not a type" at load, which takes the whole shell down.
    want "the settings page is registered in PageRegistry" \
        has "$registry" '"id": "agents"'
    want "the registry entry points at a component that builds AgentsPage" \
        has "$registry" 'AgentsPage \{\}'
    want "the page declares needsScreen, so its AgentService ref is released" \
        in_fn "$registry" '"id": "agents"' '"needsScreen": true'
    want "AgentPolicyService is registered as a singleton" \
        qmldir_has "$qmldir" '^singleton AgentPolicyService .*AgentPolicyService\.qml$'
    want "AgentsPage is registered in src/services/qmldir" \
        qmldir_has "$qmldir" '^AgentsPage \./config_tab/pages/AgentsPage\.qml$'
    want "UnrestrictedBanner is registered in src/services/qmldir" \
        qmldir_has "$qmldir" '^UnrestrictedBanner agents/UnrestrictedBanner\.qml$'

    # ── criterion 2: one toggle, over the runtime's own default ──────────────
    want "the page carries exactly one switch" \
        test "$(code "$page" | grep -cE '^[[:space:]]*CfgSwitch \{')" -eq 1
    want "the switch is bound to the service's effective default" \
        has "$page" 'AgentPolicyService\.alwaysUnrestricted'
    want "the service writes the agent runtime's own configuration file" \
        has "$svc" 'configPath: root\.configHome \+ "/apex/agent\.json"'
    # apexd/apex-agent-core/src/paths.rs: config_home() is $XDG_CONFIG_HOME
    # when set and non-empty, else $HOME/.config. A shell that hardcoded
    # ~/.config would edit a file no session reads.
    want "the config path honours XDG_CONFIG_HOME the way paths.rs does" \
        has "$svc" 'Quickshell\.env\("XDG_CONFIG_HOME"\)'

    # ── criterion 3: one key moves, and the file is never clobbered ──────────
    want "the write goes through nextConfig rather than a hand-built object" \
        in_fn "$svc" 'function setAlwaysUnrestricted' 'Policy\.nextConfig\('
    want "the service never serialises a configuration of its own" \
        lacks "$svc" 'JSON\.stringify'
    want "nextConfig copies the parsed object before touching sandbox" \
        in_fn "$js" '^function nextConfig' 'for \(var k in parsed\.config\)'
    want "nextConfig sets the sandbox key and no other" \
        test "$(fn_body "$js" '^function nextConfig' \
                 | grep -cE '^[[:space:]]*next\.[a-z_]+ =')" -eq 1
    want "a file that would not parse is refused rather than replaced" \
        in_fn "$js" '^function nextConfig' 'if \(!parsed\.ok\)'

    # ── criterion 4: the password, and where it is not ───────────────────────
    want "the service asks polkit for the action the policy file declares" \
        has "$svc" 'actionId: "org\.apexos\.shell\.agent\.set-always-unrestricted"'
    want "the polkit action file declares that same id" \
        xml_has "$policy" '<action id="org\.apexos\.shell\.agent\.set-always-unrestricted">'
    # A malformed action file has exactly one symptom, forever: polkitd does not
    # register the action and pkcheck exits 127. Nothing else complains. This
    # one was malformed on its first draft, because an XML comment may not
    # contain a double hyphen and the comment quoted a pkcheck command line.
    # --nonet so the run does not depend on fetching the DTD.
    if command -v xmllint >/dev/null 2>&1; then
        want "the polkit action file is well-formed XML" \
            xmllint --noout --nonet "$policy"
    fi
    # Without --allow-user-interaction pkcheck exits 2 on a challenge and never
    # raises a prompt, so the toggle would refuse every time with no dialog.
    want "pkcheck is allowed to raise a prompt" \
        in_fn "$svc" 'property Process _authProc' '[-][-]allow-user-interaction'
    want "pkcheck is given a subject rather than left to guess one" \
        in_fn "$svc" 'property Process _authProc' '[-][-]process'
    # The setting grants no root and must not be authenticated as though it
    # did; auth_admin on a single-user machine teaches the user to type the
    # root password at a dialog that is not about root.
    want "the action authenticates the user, not an administrator" \
        xml_has "$policy" '<allow_active>auth_self</allow_active>'
    want "the authorization is not cached for the rest of the session" \
        xml_lacks "$policy" 'auth_self_keep|auth_admin_keep'
    want "an inactive session cannot authenticate it" \
        xml_has "$policy" '<allow_inactive>no</allow_inactive>'
    want "a session with nobody present cannot authenticate it" \
        xml_has "$policy" '<allow_any>no</allow_any>'
    want "the installer registers the action" \
        grep -qE '/usr/share/polkit-1/actions/org\.apexos\.shell\.agent\.policy' "$installer"
    # Criterion 7 at the process level. A root helper anywhere in this path
    # would make the setting a root grant whatever the copy says.
    want "nothing in the service runs as root" \
        lacks "$svc" '"(pkexec|sudo|su|doas|run0|systemd-run)"'
    want "nothing on the page runs as root" \
        lacks "$page" '"(pkexec|sudo|su|doas|run0|systemd-run)"'

    # ── criterion 5: disabling is immediate ──────────────────────────────────
    # The ordering, not the presence. `_authProc.running = true` belongs in
    # this function; being reachable before the requiresAuth guard is the bug,
    # and only an order check says that.
    want "the guard returns, so nothing reaches the prompt on the way out" \
        between_in_fn "$svc" 'function setAlwaysUnrestricted' \
            'if \(!Policy\.requiresAuth\(' '_authProc\.running' 'return'
    want "the immediate path writes and returns without a prompt" \
        in_fn "$svc" 'function setAlwaysUnrestricted' 'root\._write\(proposed\.text\)'
    want "requiresAuth is asked, rather than the direction being reimplemented" \
        in_fn "$svc" 'function setAlwaysUnrestricted' 'Policy\.requiresAuth\('
    want "the decision itself lives in the testable module" \
        has "$js" '^function requiresAuth\(from, to\)'

    # ── criterion 6: it persists, and the toggle follows the file ────────────
    want "the file is watched, so an edit outside the shell is picked up" \
        in_fn "$svc" 'readonly property FileView _file' 'watchChanges: true'
    want "the displayed default is derived from the file, not assigned" \
        has "$svc" 'readonly property string defaultSandbox: Policy\.effectiveDefault'
    want "the toggle state is derived too, so a failed write cannot flip it" \
        has "$svc" 'readonly property bool alwaysUnrestricted:'
    want "a successful write re-reads the file rather than assuming" \
        in_fn "$svc" 'property Process _writeProc' 'root\._file\.reload\(\)'
    # A crash mid-write must not leave a truncated JSON the runtime then reads
    # as the defaults.
    want "the write is atomic" \
        in_fn "$svc" 'function _write' 'mv "\$1\.tmp" "\$1"'
    want "the file is written private" \
        in_fn "$svc" 'function _write' 'umask 077'
    # The JSON goes in as a positional argument. Concatenated into the command
    # string it would be shell syntax, and its contents are a file the user and
    # apex both write.
    want "the JSON is passed as an argument, never spliced into the script" \
        in_fn "$svc" 'function _write' '"--", root\.configPath, text\]'
    want "the script body reads the JSON positionally" \
        in_fn "$svc" 'function _write' '\$2'

    # ── criterion 8: a running session reports its own mode ──────────────────
    want "the session row shows a sandbox mode at all" \
        has "$srow" 'sandboxMode: Policy\.sessionSandbox\(session\)'
    # The whole criterion. A row that could see the default would eventually
    # show it.
    want "the session row cannot see the default" \
        lacks "$srow" 'AgentPolicyService'
    want "sessionSandbox takes only the session, so it has no default to read" \
        has "$js" '^function sessionSandbox\(session\) \{'
    want "the page lists running sessions by their own recorded mode" \
        has "$page" 'Policy\.sessionSandbox\(modelData\)'
    want "the page says out loud that a running session keeps its mode" \
        has "$page" 'keeps the mode it started with'

    # ── criterion 9: the indicator ───────────────────────────────────────────
    want "the Agent Center draws the banner" \
        has "$centre" 'UnrestrictedBanner \{'
    want "the banner appears exactly while the default is unrestricted" \
        in_fn "$centre" 'UnrestrictedBanner \{' \
            'visible: AgentPolicyService\.alwaysUnrestricted'
    want "the settings page draws the same banner" \
        has "$page" 'UnrestrictedBanner \{'
    want "the banner names the setting it is reporting" \
        has "$banner" 'Always Unrestricted is on'

    # ── criterion 7: what the copy claims ────────────────────────────────────
    local copy
    copy="$(extract_copy "$page" "$banner")"
    want "the copy says the sandbox is what goes away" \
        grep -qE 'no APEX sandbox|read and write every file' <<<"$copy"
    want "the copy says root is not granted" \
        grep -qE 'no_new_privs|not root' <<<"$copy"
    want "the copy says secrets stay brokered" \
        grep -qiE 'broker' <<<"$copy"
    want "the copy says the agent's own permission mode is untouched" \
        grep -qE 'bypassPermissions' <<<"$copy"
    # apex-agent-core asserts no root and no raw secret export. It asserts
    # nothing about the session being safe, and an unrestricted session reaches
    # every file the user can.
    want "the copy does not call the mode safe or secure" \
        bash -c '! grep -qiE "\\b(safe|secure|protected|sandboxed and)\\b" <<<"$1"' _ "$copy"
    # The residual, stated next to the switch that creates it — and stated as
    # what it is. `no_new_privs` closes sudo INSIDE a session; the way out is a
    # file the session wrote that the user's own shell runs later.
    want "the copy states the residual an unconfined session leaves" \
        grep -qE 'shell startup files|git hook' <<<"$copy"
    want "the copy does not claim sudo works inside a session" \
        bash -c '! grep -qiE "sudo timestamp" <<<"$1"' _ "$copy"
}

echo "── checks ──"
check_tree "$repo"
real_pass=$pass
real_fail=$fail
echo "passed=$real_pass failed=$real_fail"

# ── the pure logic, against the file the shell loads ─────────────────────────
if command -v node >/dev/null 2>&1; then
    if (cd "$repo" && node tests/agent-policy-test.js >/dev/null 2>&1); then
        echo "  PASS  tests/agent-policy-test.js"
    else
        echo "  FAIL  tests/agent-policy-test.js"
        real_fail=$((real_fail + 1))
    fi
else
    echo "  skip  tests/agent-policy-test.js: node not installed"
fi

# ── the copy reads clean ─────────────────────────────────────────────────────
slop="$HOME/.claude/skills/stop-slop/scripts/slopcheck.py"
if [ -f "$slop" ]; then
    tmpcopy="$(mktemp)"
    extract_copy "$repo/src/services/config_tab/pages/AgentsPage.qml" \
                 "$repo/src/services/agents/UnrestrictedBanner.qml" > "$tmpcopy"
    out="$(cd "$repo" && python3 "$slop" --allow-file .slopcheck-allow "$tmpcopy" 2>&1)"
    rm -f "$tmpcopy"
    if printf '%s' "$out" | grep -q "TOTAL: 0"; then
        echo "  PASS  the page's copy reads clean against the stop-slop rules"
    else
        printf '%s\n' "$out" | head -20
        echo "  FAIL  the page's copy trips the stop-slop rules"
        real_fail=$((real_fail + 1))
    fi
else
    echo "  skip  stop-slop rules: $slop not installed"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  Self-test: do these checks have teeth, and can prose turn them red?
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "── self-test: mutants ──"

MUT="$(mktemp -d)"
trap 'rm -rf "$MUT"' EXIT INT TERM

FILES=(
    src/services/agentpolicy.js
    src/services/AgentPolicyService.qml
    src/services/config_tab/pages/AgentsPage.qml
    src/services/agents/UnrestrictedBanner.qml
    src/services/agents/SessionRow.qml
    src/services/agents/AgentCenter.qml
    src/services/qmldir
    src/nexus/PageRegistry.qml
    dots-extra/polkit/org.apexos.shell.agent.policy
    dots-extra/install-arch.sh
)

fresh_copy() {
    local dst="$1"
    rm -rf "$dst"
    mkdir -p "$dst/src/services/agents" "$dst/src/services/config_tab/pages" \
             "$dst/src/nexus" "$dst/dots-extra/polkit"
    local f
    for f in "${FILES[@]}"; do cp "$repo/$f" "$dst/$f"; done
}

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
fresh_copy "$MUT/base"
expect "an unmutated copy is green" "$MUT/base" green

# ── forward mutants ──────────────────────────────────────────────────────────

# The one this whole file exists for: the prompt raised before the direction is
# decided, so switching OFF asks for a password too. Every string in the
# function is still present, which is why the check is an order and not a grep.
fresh_copy "$MUT/m1"
python3 - "$MUT/m1/src/services/AgentPolicyService.qml" <<'M1'
import sys
p = sys.argv[1]
s = open(p).read()
old = """        if (!Policy.requiresAuth(root.defaultSandbox, want)) {
            root._write(proposed.text)
            return
        }

        root._pendingText = proposed.text"""
new = """        root._pendingText = proposed.text
        if (!Policy.requiresAuth(root.defaultSandbox, want)) {
            root._write(proposed.text)
        }"""
assert old in s, "the auth branch anchor moved"
open(p, "w").write(s.replace(old, new))
M1
assert_changed "$MUT/m1" src/services/AgentPolicyService.qml \
    && expect "a prompt reachable on the way out is caught" "$MUT/m1" red

# The prompt that never appears. pkcheck without -u exits 2 on a challenge, so
# the toggle refuses every time and no dialog is ever drawn.
fresh_copy "$MUT/m2"
sed -i 's| --allow-user-interaction||' "$MUT/m2/src/services/AgentPolicyService.qml"
assert_changed "$MUT/m2" src/services/AgentPolicyService.qml \
    && expect "pkcheck that cannot prompt is caught" "$MUT/m2" red

# A root helper in a path that grants no root.
fresh_copy "$MUT/m3"
sed -i 's|"sh", "-c",\n|&|; s|command: \["sh", "-c",|command: ["pkexec", "sh", "-c",|' \
    "$MUT/m3/src/services/AgentPolicyService.qml"
assert_changed "$MUT/m3" src/services/AgentPolicyService.qml \
    && expect "a root helper in the write path is caught" "$MUT/m3" red

# The action asking the wrong question.
fresh_copy "$MUT/m4"
sed -i 's|<allow_active>auth_self</allow_active>|<allow_active>auth_admin_keep</allow_active>|' \
    "$MUT/m4/dots-extra/polkit/org.apexos.shell.agent.policy"
assert_changed "$MUT/m4" dots-extra/polkit/org.apexos.shell.agent.policy \
    && expect "an admin-authenticated, cached action is caught" "$MUT/m4" red

# Criterion 8's failure, and the one that looks harmless in review: the row
# reads the default, so moving the toggle relabels running agents.
fresh_copy "$MUT/m5"
sed -i 's|sandboxMode: Policy.sessionSandbox(session)|sandboxMode: AgentPolicyService.defaultSandbox|' \
    "$MUT/m5/src/services/agents/SessionRow.qml"
assert_changed "$MUT/m5" src/services/agents/SessionRow.qml \
    && expect "a session row reading the default is caught" "$MUT/m5" red

# The path that edits a file no session reads.
fresh_copy "$MUT/m6"
python3 - "$MUT/m6/src/services/AgentPolicyService.qml" <<'M6'
import re, sys
p = sys.argv[1]
s = open(p).read()
old = 'const x = Quickshell.env("XDG_CONFIG_HOME")'
new = 'const x = ""'
assert old in s, "the config-home anchor moved"
open(p, "w").write(s.replace(old, new))
M6
assert_changed "$MUT/m6" src/services/AgentPolicyService.qml \
    && expect "a config path that ignores XDG_CONFIG_HOME is caught" "$MUT/m6" red

# The write that becomes shell syntax.
fresh_copy "$MUT/m7"
python3 - "$MUT/m7/src/services/AgentPolicyService.qml" <<'M7'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''            "--", root.configPath, text]'''
new = '''            "--", root.configPath]'''
assert old in s, "the write argv anchor moved"
open(p, "w").write(s.replace(old, new))
M7
assert_changed "$MUT/m7" src/services/AgentPolicyService.qml \
    && expect "JSON that is not passed positionally is caught" "$MUT/m7" red

# The action file that will never register. Its only symptom in the wild is
# pkcheck exiting 127 forever, which reads as "not installed".
fresh_copy "$MUT/m12"
sed -i 's|<vendor>APEX Shell</vendor>|<vendor>APEX Shell</vendor|' \
    "$MUT/m12/dots-extra/polkit/org.apexos.shell.agent.policy"
assert_changed "$MUT/m12" dots-extra/polkit/org.apexos.shell.agent.policy \
    && expect "a polkit action file that will not parse is caught" "$MUT/m12" red

# The banner that stops reporting anything.
fresh_copy "$MUT/m8"
sed -i 's|visible: AgentPolicyService.alwaysUnrestricted|visible: false|' \
    "$MUT/m8/src/services/agents/AgentCenter.qml"
assert_changed "$MUT/m8" src/services/agents/AgentCenter.qml \
    && expect "an indicator that never appears is caught" "$MUT/m8" red

# The copy that oversells the boundary.
fresh_copy "$MUT/m9"
sed -i 's|"New sessions read and write any file you can."|"New sessions are still sandboxed and secure."|' \
    "$MUT/m9/src/services/config_tab/pages/AgentsPage.qml"
assert_changed "$MUT/m9" src/services/config_tab/pages/AgentsPage.qml \
    && expect "copy calling an unconfined session secure is caught" "$MUT/m9" red

# The page that exists and cannot be reached.
fresh_copy "$MUT/m10"
sed -i 's|"id": "agents",|"id": "agents-disabled",|' "$MUT/m10/src/nexus/PageRegistry.qml"
assert_changed "$MUT/m10" src/nexus/PageRegistry.qml \
    && expect "a page missing from the registry is caught" "$MUT/m10" red

# nextConfig moving a second dimension. Criterion 3 is the one dimension that
# must not follow the sandbox, and a write that reset it would be invisible
# until somebody's Claude started asking for confirmations again.
fresh_copy "$MUT/m11"
sed -i 's|    next.sandbox = on ? UNRESTRICTED : DEFAULT_SANDBOX;|    next.sandbox = on ? UNRESTRICTED : DEFAULT_SANDBOX;\n    next.native = "inherit";|' \
    "$MUT/m11/src/services/agentpolicy.js"
assert_changed "$MUT/m11" src/services/agentpolicy.js \
    && expect "a write that also moves dimension 1 is caught" "$MUT/m11" red

# ── the inverse mutant ───────────────────────────────────────────────────────
# Prose quoting each bug above, including the exact strings the greps look for.
# It must NOT turn anything red: a check a comment can break punishes people for
# explaining themselves, and a check a comment can SATISFY is worse.
fresh_copy "$MUT/c1"
{
    echo '// An early draft ran the prompt first:'
    echo '//     root._authProc.running = true'
    echo '// before it had asked  if (!Policy.requiresAuth(from, to))  at all,'
    echo '// so switching OFF wanted a password. It also called'
    echo '//     command: ["pkexec", "sh", "-c", ...]'
    echo '// for a setting that grants no root, dropped --allow-user-interaction'
    echo '// so no dialog was ever drawn, hardcoded'
    echo '//     const x = ""'
    echo '// instead of reading XDG_CONFIG_HOME, and spliced the JSON in with'
    echo '//     "sh", "-c", "echo " + text + " > " + path'
    echo '// None of that is here now.'
} >> "$MUT/c1/src/services/AgentPolicyService.qml"
{
    echo '// This row used to read AgentPolicyService.defaultSandbox, which'
    echo '// relabelled four running agents the moment somebody moved a toggle.'
    echo '//     sandboxMode: AgentPolicyService.defaultSandbox'
} >> "$MUT/c1/src/services/agents/SessionRow.qml"
{
    echo '// The first copy said the session was still sandboxed and secure,'
    echo '// which is safe-sounding and false: an unrestricted session reaches'
    echo '// every file the user can.'
} >> "$MUT/c1/src/services/config_tab/pages/AgentsPage.qml"
{
    echo '// visible: false   <- was hardcoded during bring-up'
} >> "$MUT/c1/src/services/agents/AgentCenter.qml"
{
    echo '// nextConfig once wrote next.native = "inherit" alongside the sandbox.'
} >> "$MUT/c1/src/services/agentpolicy.js"
assert_changed "$MUT/c1" src/services/AgentPolicyService.qml \
    && expect "prose quoting every one of these bugs stays green" "$MUT/c1" green

echo
echo "self-test: mutants applied=$mutated, failed-to-apply=$unmutated"
echo "self-test passed=$selfpass failed=$selffail"

[ "$real_fail" -eq 0 ] && [ "$selffail" -eq 0 ] && [ "$unmutated" -eq 0 ]
