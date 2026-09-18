#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  mutate-lockscreen-atspi.sh — prove run-lockscreen-atspi.sh can go red, and
#  prove it does not go red at prose.
#
#  ── Why this one needs mutating more than most ──────────────────────────────
#
#  run-lockscreen-atspi.sh reports a NEGATIVE: the shell publishes no
#  accessibility tree below its application node. A negative is the easiest
#  result in the world to produce by accident. Every one of these would yield
#  the same output as the real defect:
#
#    * the a11y status flags never took, so Qt's bridge published nothing;
#    * the registry never came up, so the walker found no applications;
#    * the walker was pointed at the wrong bus;
#    * the compositor never mapped anything;
#    * the lock never engaged, so there was no surface to read.
#
#  So the suite carries a control — a plain Qt Quick Window under the stock qml
#  runtime, on the same compositor and the same bus, in the same run — and the
#  mutants below BREAK THAT CONTROL and require the suite to notice. R1, R2 and
#  R2b are the whole argument: if a suite cannot tell a labelled window from an
#  unlabelled one, its "nothing was published" is worth nothing.
#
#  R3 breaks the GSETTINGS_BACKEND=memory line in tests/lib/atspi.sh, which is
#  the fix that made any of this measurable. Without it the D-Bus Set of
#  org.a11y.Status returns success and changes nothing, the flags read back
#  false, and Qt publishes an empty tree for EVERYTHING — control included. That
#  mutant is here because that is precisely the false negative this suite exists
#  to be immune to, and it was live in the first draft.
#
#  R4-R7 are about the other two things the suite measures: that the
#  LockedHintService chain really stops before it can reach the live system bus,
#  and that the lock really engages on the compositor. R5 is the important one:
#  it makes the service call SetLockedHint, and the suite has to go red. Without
#  it "nothing ever asks logind to set a locked hint" is a green tick over an
#  empty log file, which is the same vacuity the suite refuses in its own §5.
#
#  ── Both directions ─────────────────────────────────────────────────────────
#
#  RED (`mutate`): one thing is broken and a NAMED assertion must go red. A
#  suite that went red on some OTHER line is MISSCORED, not caught.
#
#  GREEN (`hold`): prose is added that quotes the exact things the suite
#  forbids — including the words "SetLockedHint" in a comment — and the suite
#  must stay green. G2 is the one that matters: it proves the logind assertions
#  read the CALL LOG and not the source text.
#
#  ── Four verdicts, and the harness proves it can produce all four ───────────
#
#  CAUGHT / MISSCORED / CRASHED / SURVIVED. CRASHED exists because a mutant that
#  makes the suite exit before its totals line prints no totals, and a harness
#  that only counts failures reads that as "nothing failed" — a working suite
#  reported as a broken one.
#
#  ── How the files get put back ──────────────────────────────────────────────
#
#  A pristine copy into a per-run mktemp directory, restored with plain `cp`,
#  and every restore VERIFIES sha256 against a baseline taken before anything
#  was touched. Not `git checkout --`: the arch-validate job installs git AFTER
#  actions/checkout, so the workspace has no .git at all. Not a shared scratch
#  path either — a `cp` restore in this unit once put back another agent's file.
#
#  ── This is slow, and it is slow for a reason ───────────────────────────────
#
#  Every mutant is a full bring-up: a headless compositor, a private session
#  bus, an accessibility bus, a registry, the control application, the entire
#  shell, and a session lock. About forty seconds each. There is no faster
#  honest version — the thing under test is what a running program publishes
#  over D-Bus, and nothing short of running it answers that.
#
#  Run from anywhere: ./tests/mutate-lockscreen-atspi.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

