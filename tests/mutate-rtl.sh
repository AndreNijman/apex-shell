#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  mutate-rtl.sh — prove run-rtl-test.sh can go red.
#
#  Mirroring is the shape of claim that is easiest to assert vacuously: every
#  one of these assertions can be written so that it passes over a tree that
#  does not mirror at all. Section 2's first version did exactly that — it
#  measured the label `Text`, which sits at x=0 inside its own column and reads
#  zero whether or not the row mirrors, so it reported "x=0 → x=0" and looked
#  like a product defect when it was a measurement defect.
#
#  Each mutant changes ONE arm and a NAMED assertion must go red.
#
#  Restores are `git checkout --`: authoritative about content, and a fresh
#  mtime. The file set is compared against HEAD after every mutate AND every
#  restore — a run that produces verdicts against a tree that is wrong in a
#  place no assertion looks at is a run that means nothing.
#
#  Run from anywhere: ./tests/mutate-rtl.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

ROW="src/components/config/CfgRow.qml"
SCROLL="src/components/config/CfgScroll.qml"
FIX="tests/rtl-test.qml"
SUITE_F="tests/run-rtl-test.sh"
# R4 mutates a window root, so that file has to be in the set the harness
# restores and compares -- a mutant applied to a file outside $FILES is never
# put back, and every verdict after it would be about a tree nobody is watching.
WIN="src/windows/TopBar.qml"
FILES="$ROW $SCROLL $FIX $SUITE_F $WIN"
SUITE="./tests/run-rtl-test.sh"

applied=0; noapply=0; caught=0; survived=0

tree_clean() { [ -z "$(git diff --name-only -- $FILES 2>/dev/null)" ]; }

restore() {
    git checkout -- $FILES 2>/dev/null
    if ! tree_clean; then
        echo "ABORT: tree still dirty after restore; verdicts would be meaningless" >&2
        git diff --stat -- $FILES >&2
        exit 3
    fi
}

run_suite() {
    env -i HOME="$HOME" PATH="$PATH" USER="${USER:-$(id -un)}" \
        TMPDIR="${TMPDIR:-/tmp}" "$SUITE" 2>&1
}

# mutate <id> <file> <from> <to> <assertion substring that must go red>
mutate() {
    local id="$1" file="$2" from="$3" to="$4" want="$5"

    tree_clean || { echo "ABORT: tree dirty BEFORE $id" >&2; exit 3; }
    if ! grep -qF -- "$from" "$file"; then
        printf '%-5s NO-APPLY  anchor absent in %s — this mutant proves nothing\n' "$id" "$file"
        noapply=$((noapply + 1)); return
    fi
    python3 - "$file" "$from" "$to" <<'EDIT'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding="utf-8").read()
assert s.count(a) >= 1
open(p, 'w', encoding="utf-8").write(s.replace(a, b, 1))
EDIT
    if tree_clean; then
        printf '%-5s NO-APPLY  the edit changed nothing\n' "$id"
        noapply=$((noapply + 1)); restore; return
    fi
    applied=$((applied + 1))

    local out; out="$(run_suite)"
    # The expectation is the PASS text minus its parenthetical. Three rounds of
    # this unit have recorded a mutant as SURVIVED because the harness grepped
    # for a sentence the failure does not contain (I2, B2, F3-F5) — every one of
    # those was the expectation being wrong, not the mutant.
    if printf '%s' "$out" | grep -q "^FAIL  .*$want"; then
        printf '%-5s CAUGHT    %s\n' "$id" "$want"
        caught=$((caught + 1))
    else
        printf '%-5s SURVIVED  %s\n' "$id" "$want"
        printf '      ── what the suite said instead ──\n'
        printf '%s\n' "$out" | grep -E '^(FAIL|SKIP|run-rtl-test)' | sed 's/^/      /'
        survived=$((survived + 1))
    fi
    restore
}

echo "── baseline: green, or nothing below means anything ──"
base="$(run_suite)"
printf '%s\n' "$base" | grep -E '^run-rtl-test'
if ! printf '%s' "$base" | grep -qE '^run-rtl-test: [0-9]+ passed, 0 failed'; then
    echo "ABORT: the suite is not green to begin with" >&2
    printf '%s\n' "$base" | grep -E '^(FAIL|SKIP)' >&2
    exit 3
fi

echo
echo "── the mutants ──"

# R1 — the row stops mirroring at all. The regression this work exists to
#      prevent, and the one a later refactor is most likely to cause by moving
#      the declaration to a parent that does not exist.
#
#      IT SURVIVED THE FIRST RUN OF THIS HARNESS, and the mutant was right. Every
#      geometric assertion in the fixture FORCED mirroring on by hand, and a row
#      hardcoded `enabled: false` still mirrors when you set it yourself; the one
#      assertion that read the shipped binding compared it against
#      `Qt.application.layoutDirection`, which is LeftToRight on an English
#      desktop, so `false === false` passed. The suite now runs the fixture TWICE
#      -- scrubbed and under the RTL locale with the image's platform theme --
#      and test_040 reads the row with nothing set at all. This mutant dies in
#      the RTL pass.
mutate R1 "$ROW" \
    '    LayoutMirroring.enabled: Qt.application.layoutDirection === Qt.RightToLeft' \
    '    LayoutMirroring.enabled: false' \
    "and with NOTHING set by hand the row matches"

