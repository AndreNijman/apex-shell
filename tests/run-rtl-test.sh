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

# ── 1. what actually drives Qt's layout direction ────────────────────────────
section "1. the layout direction comes from a translation catalogue, not from the locale"

probe="$(mktemp -d)"
trap 'rm -rf "$probe"' EXIT INT TERM
cat > "$probe/tst_dir.qml" <<'QMLEOF'
import QtQuick
import QtTest
TestCase {
    name: "dir"
    function test_000_report() {
        console.log("APEXDIR=" + Qt.application.layoutDirection
                    + " APEXTEXTDIR=" + Qt.locale().textDirection
                    + " APEXLOCALE=" + Qt.locale().name)
        verify(true)
    }
}
QMLEOF

# QT_LOGGING_RULES, because console.log from QML is a qt.qml category message
# and the runner's default rules drop it. A probe whose output is filtered away
# reads exactly like a probe that measured nothing.
#
# The platform theme is passed IN rather than inherited, and that is the whole
# point of this section. Round 22's version inherited QT_QPA_PLATFORMTHEME from
# whoever ran it, which is why it was green on a developer's desktop and red the
# first time the mutation harness ran it under `env -i`.
probe_raw() {   # probe_raw <locale or empty> <platform theme or empty>
    local l="$1" t="$2"
    env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
        -u LANG -u LC_ALL -u LANGUAGE -u QT_QPA_PLATFORMTHEME \
        ${l:+LANG="$l"} ${l:+LC_ALL="$l"} ${t:+QT_QPA_PLATFORMTHEME="$t"} \
        QT_LOGGING_RULES='*.debug=true;qt.*=false' QT_QPA_PLATFORM=offscreen \
        timeout 60 "$runner" -platform offscreen -input "$probe/tst_dir.qml" 2>&1 \
        | sed -n 's/.*APEXDIR=\([0-9]*\) APEXTEXTDIR=\([0-9]*\) .*/\1 \2/p' | head -1
}
app_dir()  { probe_raw "$1" "$2" | cut -d' ' -f1; }   # Qt.application.layoutDirection
text_dir() { probe_raw "$1" "$2" | cut -d' ' -f2; }   # QLocale's own opinion

# Which platform theme to ask about. On a booted APEX this is read out of the
# image's own /etc/environment, so the row below is about what this system
# actually ships rather than about a name typed into a test; anywhere else it is
# the documented default and the suite says which it used.
THEME="qt6ct"; theme_src="the documented APEX default (this is not a booted APEX host)"
if [ -e /run/ostree-booted ] && [ -r /etc/environment ]; then
    from_env="$(sed -n 's/^QT_QPA_PLATFORMTHEME=//p' /etc/environment | tail -1)"
    if [ -n "$from_env" ]; then
        THEME="$from_env"; theme_src="/etc/environment on this booted image"
        ok "the image sets QT_QPA_PLATFORMTHEME=$THEME — the thing the direction turns out to depend on"
    else
        bad "the image sets QT_QPA_PLATFORMTHEME" \
            "/etc/environment on this booted host names no platform theme, so nothing here will mirror"
    fi
else
    skp "the image sets QT_QPA_PLATFORMTHEME" \
        "not a booted APEX host — probing with the documented default, $THEME"
fi

L_RTL="ar_EG.UTF-8"; L_RTL2="he_IL.UTF-8"; L_NOCAT="ur_PK.UTF-8"

# QLocale's own opinion FIRST, and separately, because the finding this section
# exists to record is that the two disagree. If QLocale could not even parse the
# locale name there is nothing to measure and everything below would be noise.
td_rtl="$(text_dir "$L_RTL" "$THEME")"
if [ -z "$td_rtl" ]; then
    skp "Qt can be asked for a layout direction at all" \
        "the probe printed no APEXDIR line — COULD-NOT-RUN, not a pass"
    skp "the application direction follows the locale when a catalogue exists" "same"
    skp "with no platform theme nothing flips" "same"
    skp "an RTL language Qt has no catalogue for does not flip" "same"
