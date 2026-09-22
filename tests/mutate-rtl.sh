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

applied=0; noapply=0; caught=0; survived=0; misscored=0

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

# How many assertions the suite reported FAILED, or 0 if it printed no totals
# line at all (a crash, which must never read as a clean green run).
suite_failures() {
    printf '%s\n' "$1" \
        | sed -n 's/^run-rtl-test: [0-9]* passed, \([0-9]*\) failed.*/\1/p' \
        | head -1 | grep -E '^[0-9]+$' || echo 0
}

# classify <suite output> <want> -> CAUGHT | EXCUSED | MISSCORED | SURVIVED
#
# Factored out of mutate() so it can be exercised on canned output below. A
# multi-way verdict that has never been shown to produce all its answers is a
# gate that inspects nothing -- the dominant defect family in this repository,
# and one this harness exists to catch in other people's suites.
#
# EXCUSED is round 32's addition and it exists because run-rtl-test.sh now has
# a FOURTH outcome. Three of its assertions are gated on a measured
# precondition and report CANTRUN -- a named could-not-run -- on a machine
# whose platform theme carries no Qt translation loader. A mutant whose target
# row could-not-RAN was never evaluated, so calling that a SURVIVAL would
# accuse the suite of a vacuous assertion it never made, and calling it CAUGHT
# would be worse. It is neither: it is a verdict this harness may not give, and
# it fails the run.
#
# The gate cannot engage on a booted APEX host, which is where this harness is
# run, so in practice this arm should never fire. "Should never fire" is
# exactly the kind of claim this tree has been wrong about before, so it is
# detected rather than assumed.
classify() {
    local out="$1" want="$2"
    if printf '%s' "$out" | grep -q "^FAIL  .*$want"; then
        echo CAUGHT
    elif printf '%s' "$out" | grep -q "^CANTRUN  .*$want"; then
        echo EXCUSED
    elif [ "$(suite_failures "$out")" -gt 0 ]; then
        echo MISSCORED
    else
        echo SURVIVED
    fi
}

# ── self-test: the scoring above, in all three states and both directions ────
selftest() {
    local red green fails=0
    # The canned totals lines are the REAL format, four fields since round 32.
    # A self-test written against a format the suite no longer prints would
    # pass while the parser it is testing had stopped working.
    red="FAIL  the explicit numeric x: sites in src/ are exactly the bucketed ones — the set moved
run-rtl-test: 24 passed, 6 failed, 0 skipped, 0 could-not-run"
    green="run-rtl-test: 37 passed, 0 failed, 0 skipped, 0 could-not-run"
    excused="CANTRUN  with qt6ct loaded the direction follows the locale — MEASURED: links no libKF6I18n
run-rtl-test: 30 passed, 0 failed, 1 skipped, 3 could-not-run"

    chk() {  # chk <label> <want> <got>
        if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
        else printf '  FAIL %s — want %s got %s\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
    }
    chk "a red suite naming the expectation is CAUGHT" \
        CAUGHT    "$(classify "$red"   "sites in src/ are exactly the bucketed ones")"
    chk "a red suite NOT naming it is MISSCORED, not a survival" \
        MISSCORED "$(classify "$red"   "a sentence this suite never prints")"
    chk "a green suite is the only thing that is a SURVIVAL" \
        SURVIVED  "$(classify "$green" "a sentence this suite never prints")"
    chk "a row the suite COULD NOT RUN is EXCUSED, not a survival" \
        EXCUSED   "$(classify "$excused" "the direction follows the locale")"
    chk "and a could-not-run the mutant was not aimed at is still a survival" \
        SURVIVED  "$(classify "$excused" "a sentence this suite never prints")"
    chk "counting failures off a red totals line"   6 "$(suite_failures "$red")"
    chk "counting failures off a green totals line" 0 "$(suite_failures "$green")"
    chk "output with no totals line at all counts 0 and cannot read as green" \
        0 "$(suite_failures "crashed before printing anything")"
    [ "$fails" -eq 0 ] || { echo "ABORT: the harness cannot score itself" >&2; exit 3; }
}

