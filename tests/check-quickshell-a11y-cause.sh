#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-quickshell-a11y-cause.sh — run the reproduction that names the cause
#  of this repository's single largest accessibility defect, and pin it.
#
#  tests/run-lockscreen-atspi.sh measures the SYMPTOM: the running shell
#  publishes one node to AT-SPI, itself, and nothing beneath it, so every
#  Accessible.* binding in this tree is source-correct and unreachable. That
#  suite deliberately cannot say WHY. This one can, because the why is a
#  property of Qt that a 168-line program reproduces in two seconds with no
#  compositor, no bus and no quickshell:
#
#    QAccessible::installFactory registers a qAddPostRoutine that CLEARS the
#    accessibility factory list; post routines run from ~QCoreApplication;
#    qtdeclarative installs its factory from a Q_CONSTRUCTOR_FUNCTION, which
#    runs once per library load and can never run again; and quickshell
#    destroys a QCoreApplication immediately before constructing its
#    QGuiApplication. So the list is empty for the rest of the process's life.
#
#  tests/quickshell-a11y-cause.cpp carries the full argument and the five modes.
#
#  ── This is a pin, and it is meant to go red ────────────────────────────────
#
#  Mode A is quickshell's shape and must produce a NULL root. The day Qt or
#  qtdeclarative fixes this, mode A starts producing a root, THIS SUITE GOES RED,
#  and the failure message says what to do: delete the pin and replace
#  run-lockscreen-atspi.sh §5's skips with the real read-back assertions. A pin
#  that cannot go red is how a repository stays green straight through a fix and
#  leaves its own workarounds in place for years.
#
#  Modes B, C, D and E are not decoration. B is the control — a process that
#  never destroys an application object DOES get a root, so mode A's null is
#  about the destruction and not about this program being wrong. C reads the
#  cleared list directly, which nothing else can: qAccessibleFactories() is a
#  Q_GLOBAL_STATIC and not an exported symbol, so gdb cannot reach it either.
#  D measures the proposed one-line upstream fix actually working. E measures
#  the shape of tests/quickshell-a11y-shim.cpp, the LD_PRELOAD that confirms all
#  of this inside the real quickshell process.
#
#  Every assertion reads the PROGRAM'S OUTPUT, never the program's source.
#  tests/mutate-quickshell-a11y-cause.sh proves that by adding comments that
#  quote the exact strings asserted here and requiring this suite to stay green.
#
#  Run from anywhere: ./tests/check-quickshell-a11y-cause.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$here/quickshell-a11y-cause.cpp"

pass=0; fail=0; skip=0
ok()   { echo "  ok   $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL $1${2:+  — $2}"; fail=$((fail + 1)); }
# A SKIP is a could-not-run, never a pass. This suite exits 0 on a skip, so the
# totals line is the only honest way to read it.
nope() { echo "  SKIP $1${2:+  — $2}"; skip=$((skip + 1)); }
section() { printf '\n── %s ──\n' "$1"; }
totals() {
    printf '\nquickshell-a11y-cause: passed=%d failed=%d skipped=%d\n' "$pass" "$fail" "$skip"
}

[ -f "$SRC" ] || { echo "FATAL: this tree has no tests/quickshell-a11y-cause.cpp" >&2; exit 2; }

# ── what it takes to run at all ──────────────────────────────────────────────
#
# Named individually, because "could not build" and "Qt is missing" and "there
# is no compiler" are three different answers and a single SKIP line that says
# none of them is the kind of report this repository has been bitten by.
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
if ! pkg-config --exists Qt6Quick Qt6Gui Qt6Core 2>/dev/null; then
    echo "SKIP: no Qt 6 Quick development files, so nothing here was measured."
    nope "the whole suite" "pkg-config cannot find Qt6Quick/Qt6Gui/Qt6Core"
    totals; exit 0
fi

W="$(mktemp -d "${TMPDIR:-/tmp}/quickshell-a11y-cause.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT INT TERM

section "the reproduction builds"