else
    [ "$td_rtl" = "1" ] \
        && ok "QLocale calls $L_RTL right-to-left, on an image that installs glibc-langpack-en only" \
        || bad "QLocale calls $L_RTL right-to-left" "textDirection=$td_rtl"

    with_theme_rtl="$(app_dir "$L_RTL"   "$THEME")"
    with_theme_heb="$(app_dir "$L_RTL2"  "$THEME")"
    with_theme_ltr="$(app_dir ""         "$THEME")"
    no_theme_rtl="$(app_dir  "$L_RTL"    "")"
    no_theme_ltr="$(app_dir  ""          "")"
    nocat_app="$(app_dir     "$L_NOCAT"  "$THEME")"
    nocat_text="$(text_dir   "$L_NOCAT"  "$THEME")"

    # The load-bearing pair. Neither half means anything alone: a run that
    # answers RightToLeft could answer that whatever the environment is, and a
    # run that answers LeftToRight could be a probe that measured nothing.
    if [ "$with_theme_rtl" = "1" ] && [ "$with_theme_ltr" = "0" ]; then
        ok "with $THEME loaded the direction follows the locale — $L_RTL gives RightToLeft, scrubbed gives LeftToRight"
    elif [ "$with_theme_rtl" = "$with_theme_ltr" ]; then
        bad "with $THEME loaded the direction follows the locale" \
            "both runs answered $with_theme_rtl — this machine cannot produce a right-to-left application direction, so CfgRow's switch can never fire here"
    else
        bad "with $THEME loaded the direction follows the locale" \
            "$L_RTL gave $with_theme_rtl and the scrubbed run gave $with_theme_ltr"
    fi

    [ "$with_theme_heb" = "1" ] \
        && ok "and under $L_RTL2 too — a second RTL locale, so this is not one lucky name" \
        || bad "under $L_RTL2 it is RightToLeft" "got $with_theme_heb"

    # THE MECHANISM, and the reason this section was rewritten. Qt decides the
    # application direction by translating the string QT_LAYOUT_DIRECTION and
    # comparing the answer to "RTL" -- so it needs a LOADED CATALOGUE, and
    # quickshell installs no QTranslator of its own. What supplies one on a
    # shipped APEX desktop is the qt6ct platform theme, which is configured for
    # a dark palette (files/system/qt6ct/qt6ct.conf) and has no idea it is
    # holding up right-to-left layout. Drop it and every mirrored surface
    # silently stops mirroring with nothing red anywhere.
    if [ "$no_theme_rtl" = "0" ] && [ "$with_theme_rtl" = "1" ]; then
        ok "and it is the THEME that supplies it: the same $L_RTL run with no platform theme gives LeftToRight"
    elif [ "$no_theme_rtl" = "1" ]; then
        ok "the direction no longer needs a platform theme — $L_RTL is RightToLeft without one (the dependency this suite pins has been removed; say so in the ledger)"
    else
        bad "it is the platform theme that supplies the right-to-left direction" \
            "with theme=$with_theme_rtl, without=$no_theme_rtl — the pair does not isolate the theme"
    fi
    [ "$no_theme_ltr" = "0" ] \
        && ok "with neither a locale nor a theme it is LeftToRight, which is the floor everything above is measured from" \
        || bad "with neither a locale nor a theme it is LeftToRight" "got $no_theme_ltr"

    # THE CEILING. Urdu is right-to-left and Qt's own QLocale says so in the
    # same run; Qt ships no qt_ur.qm, so the application direction stays
    # LeftToRight. Every RTL language without a Qt catalogue is in this bucket
    # -- Pashto, Sindhi, Divehi, Yiddish -- and no amount of QML reaches them.
    # This is pinned rather than fixed, the way check-reduce-motion.sh pins the
    # int literals no switch can touch.
    qt_cats="$(ls /usr/share/qt6/translations/qt_*.qm 2>/dev/null | wc -l)"
    if [ "$nocat_text" = "1" ] && [ "$nocat_app" = "0" ]; then
        ok "an RTL language Qt has no catalogue for does NOT flip — $L_NOCAT is right-to-left to QLocale and LeftToRight to the application ($qt_cats qt_*.qm installed, none of them ur)"
    elif [ "$nocat_text" != "1" ]; then
        skp "an RTL language Qt has no catalogue for does NOT flip" \
            "QLocale does not call $L_NOCAT right-to-left here (textDirection=$nocat_text) — COULD-NOT-RUN"
    else
        bad "an RTL language Qt has no catalogue for does NOT flip" \
            "$L_NOCAT gave application direction $nocat_app — if a qt_ur.qm has appeared, move this pin deliberately"
    fi
fi

# The RTL half of section 2 needs an application direction that is actually
# right-to-left. Whether this machine can produce one was just measured, so the
# answer is carried forward rather than assumed a second time.
RTL_AVAILABLE=0
[ "${with_theme_rtl:-}" = "1" ] && RTL_AVAILABLE=1

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

