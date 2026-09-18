#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-lockscreen-atspi.sh — the lock screen, read back over real AT-SPI, the
#  way a screen reader reads it (roadmap P2-003).
#
#  ── What this is for ────────────────────────────────────────────────────────
#
#  tests/check-lockscreen-a11y.sh reads src/windows/Lockscreen.qml and asserts
#  the markup is there, on the right object, and cannot leak the password. It
#  says plainly, in its own header, that it does NOT run the lock screen and
#  read the tree back over AT-SPI. This is that missing half.
#
#  The difference is not academic. A screen reader never sees a QML file or a
#  QQuickItem: it connects to an accessibility bus and reads what Qt's AT-SPI
#  bridge chose to publish. The two trees differ in ways invisible from the QML
#  side — the bridge suppresses the name of any passwordEdit item, maps roles
#  into AT-SPI's own vocabulary, and drops items it judges uninteresting. The
#  only way to know what a blind user is told is to ask the bus.
#
#  ── What it found, and why the suite is shaped the way it is ────────────────
#
#  It asks the bus, and the bus says the shell publishes ONE node: itself.
#
#      root | role=application | name=quickshell | ChildCount=0
#
#  No window. No lock surface. No password field, no status line, no icons.
#  Every `Accessible.*` binding in this repository — round 28's lock screen
#  markup, the Cfg* controls, all of it — is unreachable by an assistive
#  technology at runtime, because the windows those items live in never reach
#  the accessibility tree at all.
#
#  Measured here on 2026-09-18, and narrowed rather than guessed at:
#
#    * quickshell DOES register with the accessibility registry. The bridge is
#      loaded, the bus is reachable, and the application node is published with
#      the right name — so this is not "accessibility is off".
#    * QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 changes nothing, so it is not the
#      org.a11y.Status gate either.
#    * The same harness, in the same run, on the same compositor and the same
#      bus, publishes a full three-node tree for a plain Qt Quick Window under
#      the stock `qml` runtime (tests/lockscreen-atspi-control.qml). That is §1
#      below and it is what makes the empty tree a measurement.
#    * A plain Qt Quick `Window` created INSIDE quickshell is equally absent,
#      so it is the process and not the window type.
#    * Under gdb, in the quickshell process: QGuiApplication::topLevelWindows()
#      has 2 entries, the first has type() == Qt::Window (1) — so it is neither
#      a Popup nor the Desktop, the two kinds Qt filters out — and
#      QQuickWindow::accessibleRoot() on it returns NULL. Qt's
#      QAccessibleApplication::childCount() is the size of topLevelObjects(),
#      which keeps only windows whose accessibleRoot() is non-null
#      (qtbase/src/gui/accessible/qaccessibleobject.cpp). A null accessibleRoot
#      on every window is therefore exactly a ChildCount of 0.
#
#  That is as far as this repository can take it: the remaining question is why
#  QAccessible::queryAccessibleInterface returns null for a QQuickWindow inside
#  quickshell, which is upstream work in quickshell or Qt, not here.
#
#  ── So what does this suite assert? ─────────────────────────────────────────
#
#  It PINS the measurement, the way tests/test-apex-greet-atspi.sh in apex-os
#  pins Qt's refusal to publish the AT-SPI password role: as an equality, so
#  that the day the tree stops being empty this suite goes red and says so,
#  instead of staying quietly green through the fix.
#
#  And it does NOT count the assertions the card actually asked for — the
#  field's name, role and passwordEdit, the status line's live name, the two
#  icons' absence — as passes. Every one of them is satisfied by an empty tree.
#  "No node named Password" is true of a tree with no nodes; so is "no node
#  whose name contains a private-use codepoint". They are SKIPs here, with the
#  reason printed, because a SKIP is a could-not-run and never a pass. That
#  vacuity is the whole trap this unit has been caught by before.
#
#  ── The lock is engaged for real, on a compositor of this run's own ─────────
#
#  §3 flips LockState through the shipped IPC entry point and the shipped
#  WlSessionLock engages ext-session-lock on a private headless labwc. Nothing
#  here can touch the session of whoever is at the machine: tests/lib/headless.sh
#  aborts unless the socket it came up on is inside a runtime directory this run
#  created, and tests/lib/atspi.sh aborts unless the accessibility bus is too.
#
#  ── The logind guard is MEASURED before anything is locked ──────────────────
#
#  src/services/system/LockedHintService.qml reaches for `loginctl show-user`
#  and then `busctl --system … SetLockedHint`. On a developer's machine the
#  system bus is the real one, and apex-agentd polls LockedHint to decide
#  whether Remote Control keeps running and whether a root grant survives — so a
#  test that locked first and checked afterwards would be betting the machine on
#  a private XDG_RUNTIME_DIR being enough. §2 installs recording stubs for both
#  tools, asserts from the log that the chain stops at step 1, and asserts that
#  no SetLockedHint argv is ever produced. It runs BEFORE the lock, because
#  Lockscreen.qml's Component.onCompleted pushes the initial hint at startup and
#  that is a complete exercise of the chain.
#
#  Run from anywhere: ./tests/run-lockscreen-atspi.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

