#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  mutate-quickshell-a11y-cause.sh — prove check-quickshell-a11y-cause.sh can
#  go red, and prove it does not go red at prose.
#
#  ── Why this one needs mutating ─────────────────────────────────────────────
#
#  The suite it guards is almost entirely a NEGATIVE: mode A produces a NULL
#  accessible root, and that null is the whole finding. A suite that reported
#  the same null because the program crashed, or because the assertion read a
#  string the program never prints, or because it grepped its own source, would
#  look identical and would be worth nothing. So:
#
#    * M1 makes mode A stop destroying the QCoreApplication. The null must
#      disappear and the PIN must go red — that is the "the day Qt fixes this"
#      path, exercised rather than hoped for.
#    * M2 makes mode B destroy one. The control must go red, because a control
#      that cannot fail is not a control.
#    * M8 installs mode C's factory the OTHER way. If the suite cannot tell a
#      cleared factory list from a surviving one, §3 is decoration.
#    * M5 lets the startup routine run only once. The fix assertion must go
#      red — "it ran twice" is the entire reason Q_COREAPP_STARTUP_FUNCTION is
#      the fix, and asserting the count without proving the count matters is
#      the vacuity this program keeps meeting.
#    * M10 breaks the build. A suite that treats "did not compile" as anything
#      other than a failure would report five silent nulls as five findings.
#
#  ── Both directions ────────────────────────────────────────────────────────
#
#  RED (`mutate`): one thing is broken and a NAMED assertion must go red. Red on
#  some other line is MISSCORED, not caught — the expectation is then wrong and
#  the message says to fix the expectation, not the code.
#
#  GREEN (`hold`): G1 appends a comment to the .cpp quoting the exact strings
#  the suite asserts — "accessibleRoot: NULL", "rootName: APEX-CUSTOM-ROOT",
#  "appChildCount: 1" — and the suite must stay green. That is the proof that
#  every assertion reads the PROGRAM'S OUTPUT and not the program's source,
#  which is the difference between this and a grep.
#
#  ── Four verdicts, and the harness proves it can produce all four ──────────
#
#  CAUGHT / MISSCORED / CRASHED / SURVIVED. CRASHED exists because a mutant
#  that makes the suite exit before its totals line prints no totals, and a
#  harness that only counts failures reads that as "nothing failed" — a working
#  suite reported as a broken one.
#
#  ── How the file gets put back ─────────────────────────────────────────────
#
#  A pristine copy into a per-run mktemp directory, restored with plain `cp`,
#  and every restore VERIFIES sha256. Not `git checkout --`: apex-shell's
#  arch-validate job installs git AFTER actions/checkout, so the workspace has
#  no .git at all. Not a shared scratch path either.
#
#  Run from anywhere: ./tests/mutate-quickshell-a11y-cause.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

SRC="tests/quickshell-a11y-cause.cpp"
FILES="$SRC"
SUITE="./tests/check-quickshell-a11y-cause.sh"
TOTALS_PREFIX="quickshell-a11y-cause: passed="

command -v python3 >/dev/null 2>&1   || { echo "FATAL: python3 is required" >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { echo "FATAL: sha256sum is required" >&2; exit 2; }
[ -x "$SUITE" ] || { echo "FATAL: $SUITE is not executable" >&2; exit 2; }

applied=0; noapply=0; caught=0; survived=0; misscored=0; held=0; falsered=0
unscorable=0

SNAP="$(mktemp -d "${TMPDIR:-/tmp}/mutate-qs-a11y-cause.XXXXXX")" || exit 2
trap 'rm -rf "$SNAP"' EXIT INT TERM

snap_of() { printf '%s' "$1" | tr '/' '_'; }

# shellcheck disable=SC2086  # $FILES is a deliberate, space-separated list
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
    for f in $FILES; do
        cp -- "$SNAP/$(snap_of "$f")" "$f" || exit 3
    done
    if ! tree_clean; then
        echo "ABORT: a restored file does not match its baseline sha256;" >&2
        echo "       every verdict after this point would be meaningless" >&2
        sha256sum -c "$SNAP/baseline.sha256" >&2
        exit 3
    fi
}

