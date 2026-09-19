#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  mutate-recovery-atspi-shim.sh — prove run-recovery-atspi-shim.sh can go red,
#  and prove it does not go red at prose.
#
#  ── Why this pair is worth its running time ─────────────────────────────────
#
#  The suite it guards does something no other suite in this tree does: it
#  DRIVES the product's most destructive flow over the accessibility bus and
#  reads a recording `apex` stub's argv to see what really happened. That makes
#  its headline claims — "a reader can finish this" and "a reader cannot finish
#  it early" — checkable facts rather than readings of the markup. It also
#  makes them expensive to get wrong: a green run that could not tell a
#  completable reset from an uncompletable one would certify the exact defect
#  this suite was written after.
#
#  So the mutants break the SHIPPED code and require the BUS to notice.
#
#  ── The one that earns the pair ─────────────────────────────────────────────
#
#  R12 is a PAIR of edits, and it is deliberately not a single one.
#
#  Until 2026-09-19 the factory reset could not be completed by anybody —
#  mouse, keyboard or screen reader. RecoveryService._onPlan() assigned `plan`
#  before `resetPhase`; QML property notifications are synchronous, so the loss
#  list acknowledged itself while the phase was still "planning";
#  acknowledgeLossList() refuses in that state at its first guard; nothing ever
#  acknowledged again, so commitReady was false for ever. The fix put the two
#  assignments the right way round AND gave the page a phase-change re-ack, so
#  that the order stops being load-bearing. Either half alone is now sufficient.
#
#  That is defence in depth, and the honest consequence is that NO SINGLE EDIT
#  can reproduce the defect. A harness that pretended otherwise — by picking
#  whichever half it could break and calling the result a regression gate —
#  would be claiming a guard is one-deep when it is two-deep. R12 therefore
#  applies both edits, says so in its own output, and is the only mutant here
#  that does.
#
#  ── The assertion that is deliberately NOT mutated ──────────────────────────
#
#  "pressing Erase before the loss list exists commits NOTHING" has no mutant,
#  and that is recorded rather than quietly skipped. Its refusal is three-deep:
#  the button's press() checks commitReady, commitReset() checks the phase, and
#  commitArgv() checks the token against the rendered count. No single edit
#  makes a `--commit` appear there, and manufacturing one by breaking all three
#  would be scoring a verdict about a mutant nobody would ever write. The row
#  that carries weight in both directions is ACT 4, and R9 and R12 are aimed at
#  it from two different directions.
#
#  ── Both directions ────────────────────────────────────────────────────────
#
#  RED (`mutate`): one thing is broken and a NAMED assertion must go red. Red
#  somewhere else is MISSCORED — the expectation is wrong, not the code.
#
#  GREEN (`hold`): prose, an unasserted property, and — the strongest of the
#  three — a private-use glyph added to a Text that carries no accessibility
#  markup. G3 must stay green, and it is what separates "the scan reads the
#  BUS" from "the scan greps the file for a byte".
#
#  ── Four verdicts, and the harness proves it can produce all four ──────────
#
#  CAUGHT / MISSCORED / CRASHED / SURVIVED. CRASHED exists because a mutant
#  that makes the suite exit before its totals line prints no totals, and a
#  harness that only counts failures reads that as "nothing failed".
#
#  ── How the files get put back ─────────────────────────────────────────────
#
#  A pristine copy into a per-run mktemp directory, restored with plain `cp`,
#  every restore VERIFIED by sha256. Not `git checkout --`: apex-shell's
#  arch-validate job installs git AFTER actions/checkout, so the workspace has
#  no .git at all.
#
#  ── This is slow ───────────────────────────────────────────────────────────
#
#  Every mutant is a compile of the instrument plus a full bring-up — a
#  headless compositor, two buses, a registry, the whole shell, the Nexus page
#  — and then four DoActions with settle time between them. Well over a minute
#  each. There is no faster honest version.
#
#  Run from anywhere: ./tests/mutate-recovery-atspi-shim.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

PAGE="src/services/config_tab/pages/RecoveryPage.qml"
SVC="src/services/RecoveryService.qml"
SECT="src/components/config/CfgSection.qml"
SHIM="tests/quickshell-a11y-shim.cpp"
FILES="$PAGE $SVC $SECT $SHIM"
SUITE="./tests/run-recovery-atspi-shim.sh"
TOTALS_PREFIX="recovery-atspi-shim: passed="

