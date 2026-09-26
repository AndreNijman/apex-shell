#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-surface-lifecycle-test.sh — the transient-surface state machine
#  (UI/UX roadmap v3, Phase 6).
#
#  Stages the REAL src/components/SurfaceLifecycle.qml and the real motion
#  system (tests/lib/theme-stub.sh's stage_motion) and runs
#  tests/surface-lifecycle-test.qml under qmltestrunner on the offscreen
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

mkdir -p "$stage/components"
cp "$root/src/components/SurfaceLifecycle.qml" "$stage/components/"
cp "$here/surface-lifecycle-test.qml" "$stage/"
: > "$stage/qmldir"

. "$here/lib/theme-stub.sh"
stage_motion "$stage" "$root" || { echo "RESULT: the staged motion system could not be built"; exit 1; }

out="$(QT_QPA_PLATFORM=offscreen timeout 120 "$runner" -platform offscreen \
       -input "$stage/surface-lifecycle-test.qml" 2>&1)"
rc=$?
echo "$out" | grep -E -A3 "^(PASS|FAIL|Totals)|QWARN|is not a type|Error" | grep -v "^PASS" | head -60

if grep -q 'is not a type\|module .* is not installed' <<<"$out"; then
    echo "RESULT: the staged lifecycle did not load"; exit 1
fi
passed="$(sed -n 's/^Totals: \([0-9]*\) passed.*/\1/p' <<<"$out")"
[[ -n "$passed" && "$passed" -ge 10 ]] || { echo "RESULT: too few assertions ran (${passed:-0})"; exit 1; }
[[ $rc -eq 0 ]] || { echo "RESULT: failing assertions"; exit 1; }
echo "RESULT: the surface lifecycle maps, reverses and unmaps on completion"