run_suite() {
    env -i HOME="${HOME:-/tmp}" PATH="$PATH" USER="${USER:-$(id -un)}" \
        TMPDIR="${TMPDIR:-/tmp}" "$SUITE" 2>&1
}

has_totals() { [[ "$1" == *"$TOTALS_PREFIX"* ]]; }

suite_failures() {
    printf '%s\n' "$1" \
        | sed -n 's/^quickshell-a11y-cause: passed=[0-9]* failed=\([0-9]*\).*/\1/p' \
        | head -1 | grep -E '^[0-9]+$' || echo 0
}

# classify <suite output> <expected FAIL substring>
#   -> CAUGHT | MISSCORED | CRASHED | SURVIVED
#
# Membership is `[[ "$a" == *"$b"* ]]`, never `printf | grep -q`: under
# `pipefail` a grep that matches closes the pipe, printf dies with SIGPIPE, and
# the pipeline's status is 141 on a MATCH.
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

# ── self-test: the scoring above, in all four states ────────────────────────
selftest() {
    local red green crash fails=0
    red="  FAIL PINNED: a destroyed QCoreApplication leaves QQuickWindow::accessibleRoot() null  — the root is NOT null any more
quickshell-a11y-cause: passed=13 failed=1 skipped=0"
    green="quickshell-a11y-cause: passed=14 failed=0 skipped=0"
    crash="FATAL: this tree has no tests/quickshell-a11y-cause.cpp"

    chk() {
        if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
        else printf '  FAIL %s — want %s got %s\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
    }
    chk "a red suite naming the expectation is CAUGHT" \
        CAUGHT    "$(classify "$red"   "leaves QQuickWindow::accessibleRoot() null")"
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
    tree_clean || { echo "ABORT: the snapshot does not match the file it was taken from" >&2; exit 3; }
    printf '\n// mutate-quickshell-a11y-cause.sh restore probe\n' >>"$SRC"
    if tree_clean; then
        echo "ABORT: a real edit to $SRC was not seen — the baseline is not being read" >&2
        exit 3
    fi
    echo "  ok   a real edit to the file under test is SEEN"
    restore
    echo "  ok   …and the restore puts it back, sha256 for sha256"
}

echo "── self-test: this harness can tell its four verdicts apart ──"
selftest
restore_selftest

