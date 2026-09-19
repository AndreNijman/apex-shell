#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  mutate-recovery-a11y.sh — prove tests/check-recovery-a11y.sh can go RED.
#
#  A checker that passes is worth nothing until it has been shown failing at
#  the thing it claims to check. This breaks the shipped markup one edit at a
#  time and requires the suite to fail ON THE NAMED ASSERTION — not merely to
#  fail, which is how a suite that is red for its own reasons gets certified.
#
#  ── Five verdicts, not two ──────────────────────────────────────────────────
#
#  CAUGHT / MISSCORED / CRASHED / SURVIVED, plus UNSCORABLE. CRASHED exists
#  because a mutant that makes the suite exit FATAL prints no totals line, and
#  a harness that counts only failures reads that as "nothing failed" — a
#  working suite reported as a broken one. UNSCORABLE exists because of
#  FOUND 18: a mutant aimed at an assertion the BASELINE never made is neither
#  a catch nor a survival, and scoring it either way invents a verdict.
#
#  ── Restores ────────────────────────────────────────────────────────────────
#
#  From a pristine copy in a per-run mktemp -d, every restore VERIFIED by
#  sha256. Not `git checkout --`: apex-shell's arch-validate job installs git
#  AFTER actions/checkout, so the workspace has no .git at all. The signal
#  handlers EXIT rather than return — FOUND 24: a `trap … EXIT INT TERM` whose
#  handler only returns lets bash resume at the next line after the signal,
#  scoring a verdict for a mutant that was killed and then dying inside the
#  restore on a snapshot the handler has already deleted.
#
#  ── It mutates FOUR files, and that is the point ────────────────────────────
#
#  The page; the two shared components its structure now depends on; and the
#  SERVICE that holds the refusal. The last one matters most. Round 31 made the
#  factory reset's commit button reachable over the accessibility bus, and that
#  is only defensible because the guard lives in RecoveryService.commitReset()
#  rather than in the button's visibility — FOUND 16: an invisible Qt Quick item
#  still publishes its whole subtree. R9 deletes that guard and the suite has to
#  say so.
#
#  Unlike the runtime suites in this tree, this reads source only, so a full
#  run is seconds rather than minutes.
#
#  Run from anywhere: ./tests/mutate-recovery-a11y.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

PAGE="src/services/config_tab/pages/RecoveryPage.qml"
SECTION="src/components/config/CfgSection.qml"
ROW="src/components/config/CfgRow.qml"
SVC="src/services/RecoveryService.qml"
FILES="$PAGE $SECTION $ROW $SVC"
SUITE="./tests/check-recovery-a11y.sh"
TOTALS_PREFIX="recovery-a11y: passed="

