#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-privacy-ui.sh — the structural rules of Config → Privacy & Permissions
#  (roadmap P1-061), which are all one rule: the page may never claim an
#  enforcement the machine does not have.
#
#  ── What cannot be checked by running it ────────────────────────────────────
#  This shell has no headless QML runner. A behavioural test would need a
#  compositor, and a page whose whole subject is privacy is the last thing that
#  should open a window on somebody's desktop to prove itself. So the logic
#  lives in src/services/permissions.js and tests/permissions-test.js drives it
#  under node; this file asserts the wiring that node cannot see.
#
#  ── The four things it holds ────────────────────────────────────────────────
#
#  1. NOTHING ON A TIMER CAN REVOKE ANYTHING. `apex permissions list --json`
#     writes nothing. `apex permissions revoke` writes to the permission store
#     or to an override file. A timer that reached the second would be a shell
#     that silently changed a machine's permissions while nobody was looking,
#     which is a worse defect than the one this page exists to fix.
#
#  2. EVERY ROW SHOWS THE ENFORCER BESIDE THE ANSWER. The bare tick is the
#     whole lie, and the page's row is asserted to render `enforcerLabel` as
#     well as `headline`.
#
#  3. A CONTROL COMES ONLY FROM `controlsFor`. Not from a `visible:` expression
#     somebody wrote by hand, which is how a button appears on a row that
#     cannot be revoked. `controlsFor` returns an empty list for such a row and
#     `revokeArgv` returns null even when called directly.
#
#  4. THE POLLER STOPS. PermissionsService costs one `apex permissions list`
#     per sweep, and that costs a `flatpak info` per installed application. The
#     page declares `onScreen`, PageRegistry marks it `needsScreen: true`, and
#     the timer runs on `refCount > 0`.
#
#  ── The self-test ───────────────────────────────────────────────────────────
#  Every check is a grep, and a grep that matches nothing passes a `lacks` and
#  fails nothing else. So the suite runs itself against deliberately broken
#  copies of the tree and asserts each one goes RED. A mutant that failed to
#  apply is a hard failure — it would otherwise be a green run that tested
#  nothing.
#
#  PASS = nothing on a timer changes the machine, no row renders an answer
#         without its enforcer, no control exists outside controlsFor, and the
#         poller is gated on the page being looked at.
#
#  Run from anywhere: ./tests/check-privacy-ui.sh
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

# Whole-line comments only. A trailing comment on a real line of code is fine:
# the code is still there, which is what these checks ask about.
code()       { grep -vE '^[[:space:]]*//' "$1" 2>/dev/null; }
qmldircode() { grep -vE '^[[:space:]]*#'  "$1" 2>/dev/null; }

# No pipes into `grep -q`: a pipeline's exit status under `set -o pipefail`
# reports the wrong end of it when the left side is a function.
has()        { local _c; _c=$(code "$1");       grep -qE "$2" <<<"$_c"; }
lacks()      { local _c; _c=$(code "$1");     ! grep -qE "$2" <<<"$_c"; }
qmldir_has() { local _c; _c=$(qmldircode "$1"); grep -qE "$2" <<<"$_c"; }

# That declaration's body, ending at the first closing brace indented the same
# as the opening line, comments stripped. This is what makes "no timer reaches
# revoke" mean that, rather than "the word revoke is somewhere in the file".
fn_body() {
    FN_PAT="$2" awk '
        !inside && $0 ~ ENVIRON["FN_PAT"] { inside = 1; indent = match($0, /[^ ]/); print; next }
        inside {
            print
            if ($0 ~ /^[ ]*\}/ && match($0, /[^ ]/) == indent) exit
        }
    ' "$1" 2>/dev/null | grep -vE '^[[:space:]]*//'
}
in_fn()     { local _b; _b=$(fn_body "$1" "$2");   grep -qE "$3" <<<"$_b"; }
not_in_fn() { local _b; _b=$(fn_body "$1" "$2"); ! grep -qE "$3" <<<"$_b"; }
# A function that does not exist has an empty body, and `not_in_fn` on an empty
# body is trivially true — which would turn a deleted function into a pass. So
# every not_in_fn below is paired with an existence check.
fn_exists() { local _b; _b=$(fn_body "$1" "$2"); [ -n "$_b" ]; }