pass=0; fail=0; skip=0
ok()   { echo "  ok   $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL $1${2:+  — $2}"; fail=$((fail + 1)); }
# A SKIP is a could-not-run, never a pass. Counted separately and printed on the
# totals line, because this suite exits 0 on a skip and the only honest way to
# read one is the totals, not the tick.
nope() { echo "  SKIP $1${2:+  — $2}"; skip=$((skip + 1)); }
section() { printf '\n── %s ──\n' "$1"; }

totals() {
    printf '\nlockscreen-atspi: passed=%d failed=%d skipped=%d\n' "$pass" "$fail" "$skip"
}

# ── the libraries ────────────────────────────────────────────────────────────
# Sourced at the TOP, before anything changes the environment, because both
# capture the ambient XDG_RUNTIME_DIR / WAYLAND_DISPLAY / bus addresses at
# source time and every refusal in them compares against those values. Sourcing
# atspi.sh after headless_begin would hand it a "real session" that is already
# this run's private directory, and its abort-if-ambient checks would be
# comparing a private path against a private path.
# shellcheck source=tests/lib/headless.sh
. "$here/lib/headless.sh"
# shellcheck source=tests/lib/atspi.sh
. "$here/lib/atspi.sh"

WALK="$here/atspi-walk.py"
CONTROL_QML="$here/lockscreen-atspi-control.qml"
LOCK_QML="$root/src/windows/Lockscreen.qml"

for f in "$WALK" "$CONTROL_QML" "$LOCK_QML" "$root/shell.qml"; do
    [ -f "$f" ] || { echo "FATAL: this tree has no ${f#"$root/"}" >&2; exit 2; }
done

# The qml runtime for the control, spelled the way each distribution spells it.
QMLRUN=""
for c in qml-qt6 qml /usr/lib64/qt6/bin/qml /usr/lib/qt6/bin/qml; do
    command -v "$c" >/dev/null 2>&1 && { QMLRUN="$c"; break; }
done

# Missing pieces are a SKIP with a name. at-spi is asked for first, because
# without it nothing below is a measurement of anything.
if ! atspi_require; then
    echo "SKIP: no accessibility stack, so nothing here was measured."
    totals
    exit 0
fi

control_pid=""
app_pid=""
cleanup() {
    [ -n "$control_pid" ] && kill "$control_pid" 2>/dev/null
    [ -n "$app_pid" ]     && kill "$app_pid"     2>/dev/null
    sleep 0.3
    [ -n "$control_pid" ] && kill -9 "$control_pid" 2>/dev/null
    [ -n "$app_pid" ]     && kill -9 "$app_pid"     2>/dev/null
    atspi_cleanup
    headless_cleanup
    return 0
}
trap cleanup EXIT INT TERM

headless_begin