command -v python3 >/dev/null 2>&1   || { echo "FATAL: python3 is required" >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { echo "FATAL: sha256sum is required" >&2; exit 2; }
[ -x "$SUITE" ] || { echo "FATAL: $SUITE is not executable" >&2; exit 2; }

applied=0; noapply=0; caught=0; survived=0; misscored=0; held=0; falsered=0
unscorable=0

SNAP="$(mktemp -d "${TMPDIR:-/tmp}/mutate-recovery-a11y.XXXXXX")" || exit 2
# A kill between an edit and its restore — a CI step timeout, a usage limit, a
# closed lid — would otherwise leave a MUTATED file in the tree for every later
# step in the same job, and these files are in the workflow's REQUIRED list, so
# the structure check would still pass and nothing downstream would notice. So
# the restore runs from the trap as well as from each mutant. Guarded on the
# snapshot existing, because the trap is armed before it is taken, and
# deliberately not the `restore` function: that one aborts the run on a sha
# mismatch, which is right mid-run and wrong in an exit handler.
put_back() {
    local f
    if [ -f "$SNAP/baseline.sha256" ]; then
        # shellcheck disable=SC2086
        for f in $FILES; do cp -- "$SNAP/$(snap_of "$f")" "$f" 2>/dev/null; done
    fi
    rm -rf "$SNAP"
}
# Signals get their OWN handlers, and they EXIT. A `trap … INT TERM` whose
# handler merely returns lets the script CARRY ON after the signal: bash defers
# the signal until the running command substitution finishes, runs the handler,
# and then resumes at the next line — which scores a verdict for a mutant that
# was killed, and then dies inside restore() on the snapshot the handler has
# just deleted. Measured exactly that way here before this line existed: the
# tree did come back clean, but the run ended with `cp: cannot stat` and no
# totals line, so it stopped by accident rather than by design. 130 and 143 are
# the conventional 128+SIGINT and 128+SIGTERM.
trap 'put_back; exit 130' INT
trap 'put_back; exit 143' TERM
trap put_back EXIT

snap_of() { printf '%s' "$1" | tr '/' '_'; }

# shellcheck disable=SC2086
take_snapshot() {
    local f
    for f in $FILES; do
        [ -f "$f" ] || { echo "ABORT: $f does not exist" >&2; exit 3; }
        cp -- "$f" "$SNAP/$(snap_of "$f")" || exit 3
    done
    sha256sum -- $FILES >"$SNAP/baseline.sha256" || exit 3
}
tree_clean() { sha256sum -c --status "$SNAP/baseline.sha256" 2>/dev/null; }
# shellcheck disable=SC2086
restore() {
    local f
    for f in $FILES; do cp -- "$SNAP/$(snap_of "$f")" "$f" || exit 3; done
    if ! tree_clean; then
        echo "ABORT: a restored file does not match its baseline sha256;" >&2
        echo "       every verdict after this point would be meaningless" >&2
        sha256sum -c "$SNAP/baseline.sha256" >&2
        exit 3
    fi
}

# env -i, because an assertion whose truth comes from the ambient environment is
# the same defect class as a gate that inspects nothing. XDG_RUNTIME_DIR,
# WAYLAND_DISPLAY and DBUS_SESSION_BUS_ADDRESS are deliberately not passed: the
# suite must build its own or skip, and must never find the desk's.
run_suite() {
    env -i HOME="$HOME" PATH="$PATH" USER="${USER:-$(id -un)}" \
        TMPDIR="${TMPDIR:-/tmp}" "$SUITE" 2>&1
}

has_totals() { [[ "$1" == *"$TOTALS_PREFIX"* ]]; }
suite_failures() {
    printf '%s\n' "$1" \
        | sed -n 's/^recovery-a11y: passed=[0-9]* failed=\([0-9]*\).*/\1/p' \
        | head -1 | grep -E '^[0-9]+$' || echo 0
}

# Membership with `[[ == * *]]`, never `printf | grep -q`: under `pipefail` a
# matching grep -q closes the pipe, the writer takes SIGPIPE, and the pipeline
# reports 141 on a MATCH.
classify() {
    local out="$1" want="$2" line
    if ! has_totals "$out"; then echo CRASHED; return; fi
    while IFS= read -r line; do
        case "$line" in
            "  FAIL "*) [[ "$line" == *"$want"* ]] && { echo CAUGHT; return; } ;;
        esac
    done <<<"$out"
    if [ "$(suite_failures "$out")" -gt 0 ]; then echo MISSCORED; else echo SURVIVED; fi
}

selftest() {
    local red green crash fails=0
    red="  FAIL it declares itself a button  — got '<none>'
recovery-a11y: passed=26 failed=1 skipped=0"
    green="recovery-a11y: passed=27 failed=0 skipped=0"
    crash="FATAL: cannot find src/services/config_tab/pages/RecoveryPage.qml"
    chk() {
        if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
        else printf '  FAIL %s — want %s got %s\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
    }
    chk "a red suite naming the expectation is CAUGHT" \
        CAUGHT    "$(classify "$red"   "it declares itself a button")"
    chk "a red suite NOT naming it is MISSCORED, not a survival" \
        MISSCORED "$(classify "$red"   "a sentence this suite never prints")"
    chk "a green suite is the only thing that is a SURVIVAL" \
        SURVIVED  "$(classify "$green" "a sentence this suite never prints")"
    chk "a suite that never reached its totals line is CRASHED, never a survival" \
        CRASHED   "$(classify "$crash" "a sentence this suite never prints")"
    chk "counting failures off a red totals line"   1 "$(suite_failures "$red")"
    chk "counting failures off a green totals line" 0 "$(suite_failures "$green")"
    chk "a SKIP is not a pass: the totals line carries it separately" \
        1 "$(printf '%s\n' "$green" | grep -c 'skipped=')"
    [ "$fails" -eq 0 ] || { echo "ABORT: the harness cannot score itself" >&2; exit 3; }
}

restore_selftest() {
    take_snapshot
    tree_clean || { echo "ABORT: the snapshot does not match the files it was taken from" >&2; exit 3; }
    printf '\n// mutate-recovery-a11y.sh restore probe\n' >>"$PAGE"
    if tree_clean; then
        echo "ABORT: a real edit to $PAGE was not seen — the baseline is not being read" >&2
        exit 3
    fi
    echo "  ok   a real edit to a file under test is SEEN"
    restore
    echo "  ok   …and the restore puts it back, sha256 for sha256"
}