CONTROL="tests/lockscreen-atspi-control.qml"
ATSPI="tests/lib/atspi.sh"
HINT="src/services/system/LockedHintService.qml"
IPC="src/state/IpcManager.qml"
LOCK="src/windows/Lockscreen.qml"
FILES="$CONTROL $ATSPI $HINT $IPC $LOCK"
SUITE="./tests/run-lockscreen-atspi.sh"
TOTALS_PREFIX="lockscreen-atspi: passed="

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required" >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { echo "FATAL: sha256sum is required" >&2; exit 2; }

applied=0; noapply=0; caught=0; survived=0; misscored=0; held=0; falsered=0

SNAP="$(mktemp -d "${TMPDIR:-/tmp}/mutate-lockscreen-atspi.XXXXXX")" || exit 2
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

# env -i, because an assertion whose truth comes from the ambient environment is
# the same defect class as a gate that inspects nothing. XDG_RUNTIME_DIR,
# WAYLAND_DISPLAY and DBUS_SESSION_BUS_ADDRESS are all deliberately NOT passed:
# the suite must build its own or skip, and it must never find the desk's.
run_suite() {
    env -i HOME="$HOME" PATH="$PATH" USER="${USER:-$(id -un)}" \
        TMPDIR="${TMPDIR:-/tmp}" "$SUITE" 2>&1
}

has_totals() { printf '%s\n' "$1" | grep -qF "$TOTALS_PREFIX"; }

suite_failures() {
    printf '%s\n' "$1" \
        | sed -n 's/^lockscreen-atspi: passed=[0-9]* failed=\([0-9]*\).*/\1/p' \
        | head -1 | grep -E '^[0-9]+$' || echo 0
}

# classify <suite output> <expected FAIL substring>
#   -> CAUGHT | MISSCORED | CRASHED | SURVIVED
#
# The membership test is `[[ "$t" == *"$n"* ]]`, never `printf | grep -q`: under
# `pipefail` a grep that matches closes the pipe and the printf dies with
# SIGPIPE, so the pipeline's status is 141 on a MATCH. That has scored real
# catches as misses in this repository before.
classify() {
    local out="$1" want="$2" line
    if ! has_totals "$out"; then
        echo CRASHED
        return
    fi
    while IFS= read -r line; do
        case "$line" in
            "  FAIL "*) [[ "$line" == *"$want"* ]] && { echo CAUGHT; return; } ;;
        esac
    done <<<"$out"
    if [ "$(suite_failures "$out")" -gt 0 ]; then
        echo MISSCORED
    else
        echo SURVIVED
    fi
}

# ── self-test: the scoring above, in all four states ─────────────────────────
selftest() {
    local red green crash fails=0
    red="  FAIL an Accessible.name written in QML arrives on the bus verbatim  — no node named apex-atspi-control-label
lockscreen-atspi: passed=15 failed=1 skipped=6"
    green="lockscreen-atspi: passed=16 failed=0 skipped=6"
    crash="FATAL: this tree has no tests/atspi-walk.py"

    chk() {  # chk <label> <want> <got>
        if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
        else printf '  FAIL %s — want %s got %s\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
    }
    chk "a red suite naming the expectation is CAUGHT" \
        CAUGHT    "$(classify "$red"   "arrives on the bus verbatim")"
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

# ── self-test: the RESTORE mechanism, which everything else rests on ─────────
restore_selftest() {
    # shellcheck disable=SC2086
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
       && git diff --name-only -- $FILES >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        if [ -n "$(git diff --name-only -- $FILES)" ]; then
            echo "  note the baseline is a WORKING TREE state, not HEAD:"
            # shellcheck disable=SC2086
            git diff --name-only -- $FILES | sed 's/^/         /'
        else
            echo "  ok   the baseline being snapshotted is HEAD"
        fi
    else
        echo "  note not a git work tree (a tarball checkout, which is what the arch"
        echo "       runner delivers); the baseline is the files as they arrived"
    fi

    take_snapshot
    tree_clean || { echo "ABORT: the snapshot does not match the files it was taken from" >&2; exit 3; }

    printf '\n// mutate-lockscreen-atspi.sh restore probe\n' >>"$CONTROL"
    if tree_clean; then
        echo "ABORT: a real edit to $CONTROL was not seen — the baseline is not being read" >&2
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

# mutate <id> <file> <from> <to> <assertion substring that must go red>
mutate() {
    local id="$1" file="$2" from="$3" to="$4" want="$5"
    tree_clean || { echo "ABORT: tree dirty BEFORE $id" >&2; exit 3; }
    if ! apply_edit "$file" "$from" "$to"; then
        printf '%-5s NO-APPLY  anchor absent in %s — this mutant proves nothing\n' "$id" "$file"
        noapply=$((noapply + 1)); restore; return
    fi
    applied=$((applied + 1))

    local out verdict; out="$(run_suite)"; verdict="$(classify "$out" "$want")"
    case "$verdict" in
    CAUGHT)
        printf '%-5s CAUGHT    %s\n' "$id" "$want"
        caught=$((caught + 1)) ;;
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
        printf '%s\n' "$out" | tail -5 | sed 's/^/      /'
        misscored=$((misscored + 1)) ;;
    *)
        printf '%-5s SURVIVED  %s\n' "$id" "$want"
        printf '      ── the suite stayed GREEN with this mutant applied ──\n'
        printf '%s\n' "$out" | grep -E "^  (FAIL|SKIP)|^lockscreen-atspi" | sed 's/^/      /'
        survived=$((survived + 1)) ;;
    esac
    restore
}

