#!/usr/bin/env bash
# Static invariants for §19's recovery surface and §25's "recovery and rollback
# are normal UX, not expert documentation".
#
# ── Why this exists next to tests/recovery-test.js ───────────────────────────
# The node suite drives src/services/recovery.js, which is the part with
# branches. It cannot see the QML: whether the sweep is gated on refCount,
# whether a Timer can reach a mutating verb, whether the commit button is
# gated on the rendered loss list, or whether a Repeater took an array model
# and quietly rebuilt every delegate. Each of those is one careless edit away
# from regressing with NO visible symptom — a panel that polls forever costs
# battery silently; a commit reachable without the loss list erases somebody's
# settings without showing them what went.
#
# ── THE FOUR WAYS A GREP-STYLE CHECK LIES HERE ──────────────────────────────
#
# 1. A COMMENT SATISFIES IT. Five checks in this project have been satisfied by
#    the prose in the very file they guarded. Every check below runs against
#    comment-stripped input, and the last mutant is prose quoting every bug
#    this file forbids — it must stay GREEN.
#
# 2. ANOTHER LINE OF REAL CODE SATISFIES IT. `root._proc.running = false`
#    appears in three functions here, so "the file contains it" would still
#    pass after the kill was deleted from `_standDown`. Checks that care about
#    WHERE something is are scoped to a function body by `fn_body`.
#
# 3. THE MUTANT NEVER APPLIED. A self-test that mutates a copy and watches it
#    go red proves nothing if the edit matched nothing — the copy is then
#    identical and the verdict is about the original. Every mutant is diffed
#    against its source and a mutant that did not apply is a hard failure.
#
# 4. THE PIPE LIED. `producer | grep -q` under `set -o pipefail` returns the
#    PRODUCER's status when grep exits early on a match: grep closes the pipe,
#    the producer takes SIGPIPE and dies 141, and pipefail makes 141 the
#    verdict. The same pattern therefore gives opposite answers depending on
#    where in a file the match is. Every helper below captures into a variable
#    instead — including `in_fn`, which is the one that would otherwise report
#    a function clean because its match was near the top.
#
# PASS = nothing on a timer can change the machine, no argv here is
#        privileged, the confirm token is never constructed, the commit is
#        gated on a rendered loss list, and every list is an integer model.
#
# Run from anywhere: ./tests/check-recovery-ui.sh
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
# Whole-line comments only. A trailing comment on a real line of code is fine:
# the code is still there, which is what these checks ask about.
code()       { grep -vE '^[[:space:]]*//' "$1" 2>/dev/null; }
qmldircode() { grep -vE '^[[:space:]]*#'  "$1" 2>/dev/null; }

# No pipes into `grep -q`. See point 4 in the header.
has()        { local _c; _c=$(code "$1");       grep -qE "$2" <<<"$_c"; }
lacks()      { local _c; _c=$(code "$1");     ! grep -qE "$2" <<<"$_c"; }
qmldir_has() { local _c; _c=$(qmldircode "$1"); grep -qE "$2" <<<"$_c"; }
count_in()   { local _c; _c=$(code "$1"); grep -cE "$2" <<<"$_c"; }

# fn_body <file> <ERE matching the opening line> — that declaration's body,
# ending at the first closing brace indented the same as the opening line,
# comments stripped. This is what makes "the plan is dropped in _standDown"
# mean that, rather than "the string appears somewhere in the file".
fn_body() {
    FN_PAT="$2" awk '
        !inside && $0 ~ ENVIRON["FN_PAT"] { inside = 1; indent = match($0, /[^ ]/); print; next }
        inside {
            print
            if ($0 ~ /^[ ]*\}/ && match($0, /[^ ]/) == indent) exit
        }
    ' "$1" 2>/dev/null | grep -vE '^[[:space:]]*//'
}

# in_fn / not_in_fn <file> <opening-line ERE> <ERE>. Captured, never piped.
in_fn()     { local _b; _b=$(fn_body "$1" "$2");   grep -qE "$3" <<<"$_b"; }
not_in_fn() { local _b; _b=$(fn_body "$1" "$2"); ! grep -qE "$3" <<<"$_b"; }
# A function that does not exist has an empty body, and `not_in_fn` on an empty
# body is trivially true — which would turn a deleted function into a pass. So
# every not_in_fn below is paired with a "the function exists" check.
fn_exists() { local _b; _b=$(fn_body "$1" "$2"); [ -n "$_b" ]; }

