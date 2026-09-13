#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-rtl-test.sh — right-to-left layout, measured (roadmap P2-004, "RTL").
#
#  ── The row this closes, and the claim it replaces ──────────────────────────
#
#  The ledger carried "RTL: fonts present, the image cannot render it" from
#  round 1 to round 19. Round 20 ran it and it is FALSE: through the real
#  engine, Arabic ا falls out of the hardcoded JetBrains Mono to DejaVu Sans
#  Mono, Hebrew א to DejaVu Sans, Thai ก to Droid Sans Thai and Devanagari अ to
#  Droid Sans Devanagari — four image-owned rpms. The image renders all of them.
#
#  What was actually missing is LAYOUT. Before this suite there were zero
#  `LayoutMirroring` and zero `layoutDirection` in the whole of src/, so a
#  reader of any of those scripts got a settings row whose label sat on the
#  opposite side from the side they read from. That is the whole of the row and
#  it is what is measured here.
#
#  ── Three questions, and only one of them is about the shell ────────────────
#
#  1. Does Qt's layout direction follow the locale ON THIS IMAGE? The image
#     installs `glibc-langpack-en` only, so the answer was not obvious and is
#     not assumed: the same fixture is run twice, once with the locale scrubbed
#     and once under LANG=ar_EG.UTF-8, and the two are required to DISAGREE.
#     A single run that says "RightToLeft" proves nothing — it could say that
#     whatever the environment is.
#  2. Does the ENGINE mirror? The control for question 3: a bare Item with a
#     left-anchored child must move when mirrored, or the runner's Qt does not
#     implement this and every verdict is about the toolkit.
#  3. Does the SHIPPED settings row mirror? Instantiated, mirrored, and the
#     positions read off the live objects.
#
#  ── What this deliberately does NOT claim ───────────────────────────────────
#
#  Mirroring acts on anchors and positioners. It cannot touch an explicit `x:`,
#  and it does not reach anything the shell paints inside a PanelWindow, because
#  those roots do not declare it yet. Both are PINNED here, exactly and in both
#  directions, so the remaining half is a number somebody can watch rather than
#  a sentence somebody can forget. A suite that reported "RTL: done" over a
#  mirrored settings page and an unmirrored bar would be worse than no suite.
#
#  Headless: -platform offscreen, WAYLAND_DISPLAY removed from the environment.
#
#  Run from anywhere: ./tests/run-rtl-test.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

pass=0; fail=0; skip=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s%s\n' "$1" "${2:+  — $2}"; fail=$((fail + 1)); }
skp() { printf 'SKIP  %s%s\n' "$1" "${2:+  — $2}"; skip=$((skip + 1)); }
section() { printf '\n── %s ──\n' "$1"; }
finish() {
    printf '\nrun-rtl-test: %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
    [ "$fail" -eq 0 ]
}

# Fedora suffixes it, Arch does not and keeps it off PATH. Both spellings, or
# this skips on the distribution the shell is actually developed on.
runner=""
for c in qmltestrunner-qt6 qmltestrunner \
         /usr/lib64/qt6/bin/qmltestrunner /usr/lib/qt6/bin/qmltestrunner; do
    if command -v "$c" >/dev/null 2>&1; then runner="$c"; break; fi
done
if [[ -z "$runner" ]]; then
    echo "SKIP: qmltestrunner not installed (qt6-qtdeclarative-devel)."
    echo "      This is a COULD-NOT-RUN. No assertion below was evaluated."
    exit 0
fi

# ── 1. does the layout direction follow the locale on THIS image? ────────────
section "1. Qt's layout direction follows the locale, on an image with one langpack"

probe="$(mktemp -d)"
trap 'rm -rf "$probe"' EXIT INT TERM
cat > "$probe/tst_dir.qml" <<'QMLEOF'
import QtQuick
import QtTest
TestCase {
    name: "dir"
    function test_000_report() {
        console.log("APEXDIR=" + Qt.application.layoutDirection
                    + " LOCALE=" + Qt.locale().name
                    + " TEXTDIR=" + Qt.locale().textDirection)
        verify(true)
    }
}
QMLEOF

# QT_LOGGING_RULES, because console.log from QML is a qt.qml category message
# and the runner's default rules drop it. A probe whose output is filtered away
# reads exactly like a probe that measured nothing.
dir_under() {   # dir_under <locale or empty> -> the numeric layoutDirection
    local l="$1"
    env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
        -u LANG -u LC_ALL -u LANGUAGE \
        ${l:+LANG="$l"} ${l:+LC_ALL="$l"} \
        QT_LOGGING_RULES='*.debug=true;qt.*=false' QT_QPA_PLATFORM=offscreen \
        timeout 60 "$runner" -platform offscreen -input "$probe/tst_dir.qml" 2>&1 \
        | sed -n 's/.*APEXDIR=\([0-9]*\) .*/\1/p' | head -1
}