# hold <id> <file> <from> <to> <why this must NOT fire>
hold() {
    local id="$1" file="$2" from="$3" to="$4" why="$5"
    tree_clean || { echo "ABORT: tree dirty BEFORE $id" >&2; exit 3; }
    if ! apply_edit "$file" "$from" "$to"; then
        printf '%-5s NO-APPLY  anchor absent in %s\n' "$id" "$file"
        noapply=$((noapply + 1)); restore; return
    fi
    applied=$((applied + 1))
    local out; out="$(run_suite)"
    if has_totals "$out" && [ "$(suite_failures "$out")" -eq 0 ]; then
        printf '%-5s HELD      %s\n' "$id" "$why"
        held=$((held + 1))
    else
        printf '%-5s FALSE-RED %s\n' "$id" "$why"
        printf '      ── the suite fired on something that changes nothing ──\n'
        printf '%s\n' "$out" | grep -E "^  (FAIL|SKIP)|^lockscreen-atspi|^FATAL" | sed 's/^/      /'
        falsered=$((falsered + 1))
    fi
    restore
}

echo
echo "── baseline: green, or nothing below means anything ──"
base="$(run_suite)"
printf '%s\n' "$base" | grep -E '^lockscreen-atspi'
if ! printf '%s' "$base" | grep -qE '^lockscreen-atspi: passed=[0-9]+ failed=0'; then
    echo "ABORT: the suite is not green to begin with" >&2
    printf '%s\n' "$base" | grep -E '^  (FAIL|SKIP)' >&2
    exit 3
fi
# The baseline SKIPS six assertions on purpose — §5 of the suite, which refuses
# to count a vacuous pass. That is expected here and is NOT the "a skip measures
# nothing" warning the sister harness prints; what would be wrong is §1 or §2
# skipping, because then the mutants below are aimed at checks that never ran.
# A missing quickshell or a missing qml runtime is a COULD-NOT-RUN, not a
# failure and not a pass. It is reported and the run stops with status 0, the
# way every other suite in this tree treats a machine that cannot host it —
# scoring mutants against checks that never ran would be worse than measuring
# nothing, because it would print verdicts.
if printf '%s' "$base" | grep -q 'SKIP the shell half of this suite'; then
    echo "SKIP: quickshell is absent, so the suite's §2-§5 never ran and no"
    echo "      mutant below could be scored against anything. NOTHING WAS"
    echo "      MEASURED — this is a could-not-run, not a green run."
    exit 0