echo "── self-test: this harness can tell its four verdicts apart ──"
selftest
restore_selftest

apply_edit() {
    local file="$1" from="$2" to="$3"
    python3 - "$file" "$from" "$to" <<'EDIT'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding="utf-8").read()
if s.count(a) < 1:
    sys.exit(1)
open(p, 'w', encoding="utf-8").write(s.replace(a, b, 1))
EDIT
    tree_clean && return 1
    return 0
}

echo
echo "── the baseline, before anything is touched ──"
base="$(run_suite)"
if ! has_totals "$base"; then
    echo "ABORT: the baseline never reached its totals line; nothing can be scored" >&2
    printf '%s\n' "$base" | tail -15 >&2
    exit 3
fi
printf '%s\n' "$base" | sed -n 's/^recovery-a11y: /  baseline  /p'
if [ "$(suite_failures "$base")" -gt 0 ]; then
    echo "ABORT: the baseline is already RED. Fix that before mutating anything." >&2
    printf '%s\n' "$base" | grep -E '^  FAIL' >&2
    exit 3
fi
base_oks="$(printf '%s\n' "$base" | grep -c '^  ok   ')"

# FOUND 18, learned on the GitHub Arch runner: a suite that SKIPPED out before
# its first assertion printed passed=0 failed=0 and a mutation harness graded
# eleven mutants against it. "Was the baseline green" is not the question.
# Unlike the runtime suites this one needs nothing but python3, so a short
# baseline here is a BROKEN suite rather than a machine that cannot host it —
# and it aborts instead of skipping.
if [ "$base_oks" -lt 20 ]; then
    echo "ABORT: the baseline made only $base_oks assertions. This suite needs" >&2
    echo "       nothing but python3, so that is a broken suite and not a" >&2
    echo "       machine that cannot host it. Scoring mutants against it would" >&2
    echo "       invent verdicts about nothing." >&2
    printf '%s\n' "$base" | grep -E '^  SKIP' | sed 's/^/       /' >&2
    exit 3
fi
echo "  baseline made $base_oks assertions"

baseline_asserts() {
    local want="$1" line
    while IFS= read -r line; do
        case "$line" in
            "  ok   "*) [[ "$line" == *"$want"* ]] && return 0 ;;
        esac
    done <<<"$base"
    return 1
}

mutate() {  # mutate <id> <file> <from> <to> <assertion substring that must go red>
    local id="$1" file="$2" from="$3" to="$4" want="$5"
    tree_clean || { echo "ABORT: tree dirty BEFORE $id" >&2; exit 3; }
    if ! baseline_asserts "$want"; then
        printf '%-5s UNSCORABLE the baseline never asserted: %s\n' "$id" "$want"
        printf '      A mutant aimed at a check that did not run is not a survival\n'
        printf '      and not a catch. It is nothing, and it is counted as nothing.\n'
        unscorable=$((unscorable + 1)); return
    fi
    if ! apply_edit "$file" "$from" "$to"; then
        printf '%-5s NO-APPLY  anchor absent in %s — this mutant proves nothing\n' "$id" "$file"
        noapply=$((noapply + 1)); restore; return
    fi
    applied=$((applied + 1))
    local out verdict; out="$(run_suite)"; verdict="$(classify "$out" "$want")"
    case "$verdict" in
    CAUGHT)    printf '%-5s CAUGHT    %s\n' "$id" "$want"; caught=$((caught + 1)) ;;
    MISSCORED)
        printf '%-5s MISSCORED the suite went red (%s failed) but not on the named assertion\n' \
               "$id" "$(suite_failures "$out")"
        printf '      expected a FAIL line containing: %s\n' "$want"
        printf '      ── FIX THE EXPECTATION, NOT THE CODE. What actually went red: ──\n'
        printf '%s\n' "$out" | grep -E '^  (FAIL|SKIP)' | sed 's/^/      /'
        misscored=$((misscored + 1)) ;;
    CRASHED)
        printf '%-5s MISSCORED the suite never reached its totals line\n' "$id"
        printf '%s\n' "$out" | tail -6 | sed 's/^/      /'
        misscored=$((misscored + 1)) ;;
    *)
        printf '%-5s SURVIVED  %s\n' "$id" "$want"
        printf '      the suite stayed GREEN with this broken. The assertion is vacuous.\n'
        survived=$((survived + 1)) ;;
    esac
    restore
}

