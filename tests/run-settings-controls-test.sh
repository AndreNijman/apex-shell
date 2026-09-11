#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-settings-controls-test.sh — press the shared settings controls, for real
#  (roadmap P0-024, criteria 1 and 2).
#
#  ── Why not the quickshell harness ──────────────────────────────────────────
#  tests/run-settings-pages-test.sh builds the ten real pages under quickshell
#  and asks each one what it is. It cannot press anything: quickshell offers no
#  way to post an input event. qmltestrunner does — QtTest's mouseClick and
#  keyClick post real QMouseEvent and QKeyEvent into the QQuickWindow,
#  hit-tested by position, which is the same delivery path a compositor's input
#  takes — and cannot load a page, because every page reaches a singleton that
#  needs Quickshell.
#
#  So this is the same recipe run-slider-wheel-test.sh established for P0-020,
#  pointed at the commit bar, the lifecycle line and the ordinary controls
#  instead of at the wheel.
#
#  It is Qt's own test module rather than a new framework, and the interface
#  here is the one every other check in this directory has: skip cleanly when a
#  dependency is missing, print PASS/FAIL lines, end with `passed=N failed=M`.
#
#  ── Why the staging dance ───────────────────────────────────────────────────
#  Every Cfg component says `import "../../"` to reach the Theme singleton, and
#  Theme reaches Metrics and ColorLoader, which need Quickshell — a screen list
#  and a FileView that plain qmltestrunner has no way to provide. So this script
#  copies the real src/components/config next to a Theme stub answering the
#  members those components read. The components under test are the shipped
#  files, byte for byte; only the palette they paint with is fake, and no
#  assertion here looks at a colour.
#
#  Headless: -platform offscreen, so this opens nothing on anybody's desktop.
#
#  Run from anywhere: ./tests/run-settings-controls-test.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

# Fedora suffixes it, Arch does not and keeps it off PATH. Both spellings, or
# this skips on the distribution the shell is actually developed on.
runner=""
for c in qmltestrunner-qt6 qmltestrunner \
         /usr/lib64/qt6/bin/qmltestrunner /usr/lib/qt6/bin/qmltestrunner; do
    if command -v "$c" >/dev/null 2>&1; then runner="$c"; break; fi
done

if [[ -z "$runner" ]]; then
    echo "SKIP: qmltestrunner not installed (qt6-qtdeclarative-devel)"
    exit 0
fi

stage="$(mktemp -d)"
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT INT TERM

cp -r "$root/src/components/config" "$stage/components-config-tmp"
mkdir -p "$stage/components"
mv "$stage/components-config-tmp" "$stage/components/config"
cp "$here/settings-controls-test.qml" "$stage/settings-controls-test.qml"

# The stub. Every Theme.* the config components read — grep them if this list
# ever looks short. `warning`, `subtext` and `info` joined it with P0-023: the
# commit bar is painted in the warning tone, the lifecycle line's sentence in
# subtext, and a deferred row's caption in info.
cat > "$stage/qmldir" <<'QMLDIR'
singleton Theme Theme.qml
QMLDIR

cat > "$stage/Theme.qml" <<'THEME'
pragma Singleton
import QtQuick

QtObject {
    property color active:     "#7aa2f7"
    property color background: "#1a1b26"
    property color text:       "#c0caf5"
    property color danger:     "#f7768e"
    property color warning:    "#e0af68"
    property color info:       "#7dcfff"
    property color subtext:    "#9aa5ce"
    property color fixedLight: "#eceff4"

    function fs(v) { return Math.max(7, Math.round(v)) }
    function px(v) { return Math.round(v) }
}
THEME

out="$(QT_QPA_PLATFORM=offscreen QT_LOGGING_RULES="qt.qml.binding.removal.info=false" \
       timeout 120 "$runner" -platform offscreen -input "$stage/settings-controls-test.qml" 2>&1)"
status=$?

printf '%s\n' "$out" | grep -E "^(PASS|FAIL!|SKIP|XFAIL|QWARN|Totals)" || true

if grep -qE "is not a type|module .* is not installed|Cannot assign" <<<"$out"; then
    printf '%s\n' "$out" | tail -20
    echo "RESULT: the staged test tree failed to load"
    exit 1
fi

totals="$(printf '%s\n' "$out" | grep -m1 "^Totals:")"
if [[ -z "$totals" ]]; then
    printf '%s\n' "$out" | tail -20
    echo "RESULT: test did not run to completion"
    exit 1
fi

n_pass="$(sed -E 's/.*Totals: ([0-9]+) passed.*/\1/' <<<"$totals")"
n_fail="$(sed -E 's/.*, ([0-9]+) failed.*/\1/' <<<"$totals")"
echo ""
echo "passed=$n_pass failed=$n_fail"

# A suite that runs but asserts nothing is the failure this line exists to catch.
if [[ "$n_pass" -lt 12 ]]; then
    echo "RESULT: only $n_pass assertions ran; nothing is exercising the fixture"
    exit 1
fi

if [[ "$n_fail" -ne 0 || "$status" -ne 0 ]]; then
    printf '%s\n' "$out" | grep -A3 "^FAIL!" | head -40
    echo "RESULT: failing assertions"
    exit 1
fi

echo "RESULT: one button per act, a busy bar that emits nothing, a refusal that
        keeps the draft, and every ordinary control applying its input"