# shellcheck disable=SC2046,SC2086  # pkg-config output is a deliberate word list
if ! $CXX -std=c++17 -fPIC -o "$W/repro" "$SRC" \
        $(pkg-config --cflags Qt6Quick Qt6Gui Qt6Core) \
        $(pkg-config --libs Qt6Quick Qt6Gui Qt6Core) >"$W/build.log" 2>&1; then
    bad "tests/quickshell-a11y-cause.cpp compiles against this machine's Qt 6" \
        "see the compiler output below"
    sed 's/^/      /' "$W/build.log" | head -25
    totals; exit 1
fi
ok "tests/quickshell-a11y-cause.cpp compiles against this machine's Qt 6"

QTVER="$(pkg-config --modversion Qt6Core 2>/dev/null || echo unknown)"
echo "  note: Qt $QTVER, compiler $CXX"

# env -i: an assertion whose truth comes from the ambient environment is the
# same defect class as a gate that inspects nothing. The one variable that is
# set deliberately is the platform, so no window can ever appear on a desktop.
run_mode() {
    env -i PATH="$PATH" HOME="${HOME:-/tmp}" TMPDIR="${TMPDIR:-/tmp}" \
        QT_QPA_PLATFORM=offscreen APEX_REPRO_MODE="$1" "$W/repro" 2>&1
}

for m in A B C D E; do
    out="$(run_mode "$m")"
    printf '%s' "$out" >"$W/mode-$m.txt"
    # A mode that did not reach its last line measured nothing, and every
    # assertion below would then be reading a truncated log as a negative.
    case "$out" in
        *"appIface: "*) : ;;
        # The FAIL text and the ok text below share a phrase ON PURPOSE.
        # tests/mutate-quickshell-a11y-cause.sh refuses to score a mutant whose
        # target assertion did not appear as an `ok` line in the baseline, so a
        # summary tick worded differently from its own failure would make this
        # check permanently unscorable.
        *)  bad "every mode reaches its last line" "mode $m did not; output below"
            sed 's/^/      /' "$W/mode-$m.txt" | tail -8 ;;
    esac
done
[ "$fail" -eq 0 ] && ok "every mode reaches its last line"

A="$(cat "$W/mode-A.txt")"; B="$(cat "$W/mode-B.txt")"
C="$(cat "$W/mode-C.txt")"; D="$(cat "$W/mode-D.txt")"
E="$(cat "$W/mode-E.txt")"

# A bash substring test, never `printf | grep -q`: under `set -o pipefail` a
# grep that matches can close the pipe before printf finishes writing, printf
# takes SIGPIPE, and the pipeline reports 141 on a MATCH. That has mis-scored
# suites in this repository before.
says() { [[ "$1" == *"$2"* ]]; }

# count_lines <text> <exact line>
count_lines() {
    local n=0 line
    while IFS= read -r line; do [ "$line" = "$2" ] && n=$((n + 1)); done <<<"$1"
    printf '%s' "$n"
}

# ─────────────────────────────────────────────────────────────────────────────
section "§1 mode A — quickshell's shape. THIS IS THE PIN"
# ─────────────────────────────────────────────────────────────────────────────

if says "$A" "accessibleRoot: NULL"; then
    ok "PINNED: a destroyed QCoreApplication leaves QQuickWindow::accessibleRoot() null"
else
    bad "PINNED: a destroyed QCoreApplication leaves QQuickWindow::accessibleRoot() null" \
        "the root is NOT null any more. THIS IS AN IMPROVEMENT, not a regression: Qt or qtdeclarative has been fixed. Delete this pin, and replace run-lockscreen-atspi.sh §5's skips with the real read-back assertions."
fi

if says "$A" "appChildCount: 0"; then
    ok "PINNED: and the application node therefore has no children at all"
else
    bad "PINNED: and the application node therefore has no children at all" \
        "the count moved; this is the exact number run-lockscreen-atspi.sh reads off the bus, so re-measure that suite too"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "§2 mode B — the control, so mode A is about the destruction"
# ─────────────────────────────────────────────────────────────────────────────

if says "$B" "accessibleRoot: NON-NULL"; then
    ok "a process that never destroys an application object DOES get a root"
else
    bad "a process that never destroys an application object DOES get a root" \
        "mode B is null too, so this program measures nothing and §1's null is not evidence"