check_tree() {
    local r="$1"
    local js="$r/src/services/permissions.js"
    local svc="$r/src/services/PermissionsService.qml"
    local page="$r/src/services/config_tab/pages/PrivacyPage.qml"
    local reg="$r/src/nexus/PageRegistry.qml"
    local qmldir="$r/src/services/qmldir"

    # ── the parts exist ──────────────────────────────────────────────────────
    # First and unconditionally: every check below is a grep, and a grep
    # against a missing file passes every `lacks` in the suite.
    for f in "$js" "$svc" "$page"; do
        want "$(basename "$f") exists" test -f "$f"
    done

    # ── 1. nothing on a timer can revoke ─────────────────────────────────────
    want "the polled command is the read-only one" \
        has "$svc" 'command = \["apex", "permissions", "list", "--json"\]'
    want "_beginSweep exists" fn_exists "$svc" 'function _beginSweep'
    want "the sweep cannot reach revoke" \
        not_in_fn "$svc" 'function _beginSweep' 'revoke'
    want "the sweep timer calls only _beginSweep" \
        has "$svc" 'onTriggered: root\._beginSweep\(false\)'
    want "revoke is reached from a press, never from a Timer's onTriggered" \
        lacks "$svc" 'onTriggered:.*revoke\('
    want "nothing here runs pkexec or sudo" \
        lacks "$svc" '(pkexec|sudo)'
    want "the page's only revoke call is a button press" \
        has "$page" 'onClicked: PermissionsService\.revoke\('
    want "the page starts no Timer of its own" \
        lacks "$page" '^[[:space:]]*Timer[[:space:]]*\{'

    # ── 2. the enforcer is rendered beside the answer ────────────────────────
    want "a row renders the headline" \
        has "$page" 'rowItem\.row\.headline'
    want "a row renders the enforcer beside it" \
        has "$page" 'rowItem\.row\.enforcerLabel'
    want "a row renders where the permission came from" \
        has "$page" 'rowItem\.row\.originLabel'
    want "a row renders when a change would land" \
        has "$page" 'rowItem\.row\.timingLabel'
    want "the page draws no CfgSwitch, which is the tick in another form" \
        lacks "$page" 'CfgSwitch'

    # ── 3. controls come only from controlsFor ───────────────────────────────
    want "the control list is the model for the buttons" \
        has "$page" 'model: rowItem\.controls\.length'
    want "controls come from the service, not from an inline expression" \
        has "$page" 'PermissionsService\.controlsFor\(rowItem\.row\)'
    want "controlsFor exists" fn_exists "$js" 'function controlsFor'
    want "controlsFor refuses a row that offers no control" \
        in_fn "$js" 'function controlsFor' 'if \(!row\.offersControl\)'
    want "revokeArgv exists" fn_exists "$js" 'function revokeArgv'
    want "revokeArgv refuses one too, even called directly" \
        in_fn "$js" 'function revokeArgv' '!row\.offersControl'
    want "the service refuses a null argv rather than running it" \
        in_fn "$svc" 'function revoke\(row, verb\)' 'if \(!argv\)'

    # A failed read is not an empty machine — the standing lesson, and the one
    # a permissions page must not forget.
    want "parseList exists" fn_exists "$js" 'function parseList'
    want "an unreadable answer carries a reason" \
        in_fn "$js" 'function parseList' 'empty\.reason ='
    want "the page renders that reason rather than an empty list" \
        has "$page" 'PermissionsService\.unavailableReason'

    # ── 4. the poller stops ──────────────────────────────────────────────────
    want "the service is refcounted" has "$svc" 'property int refCount'
    want "the sweep timer runs only while watched" \
        has "$svc" 'running: root\.refCount > 0'
    want "the page declares onScreen" has "$page" 'property bool onScreen'
    want "the page binds a ServiceRef to it" \
        has "$page" 'active:[[:space:]]*root\.onScreen'
    want "PageRegistry declares a privacy entry" \
        has "$reg" '"id": "privacy"'
    want "…that reaches PrivacyPage" has "$reg" 'PrivacyPage \{\}'
    want "…and marks it needsScreen" \
        in_fn "$reg" '"id": "privacy"' '"needsScreen": true'
    want "the qmldir hands out the service" \
        qmldir_has "$qmldir" '^singleton PermissionsService 1\.0 PermissionsService\.qml$'
    want "the qmldir hands out the page" \
        qmldir_has "$qmldir" '^PrivacyPage \./config_tab/pages/PrivacyPage\.qml$'
}

echo "── the tree as committed ──"
check_tree "$repo"
real_pass=$pass
real_fail=$fail

# ── self-test ────────────────────────────────────────────────────────────────
MUT=$(mktemp -d /tmp/apex-privacy-mut.XXXXXX) || exit 2
trap 'rm -rf "$MUT"' EXIT

selfpass=0
selffail=0
mutated=0
unmutated=0

copy() {
    local dest="$MUT/$1"
    mkdir -p "$dest"
    cp -r "$repo/src" "$dest/src"
}