# The fixture is run TWICE — scrubbed, and under the RTL locale with the image's
# platform theme. Round 22 ran it once, in whatever direction the operator's
# shell happened to be in, and every geometric assertion in it forced mirroring
# on by hand. A row hardcoded `LayoutMirroring.enabled: false` passed all of it.
run_fixture() {   # run_fixture <locale or empty> <theme or empty>
    local l="$1" t="$2"
    env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
        -u LANG -u LC_ALL -u LANGUAGE -u QT_QPA_PLATFORMTHEME \
        ${l:+LANG="$l"} ${l:+LC_ALL="$l"} ${t:+QT_QPA_PLATFORMTHEME="$t"} \
        QT_QPA_PLATFORM=offscreen QT_LOGGING_RULES="qt.qml.binding.removal.info=false" \
        timeout 120 "$runner" -platform offscreen -input "$stage/rtl-test.qml" 2>&1
}

# initTestCase + seven test functions + cleanupTestCase. An exact count, not a
# floor: a dropped test function would otherwise hide behind an added one, which
# is how a suite quietly stops measuring the thing it was written for — the same
# reason check-color-tokens.sh pins EXPECT_WHITE_FG.
EXPECT_TESTS=9

# Each QtTest function reported on its own line, rather than one verdict for the
# whole fixture. The mutants in tests/mutate-rtl.sh break different arms of this,
# and a single collapsed "2 of 7 assertions failed" would name the same
# assertion for all of them — which is a mutation set that cannot tell its own
# mutants apart.
qt_case() {   # qt_case <pass label> <function name> <sentence>
    if printf '%s\n' "$out" | grep -q "^PASS   : qmltestrunner::rtl::$2"; then
        ok "[$1] $3"
    elif printf '%s\n' "$out" | grep -q "qmltestrunner::rtl::$2"; then
        bad "[$1] $3" "$(printf '%s\n' "$out" | grep -m1 -A1 "FAIL!.*::$2" | tail -1 | sed 's/^ *//')"
    else
        bad "[$1] $3" "the fixture never ran $2"
    fi
}

evaluate_pass() {   # evaluate_pass <label>
    local label="$1"

    if grep -qE "is not a type|module .* is not installed|Cannot assign" <<<"$out"; then
        printf '%s\n' "$out" | tail -20
        bad "[$label] the staged test tree loads" "a type failed to resolve"
        return 1
    fi

    local totals n_pass n_fail n_ran
    totals="$(printf '%s\n' "$out" | grep -m1 '^Totals:')"
    if [ -z "$totals" ]; then
        printf '%s\n' "$out" | tail -20
        bad "[$label] the mirroring fixture runs to completion" "no Totals line"
        return 1
    fi
    n_pass="$(sed -E 's/.*Totals: ([0-9]+) passed.*/\1/' <<<"$totals")"
    n_fail="$(sed -E 's/.*, ([0-9]+) failed.*/\1/' <<<"$totals")"
    n_ran=$(( n_pass + n_fail ))
    if [ "$n_ran" -ne "$EXPECT_TESTS" ]; then
        printf '%s\n' "$out" | grep -E '^(PASS|FAIL!)' | sed 's/^/      /'
        bad "[$label] the fixture ran all $EXPECT_TESTS of its test functions" "$n_ran ran"
    else
        ok "[$label] the fixture ran all $EXPECT_TESTS of its test functions"
    fi

    qt_case "$label" test_000_the_engine_mirrors_a_plain_anchor \
            "the engine mirrors a plain left anchor, and puts it back"
    qt_case "$label" test_010_the_row_binds_mirroring_to_the_application_direction \
            "CfgRow mirrors exactly when the application does — read off the live attached object"
    qt_case "$label" test_020_the_row_passes_mirroring_down \
            "CfgRow passes mirroring down to the control it holds"
    qt_case "$label" test_030_a_real_row_swaps_its_label_and_its_control \
            "forced both ways, the label and the control swap sides"
    qt_case "$label" test_040_the_row_mirrors_without_being_told_to \
            "and with NOTHING set by hand the row matches the application's direction"
    qt_case "$label" test_050_the_banner_inset_follows_the_reading_direction \
            "CfgScroll's lifecycle banner keeps its 2px inset on the side the reader starts from"
    qt_case "$label" test_060_the_scroll_container_mirrors_without_being_told_to \
            "and an untouched CfgScroll mirrors on its shipped declaration alone"

    # A runner that exits non-zero while reporting no failed function has
    # crashed or lost a test rather than failed an assertion, and the two must
    # not read alike.
    [ "$status" -eq 0 ] \
        && ok "[$label] qmltestrunner exited cleanly, so the counts above are its own verdict" \
        || bad "[$label] qmltestrunner exited cleanly" "it exited $status"
}

out="$(run_fixture "" "")"; status=$?
evaluate_pass "LTR" || { finish; exit 1; }

# The pass that carries the whole row. Without it every assertion above is
# "the row mirrors when told to", and a row that never mirrors on its own
# satisfies all of them.
if [ "$RTL_AVAILABLE" -eq 1 ]; then
    out="$(run_fixture "$L_RTL" "$THEME")"; status=$?
    evaluate_pass "RTL"
