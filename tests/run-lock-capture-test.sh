#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-lock-capture-test.sh — a lock that waits for the arrival's picture.
#
#  Stages the REAL src/state/LockState.qml as a plain component (its
#  `pragma Singleton` stripped, nothing else touched) and runs
#  tests/lock-capture-test.qml under qmltestrunner on the offscreen platform.
#  check-lock-writes.sh pins the same rules statically; this runs them.
# ─────────────────────────────────────────────────────────────────────────────
. "$(dirname "${BASH_SOURCE[0]}")/lib/private-bus.sh"   # the session bus is ours, not the desktop's
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
runner=""
for c in qmltestrunner-qt6 qmltestrunner /usr/lib64/qt6/bin/qmltestrunner /usr/lib/qt6/bin/qmltestrunner; do
    command -v "$c" >/dev/null 2>&1 && { runner="$c"; break; }
done
[[ -n "$runner" ]] || { echo "SKIP: qmltestrunner not installed (qt6-qtdeclarative-devel)"; exit 0; }
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT INT TERM
grep -v '^pragma Singleton' "$root/src/state/LockState.qml" > "$stage/LockStateUnderTest.qml"
grep -q 'function lock()' "$stage/LockStateUnderTest.qml" || { echo "RESULT: LockState.qml did not stage"; exit 1; }
cp "$here/lock-capture-test.qml" "$stage/"
out="$(QT_QPA_PLATFORM=offscreen timeout 120 "$runner" -platform offscreen -input "$stage/lock-capture-test.qml" 2>&1)"
rc=$?
echo "$out" | grep -E -A3 '^(FAIL|Totals)|is not a type|Error' | head -40
grep -q 'is not a type\|module .* is not installed' <<<"$out" && { echo "RESULT: the component did not load"; exit 1; }
passed="$(sed -n 's/^Totals: \([0-9]*\) passed.*/\1/p' <<<"$out")"
[[ -n "$passed" && "$passed" -ge 10 ]] || { echo "RESULT: too few assertions ran (${passed:-0})"; exit 1; }
[[ $rc -eq 0 ]] || { echo "RESULT: failing assertions"; exit 1; }
echo "RESULT: a fresh lock waits at most ~120 ms for its picture and always ends locked; a repeated request, a lock during the unlock release and a lock with no capture are immediate; a late or stale picture never appears"
