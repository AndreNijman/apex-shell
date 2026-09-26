#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-i18n-host-test.sh — the host CAN install a QTranslator, and here is the
#  artefact that does it (roadmap P2-004, internationalisation baseline).
#
#  ── What this closes ────────────────────────────────────────────────────────
#
#  tests/run-i18n-test.sh proves the translation PIPELINE end to end — the
#  strings are marked, lupdate extracts them, lrelease compiles them, and a
#  running QML engine substitutes German. Its section 4 then says why none of
#  that reaches a user: the shell runs inside quickshell, quickshell builds a
#  bare QQmlEngine, and nothing in the process ever calls installTranslator. No
#  QML can fix that, because QTranslator is a C++ class and not a QML type.
#
#  The conclusion drawn from it for thirty rounds — that the fix is therefore
#  somebody else's — is one step too far. A bare QQmlEngine still resolves QML
#  modules off its import path; a QML module may carry a compiled plugin; and a
#  compiled plugin runs C++ inside the shell's own process while the import is
#  being resolved, which is before a single binding has been evaluated. So the
#  host change is a module APEX ships and shell.qml imports.
#
#  tests/apex-i18n-plugin.cpp is that module. This suite builds it and measures
#  it in two hosts: a bare QQmlEngine assembled out of quickshell's own two
#  lines (tests/apex-i18n-host.cpp), and, where one exists, the REAL
#  /usr/bin/quickshell running the SHIPPED AgentHelpContent singleton.
#
#  ── Why a second host at all ────────────────────────────────────────────────
#
#  The GitHub Arch runner has no quickshell — it is an AUR package there — so a
#  suite that could only measure this in situ would measure NOTHING on the
#  machine the gate runs on, and would sit green for ever saying so. The bare
#  engine runs anywhere Qt 6 does, and section 3 is the half the runner
#  executes. Section 4 is the half that only a machine with quickshell can run,
#  and it refuses BY NAME rather than skipping quietly.
#
#  ── Why "the strings changed" is not enough on its own ──────────────────────
#
#  Five runs, not two, because "German appeared" has at least three innocent
#  explanations and each needs its own control:
#
#    plain  no plugin at all               English, and NO plugin log line —
#                                          so the plugin is genuinely absent
#                                          and not merely quiet
#    plugin plugin + catalogue             German
#    nocat  plugin, catalogue dir EMPTY    English, and the plugin says so —
#                                          so the German came from a CATALOGUE
#                                          and not from the plugin's presence
#    late   translator installed AFTER     English — a translator installed
#           the tree exists                after evaluation changes nothing
#    late-retranslate  …plus retranslate() German — and the ONLY difference
#                                          from `late` is that one call
#
#  The last pair is why the plugin does its work from initializeEngine(). It is
#  measured rather than asserted because it is the fact a later "just install a
#  translator in main()" would break on, silently.
#
#  ── Titles ──────────────────────────────────────────────────────────────────
#
#  Every assertion goes through chk(), which takes its title ONCE and prints the
#  same words whether it passes or fails. Round 31 lost four rows to a suite
#  that called one assertion by two names depending on the outcome (FOUND 29);
#  a mutation harness cannot verify a target it cannot find. Here the drift is
#  structurally impossible rather than gated after the fact.
#
#  ── Headless discipline ─────────────────────────────────────────────────────
#
#  Nothing here needs a compositor: the platform is offscreen and the probe
#  creates no window. Every launch carries `env -u WAYLAND_DISPLAY -u DISPLAY
#  -u HYPRLAND_INSTANCE_SIGNATURE` so a machine with a live session cannot have
#  a window land on it, and this file never reads $WAYLAND_DISPLAY at all.
#
#  Run from anywhere: ./tests/run-i18n-host-test.sh
# ─────────────────────────────────────────────────────────────────────────────
. "$(dirname "${BASH_SOURCE[0]}")/lib/private-bus.sh"   # the session bus is ours, not the desktop's
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root" || exit 2

PLUGIN_SRC="$here/apex-i18n-plugin.cpp"
HOST_SRC="$here/apex-i18n-host.cpp"
QMLDIR_SRC="$here/apex-i18n-qmldir"
CONTENT="src/services/agents/AgentHelpContent.qml"
TS="translations/apex-shell_de.ts"

# The German the checked-in .ts supplies. Asserted, never merely "different":
# a run that returned any other string would still differ from English.
DE_ENTRY="Wie Agenten und Arbeitsbereiche funktionieren"
DE_READ="Anleitung lesen"
EN_ENTRY="How Agents & Workspaces work"