fi
if printf '%s' "$base" | grep -q 'SKIP the control publishes'; then
    echo "SKIP: no qml runtime, so the control never ran and R1, R2 and R2b"
    echo "      would be scored against checks that are not there. NOTHING WAS"
    echo "      MEASURED."
    exit 0
fi

echo
echo "── red: break the CONTROL, and the suite must notice ──"

# R1 — the control's label loses its accessible name. If the suite cannot tell a
#      named node from an unnamed one, its "the shell published nothing" is an
#      opinion.
mutate R1 "$CONTROL" \
    '        Accessible.name: "apex-atspi-control-label"' \
    '        // Accessible.name removed by mutant R1' \
    "an Accessible.name written in QML arrives on the bus verbatim"

# R2 — the control's window is never shown.
#
#      This mutant SURVIVED the first time it was run, and the survival was the
#      harness's fault rather than the suite's, which is why it is written up
#      here instead of quietly deleted. The expectation was that an unmapped
#      window publishes no frame. It does: Qt's
#      QAccessibleApplication::topLevelObjects() filters on window TYPE and on
#      having an accessible root, and on nothing else, so a Window that was
#      constructed and never shown is in the tree with all of its children.
#      Measured directly — the frame came back with states=enabled,sensitive
#      and neither `showing` nor `visible`.
#
#      So the suite gained the assertion this now aims at. It is a better
#      control for a LOCK SURFACE anyway: what §4 is looking for is a surface
#      that is genuinely on screen, not an object graph.
mutate R2 "$CONTROL" \
    '    visible: true' \
    '    visible: false' \
    "the control's window is MAPPED, not merely constructed"

# R2b — the control's window becomes a Popup, which is one of the two window
#       types Qt drops from the accessibility tree outright
#       (qtbase/src/gui/accessible/qaccessibleobject.cpp, topLevelObjects).
#       The application still registers and the bus still answers; the window
#       simply is not in it. That is the exact shape of §4's finding, produced
#       deliberately in a program that is known-good, so the suite has to be
#       able to see it.
mutate R2b "$CONTROL" \
    '    title:  "apex-atspi-control"' \
    '    title:  "apex-atspi-control"
    flags:  Qt.Popup' \
    "the control's WINDOW reaches the bus as a frame"

# R3 — the fix that made any of this measurable. Take GSETTINGS_BACKEND=memory
#      away and at-spi-bus-launcher cannot write the org.a11y.Status flags
#      (the dconf writer cannot be activated on a bus with no service
#      directory), the D-Bus Set returns success and changes nothing, and Qt
#      publishes an empty tree for every application including the control.
#      This is the exact false negative the suite must never report as a
#      finding.
mutate R3 "$ATSPI" \
    '    GSETTINGS_BACKEND=memory \
        "$ATSPI_BUS_LAUNCHER"' \
    '    "$ATSPI_BUS_LAUNCHER"' \
    "org.a11y.Status.ScreenReaderEnabled is true"

echo
echo "── red: break the logind guard, and the suite must notice ──"

# R4 — the service stops asking loginctl anything. The guard assertions would
#      then be true of a service that never runs, which is the vacuous shape.
mutate R4 "$HINT" \
    '        showUserProc.command = ["loginctl", "show-user", user, "-p", "Display", "--value"]' \
    '        showUserProc.command = ["true"]' \
    "LockedHintService really does reach for loginctl at startup"

