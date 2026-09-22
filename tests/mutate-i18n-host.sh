#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  mutate-i18n-host.sh — can tests/run-i18n-host-test.sh go RED?
#
#  A suite that has never failed is a suite nobody has shown to be a
#  measurement. This one breaks the three files that carry the Apex.I18n route
#  — the plugin, the qmldir, and the bare-engine host — one edit at a time, and
#  requires the suite to fail on the assertion the edit was aimed at. Then it
#  makes two edits that must NOT move a verdict, because a suite that goes red
#  at a comment is measuring the file and not the program.
#
#  ── The mutant that matters ────────────────────────────────────────────────
#
#  M1 takes qmlRegisterModule() out of the plugin's registerTypes(). That is the
#  exact trap this route cost an afternoon to: with a QQmlEngineExtensionPlugin
#  the .so is still found, still dlopen()ed — proved with a library constructor
#  that printed — and the qmldir is still read, and the import STILL fails with
#  "module Apex.I18n is not installed" because nothing registered the module.
#  Every symptom says the plugin is fine. If the suite could not see that, it
#  would certify a route that does not exist.
#
#  M4 is its qmldir twin: drop the `plugin` line and the module resolves to an
#  empty QML module — the import SUCCEEDS, no C++ runs, every string stays
#  English and nothing anywhere reports it.
#
#  M6 and M9 defend the late/retranslate pair, which is the only reason anyone
#  can say WHY the hook is initializeEngine(). M6 makes the `late` run
#  retranslate too, collapsing the pair into one measurement; M9 makes its
#  translator fail to load, so its English would be a failed load rather than a
#  demonstration about timing.
#
#  ── Verdicts are five-way ──────────────────────────────────────────────────
#
#  CAUGHT / MISSCORED / CRASHED / SURVIVED / UNSCORABLE. CRASHED exists because
#  a mutant that makes the suite die before its totals line prints no failures,
#  and a harness that counted only failures would read that as "nothing broke".
#  UNSCORABLE exists because of FOUND 18: on a machine where the baseline never
#  asserted a mutant's target — no quickshell, no Qt — a verdict about it is an
#  invention. This harness refuses to score anything at all when the baseline is
#  too thin to be a baseline, and exits 0 saying so.
#
#  Restores come from a pristine copy in a per-run mktemp -d and every restore
#  VERIFIES sha256. Not `git checkout --`: apex-shell's arch-validate job
#  installs git AFTER actions/checkout, so the workspace has no .git at all.
#
#  Run from anywhere: ./tests/mutate-i18n-host.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

PLUGIN="tests/apex-i18n-plugin.cpp"
HOST="tests/apex-i18n-host.cpp"
QMLDIR="tests/apex-i18n-qmldir"
FILES="$PLUGIN $HOST $QMLDIR"
SUITE="./tests/run-i18n-host-test.sh"
TOTALS_PREFIX="i18n-host: passed="