pass=0; fail=0; skip=0
ok()   { echo "  ok   $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL $1${2:+  — $2}"; fail=$((fail + 1)); }
# A SKIP is a could-not-run, never a pass. This suite exits 0 on a skip, so the
# totals line is the only honest way to read it.
nope() { echo "  SKIP $1${2:+  — $2}"; skip=$((skip + 1)); }
section() { printf '\n── %s ──\n' "$1"; }
totals() { printf '\ni18n-host: passed=%d failed=%d skipped=%d\n' "$pass" "$fail" "$skip"; }

# One title, both outcomes. See the header.
chk() {   # chk <title> <rc> [detail]
    if [ "$2" = 0 ]; then ok "$1"; else bad "$1" "${3:-}"; fi
}
# A bash substring test, never `printf | grep -q`: under `set -o pipefail` a
# grep that matches can close the pipe before printf finishes writing, printf
# takes SIGPIPE, and the pipeline reports 141 on a MATCH (memory: "pipefail
# makes a grep -q match return 141").
says() { [[ "$1" == *"$2"* ]]; }

for f in "$PLUGIN_SRC" "$HOST_SRC" "$QMLDIR_SRC" "$CONTENT" "$TS"; do
    [ -f "$f" ] || { echo "FATAL: this tree has no ${f#"$root"/}" >&2; exit 2; }
done

# ── what it takes to run at all ──────────────────────────────────────────────
#
# Named individually. "could not build", "Qt is missing", "there is no
# compiler" and "moc is not where this distribution puts it" are four different
# answers, and one SKIP line that says none of them is the kind of report this
# repository has been bitten by.
CXX=""
for c in g++ c++ clang++; do command -v "$c" >/dev/null 2>&1 && { CXX="$c"; break; }; done
if [ -z "$CXX" ]; then
    echo "SKIP: no C++ compiler, so nothing here was measured."
    nope "the whole suite" "no g++/c++/clang++ on PATH"
    totals; exit 0
fi
if ! command -v pkg-config >/dev/null 2>&1; then
    echo "SKIP: no pkg-config, so nothing here was measured."
    nope "the whole suite" "pkg-config is not installed"
    totals; exit 0
fi
if ! pkg-config --exists Qt6Qml Qt6Gui Qt6Core 2>/dev/null; then
    echo "SKIP: no Qt 6 QML development files, so nothing here was measured."
    nope "the whole suite" "pkg-config cannot find Qt6Qml/Qt6Gui/Qt6Core"
    totals; exit 0
fi

# moc is on no distribution's $PATH and its directory differs by distribution:
# /usr/lib64/qt6/libexec on Fedora, /usr/lib/qt6 on Arch. Ask Qt where its own
# host tools are rather than guessing, and keep the guesses as a fallback so a
# machine with no qmake6 is not written off. FOUND 19 is the same shape for the
# at-spi helpers, and there the hardcoded list WAS the search.
MOC=""
for q in qmake6 qtpaths6 qmake-qt6; do
    command -v "$q" >/dev/null 2>&1 || continue
    d="$("$q" -query QT_HOST_LIBEXECS 2>/dev/null)"
    [ -n "$d" ] && [ -x "$d/moc" ] && { MOC="$d/moc"; break; }
done
if [ -z "$MOC" ]; then
    for m in /usr/lib64/qt6/libexec/moc /usr/lib/qt6/moc /usr/lib/qt6/libexec/moc \
             /usr/lib/x86_64-linux-gnu/qt6/libexec/moc; do
        [ -x "$m" ] && { MOC="$m"; break; }
    done
fi
[ -z "$MOC" ] && MOC="$(command -v moc 2>/dev/null || true)"
if [ -z "$MOC" ]; then
    echo "SKIP: no moc, so the plugin cannot be built and nothing here was measured."
    nope "the whole suite" "moc was not found through qmake6 -query QT_HOST_LIBEXECS nor at any known path"
    totals; exit 0
fi

LRELEASE=""
for n in lrelease-qt6 lrelease6 lrelease /usr/lib64/qt6/bin/lrelease /usr/lib/qt6/bin/lrelease; do
    command -v "$n" >/dev/null 2>&1 && { LRELEASE="$n"; break; }