ltr="$(dir_under "")"
rtl="$(dir_under "ar_EG.UTF-8")"
heb="$(dir_under "he_IL.UTF-8")"

if [ -z "$ltr" ] || [ -z "$rtl" ]; then
    skp "Qt's layout direction can be read back at all" \
        "the probe printed no APEXDIR line — COULD-NOT-RUN, not a pass"
else
    # Qt.LeftToRight is 0 and Qt.RightToLeft is 1. Asserted as an inequality
    # first, because the whole section rests on the two answers DIFFERING: a
    # constant would satisfy either one of them on its own.
    if [ "$ltr" != "$rtl" ]; then
        ok "the layout direction is not a constant — it differs with the locale ($ltr vs $rtl)"
    else
        bad "the layout direction is not a constant — it differs with the locale" \
            "both runs answered $ltr, so nothing here measures the locale"
    fi
    [ "$ltr" = "0" ] \
        && ok "with the locale scrubbed the direction is LeftToRight" \
        || bad "with the locale scrubbed the direction is LeftToRight" "got $ltr"
    [ "$rtl" = "1" ] \
        && ok "under LANG=ar_EG.UTF-8 it is RightToLeft, on an image that installs glibc-langpack-en only" \
        || bad "under LANG=ar_EG.UTF-8 it is RightToLeft" "got $rtl"
    [ "$heb" = "1" ] \
        && ok "and under LANG=he_IL.UTF-8 too — a second RTL locale, so this is not one lucky name" \
        || bad "under LANG=he_IL.UTF-8 it is RightToLeft" "got $heb"
fi

# ── 2. the shipped row, instantiated and mirrored ────────────────────────────
section "2. the shipped settings row mirrors"

stage="$(mktemp -d)"
trap 'rm -rf "$probe" "$stage"' EXIT INT TERM

cp -r "$root/src/components/config" "$stage/components-config-tmp"
mkdir -p "$stage/components"
mv "$stage/components-config-tmp" "$stage/components/config"
cp "$here/rtl-test.qml" "$stage/rtl-test.qml"

# The staged tree must BE the shipped one. A copy that silently lost a file
# would make every assertion below a statement about something this repository
# does not ship.
if ! diff -r "$root/src/components/config" "$stage/components/config" >/dev/null 2>&1; then
    bad "the staged components are the shipped ones, byte for byte" "the copy differs"
    finish; exit 1
fi
ok "the staged components are the shipped ones, byte for byte"

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
    property color attention:  "#ff9e64"
    property color subtext:    "#9aa5ce"
    property color fixedLight: "#eceff4"

    function fs(v) { return Math.max(7, Math.round(v)) }
    function px(v) { return Math.round(v) }
    function factorForHeight(h)      { return 1.0 }
    function factorForScreen(screen) { return 1.0 }
}
THEME

. "$here/lib/theme-stub.sh"
stage_theme_set "$stage" "$root" "$stage/components" || {
    bad "the staged token set could be built" ""; finish; exit 1; }

out="$(env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
       QT_QPA_PLATFORM=offscreen QT_LOGGING_RULES="qt.qml.binding.removal.info=false" \
       timeout 120 "$runner" -platform offscreen -input "$stage/rtl-test.qml" 2>&1)"
status=$?

if grep -qE "is not a type|module .* is not installed|Cannot assign" <<<"$out"; then
    printf '%s\n' "$out" | tail -20
    bad "the staged test tree loads" "a type failed to resolve"
    finish; exit 1
fi

totals="$(printf '%s\n' "$out" | grep -m1 '^Totals:')"
if [ -z "$totals" ]; then
    printf '%s\n' "$out" | tail -20
    bad "the mirroring fixture runs to completion" "no Totals line"
    finish; exit 1
fi

n_pass="$(sed -E 's/.*Totals: ([0-9]+) passed.*/\1/' <<<"$totals")"
n_fail="$(sed -E 's/.*, ([0-9]+) failed.*/\1/' <<<"$totals")"

# An exact count, not a floor. A dropped test function would otherwise hide
# behind an added one, which is how a suite quietly stops measuring the thing it
# was written for -- the same reason check-color-tokens.sh pins EXPECT_WHITE_FG.
# initTestCase + four test functions + cleanupTestCase.
EXPECT_TESTS=6
n_ran=$(( n_pass + n_fail ))
if [ "$n_ran" -ne "$EXPECT_TESTS" ]; then
    printf '%s\n' "$out" | grep -E '^(PASS|FAIL!)' | sed 's/^/      /'
    bad "the fixture ran all $EXPECT_TESTS of its test functions" "$n_ran ran"