# ── the recording stubs ──────────────────────────────────────────────────────
#
# rm -f FIRST, and it is load-bearing: headless_begin makes $HEADLESS_W/bin/
# loginctl a SYMLINK to the shared `_stub` script, so `cat > …/loginctl` writes
# THROUGH the link and turns every other stub in the sandbox — apex, hyprctl,
# wlr-randr, systemctl — into a loginctl recorder.
#
# busctl is added rather than replaced: headless_begin does not stub it at all,
# so without this the shell's PowerProfileService would talk to the real system
# bus, and a LockedHintService that got past step 1 would call SetLockedHint on
# the live session. The stub exits 1, so it can never fall through to the real
# tool, and the run can say afterwards exactly what was asked of it.
export APEX_LOCKHINT_CALLS="$HEADLESS_W/logind-calls.log"
: > "$APEX_LOCKHINT_CALLS"
rm -f "$HEADLESS_W/bin/loginctl" "$HEADLESS_W/bin/busctl"
cat > "$HEADLESS_W/bin/loginctl" <<'FAKE'
#!/usr/bin/env bash
printf 'loginctl %s\n' "$*" >> "$APEX_LOCKHINT_CALLS"
# Exit 0 with nothing on stdout: what a user with no graphical session looks
# like. LockedHintService must read that as "no session", not as a session id.
exit 0
FAKE
cat > "$HEADLESS_W/bin/busctl" <<'FAKE'
#!/usr/bin/env bash
printf 'busctl %s\n' "$*" >> "$APEX_LOCKHINT_CALLS"
# Never succeeds and never reaches the real busctl. If this line is ever
# exercised with SetLockedHint the suite fails on the recording, not on the
# effect — by which point there would not have been one.
exit 1
FAKE
chmod +x "$HEADLESS_W/bin/loginctl" "$HEADLESS_W/bin/busctl"

if ! headless_start; then
    echo "SKIP: no compositor, so nothing here was measured."
    totals
    exit 0
fi

# The socket, remembered before atspi_start moves XDG_RUNTIME_DIR out from under
# it. Everything after atspi_start runs with the compositor's runtime directory
# put back, so the Wayland socket resolves by name and quickshell's own IPC
# socket lands beside it; the two buses are reached by the absolute addresses
# atspi_start exports, which do not depend on XDG_RUNTIME_DIR at all.
COMP_RUNTIME="$XDG_RUNTIME_DIR"
COMP_SOCKET="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"

if ! atspi_start; then
    echo "SKIP: the private accessibility bus did not come up, so nothing here"
    echo "      was measured. This is a COULD-NOT-RUN, not a pass."
    totals
    exit 0
fi
export XDG_RUNTIME_DIR="$COMP_RUNTIME"

section "the harness is private, and that is checked rather than intended"

if [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] &&
   [ "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" -ef "$COMP_SOCKET" ]; then
    ok "the compositor socket survived the bus setup and is still this run's own"
else
    bad "the compositor socket survived the bus setup and is still this run's own" \
        "WAYLAND_DISPLAY no longer names the socket headless_start brought up"
fi

case "$AT_SPI_BUS_ADDRESS" in
    *"unix:path=$ATSPI_RUNTIME/"*)
        ok "the accessibility bus is inside a directory this run created" ;;
    *)  bad "the accessibility bus is inside a directory this run created" \
            "got $AT_SPI_BUS_ADDRESS" ;;
esac

case "$ATSPI_STATUS" in
    *"'ScreenReaderEnabled': <true>"*)
        ok "org.a11y.Status.ScreenReaderEnabled is true, as a screen reader sets it" ;;
    *)  bad "org.a11y.Status.ScreenReaderEnabled is true, as a screen reader sets it" \
            "got ${ATSPI_STATUS:-<no answer>}; Qt's bridge publishes nothing with this false" ;;
esac

echo "  note: host $HEADLESS_COMP on $WAYLAND_DISPLAY at $HEADLESS_MODE"

# ─────────────────────────────────────────────────────────────────────────────
section "§1 the control — this harness can read a tree, proven in this run"
# ─────────────────────────────────────────────────────────────────────────────
#
# Everything below §1 is a negative result about the shell. A negative result
# from an instrument nobody checked is worthless, so the instrument is checked
# here, against a plain Qt Quick Window on the same compositor and the same bus.

control_ok=0
if [ -z "$QMLRUN" ]; then
    nope "the control publishes an accessibility tree" \
         "no qml runtime (qt6-declarative); the negatives below are UNCONTROLLED"