done
if [ -z "$LRELEASE" ]; then
    echo "SKIP: no lrelease, so there is no catalogue to load and nothing here was measured."
    nope "the whole suite" "lrelease is not installed (qt6-tools / qt6-qttools-devel)"
    totals; exit 0
fi

W="$(mktemp -d "${TMPDIR:-/tmp}/apex-i18n-host.XXXXXX")" || exit 2
cleanup() { rm -rf "$W"; }
trap cleanup EXIT INT TERM

QTVER="$(pkg-config --modversion Qt6Core 2>/dev/null || echo unknown)"
echo "  note: Qt $QTVER, compiler $CXX, moc $MOC"

# ═════════════════════════════════════════════════════════════════════════════
section "1. the artefact builds"
# ═════════════════════════════════════════════════════════════════════════════
# A build failure is a FAILURE and never a skip. A suite that reported "did not
# compile" as a could-not-run would turn every measurement below into a silent
# absence, which is the defect this repository keeps meeting from new angles.

mkdir -p "$W/imports/Apex/I18n" "$W/stage" "$W/tr" "$W/empty"

# shellcheck disable=SC2046,SC2086  # pkg-config output is a deliberate word list
if ! "$MOC" $(pkg-config --cflags-only-I Qt6Qml Qt6Core) "$PLUGIN_SRC" \
        -o "$W/apex-i18n-plugin.moc" >"$W/moc.log" 2>&1; then
    chk "moc processes tests/apex-i18n-plugin.cpp" 1 "see the output below"
    sed 's/^/      /' "$W/moc.log" | head -15
    totals; exit 1
fi
chk "moc processes tests/apex-i18n-plugin.cpp" 0

# shellcheck disable=SC2046,SC2086
if ! $CXX -std=c++17 -fPIC -shared -o "$W/imports/Apex/I18n/libapexi18n.so" "$PLUGIN_SRC" \
        -I"$W" $(pkg-config --cflags Qt6Qml Qt6Core) \
        $(pkg-config --libs Qt6Qml Qt6Core) >"$W/build-plugin.log" 2>&1; then
    chk "tests/apex-i18n-plugin.cpp builds into a QML plugin against this machine's Qt 6" 1 \
        "see the compiler output below"
    sed 's/^/      /' "$W/build-plugin.log" | head -25
    totals; exit 1
fi
chk "tests/apex-i18n-plugin.cpp builds into a QML plugin against this machine's Qt 6" 0

cp "$QMLDIR_SRC" "$W/imports/Apex/I18n/qmldir"

# shellcheck disable=SC2046,SC2086
if ! $CXX -std=c++17 -fPIC -o "$W/host" "$HOST_SRC" \
        $(pkg-config --cflags Qt6Qml Qt6Gui Qt6Core) \
        $(pkg-config --libs Qt6Qml Qt6Gui Qt6Core) >"$W/build-host.log" 2>&1; then
    chk "tests/apex-i18n-host.cpp builds into a bare-QQmlEngine host" 1 \
        "see the compiler output below"
    sed 's/^/      /' "$W/build-host.log" | head -25
    totals; exit 1
fi
chk "tests/apex-i18n-host.cpp builds into a bare-QQmlEngine host" 0

if "$LRELEASE" -silent "$TS" -qm "$W/tr/apex-shell_de.qm" >"$W/lrelease.log" 2>&1 \
   && [ -s "$W/tr/apex-shell_de.qm" ]; then
    chk "lrelease compiles $TS into the catalogue the plugin will look for" 0
else
    chk "lrelease compiles $TS into the catalogue the plugin will look for" 1 \
        "$(tail -3 "$W/lrelease.log" | tr '\n' ' ')"
    totals; exit 1
fi

# ═════════════════════════════════════════════════════════════════════════════
section "2. the fixtures differ by one line, and the singleton is the shipped one"
# ═════════════════════════════════════════════════════════════════════════════
# The plain run and the plugin run load two different files, so those two files
# have to be the same file apart from the import under test. Left unchecked,
# any future edit to one of them would move the comparison without moving the
# claim, and a suite comparing two unrelated fixtures proves nothing at all.

cp "$CONTENT" "$W/stage/AgentHelpContent.qml"
cat > "$W/stage/qmldir" <<'QMLDIR'
singleton AgentHelpContent AgentHelpContent.qml
QMLDIR

cat > "$W/stage/probe.qml" <<'PROBE'
import QtQuick
import "."