apply_edit() {  # apply_edit <file> <from> <to>; non-zero if nothing changed
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

# ── the baseline, and the guard on it ───────────────────────────────────────
#
# FOUND 18, the hard way, on the GitHub Arch runner: a suite that SKIPPED out
# before its first assertion printed passed=0 failed=0 and a mutation harness
# graded eleven mutants against it. "Was the baseline green" is not the
# question. "Did the baseline print an `ok` line containing THIS mutant's want"
# is.
echo
echo "── the baseline, before anything is touched ──"
base="$(run_suite)"
if ! has_totals "$base"; then
    echo "ABORT: the baseline never reached its totals line; nothing can be scored" >&2
    printf '%s\n' "$base" | tail -15 >&2
    exit 3
fi
printf '%s\n' "$base" | sed -n 's/^quickshell-a11y-cause: /  baseline  /p'
if [ "$(suite_failures "$base")" -gt 0 ]; then
    echo "ABORT: the baseline is already RED. Fix that before mutating anything." >&2
    printf '%s\n' "$base" | grep -E '^  FAIL' >&2
    exit 3
fi
base_oks="$(printf '%s\n' "$base" | grep -c '^  ok   ')"
if [ "$base_oks" -lt 10 ]; then
    echo "  SKIP everything: the baseline made only $base_oks assertions, so this"
    echo "       machine cannot host the suite (no compiler, or no Qt 6 Quick)."
    echo "       Scoring mutants against it would invent verdicts about nothing."
    echo
    echo "mutate-quickshell-a11y-cause: applied=0 caught=0 survived=0 misscored=0 unscorable=0 held=0 false-red=0"
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

# mutate <id> <from> <to> <assertion substring that must go red>
mutate() {
    local id="$1" from="$2" to="$3" want="$4"
    tree_clean || { echo "ABORT: tree dirty BEFORE $id" >&2; exit 3; }
    if ! baseline_asserts "$want"; then
        printf '%-5s UNSCORABLE the baseline never asserted: %s\n' "$id" "$want"
        printf '      A mutant aimed at a check that did not run is not a survival\n'
        printf '      and not a catch. It is nothing, and it is counted as nothing.\n'
        unscorable=$((unscorable + 1)); return
    fi
    if ! apply_edit "$SRC" "$from" "$to"; then
        printf '%-5s NO-APPLY  anchor absent in %s — this mutant proves nothing\n' "$id" "$SRC"
        noapply=$((noapply + 1)); restore; return
    fi
    applied=$((applied + 1))
    local out verdict; out="$(run_suite)"; verdict="$(classify "$out" "$want")"
    case "$verdict" in
    CAUGHT)
        printf '%-5s CAUGHT    %s\n' "$id" "$want"; caught=$((caught + 1)) ;;
    MISSCORED)
        printf '%-5s MISSCORED the suite went red (%s failed) but not on the named assertion\n' \
               "$id" "$(suite_failures "$out")"
        printf '      expected a FAIL line containing: %s\n' "$want"
        printf '      ── FIX THE EXPECTATION, NOT THE CODE. What actually went red: ──\n'
        printf '%s\n' "$out" | grep -E '^  (FAIL|SKIP)' | sed 's/^/      /'
        misscored=$((misscored + 1)) ;;
    CRASHED)
        printf '%-5s MISSCORED the suite never reached its totals line\n' "$id"
        printf '      ── a FATAL is the harness dying, not an assertion catching ──\n'
        printf '%s\n' "$out" | tail -6 | sed 's/^/      /'
        misscored=$((misscored + 1)) ;;
    *)
        printf '%-5s SURVIVED  %s\n' "$id" "$want"
        printf '      the suite stayed GREEN with this broken. The assertion is vacuous.\n'
        survived=$((survived + 1)) ;;
    esac
    restore
}