# R5 — the one that matters. The chain is spliced so it goes straight to step 3
#      with a hardcoded session path, which is what a service with a cached or
#      guessed path would do. SetLockedHint is then really invoked, the recorder
#      really sees it, and the suite must go red. Without this mutant "nothing
#      ever asks logind to set a locked hint" is a green tick over an empty file.
mutate R5 "$HINT" \
    '            if (exitCode !== 0 || root._sessionId === "") {
                root._failed("loginctl show-user")
                return
            }
            root.getSessionProc.command = [
                "busctl", "--system", "call", "org.freedesktop.login1",
                "/org/freedesktop/login1", "org.freedesktop.login1.Manager",
                "GetSession", "s", root._sessionId
            ]
            root.getSessionProc.running = false
            root.getSessionProc.running = true' \
    '            root.setHintProc.command = [
                "busctl", "--system", "call", "org.freedesktop.login1",
                "/org/freedesktop/login1/session/_33",
                "org.freedesktop.login1.Session",
                "SetLockedHint", "b", root._target ? "true" : "false"
            ]
            root.setHintProc.running = false
            root.setHintProc.running = true' \
    "nothing ever asks logind to set a locked hint"

echo
echo "── red: break the lock itself, and the suite must notice ──"

# R6 — the IPC handler stops locking. The IPC call still succeeds and still
#      returns 0, so an assertion that only read the reply would stay green;
#      this is what separates "the handler answered" from "the compositor
#      engaged a session lock".
mutate R6 "$IPC" \
    '        function lock() {
            LockState.locked = true
        }' \
    '        function lock() {
            LockState.locked = false
        }' \
    "acknowledged ext-session-lock"

# R7 — the lock still engages, but the shell stops reporting the ACKNOWLEDGED
#      state. The suite observes labwc's acknowledgement through that binding
#      and nothing else, so this has to go red — and it says out loud that the
#      assertion is about `secure`, not about `locked`.
mutate R7 "$LOCK" \
    '    onSecureStateChanged: LockedHintService.setLocked(sessionLock.secure)' \
    '    // onSecureStateChanged removed by mutant R7' \
    "acknowledged ext-session-lock"

echo
echo "── green: prose quoting every one of those must NOT fire it ──"

# G1 — a comment in the control quoting the bindings R1 removes.
hold G1 "$CONTROL" \
    '        Accessible.role: Accessible.StaticText' \
    '        // WRONG, kept as a warning: Accessible.name removed
        // WRONG, kept as a warning: visible: false
        Accessible.role: Accessible.StaticText' \
    "comments quoting the exact bugs this suite forbids do not fire it"

# G2 — the word SetLockedHint, in prose, in the very file whose calls are being
#      counted. The assertion reads the RECORDING, not the source, and this is
#      what proves it: a suite that grepped the file would go red here and would
#      have been asserting nothing about behaviour at all.
hold G2 "$HINT" \
    '    function setLocked(locked) {' \
    '    // Prose, not a call: busctl --system call … SetLockedHint b true is what
    // step 3 below would run, and tests/run-lockscreen-atspi.sh asserts it is
    // never reached from a private runtime directory.
    function setLocked(locked) {' \
    "the word SetLockedHint in a comment is not a call to SetLockedHint"

# G3 — the same for the lock surface: a comment naming the binding R7 deletes.
hold G3 "$LOCK" \
    'WlSessionLock {
    id: sessionLock' \
    'WlSessionLock {
    id: sessionLock

    // Prose: onSecureStateChanged is the ACKNOWLEDGED state, not the requested
    // one. LockState.locked = true is the request; `secure` is the answer.' \
    "a comment naming the secure binding is not the secure binding"

echo
printf 'mutants applied=%d, failed-to-apply=%d | red: caught=%d SURVIVED=%d MISSCORED=%d | green: held=%d FALSE-RED=%d\n' \
    "$applied" "$noapply" "$caught" "$survived" "$misscored" "$held" "$falsered"
[ "$misscored" -eq 0 ] || echo "MISSCORED means this harness is wrong, not the shell." >&2
tree_clean || { echo "ABORT: tree dirty at end of run" >&2; exit 3; }
echo "every file matches the sha256 it started with"
[ "$survived" -eq 0 ] && [ "$misscored" -eq 0 ] && [ "$falsered" -eq 0 ] && [ "$noapply" -eq 0 ]