command -v python3 >/dev/null 2>&1   || { echo "FATAL: python3 is required" >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { echo "FATAL: sha256sum is required" >&2; exit 2; }
[ -x "$SUITE" ] || { echo "FATAL: $SUITE is not executable" >&2; exit 2; }

applied=0; noapply=0; caught=0; survived=0; misscored=0; held=0; falsered=0
unscorable=0

SNAP="$(mktemp -d "${TMPDIR:-/tmp}/mutate-recovery-atspi-shim.XXXXXX")" || exit 2

snap_of() { printf '%s' "$1" | tr '/' '_'; }

# A kill between an edit and its restore — a CI step timeout, a usage limit, a
# closed lid — would otherwise leave a MUTATED file in the tree for every later
# step in the same job, and all four of these files are in the workflow's
# REQUIRED list, so the structure check would still pass and nothing downstream
# would notice. Guarded on the snapshot existing, because the trap is armed
# before it is taken, and deliberately not the `restore` function: that one
# aborts the run on a sha mismatch, which is right mid-run and wrong in an exit
# handler.
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
# just deleted. 130 and 143 are the conventional 128+SIGINT and 128+SIGTERM.
trap 'put_back; exit 130' INT
trap 'put_back; exit 143' TERM
trap put_back EXIT

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
        | sed -n 's/^recovery-atspi-shim: passed=[0-9]* failed=\([0-9]*\).*/\1/p' \
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
    red="  FAIL the loss list reaches the bus — 4 rows  — found 0
recovery-atspi-shim: passed=31 failed=1 skipped=1"
    green="recovery-atspi-shim: passed=32 failed=0 skipped=1"
    crash="FATAL: this tree has no tests/quickshell-a11y-shim.cpp"
    chk() {
        if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
        else printf '  FAIL %s — want %s got %s\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
    }
    chk "a red suite naming the expectation is CAUGHT" \
        CAUGHT    "$(classify "$red"   "the loss list reaches the bus")"
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
    printf '\n// mutate-recovery-atspi-shim.sh restore probe\n' >>"$SVC"
    if tree_clean; then
        echo "ABORT: a real edit to $SVC was not seen — the baseline is not being read" >&2
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
if s.count(a) != 1:
    sys.exit(1)
open(p, 'w', encoding="utf-8").write(s.replace(a, b, 1))
EDIT
    # An edit that changed nothing is not a mutant. `s.count(a) != 1` above
    # catches an anchor that has moved or gone ambiguous; this catches the other
    # way of proving nothing — a replacement byte-identical to what it replaced.
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
printf '%s\n' "$base" | sed -n 's/^recovery-atspi-shim: /  baseline  /p'
if [ "$(suite_failures "$base")" -gt 0 ]; then
    echo "ABORT: the baseline is already RED. Fix that before mutating anything." >&2
    printf '%s\n' "$base" | grep -E '^  FAIL' >&2
    exit 3
fi
base_oks="$(printf '%s\n' "$base" | grep -c '^  ok   ')"

# FOUND 18, learned on the GitHub Arch runner: a suite that SKIPPED out before
# its first assertion printed passed=0 failed=0 and a mutation harness graded
# eleven mutants against it. "Was the baseline green" is not the question.
if [ "$base_oks" -lt 20 ]; then
    echo "  SKIP everything: the baseline made only $base_oks assertions, so this"
    echo "       machine cannot host the suite — no quickshell, no compositor, no"
    echo "       a11y stack, or no Qt private headers. Scoring mutants against it"
    echo "       would invent verdicts about nothing. The baseline said:"
    printf '%s\n' "$base" | grep -E '^  SKIP' | sed 's/^/       /'
    echo
    echo "mutate-recovery-atspi-shim: applied=0 caught=0 survived=0 misscored=0 unscorable=0 held=0 false-red=0"
    exit 0
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

score() {   # score <id> <want> <suite output>
    local id="$1" want="$2" out="$3" verdict
    verdict="$(classify "$out" "$want")"
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
        printf '%-5s NO-APPLY  anchor absent, or no longer unique, in %s\n' "$id" "$file"
        noapply=$((noapply + 1)); restore; return
    fi
    applied=$((applied + 1))
    score "$id" "$want" "$(run_suite)"
    restore
}

# The two-edit mutant. Its own paragraph in the header says why it exists and
# why it is the only one: the guard it targets is genuinely two-deep, and a
# single-edit version would be a claim that it is one-deep.
mutate_pair() {  # mutate_pair <id> <f1> <a1> <b1> <f2> <a2> <b2> <want> <why two>
    local id="$1" f1="$2" a1="$3" b1="$4" f2="$5" a2="$6" b2="$7" want="$8" why="$9"
    tree_clean || { echo "ABORT: tree dirty BEFORE $id" >&2; exit 3; }
    if ! baseline_asserts "$want"; then
        printf '%-5s UNSCORABLE the baseline never asserted: %s\n' "$id" "$want"
        unscorable=$((unscorable + 1)); return
    fi
    if ! apply_edit "$f1" "$a1" "$b1"; then
        printf '%-5s NO-APPLY  first anchor absent, or no longer unique, in %s\n' "$id" "$f1"
        noapply=$((noapply + 1)); restore; return
    fi
    if ! apply_edit "$f2" "$a2" "$b2"; then
        printf '%-5s NO-APPLY  second anchor absent, or no longer unique, in %s\n' "$id" "$f2"
        noapply=$((noapply + 1)); restore; return
    fi
    applied=$((applied + 1))
    printf '      %s\n' "$why"
    score "$id" "$want" "$(run_suite)"
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

# A private-use codepoint, built from its NUMBER by python3 and never written
# as a character. U+F033E is a glyph this shell draws. This unit has lost one
# of these characters in transit THREE times — twice to a literal that did not
# survive being written to a file, and once to `printf '\U000f033e'`, which
# emits TEN ASCII BYTES under the C/POSIX locale that `env -i` and the CI
# container both give. So it is built here and the run ABORTS, rather than
# scoring anything, if what came back is not the four bytes U+F033E is in
# UTF-8. An abort and not a skip: a harness that quietly downgraded here would
# be the thing it exists to prevent.
PUA_CHAR="$(python3 -c 'import sys; sys.stdout.write("\U000f033e")')"
if [ "$(printf '%s' "$PUA_CHAR" | wc -c)" != "4" ]; then
    echo "ABORT: the private-use character is $(printf '%s' "$PUA_CHAR" | wc -c) bytes, not the 4 of U+F033E in UTF-8." >&2
    echo "       R4 and G3 would be mutating plain ASCII and proving nothing." >&2
    exit 3
fi

echo
echo "── RED: break the SHIPPED markup, and the BUS has to notice ──"

# The page boundary. Without a role on CfgSection the Nexus frame publishes a
# FLAT run of controls at one depth with several pages' controls mixed in, and
# nothing tells a reader which page is open.
mutate R1 "$SECT" '    Accessible.role: Accessible.Grouping' \
                  '    Accessible.role: Accessible.StaticText' \
    'the Recovery section reaches the bus as a named group'

# The state as a WORD. `stateLabel()` turns the payload's token into the same
# string the eye reads beside the glyph; the raw token is not that string.
mutate R2 "$PAGE" '                    + RecoveryService.stateLabel(compRow.row ? compRow.row.state : "")' \
                  '                    + (compRow.row ? compRow.row.state : "")' \
    'a component row carries its STATE as a word'

mutate R3 "$PAGE" '            a11yExtra:   "The command is: " + RecoveryService.rollbackCommand' \
                  '            a11yExtra:   ""' \
    'the rollback COMMAND reaches the bus'

# Aimed at the component row's DESCRIPTION, which is in the tree §5 scans.
# A glyph in the loss rows would not be: those do not exist until ACT 3.
mutate R4 "$PAGE" '                Accessible.description: (compRow.row ? compRow.row.detail : "")' \
                  "                Accessible.description: \"${PUA_CHAR} \" + (compRow.row ? compRow.row.detail : \"\")" \
    'reaches the bus inside a name or a description'

# `visible` alone leaves the node on the bus carrying enabled,sensitive and a
# Press action — FOUND 16, an invisible Qt Quick item still publishes its whole
# subtree. A reader then meets a live-looking destructive button that refuses
# in silence. `enabled` is what Qt maps to those states.
mutate R5 "$PAGE" '                            enabled: RecoveryService.commitReady' \
                  '                            enabled: true' \
    'before the plan exists the Erase button reports NO states at all'

mutate R6 "$PAGE" '                            Accessible.name: lossHeadline.text' \
                  '                            Accessible.name: ""' \
    'the count is spoken as well as listed'

mutate R7 "$PAGE" '                                       ? " — NOT backed up" : "")' \
                  '                                       ? "" : "")' \
    'says so in its NAME'

mutate R8 "$PAGE" '                                Accessible.name: (lossRow.loss ? lossRow.loss.relative : "")' \
                  '                                Accessible.name: (lossRow.loss ? "a file" : "")' \
    'the loss list reaches the bus'

# The Press action on the commit button — the whole reason a reader can finish
# this at all. Without it the node is still there and still says it is enabled;
# it simply cannot be operated.
mutate R9 "$PAGE" '                            Accessible.onPressAction: commitBtn.press()' \
                  '                            // Accessible.onPressAction removed by R9' \
    'ACT 4: a reader can COMPLETE the reset over the bus'

echo
echo "── RED: break the INSTRUMENT, and the suite must not mistake it for a finding ──"

# QAccessibleQuickWindow::child() re-enters queryAccessibleInterface() for each
# root item, so a window-only factory gives a frame with NO children — an empty
# page that reads exactly like a page with no markup. A suite that could not
# tell those apart would report this page as unmarked on the strength of a
# broken tool.
mutate R10 "$SHIM" '    if (classname == QLatin1String("QQuickItem")) {' \
                   '    if (false && classname == QLatin1String("QQuickItem")) {' \
    "the page's headline fact reaches the bus, in words"

mutate R11 "$SHIM" '__asm__("_ZN15QGuiApplication4execEv");' \
                   '__asm__("_ZN15QGuiApplication4execEvNOTTHESYMBOL");' \
    'the preload really took QGuiApplication::exec() in THIS process'

echo
echo "── RED: the FOUND-28 regression, which takes TWO edits because the fix is two-deep ──"

mutate_pair R12 \
    "$SVC"  '        root.resetPhase = "planned"
        root.plan = p' \
            '        root.plan = p
        root.resetPhase = "planned"' \
    "$PAGE" '                        Connections {
                            target: RecoveryService
                            function onResetPhaseChanged() { lossList._ack() }
                        }' \
            '                        // the phase-change re-ack, removed by R12' \
    'ACT 4: a reader can COMPLETE the reset over the bus' \
    'TWO edits on purpose: the service order and the page re-ack are independently sufficient, so this is what the defect actually took.'

echo
echo "── GREEN: prose and unasserted markup must not move a single verdict ──"

hold G1 "$PAGE" '                Accessible.name: (compRow.row ? compRow.row.label : "")' \
                '                // Strings this suite asserts, quoted here so that a suite
                // grepping the QML instead of reading the bus would go green
                // on nonsense: role=panel, name=Recovery, name=Secure Boot —
                // Needs attention, name=installer-media — cannot be determined
                // from a running system, name=warning — ACPI platform_profile
                // present, name=4 item(s) will be changed, actions=Press
                Accessible.name: (compRow.row ? compRow.row.label : "")' \
    'the suite reads the BUS, not the QML source'

hold G2 "$PAGE" '                            id: commitBtn' \
                '                            id: commitBtn
                            objectName: "apex-mutation-hold"' \
    'a property nothing asserts is not a failure'

# The strongest of the three. The state icon is a private-use glyph already and
# the page is green, because that Text carries no accessibility markup and Qt
# therefore never publishes it. Adding a SECOND private-use character to it
# must change nothing — which is what separates "the scan reads the BUS" from
# "the scan greps the file for a byte in that range".
hold G3 "$PAGE" '                    text:           RecoveryService.stateIcon(compRow.row ? compRow.row.state : "")' \
                "                    text:           \"${PUA_CHAR}\" + RecoveryService.stateIcon(compRow.row ? compRow.row.state : \"\")" \
    'a private-use glyph in an UNMARKED Text is not on the bus and is not a failure'

restore

echo
printf 'mutate-recovery-atspi-shim: applied=%d caught=%d survived=%d misscored=%d unscorable=%d held=%d false-red=%d\n' \
    "$applied" "$caught" "$survived" "$misscored" "$unscorable" "$held" "$falsered"
[ "$noapply" -gt 0 ] && printf '  %d mutant(s) DID NOT APPLY — their anchors have moved and they proved nothing\n' "$noapply"
echo "  note: 'pressing Erase before the loss list exists commits NOTHING' has no"
echo "        mutant BY DESIGN — its refusal is three-deep and no single edit can"
echo "        make a --commit appear there. See this file's header."

rc=0
[ "$survived"   -gt 0 ] && { echo "  FAIL — a vacuous assertion: the suite stayed green with a real defect in place"; rc=1; }
[ "$misscored"  -gt 0 ] && { echo "  FAIL — a mutant went red on the wrong line; the expectation is wrong"; rc=1; }
[ "$unscorable" -gt 0 ] && { echo "  FAIL — a mutant aimed at an assertion the baseline never made"; rc=1; }
[ "$falsered"   -gt 0 ] && { echo "  FAIL — the suite went red at prose or at markup nothing asserts"; rc=1; }
[ "$noapply"    -gt 0 ] && { echo "  FAIL — a mutant's anchor no longer exists in the source"; rc=1; }
exit "$rc"