assert_changed() {
    local dest="$1" rel="$2"
    if cmp -s "$repo/$rel" "$dest/$rel"; then
        echo "  FAIL  mutant did not apply: $rel"
        unmutated=$((unmutated + 1))
        return 1
    fi
    mutated=$((mutated + 1))
    return 0
}

expect() {
    local desc="$1" dest="$2" want="$3"
    local before_fail=$fail
    quiet=1
    check_tree "$dest"
    quiet=0
    local got=green
    [ "$fail" -gt "$before_fail" ] && got=red
    if [ "$got" = "$want" ]; then
        echo "  PASS  self-test $desc: $got"
        selfpass=$((selfpass + 1))
    else
        echo "  FAIL  self-test $desc: wanted $want, got $got"
        selffail=$((selffail + 1))
    fi
    fail=$before_fail
}

# m1 — the revoke put on the sweep timer. The defect this file exists for.
copy m1
sed -i 's|onTriggered: root\._beginSweep(false)|onTriggered: root.revoke(root.apps[0].rows[0], "deny")|' \
    "$MUT/m1/src/services/PermissionsService.qml"
assert_changed "$MUT/m1" src/services/PermissionsService.qml \
    && expect "a revoke on a timer" "$MUT/m1" red

# m2 — the enforcer dropped from the row, leaving the answer alone. The tick.
copy m2
sed -i 's|text:           "· enforced by " + rowItem.row.enforcerLabel|text:           ""|' \
    "$MUT/m2/src/services/config_tab/pages/PrivacyPage.qml"
assert_changed "$MUT/m2" src/services/config_tab/pages/PrivacyPage.qml \
    && expect "an answer with no enforcer beside it" "$MUT/m2" red

# m3 — controlsFor stops refusing, so every row grows buttons.
copy m3
sed -i 's|    if (!row.offersControl) {|    if (false) {|' \
    "$MUT/m3/src/services/permissions.js"
assert_changed "$MUT/m3" src/services/permissions.js \
    && expect "controlsFor no longer refusing" "$MUT/m3" red

# m4 — the poller left running whether or not the page is looked at.
copy m4
sed -i 's|running: root.refCount > 0|running: true|' \
    "$MUT/m4/src/services/PermissionsService.qml"
assert_changed "$MUT/m4" src/services/PermissionsService.qml \
    && expect "a poller that never stops" "$MUT/m4" red

# m5 — the page reachable from nowhere.
copy m5
sed -i 's|"id": "privacy"|"id": "privacy-disabled"|' \
    "$MUT/m5/src/nexus/PageRegistry.qml"
assert_changed "$MUT/m5" src/nexus/PageRegistry.qml \
    && expect "a page no registry declares" "$MUT/m5" red

# m6 — a switch back on the row, which is the bare tick returning.
copy m6
sed -i 's|CfgButton {|CfgSwitch {|' \
    "$MUT/m6/src/services/config_tab/pages/PrivacyPage.qml"
assert_changed "$MUT/m6" src/services/config_tab/pages/PrivacyPage.qml \
    && expect "a switch in place of the explained control" "$MUT/m6" red

# c1 — the inverse. Prose describing every one of those bugs must stay green,
# or the suite is matching comments rather than code.
copy c1
{
    echo '// An earlier draft ran the revoke from the sweep timer:'
    echo '//     onTriggered: root.revoke(row, "deny")'
    echo '// and polled it through pkexec:'
    echo '//     command = ["pkexec", "apex", "permissions", "revoke", app, cap]'
    echo '// and left running: true on the tick. None of that is here now.'
} >> "$MUT/c1/src/services/PermissionsService.qml"
{
    echo '// The first version drew a CfgSwitch per row and decided its'
    echo '// visibility inline, so a row nothing could revoke still got a'
    echo '// control — just a disabled one.'
} >> "$MUT/c1/src/services/config_tab/pages/PrivacyPage.qml"
{
    echo '// controlsFor used to return buttons unconditionally, with'
    echo '//     if (!row.offersControl) {   // removed during bring-up'
} >> "$MUT/c1/src/services/permissions.js"
assert_changed "$MUT/c1" src/services/PermissionsService.qml \
    && expect "prose quoting every one of those bugs stays green" "$MUT/c1" green

echo
echo "self-test: mutants applied=$mutated, failed-to-apply=$unmutated"
echo "check-privacy-ui: passed=$real_pass failed=$real_fail"
echo "self-test passed=$selfpass failed=$selffail"

[ "$real_fail" -eq 0 ] && [ "$selffail" -eq 0 ] && [ "$unmutated" -eq 0 ]