check_tree() {
    local r="$1"
    local js="$r/src/services/recovery.js"
    local svc="$r/src/services/RecoveryService.qml"
    local page="$r/src/services/config_tab/pages/RecoveryPage.qml"
    local reg="$r/src/nexus/PageRegistry.qml"
    local qmldir="$r/src/services/qmldir"

    # ── the parts exist ──────────────────────────────────────────────────────
    # First and unconditionally. Every check below is a grep, and a grep
    # against a file that is not there finds nothing — which every `lacks`
    # check would happily read as a pass.
    local f
    for f in "$js" "$svc" "$page" "$reg" "$qmldir"; do
        want "$(basename "$f") exists and is non-empty" test -s "$f"
    done

    # ── 1. only two verbs are polled, and they are the safe two ──────────────
    # `apex recover status --json` and `apex doctor --json` are file reads on
    # the OS side: no subprocess, no network, no authentication. Everything
    # else in `apex recover` changes the machine.
    want "the sweep's argv table names 'recover status --json'" \
        has "$svc" 'status: \["apex", "recover", "status", "--json"\]'
    want "the sweep's argv table names 'doctor --json'" \
        has "$svc" 'doctor: \["apex", "doctor", "--json"\]'
    want "the sweep's argv table has exactly those two entries" \
        test "$(in_fn "$svc" 'readonly property var _stepArgv' '.' && \
                fn_body "$svc" 'readonly property var _stepArgv' | grep -cE '^\s+(status|doctor):')" = 2

    # No poller can reach a mutating verb. The sweep runs ONE process and takes
    # its argv from `_stepArgv`, so this is the whole surface a timer can name.
    want "the polled process takes its argv from the table, not from a literal" \
        in_fn "$svc" 'function _next\(\)' '_proc\.command = root\._stepArgv\[step\]'
    want "_next() exists to be checked" fn_exists "$svc" 'function _next\(\)'
    want "nothing in _next() can commit" \
        not_in_fn "$svc" 'function _next\(\)' '[-]-commit'
    want "the sweep's argv table cannot commit" \
        not_in_fn "$svc" 'readonly property var _stepArgv' '[-]-commit|reset|repair'

    # ── 2. no argv here is privileged ────────────────────────────────────────
    # `sudo apex rollback` and `sudo apex recover repair --commit` appear in
    # this file as strings SHOWN to the user; neither is ever executed. The
    # distinction is that an executed argv is a JSON-ish array assigned to a
    # `command`, so that is what is scanned.
    local argvs
    argvs=$(code "$svc" | grep -E '(^|[^a-zA-Z])command\s*[:=]\s*\[' || true)
    want "every executed argv starts with apex" \
        test -z "$(grep -vE 'command\s*[:=]\s*\[\]' <<<"$argvs" | grep -vE '\[\s*"apex"' || true)"
    want "no executed argv names sudo, pkexec, run0 or systemd-run" \
        test -z "$(grep -E '"(sudo|pkexec|su|run0|systemd-run)"' <<<"$argvs" || true)"
    want "recovery.js builds no argv that is not apex's" \
        test -z "$(code "$js" | grep -E '^\s*return \["' | grep -vE 'return \["apex"' || true)"

    # ── 3. the confirm token is evidence, never a parameter ──────────────────
    # apexd derives it from the scope AND the exact paths the plan found,
    # specifically so a UI cannot commit without having rendered the loss list.
    want "exactly one place in recovery.js can emit --commit" \
        test "$(count_in "$js" '"--commit"')" = 1
    want "…and it is commitArgv" \
        in_fn "$js" 'function commitArgv' '"--commit"'
    want "planArgv exists to be checked" fn_exists "$js" 'function planArgv'
    want "the dry run's builder cannot emit --commit" \
        not_in_fn "$js" 'function planArgv' '[-]-commit'
    want "nothing in recovery.js constructs a token from a scope" \
        lacks "$js" 'confirmToken\s*=|scope \+ ":"|":" \+ .*count'

    # Each refusal, named. A single "it refuses bad input" assertion passes
    # while three of the four guards are missing.
    want "commitArgv refuses a plan that did not parse" \
        in_fn "$js" 'function commitArgv' '!plan\.ok'
    want "commitArgv refuses a token that is not this plan's" \
        in_fn "$js" 'function commitArgv' 'token !== plan\.confirmToken'
    want "commitArgv refuses a token for another scope" \
        in_fn "$js" 'function commitArgv' 'tokenScope\(token\) !== plan\.scope'
    want "commitArgv refuses a rendered count unequal to the plan's" \
        in_fn "$js" 'function commitArgv' 'renderedCount !== plan\.losses\.length'
    want "commitArgv refuses a rendered count unequal to the TOKEN's" \
        in_fn "$js" 'function commitArgv' 'renderedCount !== tokenCount\(token\)'

    # ── 4. the commit goes through that function, and only that function ─────
    want "commitReset() exists to be checked" fn_exists "$svc" 'function commitReset\(\)'
    want "commitReset builds its argv through recovery.js" \
        in_fn "$svc" 'function commitReset\(\)' 'Rec\.commitArgv\('
    want "commitReset assembles no argv of its own" \
        not_in_fn "$svc" 'function commitReset\(\)' '[-]-confirm|[-]-commit'
    want "a refused argv aborts rather than being repaired" \
        in_fn "$svc" 'function commitReset\(\)' 'if \(!argv\)'
    want "planReset() exists to be checked" fn_exists "$svc" 'function planReset\(scope\)'
    want "planReset cannot commit" \
        not_in_fn "$svc" 'function planReset\(scope\)' '[-]-commit'

    # ── 5. a token never outlives the list it was printed with ───────────────
    want "_standDown() exists to be checked" fn_exists "$svc" 'function _standDown\(\)'
    want "handing back the last reference drops the plan" \
        in_fn "$svc" 'function _standDown\(\)' '_dropPlan\(\)'
    want "the acknowledgement is checked against the plan's own token" \
        in_fn "$svc" 'function acknowledgeLossList' 'token !== root\.plan\.confirmToken'
    want "a list that goes away revokes its acknowledgement" \
        has "$svc" 'function revokeLossList\(\)'
    want "the page revokes on destruction" \
        has "$page" 'Component\.onDestruction: RecoveryService\.revokeLossList\(\)'
    want "the page acknowledges from the list that rendered the rows" \
        has "$page" 'RecoveryService\.acknowledgeLossList\(lossList\.plan\.confirmToken'
    want "the acknowledged count is the Repeater's own count" \
        has "$page" 'readonly property int shown: lossRepeater\.count'

    # ── 6. the erase button cannot appear before the list does ───────────────
    want "the danger fill is used exactly once in the page" \
        test "$(count_in "$page" 'Theme\.dangerFill\b')" = 1
    want "…and its hover pair exactly once" \
        test "$(count_in "$page" 'Theme\.dangerFillHover')" = 1
    want "the erase button is gated on commitReady" \
        has "$page" 'visible: RecoveryService\.commitReady'
    want "commitReady is derived from commitArgv, not from a flag" \
        has "$svc" 'Rec\.commitArgv\(root\.plan, root\._ackCount, root\._ackToken\) !== null'
    want "the reset disclosure starts closed" \
        has "$page" 'property bool resetOpen: false'
    want "the wider scope is never the preselected one" \
        has "$page" 'property string chosen: "desktop"'

    # ── 7. nothing runs while nobody is looking ──────────────────────────────
    want "the service exposes the refcount ServiceRef expects" \
        has "$svc" '^\s*property int refCount: 0'
    want "demand dropping to zero stands the service down" \
        in_fn "$svc" 'onRefCountChanged:' '_standDown\(\)'
    want "a sweep will not start unwatched" \
        in_fn "$svc" 'function _beginSweep\(force\)' 'refCount <= 0 && !force'
    want "the cooldown re-arms only while watched" \
        in_fn "$svc" 'function _sweepDone\(\)' 'if \(root\.refCount > 0\) root\._cooldown\.restart\(\)'
    want "the in-flight guard includes the between-steps window" \
        in_fn "$svc" 'function _beginSweep\(force\)' '_pending !== "" \|\| root\._advance\.running'
    want "the page holds a ServiceRef bound to being on screen" \
        has "$page" 'active:  root\.onScreen'
    want "the page is registered as needing the screen" \
        has "$reg" '"needsScreen": true'
    want "the recovery page is in the registry" \
        has "$reg" '"id": "recovery"'
    want "…with a component that builds it" \
        has "$reg" 'RecoveryPage \{\}'
    want "the service is a singleton in the qmldir" \
        qmldir_has "$qmldir" '^singleton RecoveryService 1\.0 RecoveryService\.qml$'
    want "the page is in the qmldir" \
        qmldir_has "$qmldir" '^RecoveryPage \./config_tab/pages/RecoveryPage\.qml$'

    # ── 8. every list is an integer model ────────────────────────────────────
    # `model: <JS array>` recreates every delegate whenever the array's
    # contents change — measured on Qt 6.10.3 in Workspaces.qml. `state` and
    # `detail` change on every sweep, so an array model would destroy and
    # rebuild all eight component rows every 20 seconds, killing the colour
    # Behaviour and flickering the list.
    want "no Repeater in the page takes an array model" \
        test -z "$(code "$page" | grep -E '^\s*model:' | grep -vE '\.length' || true)"
    want "…and there are lists to have got that wrong on" \
        test "$(count_in "$page" '^\s*model:')" -ge 5
    want "the delegates look their entry up by index" \
        test "$(count_in "$page" 'required property int index')" -ge 4

    # ── 9. an exit code is not a health verdict ──────────────────────────────
    # `apex recover status` exits 1 when anything needs attention, and
    # `apex doctor` always exits 0. Reading either as pass/fail inverts it.
    want "parseStatus exists to be checked" fn_exists "$js" 'function parseStatus'
    want "parseStatus does not branch on the exit code" \
        not_in_fn "$js" 'function parseStatus' 'exitCode [!=]=='
    want "parseDoctor exists to be checked" fn_exists "$js" 'function parseDoctor'
    want "parseDoctor does not branch on the exit code" \
        not_in_fn "$js" 'function parseDoctor' 'exitCode [!=]=='
    want "the four states are all still distinguished" \
        test "$(code "$js" | grep -cE '^\s+(verified|available|attention|unavailable):\s*"')" -ge 8
    want "available is not given the ok tone" \
        has "$js" '^\s+available:\s+"neutral"'
    want "unavailable is not given the ok tone" \
        has "$js" '^\s+unavailable:\s+"neutral"'
    want "an unrecognised state degrades away from verified" \
        in_fn "$js" 'function normalizeState' 'STATE\.UNAVAILABLE'

    # ── 10. the headless suite is real and passes ────────────────────────────
    # Asserted here so one command covers both halves, and so a check-only run
    # cannot report green while the logic under it is broken.
    # The redirection has to live INSIDE a helper, not after `want`: a
    # `want … node x >/dev/null` redirects `want`'s own stdout, which silently
    # swallows the PASS line and makes the assertion invisible. It did exactly
    # that in the first draft of this file.
    node_suite_passes() { node "$1" >/dev/null 2>&1; }
    if command -v node >/dev/null 2>&1; then
        want "the headless recovery suite passes" node_suite_passes "$r/tests/recovery-test.js"
    else
        bad "node is required to run tests/recovery-test.js"
    fi
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
    src/services/recovery.js
    src/services/RecoveryService.qml
    src/services/config_tab/pages/RecoveryPage.qml
    src/nexus/PageRegistry.qml
    src/services/qmldir
    tests/recovery-test.js
)

fresh_copy() {
    local dst="$1"
    rm -rf "$dst"
    mkdir -p "$dst/src/services/config_tab/pages" "$dst/src/nexus" "$dst/tests"
    local f
    for f in "${FILES[@]}"; do cp "$repo/$f" "$dst/$f"; done
}

# THE GUARD THE WHOLE SELF-TEST RESTS ON. A python replace that matched
# nothing leaves the copy byte-identical, and then the verdict — red or green
# — is about the ORIGINAL file and means nothing.
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

# verdict <dir> — "green 0" or "red <n>", from a quiet run of the same checks.
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
# max-broken bounds how many checks a red mutant may break. A targeted mutant
# breaks one or two; one that breaks fifteen has damaged the copy, which is a
# different outcome and must not read as success.
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

edit() {
    # edit <dir> <relpath> <python-source>. The source gets `p` (the Path) and
    # `s` (its text) and must write the result.
    local dst="$1" rel="$2"
    python3 - "$dst/$rel" <<PY
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
$3
PY
}

# ── 0. the baseline ──────────────────────────────────────────────────────────
# Without this, a mutant that came out red because the copy was EMPTY would
# look like a working check.
fresh_copy "$MUT/base"
expect "an unmutated copy is green" "$MUT/base" green

# ── 1. a mutating verb put on the sweep ──────────────────────────────────────
fresh_copy "$MUT/m1"
edit "$MUT/m1" src/services/RecoveryService.qml \
    's = s.replace(
        "doctor: [\"apex\", \"doctor\", \"--json\"]",
        "doctor: [\"apex\", \"recover\", \"repair\", \"--commit\", \"--json\"]", 1)