hold() {  # hold <id> <file> <from> <to> <what it proves>
    local id="$1" file="$2" from="$3" to="$4" what="$5"
    tree_clean || { echo "ABORT: tree dirty BEFORE $id" >&2; exit 3; }
    if ! apply_edit "$file" "$from" "$to"; then
        printf '%-5s NO-APPLY  anchor absent — this hold proves nothing\n' "$id"
        noapply=$((noapply + 1)); restore; return
    fi
    applied=$((applied + 1))
    local out; out="$(run_suite)"
    if ! has_totals "$out"; then
        printf '%-5s FALSE-RED the suite did not even finish: %s\n' "$id" "$what"
        falsered=$((falsered + 1)); restore; return
    fi
    if [ "$(suite_failures "$out")" -eq 0 ]; then
        printf '%-5s HELD      %s\n' "$id" "$what"; held=$((held + 1))
    else
        printf '%-5s FALSE-RED %s\n' "$id" "$what"
        printf '%s\n' "$out" | grep -E '^  FAIL' | sed 's/^/      /'
        falsered=$((falsered + 1))
    fi
    restore
}


echo
echo "── RED: break the SHIPPED markup, and the CHECKER has to notice ──"

# Rule 2. A role with no name is the exact shape Qt's silent fallback hides.
mutate R1 "$PAGE" '                            Accessible.name: commitBtn.a11yLabel
' \
                  '' \
    'carry an explicit Accessible.name'

# Rule 1, and the one that took two goes to get right in the lock screen suite.
# The character is built from its NUMBER by printf and never written as a
# character: a literal did not survive being written to the file there — what
# landed was U+F033 followed by the letter E, a different codepoint in a
# different plane — and nothing in the source made that visible. An unprintable
# character in a source file is not reviewable; an escape is.
# Built by PYTHON and not by `printf`. Measured 2026-09-19: under a C/POSIX
# locale — `env -i`, and the CI container — bash's `printf '\U000f033e'`
# emits the ten ASCII bytes `\U000F033E` rather than the character, so a
# mutant built that way inserts plain letters the private-use class cannot
# match and reports SURVIVED (or, worse, CAUGHT for the wrong reason) on
# exactly the machines the gate runs on. The third way this unit has lost one
# of these characters in transit; FOUND 23 has the other two.
PUA_CHAR="$(python3 -c 'import sys; sys.stdout.write("\U000f033e")')"
if [ "$(printf '%s' "$PUA_CHAR" | wc -c)" != "4" ]; then
    echo "ABORT: the private-use character is $(printf '%s' "$PUA_CHAR" | wc -c) bytes, not the 4 of U+F033E in UTF-8." >&2
    echo "       R2 and G3 would be mutating plain ASCII and proving nothing." >&2
    exit 3
fi
mutate R2 "$PAGE" '                            Accessible.name: commitBtn.a11yLabel' \
                  "                            Accessible.name: \"${PUA_CHAR} \" + commitBtn.a11yLabel" \
    'no Accessible.* binding on this page contains a private-use codepoint'

# The same rule from the other side: markup put ON a glyph rather than a glyph
# put into markup. This is the tempting mistake — the icon looks like the thing
# that carries the state, so naming it looks like the fix.
mutate R3 "$PAGE" '                    font.pixelSize: theme.fs(28)' \
                  '                    Accessible.role: Accessible.StaticText
                    Accessible.name: "refresh"
                    font.pixelSize: theme.fs(28)' \
    'no object whose text IS a glyph carries any Accessible.* binding'

mutate R4 "$PAGE" '                                Accessible.name: (lossRow.loss ? lossRow.loss.relative : "")
                                    + (lossRow.loss && !lossRow.loss.backedUp
                                       ? " — NOT backed up" : "")' \
                  '                                Accessible.name: (lossRow.loss ? lossRow.loss.relative : "")' \
    'a loss row that is not backed up says so in its NAME'

mutate R5 "$PAGE" '                Accessible.role: Accessible.ListItem
                Accessible.name: (routeRow.route ? routeRow.route.id : "")' \
                  '                Accessible.name: (routeRow.route ? routeRow.route.id : "")' \
    'the 6 recovery routes are named on the bus (routeRow)'

mutate R6 "$PAGE" '                            Accessible.onPressAction: commitBtn.press()' \
                  '                            Accessible.onPressAction: RecoveryService.commitReset()' \
    'a reader presses it through the SAME press() a pointer does'

mutate R7 "$PAGE" '                            activeFocusOnTab: RecoveryService.commitReady' \
                  '                            activeFocusOnTab: true' \
    'its tab stop exists only while the button does'

mutate R8 "$PAGE" '                            Keys.onPressed: function (event) {' \
                  '                            function unreachable(event) {' \
    'and a keyboard can press it'

