#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-keyboard-nav-test.sh — the shared tab list on the keyboard (UI/UX
#  roadmap v3 Phase 21). TabSwitcher is the tab bar of the Dashboard, the
#  network panel, the audio pane and the settings column, and it was
#  pointer-only. Under qmltestrunner on the offscreen platform, against the
#  REAL TabSwitcher and controls, the real motion system and roles, a stub
#  palette: one Tab stop, the arrows along its axis (wrapping), Home/End, a
#  mirrored row reversed, a ring only while it has keyboard focus, and a
#  single-page switcher that is no Tab stop at all.
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

mkdir -p "$stage/components"
# The controls the config components are built on (ApexPressable & co.,
# UI/UX roadmap Phase 3), at the same relative path.
cp -r "$root/src/components/controls" "$stage/components/controls"
cp "$root/src/components/TabSwitcher.qml" "$stage/components/TabSwitcher.qml"
cp "$root/src/components/TimeInput.qml" "$stage/components/TimeInput.qml"
mkdir -p "$stage/popups"
cp "$root/src/popups/ChannelColumn.qml" "$stage/popups/ChannelColumn.qml"
cp "$root/src/popups/DeviceList.qml" "$stage/popups/DeviceList.qml"
cp "$here/keyboard-nav-test.qml" "$stage/keyboard-nav-test.qml"

# The staged tree must BE the shipped one. A copy that silently lost a file
# would make every assertion below a statement about something this repository
# does not ship.

cat > "$stage/qmldir" <<'QMLDIR'
singleton Theme Theme.qml
QMLDIR

# Every Theme.* the config components read. `attention` is here because
# CfgRow's status readout is painted in it when the readback disagrees.
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
    property color attention:  "#ff9e64"
    property color subtext:    "#9aa5ce"
    property color fixedLight: "#eceff4"

    function fs(v) { return Math.max(7, Math.round(v)) }
    function px(v) { return Math.round(v) }

    // The size half. Since P1-040 the staged components do not read a size
    // from this singleton at all — each declares its own ThemeSet for the
    // output it is on, and asks here only for the FACTOR. One output, one
    // factor, in a tree with no compositor: 1.0.
    function factorForHeight(h)      { return 1.0 }
    function factorForScreen(screen) { return 1.0 }
}
THEME

# ThemeSet itself, generated from src/theme/ThemeSet.qml rather than written
# out here, and checked to cover every token the staged components read.
. "$here/lib/theme-stub.sh"
stage_theme_set "$stage" "$root" "$stage/components" "$stage/popups" || {
    echo "RESULT: the staged token set could not be built"; exit 1; }
# The motion system the staged controls take their timing from (Phase 1 of the
# UI/UX roadmap): copied from src/theme at the shipped defaults.
stage_motion "$stage" "$root" || {
    echo "RESULT: the staged motion system could not be built"; exit 1; }

# WAYLAND_DISPLAY is removed from the environment rather than merely unused.
# The offscreen platform does not need it, but a plugin that ever decides to
# probe for a compositor must not find the one somebody is working in.
out="$(env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
       QT_QPA_PLATFORM=offscreen QT_LOGGING_RULES="qt.qml.binding.removal.info=false" \
       timeout 120 "$runner" -platform offscreen -input "$stage/keyboard-nav-test.qml" 2>&1)"
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

# An exact count, not a floor. The fixture finds its controls by objectName and
# reads names CfgRow supplies; a fixture that found none would simply be quiet,
# and a floor would let a dropped test function hide behind an added one.
# QtTest's total is initTestCase + the test functions + cleanupTestCase.
EXPECT_TESTS=16  # 14 + initTestCase/cleanupTestCase
n_ran=$(( n_pass + n_fail ))
if [[ "$n_ran" -ne "$EXPECT_TESTS" ]]; then
    echo "RESULT: $n_ran test functions ran, expected $EXPECT_TESTS"
    exit 1
fi

if [[ "$n_fail" -ne 0 || "$status" -ne 0 ]]; then
    printf '%s\n' "$out" | grep -A3 "^FAIL!" | head -60
    echo "RESULT: failing assertions"
    exit 1
fi

echo "RESULT: the tab lists and the quick-control sliders answer the keyboard: one Tab stop, arrows along the axis, Home/End, the mirror respected, a ring only for keyboard focus; a level steps 5 %/20 % and reaches its ends; the clock's HH:MM are two spin boxes; the audio pane's devices are one list"