p.write_text(s)'
assert_changed "$MUT/m1" src/services/RecoveryService.qml \
    && expect "a mutating verb on the sweep timer is caught" "$MUT/m1" red 4

# ── 2. the commit argv hand-built in QML ─────────────────────────────────────
fresh_copy "$MUT/m2"
edit "$MUT/m2" src/services/RecoveryService.qml \
    's = s.replace(
        "const argv = Rec.commitArgv(root.plan, root._ackCount, root._ackToken)",
        "const argv = [\"apex\", \"recover\", \"reset\", \"--scope\", root.plan.scope, \"--commit\", \"--confirm\", root.plan.confirmToken]", 1)
p.write_text(s)'
assert_changed "$MUT/m2" src/services/RecoveryService.qml \
    && expect "a commit argv assembled outside recovery.js is caught" "$MUT/m2" red 3

# ── 3. the rendered-count guard removed ──────────────────────────────────────
# The one that matters most: with this gone, a commit can go out against a loss
# list the user never saw in full.
fresh_copy "$MUT/m3"
edit "$MUT/m3" src/services/recovery.js \
    's = s.replace(
        "    if (renderedCount !== plan.losses.length) return null;",
        "    // the list is rendered by then anyway", 1)
p.write_text(s)'
assert_changed "$MUT/m3" src/services/recovery.js \
    && expect "dropping the rendered-count guard is caught" "$MUT/m3" red 2

