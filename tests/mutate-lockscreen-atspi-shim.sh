#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  mutate-lockscreen-atspi-shim.sh — prove run-lockscreen-atspi-shim.sh can go
#  red, and prove it does not go red at prose.
#
#  ── Why this one needs mutating more than most ──────────────────────────────
#
#  The suite it guards exists because its predecessor could not make these
#  assertions at all: with quickshell publishing an empty tree, "the password
#  field reaches the bus" and "no private-use glyph reaches a reader" are both
#  satisfied by nothing being there, which is why run-lockscreen-atspi.sh §5
#  records them as SKIPs. Restoring Qt's factory makes them answerable — and
#  makes it possible to write them badly. A read-back suite that cannot tell a
#  labelled field from an unlabelled one has replaced one vacuity with another.
#
#  So the mutants break the SHIPPED QML and require the BUS to notice:
#
#    * S1 removes Accessible.passwordEdit. Qt then stops suppressing the
#      field's name, "Password" arrives on the bus, and the assertion that
#      claims to observe the suppression must go red. If it does not, that
#      assertion was reading an empty name that was empty for some other
#      reason — which is exactly what an empty tree gives you.
#    * S2 changes the idle description. The suite must notice the text, not
#      merely the presence of a description.
#    * S3 drops the status line's Accessible.role. A reader that meets an
#      unnamed item with no role skips it.
#    * S4 puts a private-use codepoint — the padlock the shell draws with —
#      into the one accessible string the bus actually delivers here, and the
#      tree-wide scan must find it.
#    * S5 breaks the INSTRUMENT rather than the shell: it makes the shim
#      answer only for QQuickWindow. QAccessibleQuickWindow::child() re-enters
#      queryAccessibleInterface() for each root item, so the frame arrives with
#      no children and every field assertion fails. That is the false negative
#      the three-branch factory exists to avoid, and a suite that could not
#      tell it from "the markup is missing" would report the shell's markup as
#      absent on the strength of a broken instrument.
#    * S6 breaks the interposed symbol name in the shim, so the preload hooks
#      nothing. The suite must say the preload did not take, rather than
#      reporting an unmodified shell's empty tree as a finding.
#
#  ── Both directions ────────────────────────────────────────────────────────
#
#  RED (`mutate`): one thing is broken and a NAMED assertion must go red. Red
#  somewhere else is MISSCORED — the expectation is wrong, not the code.
#
#  GREEN (`hold`): G1 adds a comment to Lockscreen.qml quoting the exact
#  strings the suite asserts, and G2 adds an Accessible.name to an item no
#  assertion mentions. Both must stay green: the first proves the suite reads
#  the BUS and not the QML source, the second proves it is not a node count.
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
#  Every mutant is a compile of the instrument plus a full bring-up: a headless
#  compositor, two buses, a registry, the whole shell and a session lock, then
#  two tree walks. About a minute each. There is no faster honest version.
#
#  Run from anywhere: ./tests/mutate-lockscreen-atspi-shim.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

LOCK="src/windows/Lockscreen.qml"
SHIM="tests/quickshell-a11y-shim.cpp"
FILES="$LOCK $SHIM"
SUITE="./tests/run-lockscreen-atspi-shim.sh"
TOTALS_PREFIX="lockscreen-atspi-shim: passed="