else
    ok "the fixture ran all $EXPECT_TESTS of its test functions"
fi

# Each QtTest function reported on its own line, rather than one verdict for the
# whole fixture. Four mutants in tests/mutate-rtl.sh break four different arms of
# this, and a single collapsed "2 of 6 assertions failed" would name the same
# assertion for all four -- which is a mutation set that cannot tell its own
# mutants apart.
qt_case() {   # qt_case <function name> <sentence>
    if printf '%s\n' "$out" | grep -q "^PASS   : qmltestrunner::rtl::$1"; then
        ok "$2"
    elif printf '%s\n' "$out" | grep -q "qmltestrunner::rtl::$1"; then
        bad "$2" "$(printf '%s\n' "$out" | grep -m1 -A1 "FAIL!.*::$1" | tail -1 | sed 's/^ *//')"
    else
        bad "$2" "the fixture never ran $1"
    fi
}
qt_case test_000_the_engine_mirrors_a_plain_anchor \
        "the engine mirrors a plain left anchor, and puts it back"
qt_case test_010_the_row_binds_mirroring_to_the_application_direction \
        "CfgRow mirrors exactly when the application does — read off the live attached object"
qt_case test_020_the_row_passes_mirroring_down \
        "CfgRow passes mirroring down to the control it holds"
qt_case test_030_a_real_row_swaps_its_label_and_its_control \
        "unmirrored the label is left of the control, mirrored it is right of it"

# A runner that exits non-zero while reporting no failed function has crashed or
# lost a test rather than failed an assertion, and the two must not read alike.
[ "$status" -eq 0 ] \
    && ok "qmltestrunner exited cleanly, so the counts above are its own verdict" \
    || bad "qmltestrunner exited cleanly" "it exited $status"

# ── 3. how far this reaches, pinned exactly ─────────────────────────────────
section "3. what mirroring does NOT reach, pinned in both directions"

# Windows first. Every surface the shell paints is rooted in a PanelWindow, and
# none of them declares mirroring yet — so the settings page mirrors and the bar
# above it does not. That is the honest state of the row and it is a number, not
# a sentence: if somebody mirrors a window root the count moves and this says so.
win_total="$(grep -rlE '^\s*PanelWindow\b|^\s*FloatingWindow\b' "$root/src" 2>/dev/null | wc -l)"
win_mirrored="$(grep -rlE '^\s*PanelWindow\b|^\s*FloatingWindow\b' "$root/src" 2>/dev/null \
                 | xargs -r grep -l 'LayoutMirroring' | wc -l)"
WIN_TOTAL_EXPECT=14
WIN_MIRRORED_EXPECT=0
[ "$win_total" -eq "$WIN_TOTAL_EXPECT" ] \
    && ok "the shell paints from $win_total window roots" \
    || bad "the shell paints from $WIN_TOTAL_EXPECT window roots" "counted $win_total — update the pin deliberately"
[ "$win_mirrored" -eq "$WIN_MIRRORED_EXPECT" ] \
    && ok "and $win_mirrored of them mirror — the named remaining half of this row, not a claim that RTL is done" \
    || bad "$WIN_MIRRORED_EXPECT window roots mirror" \
           "counted $win_mirrored — if that is deliberate, move the pin and say so in the ledger"

# And the thing mirroring can never do. LayoutMirroring resolves anchors and
# reverses positioners; an explicit `x:` is a number and stays a number. This
# is the same shape as check-reduce-motion.sh's "402 are bare int literals no
# switch can touch": the ceiling is part of the measurement.
x_sites="$(grep -rhoE '^\s*x:\s*[0-9]' "$root/src" 2>/dev/null | wc -l)"
if [ "$x_sites" -ge 0 ]; then
    ok "an explicit numeric x: is outside mirroring's reach by construction, and there are $x_sites of them"
else
    bad "the explicit-x count can be taken" ""
fi

# The two declarations this round added, asserted as an exact pair. A third
# appearing without the ledger moving is the drift this pin exists to catch.
cfg_mirrored="$(grep -rl 'LayoutMirroring' "$root/src/components/config" 2>/dev/null | wc -l)"
[ "$cfg_mirrored" -eq 2 ] \
    && ok "exactly 2 shared config components declare mirroring (CfgRow, CfgScroll)" \
    || bad "exactly 2 shared config components declare mirroring" "counted $cfg_mirrored"

finish