else
    before="$(python3 "$WALK" --count 2>/dev/null || echo 0)"
    if [ "$before" = "0" ]; then
        ok "nothing is registered with the private registry before anything starts"
    else
        bad "nothing is registered with the private registry before anything starts" \
            "$before application(s) already present — this bus is not this run's alone"
    fi

    # atspi_run_app, not a bare exec: the application must DISCOVER the bus
    # through org.a11y.Bus on the session bus, exactly as a real one does,
    # rather than being handed the address in AT_SPI_BUS_ADDRESS.
    atspi_run_app "$QMLRUN" -platform wayland "$CONTROL_QML" \
        >"$HEADLESS_W/control.out" 2>&1 &
    control_pid=$!

    for _ in $(seq 1 80); do
        [ "$(python3 "$WALK" --count 2>/dev/null || echo 0)" != "0" ] && break
        sleep 0.25
    done
    python3 "$WALK" --dump >"$HEADLESS_W/control-tree.txt" 2>/dev/null

    if [ -s "$HEADLESS_W/control-tree.txt" ]; then
        ok "the control registers with the accessibility registry"
    else
        bad "the control registers with the accessibility registry" \
            "the registry lists no application at all"
        sed 's/^/      /' "$HEADLESS_W/control.out" 2>/dev/null | tail -5
    fi

    if grep -q '| role=frame |' "$HEADLESS_W/control-tree.txt"; then
        ok "the control's WINDOW reaches the bus as a frame"
    else
        bad "the control's WINDOW reaches the bus as a frame" \
            "no frame node; this harness cannot see windows at all, so §4 proves nothing"
    fi

    if grep -qF '| name=apex-atspi-control-label |' "$HEADLESS_W/control-tree.txt"; then
        ok "an Accessible.name written in QML arrives on the bus verbatim"
        control_ok=1
    else
        bad "an Accessible.name written in QML arrives on the bus verbatim" \
            "no node named apex-atspi-control-label"
        sed 's/^/      /' "$HEADLESS_W/control-tree.txt" | head -10
    fi

    kill "$control_pid" 2>/dev/null
    for _ in $(seq 1 40); do
        [ "$(python3 "$WALK" --count 2>/dev/null || echo 0)" = "0" ] && break
        sleep 0.25
    done
    control_pid=""
fi

# ─────────────────────────────────────────────────────────────────────────────
section "§2 the logind guard, measured BEFORE anything is locked"
# ─────────────────────────────────────────────────────────────────────────────

if ! command -v quickshell >/dev/null 2>&1; then
    nope "the shell half of this suite" "quickshell is not installed"
    echo
    echo "  Everything from §2 down needs the shipped shell running. The control"
    echo "  in §1 still measured the harness; nothing measured the lock screen."
    totals
    exit 0
fi

shell_log="$HEADLESS_W/shell.log"
# QT_LOGGING_RULES: quickshell prints QML console output at DEBUG, and
# LockedHintService's refusal is a console.warn. Without this the assertion
# below would be reading a log the warning never reached.
QT_LOGGING_RULES="qml=true" atspi_run_app quickshell -p "$root/shell.qml" \
    >"$shell_log" 2>&1 &
app_pid=$!

for _ in $(seq 1 120); do
    grep -q "Configuration Loaded" "$shell_log" && break
    sleep 0.25
done
if ! grep -q "Configuration Loaded" "$shell_log"; then
    bad "the shipped shell loads on the private compositor" "it never loaded"
    tail -20 "$shell_log"
    totals
    exit 1
fi
ok "the shipped shell loads on the private compositor"

# Lockscreen.qml's Component.onCompleted pushes the initial hint, so the whole
# LockedHintService chain has already been exercised by the time the shell
# reports itself loaded. Give the process substitution a bounded moment anyway:
# it is three chained QProcesses.
for _ in $(seq 1 40); do
    grep -q 'loginctl show-user' "$APEX_LOCKHINT_CALLS" && break
    sleep 0.25
done

if grep -q 'loginctl show-user .* -p Display --value' "$APEX_LOCKHINT_CALLS"; then
    ok "LockedHintService really does reach for loginctl at startup"