# ── 4. the token compared loosely ────────────────────────────────────────────
fresh_copy "$MUT/m4"
edit "$MUT/m4" src/services/recovery.js \
    's = s.replace(
        "    if (token !== plan.confirmToken)          return null;",
        "    if (!looksLikeToken(token))               return null;", 1)
p.write_text(s)'
assert_changed "$MUT/m4" src/services/recovery.js \
    && expect "accepting any well-formed token is caught" "$MUT/m4" red 2

# ── 5. the sweep left ungated ────────────────────────────────────────────────
fresh_copy "$MUT/m5"
edit "$MUT/m5" src/services/RecoveryService.qml \
    's = s.replace(
        "        if (root.refCount > 0) root._cooldown.restart()",
        "        root._cooldown.restart()", 1)
p.write_text(s)'
assert_changed "$MUT/m5" src/services/RecoveryService.qml \
    && expect "a cooldown that re-arms unwatched is caught" "$MUT/m5" red 2

# ── 6. the plan surviving a close ────────────────────────────────────────────
fresh_copy "$MUT/m6"
edit "$MUT/m6" src/services/RecoveryService.qml \
    's = s.replace(
        "        root._dropPlan()\n    }\n\n    onRefCountChanged:",
        "    }\n\n    onRefCountChanged:", 1)