# R2 — the row mirrors ALWAYS, not when the application does. Every geometric
#      assertion in section 2 still passes: the row does mirror when told to.
#      Only the assertion that reads the switch off the live attached object and
#      compares it with Qt.application.layoutDirection can see this, and the
#      user-visible result is a settings page that is backwards in English.
mutate R2 "$ROW" \
    '    LayoutMirroring.enabled: Qt.application.layoutDirection === Qt.RightToLeft' \
    '    LayoutMirroring.enabled: true' \
    "CfgRow mirrors exactly when the application does"

# R3 — the row mirrors itself and leaves everything inside it alone. This is the
#      half-mirrored row: the label swaps sides, the control the page handed it
#      does not, and the result looks more broken than no mirroring.
mutate R3 "$ROW" \
    '    LayoutMirroring.childrenInherit: true' \
    '    LayoutMirroring.childrenInherit: false' \
    "CfgRow passes mirroring down to the control it holds"

# R4 — the pin in section 3. A window root gains mirroring and the ledger does
#      not: the count must move and the suite must say so, because "0 of 14
#      mirror" is the honest half of this row and a silently drifting number is
#      how a named remaining half becomes a forgotten one.
mutate R4 "$WIN" \
    'PanelWindow {' \
    'PanelWindow {
    LayoutMirroring.enabled: false' \
    "window roots mirror"

# R5 — the locale probe stops varying. Both runs are handed the same locale, so
#      the section measures a constant while printing a number that looks like a
#      measurement. The disagreement assertion is the only thing standing
#      between that and four green lines.
mutate R5 "$SUITE_F" \
    '    with_theme_ltr="$(app_dir ""         "$THEME")"' \
    '    with_theme_ltr="$(app_dir "$L_RTL"   "$THEME")"' \
    "the direction follows the locale"

# R6 — the fixture's own vacuity floor. Delete a test function and QtTest
#      happily reports the rest as passing; the exact count is what turns a
#      quietly shrinking fixture into a failure. Same shape as B5 in the
#      installer set and EXPECT_WHITE_FG in check-color-tokens.sh.
mutate R6 "$FIX" \
    '        function test_030_a_real_row_swaps_its_label_and_its_control() {' \
    '        function DISABLED_030_a_real_row_swaps_its_label_and_its_control() {' \
    "the fixture ran all"

# R7 — the toolkit control. If the engine itself stopped mirroring, every
#      verdict here would be about Qt rather than about this repository, and the
#      suite has to notice rather than report the row as broken.
mutate R7 "$FIX" \
    '            plain.LayoutMirroring.enabled = true' \
    '            plain.LayoutMirroring.enabled = false' \
    "the engine mirrors a plain left anchor"

# R8 — the PLATFORM THEME is dropped from the positive probe. This is the
#      regression that would follow from someone removing
#      QT_QPA_PLATFORMTHEME=qt6ct from the image, and round 23 measured that it
#      is the whole mechanism: Qt decides the application direction by
#      translating QT_LAYOUT_DIRECTION, quickshell installs no QTranslator, and
#      the qt6ct platform theme -- configured for a dark palette -- is what
#      brings one. Without it, ar_EG comes back LeftToRight and every mirrored
#      surface in the shell silently stops mirroring.
#
#      It lands on the same named assertion as R5 and that is deliberate: they
#      are two different arms of the one claim that the direction is not a
#      constant. B13/B14 in the installer set are the same shape.
mutate R8 "$SUITE_F" \
    '    with_theme_rtl="$(app_dir "$L_RTL"   "$THEME")"' \
    '    with_theme_rtl="$(app_dir "$L_RTL"   "")"' \
    "the direction follows the locale"

# R9 — the ceiling row stops being a ceiling. `ur_PK` is asked because Qt ships
#      no qt_ur.qm; handing that probe a locale Qt DOES have a catalogue for
#      turns the pin into a statement that is simply false, and the row must say
#      so rather than reporting a limit it did not measure.
mutate R9 "$SUITE_F" \
    'L_RTL="ar_EG.UTF-8"; L_RTL2="he_IL.UTF-8"; L_NOCAT="ur_PK.UTF-8"' \
    'L_RTL="ar_EG.UTF-8"; L_RTL2="he_IL.UTF-8"; L_NOCAT="ar_EG.UTF-8"' \
    "an RTL language Qt has no catalogue for does NOT flip"

# R10 — the bare `x:` comes back. Round 23 converted three sites that mirroring
#       cannot reach into anchors; this puts the worst of them back, the
#       lifecycle banner inside the component that declares the mirroring. The
#       allowlist in section 3 is a SET rather than a count for exactly this: a
#       count would have read the same if one site were fixed and another added.
mutate R10 "$SCROLL" \
    '        anchors.left:       root.left
        anchors.leftMargin: 2' \
    '        x:     2' \
    "explicit numeric x: sites left in src/ are exactly the bucketed ones"

# R11 — the anchor stays but the inset changes. Nothing about the SET of x:
#       sites moves, so only the geometry read off the live banner can see it.
#       This is the mutant that proves the banner assertion is a measurement and
#       not a grep for the word `anchors`.
mutate R11 "$SCROLL" \
    '        anchors.leftMargin: 2' \
    '        anchors.leftMargin: 4' \
    "lifecycle banner keeps its 2px inset"

echo
printf 'mutants applied=%d, failed-to-apply=%d, caught=%d, SURVIVED=%d\n' \
    "$applied" "$noapply" "$caught" "$survived"
tree_clean || { echo "ABORT: tree dirty at end of run" >&2; exit 3; }
echo "the tree matches HEAD"
[ "$survived" -eq 0 ] && [ "$noapply" -eq 0 ]