else
    bad "LockedHintService really does reach for loginctl at startup" \
        "nothing in the call log; the guard below would be vacuous"
    sed 's/^/      /' "$APEX_LOCKHINT_CALLS"
fi

# The refusal itself. Named rather than inferred: the service logs exactly this
# when step 1 hands it no session id, and that is the step that stops the chain
# before anything reaches the system bus.
#
# Waited for, not read once. The recorder above sees loginctl the moment it is
# EXECED; the warning is written when the QProcess reports it exited and the
# log is flushed, which is later by an unbounded-but-small amount. Reading the
# log straight after the call log made this assertion fail about half the time
# on a machine where the chain had behaved perfectly.
for _ in $(seq 1 40); do
    grep -q 'LockedHintService: loginctl show-user failed' "$shell_log" && break
    sleep 0.25
done
if grep -q 'LockedHintService: loginctl show-user failed' "$shell_log"; then
    ok "the chain stops at step 1 — a private runtime dir yields no Display session"
else
    bad "the chain stops at step 1 — a private runtime dir yields no Display session" \
        "the shell never logged the refusal, so the chain went further than this suite believes"
fi

# The one that would matter most if it were false.
if grep -q 'SetLockedHint' "$APEX_LOCKHINT_CALLS"; then
    bad "nothing ever asks logind to set a locked hint" \
        "SetLockedHint was invoked — on a real machine that reaches the live session"
    grep 'SetLockedHint' "$APEX_LOCKHINT_CALLS" | sed 's/^/      /'
else
    ok "nothing ever asks logind to set a locked hint"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "§3 the lock engages for real, on this run's own compositor"
# ─────────────────────────────────────────────────────────────────────────────

hint_calls_before="$(grep -c 'loginctl show-user' "$APEX_LOCKHINT_CALLS" 2>/dev/null || echo 0)"

# The shipped IPC entry point (src/state/IpcManager.qml), which is what
# PowerControl.sh, hypridle's lock_cmd and `loginctl lock-session` all use.
if quickshell -p "$root/shell.qml" ipc call lockscreen lock >/dev/null 2>&1; then
    ok "the shipped 'lockscreen lock' IPC handler accepts the call"
else
    bad "the shipped 'lockscreen lock' IPC handler accepts the call" \
        "the IPC call failed; nothing below locked anything"
fi

# Proof the compositor ACKNOWLEDGED the lock, not merely that the flag was set.
#
# Lockscreen.qml binds onSecureStateChanged to LockedHintService.setLocked, and
# `secure` only flips once ext-session-lock has actually engaged. The service
# then starts its chain again, which the loginctl recorder sees. So a second
# `show-user` in the log is the compositor's acknowledgement, observed from
# outside the process. No second call means labwc never took the lock, and §4
# would be reading an unlocked shell.
lock_engaged=0
for _ in $(seq 1 60); do
    now="$(grep -c 'loginctl show-user' "$APEX_LOCKHINT_CALLS" 2>/dev/null || echo 0)"
    [ "$now" -gt "$hint_calls_before" ] && { lock_engaged=1; break; }
    sleep 0.25
done
if [ "$lock_engaged" = "1" ]; then
    ok "$HEADLESS_COMP acknowledged ext-session-lock — WlSessionLock.secure flipped"
else
    bad "$HEADLESS_COMP acknowledged ext-session-lock — WlSessionLock.secure flipped" \
        "no second LockedHintService chain; the lock surface was never instantiated"
fi

# And the guard again, now that a lock really did engage. Step 1 failing before
# the lock does not prove it fails after one.
if grep -q 'SetLockedHint' "$APEX_LOCKHINT_CALLS"; then
    bad "an ENGAGED lock still asks logind for nothing" \
        "SetLockedHint was invoked after the lock engaged"
else
    ok "an ENGAGED lock still asks logind for nothing"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "§4 what a screen reader is told about the LOCKED surface"
# ─────────────────────────────────────────────────────────────────────────────

