#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-password-shapes-test.sh — the lock and login screens' password shapes.
#
#  Stages the REAL src/components/auth/PasswordShapes.qml with the real motion
#  table and runs tests/password-shapes-test.qml under qmltestrunner on the
#  offscreen platform. The component imports theme/motion.js relative to
#  itself, so the stage mirrors src/'s layout.
# ─────────────────────────────────────────────────────────────────────────────
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
mkdir -p "$stage/components/auth" "$stage/theme"
cp "$root/src/components/auth/PasswordShapes.qml" "$stage/components/auth/"
cp "$root/src/theme/motion.js" "$stage/theme/"
cp "$here/password-shapes-test.qml" "$stage/"
out="$(QT_QPA_PLATFORM=offscreen timeout 120 "$runner" -platform offscreen -input "$stage/password-shapes-test.qml" 2>&1)"
rc=$?
echo "$out" | grep -E -A3 '^(FAIL|Totals)|is not a type|Error' | head -40
grep -q 'is not a type\|module .* is not installed' <<<"$out" && { echo "RESULT: the component did not load"; exit 1; }
passed="$(sed -n 's/^Totals: \([0-9]*\) passed.*/\1/p' <<<"$out")"
[[ -n "$passed" && "$passed" -ge 7 ]] || { echo "RESULT: too few assertions ran (${passed:-0})"; exit 1; }
[[ $rc -eq 0 ]] || { echo "RESULT: failing assertions"; exit 1; }
echo "RESULT: one shape per character, chosen by position, cleared as one gesture, a fade under Reduce Motion"