command -v python3 >/dev/null 2>&1   || { echo "FATAL: python3 is required" >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { echo "FATAL: sha256sum is required" >&2; exit 2; }
[ -x "$SUITE" ] || { echo "FATAL: $SUITE is not executable" >&2; exit 2; }

applied=0; noapply=0; caught=0; survived=0; misscored=0; held=0; falsered=0
unscorable=0

SNAP="$(mktemp -d "${TMPDIR:-/tmp}/mutate-i18n-host.XXXXXX")" || exit 2

snap_of() { printf '%s' "$1" | tr '/' '_'; }

# A kill between an edit and its restore — a CI step timeout, a usage limit, a
# closed lid — would otherwise leave a MUTATED file in the tree for every later
# step in the same job, and all three of these are in the workflow's REQUIRED
# list, so the structure check would still pass and nothing downstream would
# notice. Hence a restore from the trap as well as after each mutant. Guarded
# on the snapshot existing, because the trap is armed before it is taken, and
# deliberately NOT the `restore` function: that one aborts on a sha mismatch,
# which is right mid-run and wrong in an exit handler.
put_back() {
    local f
    if [ -f "$SNAP/baseline.sha256" ]; then
        # shellcheck disable=SC2086
        for f in $FILES; do cp -- "$SNAP/$(snap_of "$f")" "$f" 2>/dev/null; done
    fi
    rm -rf "$SNAP"
}
# Signals get their OWN handlers, and they EXIT. A `trap … INT TERM` whose
# handler merely returns lets the script CARRY ON after the signal (FOUND 24):
# bash defers the signal until the running command substitution finishes, runs
# the handler, and resumes at the next line — scoring a verdict for a mutant
# that was killed, then dying inside restore() on a snapshot the handler has
# already deleted. 130 and 143 are 128+SIGINT and 128+SIGTERM.
trap 'put_back; exit 130' INT
trap 'put_back; exit 143' TERM
trap put_back EXIT

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
        | sed -n 's/^i18n-host: passed=[0-9]* failed=\([0-9]*\).*/\1/p' \
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
    red="  FAIL with the module imported, the SHIPPED singleton's entryLabel reads the German from translations/apex-shell_de.ts  — got [How Agents & Workspaces work]
i18n-host: passed=23 failed=1 skipped=0"
    green="i18n-host: passed=24 failed=0 skipped=0"
    crash="FATAL: this tree has no tests/apex-i18n-plugin.cpp"

    chk() {
        if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
        else printf '  FAIL %s — want %s got %s\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
    }
    chk "a red suite naming the expectation is CAUGHT" \
        CAUGHT    "$(classify "$red"   "reads the German from")"
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
    printf '\n// mutate-i18n-host.sh restore probe\n' >>"$PLUGIN"
    printf '\n# mutate-i18n-host.sh restore probe\n' >>"$QMLDIR"
    if tree_clean; then
        echo "ABORT: real edits to $PLUGIN and $QMLDIR were not seen — the baseline is not being read" >&2
        exit 3
    fi
    echo "  ok   real edits to the files under test are SEEN"
    restore
    echo "  ok   …and the restore puts them back, sha256 for sha256"
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
# before its first assertion printed passed=0 failed=0, and a mutation harness
# graded eleven mutants against it. "Was the baseline green" is not the
# question. "Did the baseline print an `ok` line containing THIS mutant's want"
# is, and it is asked per mutant below as well as in aggregate here.
echo
echo "── the baseline, before anything is touched ──"
base="$(run_suite)"
if ! has_totals "$base"; then
    echo "ABORT: the baseline never reached its totals line; nothing can be scored" >&2
    printf '%s\n' "$base" | tail -15 >&2
    exit 3
fi
printf '%s\n' "$base" | sed -n 's/^i18n-host: /  baseline  /p'
if [ "$(suite_failures "$base")" -gt 0 ]; then
    echo "ABORT: the baseline is already RED. Fix that before mutating anything." >&2
    printf '%s\n' "$base" | grep -E '^  FAIL' >&2
    exit 3
fi
base_oks="$(printf '%s\n' "$base" | grep -c '^  ok   ')"
# 15 rather than 1: a machine with no quickshell still reaches 21 assertions,
# and a machine with no Qt or no compiler reaches ONE (the whole-suite SKIP) or
# none. Anything between is a suite that fell over part-way, and scoring
# mutants against it would invent verdicts about nothing.
if [ "$base_oks" -lt 15 ]; then
    echo "  SKIP everything: the baseline made only $base_oks assertions, so this"
    echo "       machine cannot host the suite (no compiler, no Qt 6 QML, no moc"
    echo "       or no lrelease). Scoring mutants against it would invent verdicts."
    echo
    echo "mutate-i18n-host: applied=0 caught=0 survived=0 misscored=0 unscorable=0 held=0 false-red=0"
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

# mutate <id> <file> <from> <to> <assertion substring that must go red>
mutate() {
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

# hold <id> <file> <from> <to> <what it proves>
hold() {
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
echo "── RED: each of these must make a NAMED assertion fail ──"

# The one that matters. Everything about the plugin still looks right.
mutate M1 "$PLUGIN" '        qmlRegisterModule(uri, 1, 0);' \
          '        (void) uri;' \
          'every host mode reaches its last line'

mutate M2 "$PLUGIN" '            QCoreApplication::installTranslator(tr);' \
          '            (void) tr;' \
          'reads the German from'

mutate M3 "$PLUGIN" '            qInfo("APEXI18N: no catalogue for %s in %s",' \
          '            if (false) qInfo("APEXI18N: no catalogue for %s in %s",' \
          'REPORTS the absence rather than going quiet'

mutate M4 "$QMLDIR" 'plugin apexi18n' \
          '# plugin apexi18n' \
          "the plugin's registerTypes runs"

mutate M5 "$QMLDIR" 'module Apex.I18n' \
          'module Apex.I18nElsewhere' \
          'every host mode reaches its last line'

mutate M6 "$PLUGIN" '        if (tr->load(QLocale(), QStringLiteral("apex-shell"),' \
          '        if (tr->load(QLocale(), QStringLiteral("apex-shell-not-this-one"),' \
          'the plugin installs a QTranslator from inside'

mutate M7 "$HOST" '    const bool wantsPlugin = (mode == QLatin1String("plugin")
                              || mode == QLatin1String("nocat"));' \
          '    const bool wantsPlugin = (mode == QLatin1String("plugin")
                              || mode == QLatin1String("nocat")
                              || mode == QLatin1String("plain"));' \
          'with no import path the plugin does not run at all'

mutate M8 "$HOST" '        if (mode == QLatin1String("late-retranslate")) {' \
          '        if (mode == QLatin1String("late") || mode == QLatin1String("late-retranslate")) {' \
          'changes nothing already evaluated'

mutate M9 "$HOST" '        if (tr->load(QLocale(), QStringLiteral("apex-shell"), QStringLiteral("_"), trdir)) {' \
          '        if (false && tr->load(QLocale(), QStringLiteral("apex-shell"), QStringLiteral("_"), trdir)) {' \
          'so its English is not a failed load'

# A build that does not build is a FAILURE. A suite that reported it as a skip
# would turn every measurement in it into a silent absence.
mutate M10 "$PLUGIN" 'class ApexI18nPlugin : public QQmlExtensionPlugin' \
           'class ApexI18nPlugin : public QQmlExtensionPlugin THIS IS NOT C++' \
           'builds into a QML plugin against'

mutate M11 "$HOST" 'int main(int argc, char **argv)' \
           'int main(int argc, char **argv) THIS IS NOT C++' \
           'builds into a bare-QQmlEngine host'

echo
echo "── GREEN: prose and unasserted output must not move a single verdict ──"

hold G1 "$PLUGIN" '#include <QCoreApplication>' \
        '// Prose that quotes every string the suite asserts, so that a suite
// grepping this file instead of running it would go green on nonsense:
//   APEXI18N: registerTypes uri=Apex.I18n
//   APEXI18N: installed
//   APEXI18N: no catalogue for
//   APEXHOST first entryLabel=Wie Agenten und Arbeitsbereiche funktionieren
//   APEXHOST second entryLabel=Wie Agenten und Arbeitsbereiche funktionieren
//   APEXPROBE entryLabel=Wie Agenten und Arbeitsbereiche funktionieren
#include <QCoreApplication>' \
        'the suite reads the program OUTPUT, not the program source'

hold G2 "$HOST" '    printf("APEXHOST create=ok\n");' \
        '    printf("APEXHOST create=ok\n");
    printf("APEXHOST note=a line no assertion in the suite mentions\n");' \
        'output nothing asserts is not a failure'

restore

echo
printf 'mutate-i18n-host: applied=%d caught=%d survived=%d misscored=%d unscorable=%d held=%d false-red=%d\n' \
    "$applied" "$caught" "$survived" "$misscored" "$unscorable" "$held" "$falsered"
[ "$noapply" -gt 0 ] && printf '  %d mutant(s) DID NOT APPLY — their anchors have moved and they proved nothing\n' "$noapply"

rc=0
[ "$survived"   -gt 0 ] && { echo "  FAIL — a vacuous assertion: the suite stayed green with a real defect in place"; rc=1; }
[ "$misscored"  -gt 0 ] && { echo "  FAIL — a mutant went red on the wrong line; the expectation is wrong"; rc=1; }
[ "$unscorable" -gt 0 ] && { echo "  FAIL — a mutant aimed at an assertion the baseline never made"; rc=1; }
[ "$falsered"   -gt 0 ] && { echo "  FAIL — the suite went red at prose or at output nothing asserts"; rc=1; }
[ "$noapply"    -gt 0 ] && { echo "  FAIL — a mutant's anchor no longer exists in the source"; rc=1; }
exit "$rc"
