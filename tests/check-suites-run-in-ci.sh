#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-suites-run-in-ci.sh — apex-shell's half. A suite nobody runs is not a
#  gate.
#
#  apex-os has had this since 2026-09-12, where it found 13 of 70 suites named
#  in no workflow — including 60 lid assertions for a feature the owner had
#  asked for by name. But that gate globs `tests/test-*.sh` IN APEX-OS ONLY: it
#  can neither see nor protect anything here, which p2-b pointed out while
#  landing a suite it therefore had to wire by hand.
#
#  This one differs in a way that matters. apex-shell invokes suites through
#  other suites — check-headless-runners.sh drives six, run-nexus-smoke.sh
#  drives popup-smoke — so "named in a workflow" is the wrong question and
#  would have condemned six innocent files. It asks REACHABILITY instead: a
#  suite counts as run if a workflow names it, or if any suite that is itself
#  reachable invokes it. Measured on the day it was written: 62 suites, 55
#  named directly, 61 reachable, exactly ONE orphan (run-nexus-smoke.sh).
#
#  Comment lines are stripped before matching, because prose naming a suite is
#  not an invocation of it — the apex-os gate shipped that bug and reported a
#  suite as run on the strength of its own explanatory comment.
#
#  Both arms fail, and the second is the point:
#    a suite nothing reaches, not in the exempt file  -> fail, named
#    an exempt suite that IS now reachable            -> fail, "delete the line"
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
EXEMPT=tests/suites-not-in-ci.txt

mapfile -t suites < <(ls tests/*test*.sh tests/check-*.sh tests/run-*.sh 2>/dev/null | sort -u)
[ "${#suites[@]}" -gt 0 ] || { echo "FATAL: found no suites to check"; exit 1; }

wf="$(cat .github/workflows/*.yml 2>/dev/null | grep -vE '^[[:space:]]*#')"

exempt=()
[ -f "$EXEMPT" ] && mapfile -t exempt < <(grep -vE '^[[:space:]]*(#|$)' "$EXEMPT" | awk '{print $1}')
is_exempt() { local n; for n in ${exempt[@]+"${exempt[@]}"}; do [ "$n" = "$1" ] && return 0; done; return 1; }

# Seed with suites a real workflow line names, then close transitively.
declare -A reach=()
# A bash substring test, NOT `printf ... | grep -q`. Under `set -o pipefail`
# that pipeline returns 141, not 0, whenever grep matches EARLY enough to exit
# before printf finishes writing — printf takes SIGPIPE and pipefail reports
# it. The `&&` then never fires and a suite that IS named reads as unreachable.
# It is position-dependent, so it failed for 5 of 63 suites and looked
# arbitrary: run-rtl-test.sh is named at ci.yml:1599 and was reported orphaned.
# Caught because the answer disagreed with a separate measurement.
for s in "${suites[@]}"; do
    b="${s#tests/}"
    [[ "$wf" == *"$b"* ]] && reach["$b"]=1
done
changed=1
while [ "$changed" = 1 ]; do
    changed=0
    for s in "${suites[@]}"; do
        [ -n "${reach[${s#tests/}]:-}" ] || continue
        for t in "${suites[@]}"; do
            b="${t#tests/}"
            [ "$b" = "${s#tests/}" ] && continue
            [ -n "${reach[$b]:-}" ] && continue
            grep -qF "$b" "$s" 2>/dev/null && { reach["$b"]=1; changed=1; }
        done
    done
done

orphan=(); resurrected=()
for s in "${suites[@]}"; do
    b="${s#tests/}"
    if [ -n "${reach[$b]:-}" ]; then is_exempt "$s" && resurrected+=("$s")
    else is_exempt "$s" || orphan+=("$s"); fi
done

printf '\nsuite coverage (apex-shell): %d suites, %d reachable from CI, %d exempt, %d unreachable and undeclared\n' \
    "${#suites[@]}" "${#reach[@]}" "${#exempt[@]}" "${#orphan[@]}"
rc=0
if [ "${#orphan[@]}" -gt 0 ]; then
    echo "  FAIL — no CI path reaches these, and they are not in $EXEMPT:"
    printf '    %s\n' "${orphan[@]}"; rc=1
fi
if [ "${#resurrected[@]}" -gt 0 ]; then
    echo "  FAIL — these are in $EXEMPT but CI now reaches them. Delete their lines:"
    printf '    %s\n' "${resurrected[@]}"; rc=1
fi
[ "$rc" -eq 0 ] && echo "  every suite is reachable from CI or a recorded, reasoned exception"
exit "$rc"