# Settle: the surface is created, mapped and rendered asynchronously, and Qt
# publishes accessibility changes as they happen. Two seconds is not a
# measurement, it is a floor; the assertions below are the measurement.
sleep 2
python3 "$WALK" --dump >"$HEADLESS_W/locked-tree.txt" 2>/dev/null
python3 "$WALK" --json >"$HEADLESS_W/locked-tree.json" 2>/dev/null
nodes="$(grep -c . "$HEADLESS_W/locked-tree.txt" 2>/dev/null || echo 0)"

if grep -q '| role=application | name=quickshell |' "$HEADLESS_W/locked-tree.txt"; then
    ok "the locked shell IS on the accessibility bus (the bridge is loaded and reachable)"
else
    bad "the locked shell IS on the accessibility bus (the bridge is loaded and reachable)" \
        "no application node named quickshell; this is not the 'empty tree' case, it is worse"
    sed 's/^/      /' "$HEADLESS_W/locked-tree.txt" | head -10
fi

echo "  note: the shell's whole published tree, $nodes node(s):"
sed 's/^/        /' "$HEADLESS_W/locked-tree.txt"

# ── The pin ─────────────────────────────────────────────────────────────────
#
# An EQUALITY, not a tolerance. The measured fact today is that the shell
# publishes exactly one node — the application — and nothing beneath it. That is
# a defect, and it is pinned here so the day it is fixed this suite goes RED and
# says what to do, instead of staying green through the fix and leaving the
# read-back assertions below permanently skipped. tests/test-apex-greet-atspi.sh
# in apex-os pins Qt's missing AT-SPI password role the same way and for the
# same reason.
if [ "$nodes" = "1" ]; then
    ok "PINNED: the shell publishes ONE node, itself — no window ever reaches the tree"
    echo "        This is the defect, recorded as the current truth. quickshell's"
    echo "        windows are top-level and are not Popups, and Qt's"
    echo "        QQuickWindow::accessibleRoot() returns null for them, so"
    echo "        QAccessibleApplication::childCount() is 0. Every Accessible.*"
    echo "        binding in this repository is unreachable at runtime."
elif [ "$nodes" -gt 1 ]; then
    bad "PINNED: the shell publishes ONE node, itself — no window ever reaches the tree" \
        "$nodes nodes now. THIS IS AN IMPROVEMENT, not a regression: quickshell or Qt has been fixed. Replace this pin and §5's skips with the real read-back assertions."
else
    bad "PINNED: the shell publishes ONE node, itself — no window ever reaches the tree" \
        "$nodes nodes; the shell is not on the bus at all"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "§5 the read-back the roadmap asks for — NOT measured, and why"
# ─────────────────────────────────────────────────────────────────────────────
#
# Each of these is trivially satisfiable by an empty tree, which is the exact
# shape of vacuous pass this unit has been caught by before. They are SKIPs with
# a reason attached, and the reason is printed once here rather than four times.

if [ "$nodes" = "1" ]; then
    why="the tree has no nodes below the application, so this assertion would pass vacuously"
    nope "the password field reaches the bus at all"                 "$why"
    nope "Accessible.passwordEdit reaches the tree (Qt suppresses the field's NAME for it, which is how it is observable)" "$why"
    nope "the field's live description reaches the bus"              "$why"
    nope "the status line's live Accessible.name reaches the bus"    "$why"
    nope "neither private-use icon reaches the bus as a named node"  "$why"
    nope "Accessible.announce() produces an AT-SPI announcement"     "$why, and with WLR_LIBINPUT_NO_DEVICES=1 nothing can type, so neither fail() nor the Caps Lock transition can be triggered to emit one"
else
    nope "the read-back assertions" \
        "the tree is no longer empty; write them, and delete this branch"
fi

# ── Two things this suite deliberately does not claim ───────────────────────
#
#  * It does not claim the markup in Lockscreen.qml is wrong. It is right, and
#    tests/check-lockscreen-a11y.sh proves it against the source. It claims the
#    markup has nowhere to go.
#  * It does not claim a screen reader gets NOTHING from APEX. The greeter is a
#    separate process running the stock qml runtime, and apex-os's
#    tests/test-apex-greet-atspi.sh reads its tree back successfully. The login
#    screen is accessible; the desktop and the lock screen are not.

totals
[ "$fail" -eq 0 ] || exit 1
exit 0
