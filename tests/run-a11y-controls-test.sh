#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-a11y-controls-test.sh — what a screen reader and a keyboard-only user
#  get from the shared settings controls (roadmap P2-003).
#
#  ── What was measured before this existed ───────────────────────────────────
#
#  Zero `Accessible.` usages across 209 QML files. No FocusScope, no
#  KeyNavigation, and exactly one real `activeFocusOnTab` in the whole shell
#  (CfgSlider). 166 MouseArea and 28 TapHandler against that one tab stop.
#  Eleven Settings pages and the nav pane were reachable only with a mouse, and
#  a reader landing on any control in them found an unnamed element.
#
#  The repair is in the shared controls rather than in the pages: 294 of this
#  tree's 671 user-facing labels are in config_tab/pages, and naming each
#  control at its call site would both be 294 edits and rot the first time
#  somebody changed a label without changing its twin. CfgRow already holds the
#  words — it hands them to whatever control was placed in it.
#
#  ── Why qmltestrunner and not the quickshell harness ────────────────────────
#
#  tests/run-settings-pages-test.sh builds the real pages under quickshell and
#  asks each one what it is. It cannot press anything: quickshell offers no way
#  to post an input event. QtTest does — keyClick posts a real QKeyEvent into
#  the QQuickWindow through the same delivery agent a compositor's input takes —
#  and cannot load a page, because every page reaches a singleton that needs
#  Quickshell. So this is the recipe run-slider-wheel-test.sh established for
#  P0-020 and run-settings-controls-test.sh reused for P0-024, pointed at
#  accessibility.
#
#  ── Why the staging dance ───────────────────────────────────────────────────
#
#  Every Cfg component says `import "../../"` to reach the Theme singleton, and
#  Theme reaches Metrics and ColorLoader, which need Quickshell — a screen list
#  and a FileView that plain qmltestrunner cannot provide. So the real
#  src/components/config is copied next to a Theme stub answering the members
#  those components read. The components under test are the shipped files, byte
#  for byte, and no assertion in here looks at a colour.
#
#  Headless: -platform offscreen, so this opens nothing on anybody's desktop.
#
#  Run from anywhere: ./tests/run-a11y-controls-test.sh
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
cp "$here/a11y-controls-test.qml" "$stage/a11y-controls-test.qml"

# The staged tree must BE the shipped one. A copy that silently lost a file
# would make every assertion below a statement about something this repository
# does not ship.
if ! diff -r "$root/src/components/config" "$stage/components/config" >/dev/null 2>&1; then
    echo "RESULT: the staged components differ from the shipped ones"
    exit 1
fi

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
}
THEME

# WAYLAND_DISPLAY is removed from the environment rather than merely unused.
# The offscreen platform does not need it, but a plugin that ever decides to
# probe for a compositor must not find the one somebody is working in.
out="$(env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
       QT_QPA_PLATFORM=offscreen QT_LOGGING_RULES="qt.qml.binding.removal.info=false" \
       timeout 120 "$runner" -platform offscreen -input "$stage/a11y-controls-test.qml" 2>&1)"
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
EXPECT_TESTS=21
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

echo "RESULT: every shared control names itself from the row that holds it,
        declares its kind and state, is reachable with Tab and operable with
        Space — and one that has been switched off ignores both"
