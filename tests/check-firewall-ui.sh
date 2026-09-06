#!/usr/bin/env bash
# Static invariants for P1-044's firewall surface.
#
# ── Why this exists next to tests/firewall-test.js ───────────────────────────
# The node suite drives src/services/firewall.js, which is the part with
# branches. It cannot see the QML: whether the sweep is gated on refCount,
# whether anything a timer can reach could change the machine, whether the page
# is registered so it can be opened at all, or whether a control is labelled
# with a word P0-023's vocabulary bans. Each is one careless edit from
# regressing with no visible symptom — a panel that polls forever costs battery
# silently, and a page missing from the registry is a feature nobody can find.
#
# ── THE THREE WAYS A GREP-STYLE CHECK LIES HERE ─────────────────────────────
#
# 1. A COMMENT SATISFIES IT. This file's own header names every command it
#    forbids. Every check runs against comment-stripped input, and the last
#    mutant in the self-test is prose quoting the banned strings — it must stay
#    GREEN.
#
# 2. THE MUTANT NEVER APPLIED. A self-test that mutates a copy and watches it
#    go red proves nothing if the edit matched nothing: the copy is then
#    identical and the verdict is about the original. Every mutant is diffed
#    against its source, and one that did not apply is a hard failure.
#
# 3. THE PIPE LIED. `producer | grep -q` under `set -o pipefail` returns the
#    PRODUCER's status when grep exits early on a match. Every helper captures
#    into a variable instead.
#
# PASS = nothing on a timer can change the machine, no argv here is privileged,
#        the page is registered and refcounted, and the words obey P0-023.
#
# Run from anywhere: ./tests/check-firewall-ui.sh
#            or:     ./tests/check-firewall-ui.sh --self-test
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"