command -v python3 >/dev/null 2>&1   || { echo "FATAL: python3 is required" >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { echo "FATAL: sha256sum is required" >&2; exit 2; }
[ -x "$SUITE" ] || { echo "FATAL: $SUITE is not executable" >&2; exit 2; }

applied=0; noapply=0; caught=0; survived=0; misscored=0; held=0; falsered=0
unscorable=0

SNAP="$(mktemp -d "${TMPDIR:-/tmp}/mutate-lockscreen-atspi-shim.XXXXXX")" || exit 2
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
trap put_back EXIT INT TERM

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
        | sed -n 's/^lockscreen-atspi-shim: passed=[0-9]* failed=\([0-9]*\).*/\1/p' \
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
    red="  FAIL the password field reaches the bus at all  — no node with role=text
lockscreen-atspi-shim: passed=22 failed=1 skipped=1"
    green="lockscreen-atspi-shim: passed=23 failed=0 skipped=1"
    crash="FATAL: this tree has no tests/quickshell-a11y-shim.cpp"
    chk() {
        if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
        else printf '  FAIL %s — want %s got %s\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
    }
    chk "a red suite naming the expectation is CAUGHT" \
        CAUGHT    "$(classify "$red"   "the password field reaches the bus at all")"
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
    printf '\n// mutate-lockscreen-atspi-shim.sh restore probe\n' >>"$SHIM"
    if tree_clean; then
        echo "ABORT: a real edit to $SHIM was not seen — the baseline is not being read" >&2
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
printf '%s\n' "$base" | sed -n 's/^lockscreen-atspi-shim: /  baseline  /p'
if [ "$(suite_failures "$base")" -gt 0 ]; then
    echo "ABORT: the baseline is already RED. Fix that before mutating anything." >&2
    printf '%s\n' "$base" | grep -E '^  FAIL' >&2
    exit 3
fi
base_oks="$(printf '%s\n' "$base" | grep -c '^  ok   ')"

# FOUND 18, learned on the GitHub Arch runner: a suite that SKIPPED out before
# its first assertion printed passed=0 failed=0 and a mutation harness graded
# eleven mutants against it. "Was the baseline green" is not the question.
if [ "$base_oks" -lt 15 ]; then
    echo "  SKIP everything: the baseline made only $base_oks assertions, so this"
    echo "       machine cannot host the suite — no quickshell, no compositor, no"
    echo "       a11y stack, or no Qt private headers. Scoring mutants against it"
    echo "       would invent verdicts about nothing. The baseline said:"
    printf '%s\n' "$base" | grep -E '^  SKIP' | sed 's/^/       /'
    echo
    echo "mutate-lockscreen-atspi-shim: applied=0 caught=0 survived=0 misscored=0 unscorable=0 held=0 false-red=0"
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
echo "── RED: break the SHIPPED markup, and the BUS has to notice ──"

mutate S1 "$LOCK" '                        Accessible.passwordEdit: true' \
                  '                        Accessible.passwordEdit: false' \
    'Qt suppresses the field'"'"'s NAME, which is how it is observable'

mutate S2 "$LOCK" '                                               : "Type your password and press Enter to unlock."' \
                  '                                               : "Enter your passphrase."' \
    "the field's live description reaches the bus, verbatim"

mutate S3 "$LOCK" '                    Accessible.role: Accessible.StaticText' \
                  '                    Accessible.ignored: true' \
    'the status line reaches the bus as a label'

# A private-use codepoint, built from its NUMBER by printf and never written
# as a character. U+F033E is the padlock this shell draws. Two things went
# wrong when it was a literal, and both are worth the reader's time:
#
#   * the character did not survive being written to the file — what landed
#     was U+F033 followed by the letter E, a DIFFERENT codepoint in a
#     different plane — and nothing about the source made that visible;
#   * and the suite's own class had lost its BMP bounds the same way, so the
#     mutant it did apply was one the assertion genuinely could not catch.
#
# It SURVIVED, and the survival was correct twice over. Both halves are fixed:
# the class is written in escapes and covers all three private-use planes, and
# this builds its character with printf.
#
# Aimed at the DESCRIPTION, not at Accessible.name. passwordEdit makes Qt
# return an EMPTY name for that item, so a glyph put there never reaches the
# bus at all; a mutant pointed at a string the bus never delivers proves
# nothing about the assertion it was aimed at. The description is the one
# accessible string on the locked surface a reader actually receives here.
PUA_CHAR="$(printf '\U000f033e')"
mutate S4 "$LOCK" '                                               : "Type your password and press Enter to unlock."' \
                  "                                               : \"${PUA_CHAR} Type your password and press Enter to unlock.\"" \
    'neither private-use icon reaches the bus as a named node'

echo
echo "── RED: break the INSTRUMENT, and the suite must not mistake it for a finding ──"

mutate S5 "$SHIM" '    if (classname == QLatin1String("QQuickItem")) {' \
                  '    if (false && classname == QLatin1String("QQuickItem")) {' \
    'the password field reaches the bus at all'

mutate S6 "$SHIM" '__asm__("_ZN15QGuiApplication4execEv");' \
                  '__asm__("_ZN15QGuiApplication4execEvNOTTHESYMBOL");' \
    'the preload really took QGuiApplication::exec() in THIS process'

echo
echo "── GREEN: prose and unasserted markup must not move a single verdict ──"

hold G1 "$LOCK" '                        Accessible.passwordEdit: true' \
                '                        // Strings this suite asserts, quoted here so that a suite
                        // grepping the QML instead of reading the bus would go
                        // green on nonsense: role=text, role=label, name=,
                        // desc=Type your password and press Enter to unlock.,
                        // editable, focusable, actions=SetFocus
                        Accessible.passwordEdit: true' \
    'the suite reads the BUS, not the QML source'

hold G2 "$LOCK" '                        Accessible.role:         Accessible.EditableText' \
                '                        objectName: "apex-mutation-hold"
                        Accessible.role:         Accessible.EditableText' \
    'a property nothing asserts is not a failure'

restore

echo
printf 'mutate-lockscreen-atspi-shim: applied=%d caught=%d survived=%d misscored=%d unscorable=%d held=%d false-red=%d\n' \
    "$applied" "$caught" "$survived" "$misscored" "$unscorable" "$held" "$falsered"
[ "$noapply" -gt 0 ] && printf '  %d mutant(s) DID NOT APPLY — their anchors have moved and they proved nothing\n' "$noapply"

rc=0
[ "$survived"   -gt 0 ] && { echo "  FAIL — a vacuous assertion: the suite stayed green with a real defect in place"; rc=1; }
[ "$misscored"  -gt 0 ] && { echo "  FAIL — a mutant went red on the wrong line; the expectation is wrong"; rc=1; }
[ "$unscorable" -gt 0 ] && { echo "  FAIL — a mutant aimed at an assertion the baseline never made"; rc=1; }
[ "$falsered"   -gt 0 ] && { echo "  FAIL — the suite went red at prose or at markup nothing asserts"; rc=1; }
[ "$noapply"    -gt 0 ] && { echo "  FAIL — a mutant's anchor no longer exists in the source"; rc=1; }
exit "$rc"