# hold <id> <from> <to> <what it proves>
hold() {
    local id="$1" from="$2" to="$3" what="$4"
    tree_clean || { echo "ABORT: tree dirty BEFORE $id" >&2; exit 3; }
    if ! apply_edit "$SRC" "$from" "$to"; then
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
echo "── RED: each of these must make a NAMED assertion fail ──"

mutate M1 'const bool deleteCoreApp = (strcmp(m, "B") != 0);' \
          'const bool deleteCoreApp = (strcmp(m, "B") != 0 && strcmp(m, "A") != 0);' \
          'leaves QQuickWindow::accessibleRoot() null'

mutate M2 'const bool deleteCoreApp = (strcmp(m, "B") != 0);' \
          'const bool deleteCoreApp = true;' \
          'a process that never destroys an application object DOES get a root'

mutate M3 'w->setTitle(QStringLiteral("QTROOT"));' \
          'w->setTitle(QStringLiteral("NOTQTROOT"));' \
          'reading the window title through QAccessibleQuickWindow'

mutate M4 '    if (strcmp(mode(), "D") == 0)
        installApexFactory("Q_COREAPP_STARTUP_FUNCTION");' \
          '    if (false && strcmp(mode(), "D") == 0)
        installApexFactory("Q_COREAPP_STARTUP_FUNCTION");' \
          'runs once per APPLICATION OBJECT'

mutate M5 '    if (strcmp(mode(), "D") == 0)
        installApexFactory("Q_COREAPP_STARTUP_FUNCTION");' \
          '    static bool once = false;
    if (strcmp(mode(), "D") == 0 && !once) {
        once = true;
        installApexFactory("Q_COREAPP_STARTUP_FUNCTION");
    }' \
          'so the factory is back after the destruction and the root is non-null again'

mutate M6 'QStringLiteral("APEX-CUSTOM-ROOT")' \
          'QStringLiteral("APEX-OTHER-ROOT")' \
          'the root really is the one the startup routine installed, not a leftover'

mutate M7 '    if (strcmp(mode(), "C") == 0)
        installApexFactory("Q_CONSTRUCTOR_FUNCTION");' \
          '    if (false && strcmp(mode(), "C") == 0)
        installApexFactory("Q_CONSTRUCTOR_FUNCTION");' \
          'mode C really did install a factory before the application existed'

mutate M8 '    if (strcmp(mode(), "D") == 0)
        installApexFactory("Q_COREAPP_STARTUP_FUNCTION");' \
          '    if (strcmp(mode(), "D") == 0 || strcmp(mode(), "C") == 0)
        installApexFactory("Q_COREAPP_STARTUP_FUNCTION");' \
          'is GONE after the destruction'

mutate M9 '    if (strcmp(m, "E") == 0)
        installApexFactory("after-QGuiApplication");' \
          '    if (false && strcmp(m, "E") == 0)
        installApexFactory("after-QGuiApplication");' \
          'installing a factory AFTER the QGuiApplication exists also restores the tree'

mutate M10 'int main(int, char **argv)' \
           'int main(int, char **argv) THIS IS NOT C++' \
           "compiles against this machine's Qt 6"

mutate M11 '    QAccessibleInterface *appIface = QAccessible::queryAccessibleInterface(app);' \
           '    if (strcmp(m, "A") == 0) { delete w; delete app; return 0; }
    QAccessibleInterface *appIface = QAccessible::queryAccessibleInterface(app);' \
           'every mode reaches its last line'

echo
echo "── GREEN: prose and unasserted output must not move a single verdict ──"

hold G1 'static const char *mode()' \
        '// Prose that quotes every string the suite asserts, so that a suite
// grepping this file instead of running it would go green on nonsense:
//   accessibleRoot: NULL
//   accessibleRoot: NON-NULL
//   rootName: QTROOT
//   rootName: APEX-CUSTOM-ROOT
//   appChildCount: 0
//   appChildCount: 1
//   install: Q_CONSTRUCTOR_FUNCTION installed apexFactory
//   install: Q_COREAPP_STARTUP_FUNCTION installed apexFactory
static const char *mode()' \
        'the suite reads the program OUTPUT, not the program source'

hold G2 '    printf("guiapp: constructed\n");' \
        '    printf("guiapp: constructed\n");
    printf("note: a line no assertion in the suite mentions\n");' \
        'output nothing asserts is not a failure'

restore

echo
printf 'mutate-quickshell-a11y-cause: applied=%d caught=%d survived=%d misscored=%d unscorable=%d held=%d false-red=%d\n' \
    "$applied" "$caught" "$survived" "$misscored" "$unscorable" "$held" "$falsered"
[ "$noapply" -gt 0 ] && printf '  %d mutant(s) DID NOT APPLY — their anchors have moved and they proved nothing\n' "$noapply"

rc=0
[ "$survived"   -gt 0 ] && { echo "  FAIL — a vacuous assertion: the suite stayed green with a real defect in place"; rc=1; }
[ "$misscored"  -gt 0 ] && { echo "  FAIL — a mutant went red on the wrong line; the expectation is wrong"; rc=1; }
[ "$unscorable" -gt 0 ] && { echo "  FAIL — a mutant aimed at an assertion the baseline never made"; rc=1; }
[ "$falsered"   -gt 0 ] && { echo "  FAIL — the suite went red at prose or at output nothing asserts"; rc=1; }
[ "$noapply"    -gt 0 ] && { echo "  FAIL — a mutant's anchor no longer exists in the source"; rc=1; }
exit "$rc"