QtObject {
    readonly property string entryLabel: AgentHelpContent.entryLabel
    readonly property string cardRead: AgentHelpContent.cardRead
    Component.onCompleted: {
        console.log("APEXPROBE entryLabel=" + entryLabel)
        console.log("APEXPROBE cardRead=" + cardRead)
    }
}
PROBE

# Built from the first by INSERTING the import, so the two cannot drift apart
# by hand. sed on a fixed anchor, and the assertion below is what proves the
# insertion happened where it was meant to.
sed '/^import QtQuick$/a import Apex.I18n' "$W/stage/probe.qml" > "$W/stage/probe-import.qml"

diffout="$(diff "$W/stage/probe.qml" "$W/stage/probe-import.qml")"
if [ "$(grep -c '^>' <<<"$diffout")" = 1 ] && [ "$(grep -c '^<' <<<"$diffout")" = 0 ] \
   && says "$diffout" "> import Apex.I18n"; then
    chk "the two probe fixtures differ by exactly one line, and it is the Apex.I18n import" 0
else
    chk "the two probe fixtures differ by exactly one line, and it is the Apex.I18n import" 1 \
        "$(tr '\n' ' ' <<<"$diffout")"
fi

if cmp -s "$CONTENT" "$W/stage/AgentHelpContent.qml"; then
    chk "the singleton under test is a byte-identical copy of the shipped $CONTENT" 0
else
    chk "the singleton under test is a byte-identical copy of the shipped $CONTENT" 1 \
        "the copy differs from the shipped file"
fi

# ═════════════════════════════════════════════════════════════════════════════
section "3. a bare QQmlEngine — the shape quickshell builds — takes the module"
# ═════════════════════════════════════════════════════════════════════════════
# env -i: an assertion whose truth comes from the ambient environment is the
# same defect class as a gate that inspects nothing (FOUND 5). The locale is
# set deliberately because it is the input under test, and the platform is set
# deliberately so no window can appear on anybody's desk.
#
# QT_FORCE_STDERR_LOGGING is not decoration. Fedora builds Qt with journald
# support, so the DEFAULT message handler sends qInfo() to the journal and not
# to stderr whenever stderr is not a terminal — which is every CI run and every
# command substitution. Without this the plugin's own lines would be missing
# from the output, and the "no plugin line appeared" assertion below would pass
# for a plugin that ran perfectly. The positive assertion in the `plugin` run is
# the control for the negative one in the `plain` run: they use the identical
# launcher, so an absence there is an absence and not a routing choice.
run_host() {   # run_host <mode> <catalogue dir>
    env -i -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
        PATH="$PATH" HOME="${HOME:-/tmp}" TMPDIR="${TMPDIR:-/tmp}" \
        QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 \
        LANG=de_DE.UTF-8 LC_ALL=de_DE.UTF-8 \
        APEX_I18N_MODE="$1" \
        APEX_I18N_STAGE="$W/stage" \
        APEX_I18N_IMPORTS="$W/imports" \
        APEX_SHELL_TRANSLATIONS="$2" \
        timeout 120 "$W/host" 2>&1
}

hostfield() {   # hostfield <output> <tag> <name>
    sed -n "s/^APEXHOST $2 $3=\\(.*\\)$/\\1/p" <<<"$1" | head -1
}

for m in plain plugin nocat late late-retranslate; do
    case "$m" in
        nocat) cat="$W/empty" ;;
        *)     cat="$W/tr" ;;
    esac
    run_host "$m" "$cat" >"$W/mode-$m.txt" 2>&1
done

PLAIN="$(cat "$W/mode-plain.txt")"
PLUGIN="$(cat "$W/mode-plugin.txt")"
NOCAT="$(cat "$W/mode-nocat.txt")"
LATE="$(cat "$W/mode-late.txt")"
LATER="$(cat "$W/mode-late-retranslate.txt")"

reached=0
for m in plain plugin nocat late late-retranslate; do
    says "$(cat "$W/mode-$m.txt")" "APEXHOST done=$m" || {
        reached=1
        echo "      mode $m did not reach its last line:"
        sed 's/^/        /' "$W/mode-$m.txt" | tail -8
    }
done
chk "every host mode reaches its last line" "$reached" "a truncated run reads as a negative"

# The locale really is right-to-… no: really is German. If it were not, every
# English answer below would be correct for the wrong reason.
says "$PLUGIN" "APEXHOST locale=de_DE" \
    && chk "the runs really are under a German locale" 0 \
    || chk "the runs really are under a German locale" 1 \
           "got: $(hostfield "$PLUGIN" "" locale)"

