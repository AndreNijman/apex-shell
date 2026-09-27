#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-spring-follower-test.sh — a value on the closed-form spring, per frame
#  (Fluid F7).
#
#  Stages the real motion system (tests/lib/theme-stub.sh's stage_motion, which
#  carries src/theme/anim/SpringFollower.qml and theme/spring.js) and runs
#  tests/spring-follower-test.qml under qmltestrunner on the offscreen
#  platform: no compositor, no window on anybody's desk.
# ─────────────────────────────────────────────────────────────────────────────
. "$(dirname "${BASH_SOURCE[0]}")/lib/private-bus.sh"   # the session bus is ours, not the desktop's
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

runner=""
for c in qmltestrunner-qt6 qmltestrunner \
         /usr/lib64/qt6/bin/qmltestrunner /usr/lib/qt6/bin/qmltestrunner; do
    if command -v "$c" >/dev/null 2>&1; then runner="$c"; break; fi
done
[[ -n "$runner" ]] || { echo "SKIP: qmltestrunner not installed (qt6-qtdeclarative-devel)"; exit 0; }

stage="$(mktemp -d)"
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT INT TERM

cp "$here/spring-follower-test.qml" "$stage/"
: > "$stage/qmldir"

. "$here/lib/theme-stub.sh"
stage_motion "$stage" "$root" || { echo "RESULT: the staged motion system could not be built"; exit 1; }

out="$(QT_QPA_PLATFORM=offscreen timeout 120 "$runner" -platform offscreen \
       -input "$stage/spring-follower-test.qml" 2>&1)"
rc=$?
echo "$out" | grep -E -A3 "^(PASS|FAIL|Totals)|QWARN|is not a type|Error" | grep -v "^PASS" | head -60

if grep -q 'is not a type\|module .* is not installed' <<<"$out"; then
    echo "RESULT: the staged follower did not load"; exit 1
fi
passed="$(sed -n 's/^Totals: \([0-9]*\) passed.*/\1/p' <<<"$out")"
[[ -n "$passed" && "$passed" -ge 6 ]] || { echo "RESULT: too few assertions ran (${passed:-0})"; exit 1; }
[[ $rc -eq 0 ]] || { echo "RESULT: failing assertions"; exit 1; }
echo "RESULT: a follower is born on its target, keeps its velocity through a retarget, lands exactly and jumps when not live"