pass=0
fail=0
quiet=0
ok()  { [ "$quiet" -eq 1 ] || echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { [ "$quiet" -eq 1 ] || echo "  FAIL  $1"; fail=$((fail + 1)); }
want() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

code()       { grep -vE '^[[:space:]]*//' "$1" 2>/dev/null; }
qmldircode() { grep -vE '^[[:space:]]*#'  "$1" 2>/dev/null; }
has()        { local _c; _c=$(code "$1");       grep -qE "$2" <<<"$_c"; }
lacks()      { local _c; _c=$(code "$1");     ! grep -qE "$2" <<<"$_c"; }
qmldir_has() { local _c; _c=$(qmldircode "$1"); grep -qE "$2" <<<"$_c"; }

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
fn_exists() { local _b; _b=$(fn_body "$1" "$2"); [ -n "$_b" ]; }

check_tree() {
    local r="$1"
    local js="$r/src/services/firewall.js"
    local svc="$r/src/services/FirewallService.qml"
    local page="$r/src/services/config_tab/pages/FirewallPage.qml"
    local reg="$r/src/nexus/PageRegistry.qml"
    local qmldir="$r/src/services/qmldir"

    # First and unconditionally: every check below is a grep, and a grep
    # against a file that is not there finds nothing — which every `lacks`
    # check would happily read as a pass.
    local f
    for f in "$js" "$svc" "$page" "$reg" "$qmldir"; do
        want "$(basename "$f") exists and is non-empty" test -s "$f"
    done

    # ── 1. the page can be opened at all ─────────────────────────────────────
    # A singleton missing from the qmldir is not a broken page; it is
    # "FirewallService is not a type" and the whole shell fails to start. The
    # Agents page proved that once already.
    want "FirewallService is a registered singleton" \
        qmldir_has "$qmldir" '^singleton FirewallService 1\.0 FirewallService\.qml$'
    want "FirewallPage is reachable through the qmldir" \
        qmldir_has "$qmldir" '^FirewallPage \./config_tab/pages/FirewallPage\.qml$'
    want "the page is in the registry, so it has a row in the sidebar" \
        has "$reg" '"id": "firewall"'
    want "the registry names a component for it" \
        has "$reg" 'firewallComp'

    # ── 2. nothing runs while nobody is looking ──────────────────────────────
    # Three processes every 30 seconds from login to logout, for a page most
    # users open once, is a battery cost with no symptom.
    want "the page holds a ServiceRef rather than forcing the service on" \
        has "$page" 'ServiceRef'
    want "the ref is gated on the page being on screen" \
        has "$page" 'active: root\.onScreen'
    want "the registry says this page needs to know when it is on screen" \
        test "$(FN_PAT='"id": "firewall"' awk '
            $0 ~ ENVIRON["FN_PAT"] { inside = 1 }
            inside && /needsScreen/ { print; exit }' "$reg" | grep -c 'true')" = 1
    want "the sweep refuses to start with no watchers" \
        in_fn "$svc" 'function _beginSweep' 'refCount <= 0 && !force'
    want "_standDown() exists to be checked" fn_exists "$svc" 'function _standDown'
    want "losing the last watcher kills the sweep in flight" \
        in_fn "$svc" 'function _standDown' '_proc\.running = false'

    # ── 3. nothing a timer can reach changes the machine ─────────────────────
    # The sweep runs ONE process and takes its argv from `_stepArgv`, so that
    # table is the whole surface a timer can name.
    want "the polled process takes its argv from the table, not from a literal" \
        in_fn "$svc" 'function _next\(\)' '_proc\.command = root\._stepArgv\[step\]'
    want "_next() exists to be checked" fn_exists "$svc" 'function _next\(\)'
    want "the argv table has exactly three entries" \
        test "$(fn_body "$svc" 'readonly property var _stepArgv' | grep -cE '^\s+(unit|status|catalogue):')" = 3
    want "no polled verb can allow, deny or reload" \
        not_in_fn "$svc" 'readonly property var _stepArgv' '"(allow|deny|reload|start|stop|enable)"'

    # ── 4. no argv here is privileged ────────────────────────────────────────
    # `sudo apex firewall allow` appears in this tree as a string SHOWN to the
    # user; it is never executed. The distinction is that an executed argv is
    # an array assigned to a `command`, so that is what is scanned.
    local argvs
    argvs=$(code "$svc" | grep -E '(^|[^a-zA-Z])command\s*[:=]\s*\[' || true)
    want "no executed argv names sudo, pkexec, run0 or systemd-run" \
        test -z "$(grep -E '"(sudo|pkexec|su|run0|systemd-run)"' <<<"$argvs" || true)"
    want "the page executes nothing at all" \
        lacks "$page" '(^|[^a-zA-Z])(Process|command)\s*[:=]'
    # `systemctl show` reads; `systemctl start` does not. The distinction is
    # the subcommand, and it is worth asserting because they are one word apart.
    want "the only systemctl the service runs is 'show'" \
        test -z "$(fn_body "$svc" 'readonly property var _stepArgv' \
                   | grep -E '"systemctl"' | grep -v '"show"' || true)"

    # ── 5. the words obey P0-023 ─────────────────────────────────────────────
    # Discard, Undo, Forget, Restore, Commit and Write are each one of the four
    # verbs wearing another name. A page that used one would teach a user a
    # fifth thing that must do something else.
    local labels
    labels=$(code "$page" | grep -E '^\s*label:' || true)
    want "no control is labelled with a word the vocabulary bans" \
        test -z "$(grep -E '"(Discard|Undo|Forget|Restore|Commit|Write)"' <<<"$labels" || true)"
    want "the page declares which of the four states its controls are in" \
        has "$page" 'lifecycle: "live"'

    # ── 6. a rejected exception is not drawn like a working one ──────────────
    # The one answer this surface must never give is "that port is open" about
    # a port the reload refused. firewall.js marks the row; the page has to
    # actually use the mark.
    want "the page reads the rejected flag" has "$page" 'modelData\.rejected'
    want "and shows it as a warning rather than as a value" \
        has "$page" 'statusWarns: modelData\.rejected'
}

# ── the self-test ────────────────────────────────────────────────────────────
# Each mutant breaks one thing and must make the suite go red. The last one
# must not: it is prose naming every command the checks forbid, and a check
# that a comment can satisfy is a check that is not testing the code.
if [ "${1:-}" = "--self-test" ]; then
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    quiet=1; check_tree "$repo"; quiet=0
    base_pass=$pass; base_fail=$fail
    echo "baseline: $base_pass passed, $base_fail failed"
    [ "$base_fail" -eq 0 ] || { echo "the baseline itself fails; fix that first"; exit 1; }

    mutants=(
      "svc|s/refCount <= 0 \&\& !force/false/|the sweep may run with nobody watching"
      "svc|s/root\._proc\.running = false/:/|_standDown leaves the sweep running"
      "svc|s/unit:      \[\"systemctl\", \"show\"/unit:      [\"systemctl\", \"start\"/|the unit step starts the service instead of reading it"
      "svc|s|_proc.command = root._stepArgv\[step\]|_proc.command = [\"apex\", \"firewall\", \"reload\"]|;|a timer can reach a verb that changes the machine"
      "page|s/lifecycle: \"live\"/lifecycle: \"\"/|the page does not say what its controls do"
      "page|s/label:       \"Turn it on\"/label:       \"Commit\"/|a control uses a banned word"
      "page|s/statusWarns: modelData\.rejected/statusWarns: false/|a rejected exception is drawn like a working one"
      "page|s/active: root\.onScreen/active: true/|the service polls whether or not anyone is looking"
      "qmldir|/^singleton FirewallService/d|the singleton is missing from the qmldir"
      "reg|/\"id\": \"firewall\"/d|the page is not in the registry"
    )
    caught=0; missed=0
    for m in "${mutants[@]}"; do
        which="${m%%|*}"; rest="${m#*|}"
        expr="${rest%|*}"; label="${rest##*|}"
        rm -rf "$tmp/t"; cp -r "$repo" "$tmp/t" 2>/dev/null
        case "$which" in
            svc)    target="$tmp/t/src/services/FirewallService.qml" ;;
            page)   target="$tmp/t/src/services/config_tab/pages/FirewallPage.qml" ;;
            qmldir) target="$tmp/t/src/services/qmldir" ;;
            reg)    target="$tmp/t/src/nexus/PageRegistry.qml" ;;
        esac
        cp "$target" "$tmp/orig"
        sed -i "$expr" "$target"
        if cmp -s "$tmp/orig" "$target"; then
            echo "  MUTANT DID NOT APPLY: $label"
            echo "    $expr"
            missed=$((missed + 1)); continue
        fi
        pass=0; fail=0; quiet=1; check_tree "$tmp/t"; quiet=0
        if [ "$fail" -gt 0 ]; then
            printf '  caught  %-58s (%d failed)\n' "$label" "$fail"
            caught=$((caught + 1))
        else
            printf '  MISSED  %-58s\n' "$label"
            missed=$((missed + 1))
        fi
    done

    # The green mutant. Prose naming every forbidden command must not redden a
    # single check — five checks in this project have been satisfied by the
    # comment in the very file they guarded.
    rm -rf "$tmp/t"; cp -r "$repo" "$tmp/t"
    cat >> "$tmp/t/src/services/FirewallService.qml" <<'PROSE'
// Prose mutant. None of these may be read as code: this service never runs
// sudo apex firewall allow, pkexec, run0, systemd-run, systemctl start
// apex-firewall, or command: ["sudo", "apex", "firewall", "reload"]. It also
// does not label anything Discard, Undo, Forget, Restore, Commit or Write.
PROSE
    pass=0; fail=0; quiet=1; check_tree "$tmp/t"; quiet=0
    if [ "$fail" -eq 0 ]; then
        echo "  caught  prose naming every banned command stays green"
        caught=$((caught + 1))
    else
        echo "  MISSED  prose naming every banned command reddened $fail checks"
        missed=$((missed + 1))
    fi

    echo
    echo "self-test: $caught/$((caught + missed)) mutants behaved, $missed did not"
    [ "$missed" -eq 0 ]
    exit $?
fi

echo "== firewall surface =="
check_tree "$repo"
echo
echo "firewall-ui: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