# ── plain: no plugin, and provably no plugin ────────────────────────────────
says "$PLAIN" "APEXI18N" \
    && chk "with no import path the plugin does not run at all — no plugin line in the output" 1 \
           "an APEXI18N line appeared in the plain run" \
    || chk "with no import path the plugin does not run at all — no plugin line in the output" 0

[ "$(hostfield "$PLAIN" first entryLabel)" = "$EN_ENTRY" ] \
    && chk "with no plugin the bare engine reads the English source string" 0 \
    || chk "with no plugin the bare engine reads the English source string" 1 \
           "got [$(hostfield "$PLAIN" first entryLabel)]"

# ── plugin: the route ───────────────────────────────────────────────────────
says "$PLUGIN" "APEXI18N: registerTypes uri=Apex.I18n" \
    && chk "the plugin's registerTypes runs, which is what makes the module exist to the engine" 0 \
    || chk "the plugin's registerTypes runs, which is what makes the module exist to the engine" 1 \
           "no registerTypes line; $(tail -2 "$W/mode-plugin.txt" | tr '\n' ' ')"

says "$PLUGIN" "APEXI18N: installed " \
    && chk "the plugin installs a QTranslator from inside the engine's own process" 0 \
    || chk "the plugin installs a QTranslator from inside the engine's own process" 1 \
           "no install line; $(tail -2 "$W/mode-plugin.txt" | tr '\n' ' ')"

[ "$(hostfield "$PLUGIN" first entryLabel)" = "$DE_ENTRY" ] \
    && chk "with the module imported, the SHIPPED singleton's entryLabel reads the German from $TS" 0 \
    || chk "with the module imported, the SHIPPED singleton's entryLabel reads the German from $TS" 1 \
           "got [$(hostfield "$PLUGIN" first entryLabel)]"

[ "$(hostfield "$PLUGIN" first cardRead)" = "$DE_READ" ] \
    && chk "a second independent string, cardRead, also reads its German" 0 \
    || chk "a second independent string, cardRead, also reads its German" 1 \
           "got [$(hostfield "$PLUGIN" first cardRead)]"

# THE SENSITIVITY CHECK. Without it the rest is decoration: two runs that
# returned the same text would leave every equality above satisfiable by a
# fixture that never translated anything.
[ "$(hostfield "$PLAIN" first entryLabel)" != "$(hostfield "$PLUGIN" first entryLabel)" ] \
    && chk "the same fixture gives DIFFERENT text with and without the module" 0 \
    || chk "the same fixture gives DIFFERENT text with and without the module" 1 \
           "both runs said [$(hostfield "$PLAIN" first entryLabel)]"

# ── nocat: the German came from a catalogue, not from a plugin being there ──
says "$NOCAT" "APEXI18N: no catalogue for" \
    && chk "pointed at an empty directory the plugin REPORTS the absence rather than going quiet" 0 \
    || chk "pointed at an empty directory the plugin REPORTS the absence rather than going quiet" 1 \
           "no such line; $(tail -2 "$W/mode-nocat.txt" | tr '\n' ' ')"

[ "$(hostfield "$NOCAT" first entryLabel)" = "$EN_ENTRY" ] \
    && chk "with the plugin loaded but no catalogue the strings stay English, so the German came from the .qm" 0 \
    || chk "with the plugin loaded but no catalogue the strings stay English, so the German came from the .qm" 1 \
           "got [$(hostfield "$NOCAT" first entryLabel)]"

# ── late: why the hook is initializeEngine ──────────────────────────────────
says "$LATE" "APEXHOST late-install=FAILED" \
    && chk "the late run really loaded a catalogue, so its English is not a failed load" 1 \
           "the late install failed, so this pair measured nothing" \
    || chk "the late run really loaded a catalogue, so its English is not a failed load" 0

[ "$(hostfield "$LATE" second entryLabel)" = "$EN_ENTRY" ] \
    && chk "a QTranslator installed AFTER the tree exists changes nothing already evaluated" 0 \
    || chk "a QTranslator installed AFTER the tree exists changes nothing already evaluated" 1 \
           "got [$(hostfield "$LATE" second entryLabel)]"

[ "$(hostfield "$LATER" second entryLabel)" = "$DE_ENTRY" ] \
    && chk "the same late install DOES take effect once the engine is asked to retranslate" 0 \
    || chk "the same late install DOES take effect once the engine is asked to retranslate" 1 \
           "got [$(hostfield "$LATER" second entryLabel)]"