echo "── self-test: this harness can tell its three verdicts apart ──"
selftest

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

    # The expectation must be a substring of the suite's FAIL label, and the
    # FAIL label is NOT reliably the PASS label minus its parenthetical — this
    # harness said it was, and for five assertions in run-rtl-test.sh it was
    # false, which is how R10 came back SURVIVED while the suite was red on six
    # lines. Those five labels have been aligned; `classify` catches the next
    # one rather than reporting it as a product defect.
    local out verdict; out="$(run_suite)"; verdict="$(classify "$out" "$want")"
    if [ "$verdict" = CAUGHT ]; then
        printf '%-5s CAUGHT    %s\n' "$id" "$want"
        caught=$((caught + 1))
    elif [ "$verdict" = MISSCORED ]; then
        # NOT a survival. The suite went red -- just not on the assertion this
        # mutant NAMES. The two states look identical if you only grep for one
        # sentence, and this unit has now recorded the wrong one FIVE times
        # (I2, B2, F3-F5, R10); every time it was chased as a product defect
        # before somebody read the output. They are mechanically
        # distinguishable, so the harness distinguishes them.
        printf '%-5s MISSCORED the suite went red (%s failed) but not on the named assertion\n' \
               "$id" "$(suite_failures "$out")"
        printf '      expected a FAIL line containing: %s\n' "$want"
        printf '      ── FIX THE EXPECTATION, NOT THE CODE. What actually went red: ──\n'
        printf '%s\n' "$out" | grep -E '^FAIL' | sed 's/^/      /'
        misscored=$((misscored + 1))
    elif [ "$verdict" = EXCUSED ]; then
        # The row this mutant is aimed at reported a could-not-run, so it was
        # never evaluated and no verdict about it is available. Counted with
        # the misscores because it means the same thing: this harness cannot
        # score this mutant on this machine and must not pretend otherwise.
        printf '%-5s EXCUSED   the target row could-not-RAN; no verdict is available\n' "$id"
        printf '      the assertion aimed at: %s\n' "$want"
        printf '%s\n' "$out" | grep -E '^CANTRUN' | sed 's/^/      /'
        misscored=$((misscored + 1))
    else
        printf '%-5s SURVIVED  %s\n' "$id" "$want"
        printf '      ── the suite stayed GREEN with this mutant applied ──\n'
        printf '%s\n' "$out" | grep -E '^(FAIL|SKIP|CANTRUN|run-rtl-test)' | sed 's/^/      /'
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
#      IT SURVIVED TWICE, for two DIFFERENT reasons, and both times the mutant
#      was right and the fixture was wrong.
#
#      FIRST SURVIVAL (round 23). Every geometric assertion in the fixture
#      FORCED mirroring on by hand, and a row hardcoded `enabled: false` still
#      mirrors when you set it yourself; the one assertion that read the shipped
#      binding compared it against `Qt.application.layoutDirection`, which is
#      LeftToRight on an English desktop, so `false === false` passed. The fix
#      was to run the fixture TWICE -- scrubbed, and under the RTL locale with
#      the image's platform theme -- so test_040 is asked the question with the
#      application actually in RightToLeft.
#
#      SECOND SURVIVAL (round 25), and it is the subtler one. The two-pass run
#      landed and this mutant STILL lived, because test_040 was reading `row` --
#      the same instance test_030 had just finished driving. test_030 forces
#      mirroring both ways and then calls `restoreBinding()`, which installs the
#      CORRECT binding imperatively; QtTest runs functions in name order, so by
#      the time test_040 looked, the suite had REPAIRED the exact declaration
#      the mutant broke. "Nothing was set by hand" was simply false -- something
#      had been set by hand, and it happened to be the right thing.
#
#      The fix is `row2` and `scroll2` in the fixture: instances nothing
#      anywhere writes to, which is the whole reason they exist. test_040 and
#      test_060 read those. A restored binding masking a broken declaration is
#      the same false-green family as N8 and K4 -- an assertion that cannot fail
#      because the thing it measures was repaired before it looked.
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
#      not: the count must move and the suite must say so, because "0 of 14"
#      is the honest half of this row and a silently drifting number is how a
#      named remaining half becomes a forgotten one.
#
#      Round 32 makes this mutant sharper than it was. What it writes is
#      EXACTLY the edit somebody closing standing-queue item 7 would make, and
#      that edit is a SILENT NO-OP: PanelWindow's chain is
#      PanelWindowInterface -> WindowInterface -> Reloadable -> QObject, with
#      no Item and no Window in it, so Qt attaches nothing, creates the object
#      anyway, leaves errorString() empty and prints one QWARN. Before round 32
#      this suite counted the STRING, so that no-op would have moved the count
#      from 0 to 14 and been signed off as the remaining half of the row. The
#      two rows this mutant now sits above are what stop that.
mutate R4 "$WIN" \
    'PanelWindow {' \
    'PanelWindow {
    LayoutMirroring.enabled: false' \
    "window roots declare mirroring"

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
    "explicit numeric x: sites in src/ are exactly the bucketed ones"