p.write_text(s)'
assert_changed "$MUT/m6" src/services/RecoveryService.qml \
    && expect "a confirm token that outlives the panel is caught" "$MUT/m6" red 2

# ── 7. an array model ────────────────────────────────────────────────────────
fresh_copy "$MUT/m7"
edit "$MUT/m7" src/services/config_tab/pages/RecoveryPage.qml \
    's = s.replace(
        "model: RecoveryService.status.rows.length",
        "model: RecoveryService.status.rows", 1)
p.write_text(s)'
assert_changed "$MUT/m7" src/services/config_tab/pages/RecoveryPage.qml \
    && expect "an array model that would rebuild every delegate is caught" "$MUT/m7" red 2

# ── 8. `available` painted as fine ───────────────────────────────────────────
fresh_copy "$MUT/m8"
edit "$MUT/m8" src/services/recovery.js \
    's = s.replace("    available:   \"neutral\",", "    available:   \"ok\",", 1)
p.write_text(s)'
assert_changed "$MUT/m8" src/services/recovery.js \
    && expect "painting an unverified rollback target green is caught" "$MUT/m8" red 3

# ── 9. an exit code read as a health verdict ─────────────────────────────────
fresh_copy "$MUT/m9"
edit "$MUT/m9" src/services/recovery.js \
    's = s.replace(
        "    var doc = parseJson(text);\n    if (!doc)\n        return EMPTY_STATUS;",
        "    if (exitCode !== 0) return EMPTY_STATUS;\n    var doc = parseJson(text);\n    if (!doc)\n        return EMPTY_STATUS;", 1)