[ "$(hostfield "$LATER" first entryLabel)" = "$EN_ENTRY" ] \
    && chk "the retranslate run starts English too, so the pair differs only in the retranslate call" 0 \
    || chk "the retranslate run starts English too, so the pair differs only in the retranslate call" 1 \
           "got [$(hostfield "$LATER" first entryLabel)]"

# ═════════════════════════════════════════════════════════════════════════════
section "4. and the REAL host — quickshell itself"
# ═════════════════════════════════════════════════════════════════════════════
# Section 3 is a host this repository assembled. This is the binary the shell
# really runs in. The refusal is by name: the Arch CI runner has no quickshell,
# and "the route works" must never be reported off a machine that did not try.
if ! command -v quickshell >/dev/null 2>&1; then
    nope "the real host, /usr/bin/quickshell, takes the module too" \
         "quickshell is not installed here (it is an AUR package on Arch), so section 4 measured nothing"
    nope "inside the real quickshell the shipped singleton reads its German" \
         "quickshell is not installed here"
    nope "inside the real quickshell, with no import path, the same fixture stays English" \
         "quickshell is not installed here"
    totals
    [ "$fail" -gt 0 ] && exit 1
    exit 0
fi

# A private runtime directory: quickshell writes an instance log tree under
# XDG_RUNTIME_DIR, and a suite has no business writing into the live session's.
mkdir -p "$W/run"
chmod 700 "$W/run"

run_qs() {   # run_qs <probe file> <import path or empty> <catalogue dir> <out file>
    local probe="$1" imports="$2" cat="$3" out="$4" i
    # env -u …: rule A of tests/check-headless-runners.sh, and the reason it
    # exists. Nothing here may reach the display the caller is sitting at.
    # shellcheck disable=SC2086
    env -i -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
        PATH="$PATH" HOME="${HOME:-/tmp}" TMPDIR="${TMPDIR:-/tmp}" \
        XDG_RUNTIME_DIR="$W/run" \
        QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 \
        LANG=de_DE.UTF-8 LC_ALL=de_DE.UTF-8 \
        QT_LOGGING_RULES="qml.debug=true;js.debug=true" \
        ${imports:+QML_IMPORT_PATH="$imports"} \
        APEX_SHELL_TRANSLATIONS="$cat" \
        quickshell -p "$probe" >"$out" 2>&1 &
    local pid=$!
    # Poll rather than wait out a timeout: quickshell loads in well under a
    # second and there are two runs. Thirty seconds is the ceiling, not the
    # cost.
    for ((i = 0; i < 150; i++)); do
        grep -q 'APEXPROBE entryLabel=' "$out" 2>/dev/null && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    return 0
}

run_qs "$W/stage/probe-import.qml" "$W/imports" "$W/tr"    "$W/qs-plugin.txt"
run_qs "$W/stage/probe.qml"        ""           "$W/tr"    "$W/qs-plain.txt"

QSP="$(cat "$W/qs-plugin.txt")"
QSN="$(cat "$W/qs-plain.txt")"

qsfield() { sed -n "s/.*APEXPROBE $2=\\(.*\\)$/\\1/p" <<<"$1" | head -1 | sed 's/[[:space:]]*$//'; }

if says "$QSP" "APEXI18N: installed " && says "$QSP" "APEXPROBE entryLabel="; then
    chk "the real host, /usr/bin/quickshell, takes the module too" 0
else
    chk "the real host, /usr/bin/quickshell, takes the module too" 1 \
        "$(tail -4 "$W/qs-plugin.txt" | tr '\n' ' ')"
fi

[ "$(qsfield "$QSP" entryLabel)" = "$DE_ENTRY" ] \
    && chk "inside the real quickshell the shipped singleton reads its German" 0 \
    || chk "inside the real quickshell the shipped singleton reads its German" 1 \
           "got [$(qsfield "$QSP" entryLabel)]"

if [ "$(qsfield "$QSN" entryLabel)" = "$EN_ENTRY" ] && ! says "$QSN" "APEXI18N"; then
    chk "inside the real quickshell, with no import path, the same fixture stays English" 0
else
    chk "inside the real quickshell, with no import path, the same fixture stays English" 1 \
        "got [$(qsfield "$QSN" entryLabel)]$(says "$QSN" APEXI18N && echo ' and the plugin ran anyway')"
fi

totals
[ "$fail" -gt 0 ] && exit 1
exit 0