else
    skp "the shipped row is measured under a right-to-left application direction" \
        "section 1 could not produce one on this machine — COULD-NOT-RUN, so the binding CfgRow actually ships is unmeasured here"
fi

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

# ── and the thing mirroring can NEVER do ────────────────────────────────────
#
# LayoutMirroring resolves anchors and reverses positioners. An explicit `x:` is
# a number and stays a number, so every one of these sites is outside its reach
# by construction — the same shape as check-reduce-motion.sh's "402 are bare int
# literals no switch can touch". Round 22 counted them and asserted
# `[ "$x_sites" -ge 0 ]`, which is true of every integer; that is the gate that
# inspects nothing, and this replaces it.
#
# The pin is the SET, not the count, because the count is what hides a swap: one
# site fixed and one added reads as no change. Each entry below was read and
# bucketed by hand, and the bucket is the reason it is allowed to stay:
#
#   NOT AN ITEM'S X AT ALL (4) — mirroring must not touch these and could not.
#     TopBar.qml            x2  `Region` entries in the input mask, not visuals
#     LabwcBackend.qml      x1  a JavaScript object literal, a geometry record
#     NiriService.qml       x1  the same literal, in the niri backend
#
#   WIDTH-COMPENSATED (8) — an arithmetic no-op, not luck. Mirrored, x becomes
#   `parent.width - x - width`; with `x: N, width: parent.width - 2N` that is N
#   again, and with `x: 0, width: root.width` it is 0. Identical geometry both
#   ways, so converting them to anchors would change nothing a reader sees.
#     AppearancePage.qml    x1  x:10 width: parent.width - 20
#     DataPage.qml          x2  x:10 width: parent.width - 20
#     MiscPage.qml          x3  x:10 width: parent.width - 20
#     KeybindsPage.qml      x2  x:0  width: root.width  (full bleed)
#
#   GEOMETRY PLUMBING (1)
#     ArchMenu.qml          x1  a mask proxy whose x feeds the popup's mask
#
# What is NOT on this list is the point: the three sites that were a bare left
# inset with an intrinsic or asymmetric width — CfgScroll's lifecycle banner
# (x:2 against a 12px right inset, inside the component that declares the
# mirroring), and MiscPage's About row and Update button — are now anchored, and
# a new one anywhere in src/ fails this.
x_expect="$(cat <<'XEOF'
1 src/popups/ArchMenu.qml x: 0
1 src/services/compositor/LabwcBackend.qml x: 0, y: 0, width: 0, height: 0
2 src/services/config_tab/KeybindsPage.qml x: 0
1 src/services/config_tab/pages/AppearancePage.qml x: 10
2 src/services/config_tab/pages/DataPage.qml x: 10
3 src/services/config_tab/pages/MiscPage.qml x: 10
1 src/services/system/NiriService.qml x: 0, y: 0, width: 0, height: 0
2 src/windows/TopBar.qml x: 0; y: 0
XEOF
)"
x_now="$(cd "$root" && grep -rnE '^[[:space:]]*x:[[:space:]]*[0-9]' src 2>/dev/null \
         | sed -E 's/^([^:]+):[0-9]+:[[:space:]]*/\1\t/; s/[[:space:]]+/ /g' \
         | sort | uniq -c | sed 's/^ *//')"
x_sites="$(cd "$root" && grep -rhcE '^[[:space:]]*x:[[:space:]]*[0-9]' -r src 2>/dev/null | paste -sd+ | bc 2>/dev/null)"
[ -n "$x_sites" ] || x_sites="$(cd "$root" && grep -rE '^[[:space:]]*x:[[:space:]]*[0-9]' src 2>/dev/null | wc -l)"

if [ "$x_now" = "$x_expect" ]; then
    ok "the $x_sites explicit numeric x: sites left in src/ are exactly the bucketed ones — none of them is a bare left inset"
else
    bad "the explicit numeric x: sites in src/ are exactly the bucketed ones" \
        "the set moved; a new x: is a site mirroring cannot reach and needs a bucket or an anchor"
    diff <(printf '%s\n' "$x_expect") <(printf '%s\n' "$x_now") | sed 's/^/      /'
fi

# The two declarations this round added, asserted as an exact pair. A third
# appearing without the ledger moving is the drift this pin exists to catch.
cfg_mirrored="$(grep -rl 'LayoutMirroring' "$root/src/components/config" 2>/dev/null | wc -l)"
[ "$cfg_mirrored" -eq 2 ] \
    && ok "exactly 2 shared config components declare mirroring (CfgRow, CfgScroll)" \
    || bad "exactly 2 shared config components declare mirroring" "counted $cfg_mirrored"

finish