p.write_text(s)'
assert_changed "$MUT/m9" src/services/recovery.js \
    && expect "blanking the panel on a status that exited 1 is caught" "$MUT/m9" red 3

# ── 10. a privileged argv ────────────────────────────────────────────────────
fresh_copy "$MUT/m10"
edit "$MUT/m10" src/services/RecoveryService.qml \
    's = s.replace(
        "        status: [\"apex\", \"recover\", \"status\", \"--json\"],",
        "        status: [\"pkexec\", \"apex\", \"recover\", \"status\", \"--json\"],", 1)
p.write_text(s)'
assert_changed "$MUT/m10" src/services/RecoveryService.qml \
    && expect "a privileged argv anywhere in the service is caught" "$MUT/m10" red 4

# ── 11. the page unregistered ────────────────────────────────────────────────
# The whole gap this closes is "recovery exists in the CLI and nowhere a user
# can see it". A page nobody can reach is that gap again.
fresh_copy "$MUT/m11"
edit "$MUT/m11" src/nexus/PageRegistry.qml \
    's = s.replace("\"id\": \"recovery\",", "\"id\": \"recovery-disabled\",", 1)
p.write_text(s)'
assert_changed "$MUT/m11" src/nexus/PageRegistry.qml \
    && expect "removing the page from the registry is caught" "$MUT/m11" red 2

# ── the inverse mutant ───────────────────────────────────────────────────────
# Prose that would trip a naive version of every check above, including prose
# quoting the exact strings the greps look for. It must NOT turn anything red:
# a check a comment can break punishes people for explaining themselves, and
# this repository has shipped the opposite mistake — a check a comment could
# SATISFY — five times.
fresh_copy "$MUT/c1"
{
    echo '// An earlier draft polled the reset:'
    echo '//     doctor: ["apex", "recover", "reset", "--commit", "--json"]'
    echo '// and ran it through pkexec:'
    echo '//     status: ["pkexec", "apex", "recover", "status", "--json"]'
    echo '// It also built the argv by hand —'
    echo '//     const argv = ["apex", "recover", "reset", "--scope", s, "--commit", "--confirm", t]'
    echo '// — and re-armed the cooldown with no guard:'
    echo '//     root._cooldown.restart()'
    echo '// and left the plan alive across a close, by dropping _dropPlan()'
    echo '// from _standDown entirely. None of that is here now.'
} >> "$MUT/c1/src/services/RecoveryService.qml"
{
    echo '// The first version compared tokens loosely:'
    echo '//     if (!looksLikeToken(token)) return null;   // and nothing else'
    echo '// with no renderedCount !== plan.losses.length check at all, and it'
    echo '// blanked the panel on a status that exited 1:'
    echo '//     if (exitCode !== 0) return EMPTY_STATUS;'
    echo '// It also painted an unverified rollback target green:'
    echo '//     available:   "ok",'
} >> "$MUT/c1/src/services/recovery.js"
{
    echo '// This list used to be'
    echo '//     model: RecoveryService.status.rows'
    echo '// which rebuilt all eight delegates on every sweep.'
} >> "$MUT/c1/src/services/config_tab/pages/RecoveryPage.qml"
{
    echo '// "id": "recovery-disabled",   <- was hidden during bring-up'
} >> "$MUT/c1/src/nexus/PageRegistry.qml"
assert_changed "$MUT/c1" src/services/RecoveryService.qml \
    && expect "prose quoting every one of these bugs stays green" "$MUT/c1" green

echo
echo "self-test: mutants applied=$mutated, failed-to-apply=$unmutated"
echo "self-test passed=$selfpass failed=$selffail"

[ "$real_fail" -eq 0 ] && [ "$selffail" -eq 0 ] && [ "$unmutated" -eq 0 ]