# R11 — the anchor stays but the inset changes. Nothing about the SET of x:
#       sites moves, so only the geometry read off the live banner can see it.
#       This is the mutant that proves the banner assertion is a measurement and
#       not a grep for the word `anchors`.
mutate R11 "$SCROLL" \
    '        anchors.leftMargin: 2' \
    '        anchors.leftMargin: 4' \
    "lifecycle banner keeps its 2px inset"

# R12 — the same hardcode on the OTHER component that declares mirroring. R1
#       covers CfgRow; nothing covered CfgScroll's own declaration until
#       test_060 existed, and section 3 only COUNTS the files containing the
#       word `LayoutMirroring` -- a count cannot tell a live binding from one
#       that is present and overridden. Like R1, this can only die in the RTL
#       pass, and only against an instance the fixture never touches: test_050
#       drives `scroll` and restores its binding by hand, so a mutant measured
#       there would be masked exactly as R1 was.
mutate R12 "$SCROLL" \
    '    LayoutMirroring.enabled: Qt.application.layoutDirection === Qt.RightToLeft' \
    '    LayoutMirroring.enabled: false' \
    "an untouched CfgScroll mirrors on its shipped declaration alone"

# R13 — and the other direction, because an assertion that can only fail one way
#       is half an assertion. R12 is caught in the RTL pass; this one is caught
#       in the LTR pass, where a container that mirrors ALWAYS puts its banner
#       on the right of an English settings page. R2 is the same pair for
#       CfgRow. test_050 cannot see either of these -- it sets the switch
#       itself before measuring.
mutate R13 "$SCROLL" \
    '    LayoutMirroring.enabled: Qt.application.layoutDirection === Qt.RightToLeft' \
    '    LayoutMirroring.enabled: true' \
    "an untouched CfgScroll mirrors on its shipped declaration alone"

# R14 — the attach probe's CONTROL. Both halves of that row are turned into
#       the same question, so the probe can no longer tell "LayoutMirroring
#       silently does nothing HERE" from "LayoutMirroring does nothing
#       ANYWHERE". A row whose control has stopped controlling must not stay
#       green: without it, "the no-op is silent" would be a sentence about a
#       probe that measures one thing twice.
mutate R14 "$SUITE_F" \
    '    Component { id: asWindow; Window { LayoutMirroring.enabled: true } }' \
    '    Component { id: asWindow; QtObject { LayoutMirroring.enabled: true } }' \
    "attaching LayoutMirroring to a non-Item is a SILENT no-op"

# R15 — the OTHER direction of the prototype-chain row, and the direction that
#       actually matters. That row exists to go RED on the day Quickshell gives
#       its windows an Item or Window ancestor, because that is the day
#       standing-queue item 7 stops being impossible and becomes a task. This
#       makes the walk find an ancestor where there is none, and the suite has
#       to say THE ROUTE HAS OPENED rather than quietly keep reporting a gap
#       that is no longer a gap. A pin that can only fail when things get worse
#       is half a pin.
mutate R15 "$SUITE_F" \
    '        [ "$link" = "Item" ] && has_item=1' \
    '        [ "$link" = "Reloadable" ] && has_item=1' \
    "the shell's window roots are types LayoutMirroring cannot attach to"

echo
printf 'mutants applied=%d, failed-to-apply=%d, caught=%d, SURVIVED=%d, MISSCORED=%d\n' \
    "$applied" "$noapply" "$caught" "$survived" "$misscored"
[ "$misscored" -eq 0 ] || echo "MISSCORED means this harness is wrong, not the shell." >&2
tree_clean || { echo "ABORT: tree dirty at end of run" >&2; exit 3; }
echo "the tree matches HEAD"
[ "$survived" -eq 0 ] && [ "$noapply" -eq 0 ] && [ "$misscored" -eq 0 ]