fi

if says "$B" "rootName: QTROOT"; then
    ok "the root mode B gets is Qt's own, reading the window title through QAccessibleQuickWindow"
else
    bad "the root mode B gets is Qt's own, reading the window title through QAccessibleQuickWindow" \
        "expected the window title back; got $(printf '%s\n' "$B" | sed -n 's/^rootName: //p')"
fi

if says "$B" "appChildCount: 1"; then
    ok "and the application node counts that window as a child"
else
    bad "and the application node counts that window as a child" \
        "got $(printf '%s\n' "$B" | sed -n 's/^appChildCount: //p')"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "§3 mode C — the factory list really is CLEARED, read directly"
# ─────────────────────────────────────────────────────────────────────────────
#
# The only direct read there is. Everything above is consistent with "Qt Quick's
# factory was never installed"; this installs OUR OWN factory the same way
# qtdeclarative installs its one, and watches it vanish.

if says "$C" "install: Q_CONSTRUCTOR_FUNCTION installed apexFactory"; then
    ok "mode C really did install a factory before the application existed"
else
    bad "mode C really did install a factory before the application existed" \
        "no install line, so the mutant below would be proving nothing"
fi

if [ "$(count_lines "$C" "install: Q_CONSTRUCTOR_FUNCTION installed apexFactory")" = "1" ]; then
    ok "a Q_CONSTRUCTOR_FUNCTION install runs exactly ONCE — per library load, not per application"
else
    bad "a Q_CONSTRUCTOR_FUNCTION install runs exactly ONCE — per library load, not per application" \
        "it ran $(count_lines "$C" "install: Q_CONSTRUCTOR_FUNCTION installed apexFactory") time(s)"
fi

if says "$C" "accessibleRoot: NULL"; then
    ok "a factory installed the way qtdeclarative installs its one is GONE after the destruction"
else
    bad "a factory installed the way qtdeclarative installs its one is GONE after the destruction" \
        "our own factory survived, so the cleared-list explanation is wrong and FOUND 20 needs re-deriving"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "§4 mode D — the one-line upstream fix, measured working"
# ─────────────────────────────────────────────────────────────────────────────

if [ "$(count_lines "$D" "install: Q_COREAPP_STARTUP_FUNCTION installed apexFactory")" = "2" ]; then
    ok "a Q_COREAPP_STARTUP_FUNCTION install runs once per APPLICATION OBJECT — here, twice"
else
    bad "a Q_COREAPP_STARTUP_FUNCTION install runs once per APPLICATION OBJECT — here, twice" \
        "it ran $(count_lines "$D" "install: Q_COREAPP_STARTUP_FUNCTION installed apexFactory") time(s); if it is not re-running, it is not the fix"
fi

if says "$D" "accessibleRoot: NON-NULL"; then
    ok "so the factory is back after the destruction and the root is non-null again"
else
    bad "so the factory is back after the destruction and the root is non-null again" \
        "the proposed upstream fix does not work on this Qt; do not report it as the fix"
fi

if says "$D" "rootName: APEX-CUSTOM-ROOT"; then
    ok "and the root really is the one the startup routine installed, not a leftover"
else
    bad "and the root really is the one the startup routine installed, not a leftover" \
        "got $(printf '%s\n' "$D" | sed -n 's/^rootName: //p')"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "§5 mode E — the shape of the LD_PRELOAD instrument"
# ─────────────────────────────────────────────────────────────────────────────

if says "$E" "rootName: APEX-CUSTOM-ROOT" && says "$E" "appChildCount: 1"; then
    ok "installing a factory AFTER the QGuiApplication exists also restores the tree"
else
    bad "installing a factory AFTER the QGuiApplication exists also restores the tree" \
        "tests/quickshell-a11y-shim.cpp depends on this being true in-process"
fi

echo
echo "  What this means for the shell, in one line: the markup in this"
echo "  repository is correct and Qt cannot see it, and the fix is one macro in"
echo "  qtdeclarative or one fewer QCoreApplication in quickshell."

totals
[ "$fail" -eq 0 ]