# The gate itself, in the SERVICE. This is the mutant that says exposing the
# button over the accessibility bus did not become a way around the refusal.
mutate R9 "$SVC" '        if (root.resetPhase !== "planned") return
        const argv = Rec.commitArgv' \
                 '        const argv = Rec.commitArgv' \
    'the service refuses a commit the rendered list does not cover'

# The shared component. Losing the group does not lose a NAME anywhere — it
# loses the STRUCTURE, and the delegate rows stop being children of anything.
# This one SURVIVED when it was first written, and the survival was correct:
# every assertion in the suite was about RecoveryPage.qml, so deleting the
# grouping from the shared component left the page's own markup intact and the
# checker green — while the measured consequence is that the page's rows stop
# being children of anything at all. §6 exists because of this mutant.
mutate R10 "$SECTION" '    Accessible.role: Accessible.Grouping' \
                      '    Accessible.ignored: true' \
    'a settings section is a GROUP, so this page'"'"'s rows have a parent on the bus'

mutate R11 "$SECTION" '    Accessible.name: root.title' \
                      '    Accessible.name: "Settings"' \
    'the group is named by its title'

mutate R12 "$PAGE" '                            enabled: RecoveryService.commitReady' \
                   '                            enabled: true' \
    'the BUS is told it is unavailable before the loss list exists'

# The defect that could not be committed. Swapping these two back is a one-line
# edit that nothing else in this repository notices: recovery-test.js tests
# commitArgv, which is correct in isolation, and check-recovery-ui.sh asserts
# the wiring exists, which it does.
mutate R13 "$SVC" '        root.resetPhase = "planned"
        root.plan = p' \
                  '        root.plan = p
        root.resetPhase = "planned"' \
    '_onPlan() sets resetPhase BEFORE plan'

mutate R14 "$PAGE" '                            function onResetPhaseChanged() { lossList._ack() }' \
                   '                            function onResetMessageChanged() { lossList._ack() }' \
    'the loss list re-acknowledges on a phase change'

echo
echo "── GREEN: prose and unasserted markup must not move a single verdict ──"

# The one that matters most in this repository: five checks here have been
# satisfied by the prose in the very file they guarded. This quotes every rule
# the suite enforces, in a comment, and must change nothing.
hold G1 "$PAGE" '    // ── Header ─' \
                '    // Accessible.role: Accessible.Button and Accessible.name: "Erase 4
    // item(s) now" and Accessible.onPressAction: commitBtn.press() and
    // activeFocusOnTab: RecoveryService.commitReady go somewhere below this
    // line, and none of it is markup.
    // ── Header ─' \
    'prose quoting every rule this suite enforces stays green'

hold G2 "$PAGE" '                            Accessible.name: commitBtn.a11yLabel' \
                '                            objectName: "apex-mutation-hold"
                            Accessible.name: commitBtn.a11yLabel' \
    'a property nothing asserts is not a failure'

# A glyph with NO markup is the SHIPPED state and must stay green. Without this
# the icon rule would also be satisfied by a checker that simply refuses icons,
# and this page would have to stop drawing them to go green.
hold G3 "$PAGE" '    Item { width: parent.width; height: theme.px(10) }' \
                "    Text { text: \"${PUA_CHAR}\" }
    Item { width: parent.width; height: theme.px(10) }" \
    'an icon that carries no accessibility markup is not a finding'

restore

echo
printf 'mutate-recovery-a11y: applied=%d caught=%d survived=%d misscored=%d unscorable=%d held=%d false-red=%d\n' \
    "$applied" "$caught" "$survived" "$misscored" "$unscorable" "$held" "$falsered"
[ "$noapply" -gt 0 ] && printf '  %d mutant(s) DID NOT APPLY — their anchors have moved and they proved nothing\n' "$noapply"

rc=0
[ "$survived"   -gt 0 ] && { echo "  FAIL — a vacuous assertion: the suite stayed green with a real defect in place"; rc=1; }
[ "$misscored"  -gt 0 ] && { echo "  FAIL — a mutant went red on the wrong line; the expectation is wrong"; rc=1; }
[ "$unscorable" -gt 0 ] && { echo "  FAIL — a mutant aimed at an assertion the baseline never made"; rc=1; }
[ "$falsered"   -gt 0 ] && { echo "  FAIL — the suite went red at prose or at markup nothing asserts"; rc=1; }
[ "$noapply"    -gt 0 ] && { echo "  FAIL — a mutant's anchor no longer exists in the source"; rc=1; }
exit "$rc"
