#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-lockscreen-atspi-shim.sh — read the LOCK SCREEN's accessibility markup
#  back over real AT-SPI, with Qt's accessibility factory put back.
#
#  ── Why this suite exists, and why it is separate ───────────────────────────
#
#  tests/run-lockscreen-atspi.sh measures the DEFECT and pins it: the running
#  shell publishes exactly ONE node to the accessibility bus, its own
#  application node, so its §5 read-back assertions are recorded as SKIPs — an
#  empty tree satisfies every one of them vacuously, and a vacuous pass is the
#  failure mode this unit has been caught by before.
#
#  tests/check-quickshell-a11y-cause.sh names WHY, in a program with no
#  compositor and no bus: ~QCoreApplication runs a post routine that CLEARS
#  Qt's accessibility factory list, qtdeclarative installs its factory from a
#  Q_CONSTRUCTOR_FUNCTION that can only run once per library load, and
#  quickshell destroys a QCoreApplication immediately before constructing its
#  QGuiApplication.
#
#  This suite is the third thing, and it is the one the roadmap actually asked
#  for: with tests/quickshell-a11y-shim.cpp restoring that factory inside the
#  running process, the shipped markup DOES reach the bus, and the assertions
#  §5 could only skip become assertions that can fail. It is a separate file
#  rather than a §6 because it answers a different question — "is the markup
#  right" instead of "can the markup be seen" — and because the pin in the
#  other suite must keep measuring the unmodified shell.
#
#  ── The control is INSIDE the run, and that is the whole design ─────────────
#
#  §4 reads the tree back BEFORE the shim installs anything and requires
#  exactly one node: the defect, re-measured in this very run, on this very
#  compositor, with these very buses. §6's tree is therefore attributable to
#  the factory install and to nothing else — not to a bus that came up late,
#  not to a lock that engaged this time, not to a machine that behaves
#  differently. The shim waits for a FILE rather than a delay so that the
#  order of those two reads can never be a race.
#
#  ── What it does NOT claim ─────────────────────────────────────────────────
#
#  Not that the shell is accessible. It is not: nothing here is shipped, the
#  factory is put back by an LD_PRELOAD that exists only in this test tree, and
#  on a real machine a screen reader still gets one node. What it claims is
#  that the markup in src/windows/Lockscreen.qml is correct all the way to the
#  bus, so the whole remaining defect is the upstream one — and that when
#  upstream is fixed there is nothing else to write.
#
#  Read the totals line, never the tick: this suite exits 0 on a skip.
#
#  Run from anywhere: ./tests/run-lockscreen-atspi-shim.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

pass=0; fail=0; skip=0
ok()   { echo "  ok   $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL $1${2:+  — $2}"; fail=$((fail + 1)); }
nope() { echo "  SKIP $1${2:+  — $2}"; skip=$((skip + 1)); }
section() { printf '\n── %s ──\n' "$1"; }
totals() {
    printf '\nlockscreen-atspi-shim: passed=%d failed=%d skipped=%d\n' "$pass" "$fail" "$skip"
}

# shellcheck source=tests/lib/headless.sh
. "$here/lib/headless.sh"
# shellcheck source=tests/lib/atspi.sh
. "$here/lib/atspi.sh"

WALK="$here/atspi-walk.py"
SHIM_SRC="$here/quickshell-a11y-shim.cpp"
LOCK_QML="$root/src/windows/Lockscreen.qml"
for f in "$WALK" "$SHIM_SRC" "$LOCK_QML" "$root/shell.qml"; do
    [ -f "$f" ] || { echo "FATAL: this tree has no ${f#"$root/"}" >&2; exit 2; }
done

# The exact description Lockscreen.qml binds when the field is idle — not
# checking, no error, no Caps Lock. Spelled here so a change to either side is
# a visible disagreement rather than a silently weakened assertion.
IDLE_DESC="Type your password and press Enter to unlock."

# ─────────────────────────────────────────────────────────────────────────────
section "§1 what it takes to run at all — each missing piece named separately"
# ─────────────────────────────────────────────────────────────────────────────

if ! atspi_require; then
    echo "SKIP: no accessibility stack, so nothing here was measured."
    nope "the whole suite" "at-spi is not available"
    totals; exit 0
fi
if ! command -v quickshell >/dev/null 2>&1; then
    echo "SKIP: no quickshell, so nothing here was measured."
    nope "the whole suite" "quickshell is not installed (it is an AUR package on Arch)"
    totals; exit 0
fi

CXX=""
for c in g++ c++ clang++; do command -v "$c" >/dev/null 2>&1 && { CXX="$c"; break; }; done
if [ -z "$CXX" ]; then
    echo "SKIP: no C++ compiler, so the instrument cannot be built."
    nope "the whole suite" "no g++/c++/clang++ on PATH"
    totals; exit 0
fi
if ! command -v pkg-config >/dev/null 2>&1 || ! pkg-config --exists Qt6Quick Qt6Gui Qt6Core; then
    echo "SKIP: no Qt 6 Quick development files, so the instrument cannot be built."
    nope "the whole suite" "pkg-config cannot find Qt6Quick/Qt6Gui/Qt6Core"
    totals; exit 0
fi

# Qt's PRIVATE headers, which the shim needs because QAccessibleQuickWindow and
# friends are not public API. Discovered, never hardcoded: the version
# directory is part of the path and differs on every Qt release, and a
# hardcoded one would report "Qt is missing" on a machine that has it.
INCDIR="$(pkg-config --variable=includedir Qt6Core 2>/dev/null)"
PRIV_INC=()
PRIV_PROBE=""
if [ -n "$INCDIR" ]; then
    for mod in QtCore QtGui QtQml QtQuick; do
        d="$(ls -d "$INCDIR/$mod"/*/"$mod" 2>/dev/null | head -1)"
        [ -n "$d" ] && PRIV_INC+=(-I"${d%/"$mod"}" -I"$d")
    done
    PRIV_PROBE="$(ls "$INCDIR"/QtQuick/*/QtQuick/private/qaccessiblequickview_p.h 2>/dev/null | head -1)"
fi
if [ -z "$PRIV_PROBE" ]; then
    echo "SKIP: Qt 6 PRIVATE headers are not installed, so the instrument cannot"
    echo "      be built. On Fedora that is qt6-qtbase-private-devel plus"
    echo "      qt6-qtdeclarative-devel; the path looked for was"
    echo "      ${INCDIR:-<no includedir>}/QtQuick/<version>/QtQuick/private/qaccessiblequickview_p.h"
    nope "the whole suite" "no qaccessiblequickview_p.h under ${INCDIR:-<no includedir>}"
    totals; exit 0
fi
echo "  note: Qt $(pkg-config --modversion Qt6Core), $CXX, private headers at ${PRIV_PROBE%/qaccessiblequickview_p.h}"

# ─────────────────────────────────────────────────────────────────────────────
section "§2 the instrument builds, and it really does interpose"
# ─────────────────────────────────────────────────────────────────────────────

W="$(mktemp -d "${TMPDIR:-/tmp}/lockscreen-atspi-shim.XXXXXX")" || exit 2
SHIM="$W/shim.so"
TRIGGER="$W/install-now"

# A build failure HERE is a failure, not a skip: every prerequisite above was
# found, so the only remaining explanations are a broken instrument or a Qt
# whose private API moved — and both of those are things this suite should say.
# shellcheck disable=SC2046,SC2086
if ! $CXX -std=c++17 -fPIC -shared -o "$SHIM" "$SHIM_SRC" \
        $(pkg-config --cflags Qt6Quick Qt6Gui Qt6Core) "${PRIV_INC[@]}" \
        $(pkg-config --libs Qt6Quick Qt6Gui Qt6Core) -ldl >"$W/build.log" 2>&1; then
    bad "tests/quickshell-a11y-shim.cpp builds against this machine's Qt 6" \
        "every prerequisite was present, so this is the instrument or Qt's private API"
    sed 's/^/      /' "$W/build.log" | head -25
    totals; exit 1
fi
ok "tests/quickshell-a11y-shim.cpp builds against this machine's Qt 6"

# The symbol it takes over must actually be the one quickshell calls. If
# quickshell ever stops going through the PLT for it — a static build, an
# inlined call, a different entry point — the preload silently does nothing and
# every assertion below would read as "the markup is unreachable after all".
QS_BIN="$(command -v quickshell)"
# Captured into a variable and matched with a bash substring test, NOT
# `nm | grep -q`. Under `set -o pipefail` a grep -q that MATCHES closes the
# pipe, nm dies with SIGPIPE, and the pipeline's status is 141 — so the
# assertion fails precisely when it should pass. That is not hypothetical: it
# is how this very line was first written, and it went red on a machine where
# the symbol was plainly there.
QS_DYNSYMS="$(nm -D "$QS_BIN" 2>/dev/null || true)"
if [ -z "$QS_DYNSYMS" ]; then
    nope "quickshell calls QGuiApplication::exec() through the PLT" \
         "nm read no dynamic symbols from $QS_BIN, so this could not be checked"
elif [[ "$QS_DYNSYMS" == *"U _ZN15QGuiApplication4execEv"* ]]; then
    ok "quickshell calls QGuiApplication::exec() through the PLT, so LD_PRELOAD can take it"
else
    bad "quickshell calls QGuiApplication::exec() through the PLT, so LD_PRELOAD can take it" \
        "the symbol is not UNDEFINED in $QS_BIN; the preload cannot hook and nothing below would measure the shell"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "§3 a private compositor and two private buses"
# ─────────────────────────────────────────────────────────────────────────────

app_pid=""
cleanup() {
    [ -n "$app_pid" ] && kill "$app_pid" 2>/dev/null
    sleep 0.3
    [ -n "$app_pid" ] && kill -9 "$app_pid" 2>/dev/null
    atspi_cleanup
    headless_cleanup
    rm -rf "$W"
    return 0
}
trap cleanup EXIT INT TERM

headless_begin

# The recording stubs, for the reasons tests/run-lockscreen-atspi.sh gives at
# length: rm -f FIRST because headless_begin makes bin/loginctl a SYMLINK to a
# shared stub and writing through it turns every other stub into a loginctl
# recorder, and busctl at all because headless_begin does not stub it, so the
# shell's PowerProfileService would otherwise reach the real system bus.
export APEX_LOCKHINT_CALLS="$HEADLESS_W/logind-calls.log"
: > "$APEX_LOCKHINT_CALLS"
rm -f "$HEADLESS_W/bin/loginctl" "$HEADLESS_W/bin/busctl"
cat > "$HEADLESS_W/bin/loginctl" <<'FAKE'
#!/usr/bin/env bash
printf 'loginctl %s\n' "$*" >> "$APEX_LOCKHINT_CALLS"
exit 0
FAKE
cat > "$HEADLESS_W/bin/busctl" <<'FAKE'
#!/usr/bin/env bash
printf 'busctl %s\n' "$*" >> "$APEX_LOCKHINT_CALLS"
exit 1
FAKE
chmod +x "$HEADLESS_W/bin/loginctl" "$HEADLESS_W/bin/busctl"

if ! headless_start; then
    echo "SKIP: no compositor, so nothing here was measured."
    nope "everything below §3" "no nested compositor"
    totals; exit 0
fi
COMP_RUNTIME="$XDG_RUNTIME_DIR"
COMP_SOCKET="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
if ! atspi_start; then
    echo "SKIP: the private accessibility bus did not come up."
    nope "everything below §3" "no private a11y bus; this is a could-not-run, not a pass"
    totals; exit 0
fi
export XDG_RUNTIME_DIR="$COMP_RUNTIME"

if [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] &&
   [ "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" -ef "$COMP_SOCKET" ]; then
    ok "the compositor socket survived the bus setup and is still this run's own"
else
    bad "the compositor socket survived the bus setup and is still this run's own" \
        "WAYLAND_DISPLAY no longer names the socket headless_start brought up"
fi

case "$ATSPI_STATUS" in
    *"'ScreenReaderEnabled': <true>"*)
        ok "org.a11y.Status.ScreenReaderEnabled is true, as a screen reader sets it" ;;
    *)  bad "org.a11y.Status.ScreenReaderEnabled is true, as a screen reader sets it" \
            "got ${ATSPI_STATUS:-<no answer>}; Qt's bridge publishes nothing with this false" ;;
esac
echo "  note: host $HEADLESS_COMP on $WAYLAND_DISPLAY at $HEADLESS_MODE"

# ─────────────────────────────────────────────────────────────────────────────
section "§4 the shell, the lock, and THE CONTROL — the defect, re-measured here"
# ─────────────────────────────────────────────────────────────────────────────

shell_log="$W/shell.log"
QT_LOGGING_RULES="qml=true" atspi_run_app env \
    LD_PRELOAD="$SHIM" APEX_SHIM_TRIGGER="$TRIGGER" \
    quickshell -p "$root/shell.qml" >"$shell_log" 2>&1 &
app_pid=$!

for _ in $(seq 1 160); do grep -q "Configuration Loaded" "$shell_log" && break; sleep 0.25; done
if ! grep -q "Configuration Loaded" "$shell_log"; then
    bad "the shipped shell loads on the private compositor, under the preload" "it never loaded"
    tail -20 "$shell_log"
    totals; exit 1
fi
ok "the shipped shell loads on the private compositor, under the preload"

if grep -q 'APEXSHIM: interposed QGuiApplication::exec()' "$shell_log"; then
    ok "the preload really took QGuiApplication::exec() in THIS process"
else
    bad "the preload really took QGuiApplication::exec() in THIS process" \
        "the shim never announced itself; everything below would be about an unmodified shell"
fi

# ── wait for the STARTUP hint chain to finish before asking for a lock ──────
#
# Load-bearing, and it cost four runs to find out. LockedHintService._pump()
# returns immediately when _busy is true, and its _failed() path clears _busy
# but DELIBERATELY does not re-pump (see the comment in
# src/services/system/LockedHintService.qml). _succeeded() does. So a
# setLocked(true) that arrives while a FAILING chain is still in flight updates
# _desired and is then never acted on: the lock engages, the surface comes up,
# and logind is never told. Lockscreen.qml's Component.onCompleted starts
# exactly such a chain at startup, and on this private runtime directory it
# always fails at step 1.
#
# Measured here before this wait existed: the lock-acknowledged assertion went
# red on 2 runs in 9 while the lock had in fact engaged — §6 read the whole
# lock surface back in those same runs. tests/run-lockscreen-atspi.sh does not
# see it because its §2 waits for that warning as an assertion of its own, and
# so closes the race by accident. This closes it on purpose.
for _ in $(seq 1 80); do
    grep -q 'LockedHintService: loginctl show-user failed' "$shell_log" && break
    sleep 0.25
done
if grep -q 'LockedHintService: loginctl show-user failed' "$shell_log"; then
    ok "the startup hint chain has finished, so the lock's own chain cannot be swallowed"
else
    bad "the startup hint chain has finished, so the lock's own chain cannot be swallowed" \
        "no refusal logged in 20s; the lock assertion below may be racing an in-flight chain"
fi

hint_before="$(grep -c 'loginctl show-user' "$APEX_LOCKHINT_CALLS" 2>/dev/null || echo 0)"
if quickshell -p "$root/shell.qml" ipc call lockscreen lock >/dev/null 2>&1; then
    ok "the shipped 'lockscreen lock' IPC handler accepts the call"
else
    bad "the shipped 'lockscreen lock' IPC handler accepts the call" \
        "the IPC call failed; nothing below locked anything"
fi

# 160 quarter-seconds, not the 60 tests/run-lockscreen-atspi.sh uses. Measured,
# not padded: at 60 this assertion failed on 1 run in 5 here while the lock had
# in fact engaged — §6 read the lock surface back perfectly in the same run. The
# preload adds a process to the startup path and the `ipc call` spawns a second
# quickshell client, and 15s is simply not the ceiling on a loaded machine. A
# flaky assertion is worse than no assertion: it teaches everyone to re-run.
lock_engaged=0
for _ in $(seq 1 160); do
    now="$(grep -c 'loginctl show-user' "$APEX_LOCKHINT_CALLS" 2>/dev/null || echo 0)"
    [ "$now" -gt "$hint_before" ] && { lock_engaged=1; break; }
    sleep 0.25
done
if [ "$lock_engaged" = "1" ]; then
    ok "$HEADLESS_COMP acknowledged ext-session-lock — WlSessionLock.secure flipped"
else
    bad "$HEADLESS_COMP acknowledged ext-session-lock — WlSessionLock.secure flipped" \
        "no second LockedHintService chain; the lock surface was never instantiated"
fi

# ── the control ─────────────────────────────────────────────────────────────
sleep 2
python3 "$WALK" --dump >"$W/tree-before.txt" 2>/dev/null
before_nodes="$(grep -c . "$W/tree-before.txt" 2>/dev/null || echo 0)"
if [ "$before_nodes" = "1" ]; then
    ok "CONTROL: with the factory still cleared, the LOCKED shell publishes ONE node"
else
    bad "CONTROL: with the factory still cleared, the LOCKED shell publishes ONE node" \
        "$before_nodes nodes. If it is MORE, upstream has been fixed and this whole instrument is obsolete — delete it and write the read-back straight. If it is ZERO, the shell is not on the bus at all and §6 measures nothing."
    sed 's/^/      /' "$W/tree-before.txt" | head -10
fi

# ─────────────────────────────────────────────────────────────────────────────
section "§5 the factory goes back, and the roots change in-process"
# ─────────────────────────────────────────────────────────────────────────────

: > "$TRIGGER"
for _ in $(seq 1 120); do grep -q 'APEXSHIM: DONE' "$shell_log" && break; sleep 0.25; done
if ! grep -q 'APEXSHIM: DONE' "$shell_log"; then
    bad "the shim installs the factory when asked" "it never finished; the trigger file was $TRIGGER"
    grep '^APEXSHIM' "$shell_log" | sed 's/^/      /'
    totals; exit 1
fi
ok "the shim installs the factory when asked"

shim_before_null="$(grep -c '^APEXSHIM before: window.*root=NULL' "$shell_log" || true)"
shim_before_nonnull="$(grep -c '^APEXSHIM before: window.*root=NON-NULL' "$shell_log" || true)"
shim_after_null="$(grep -c '^APEXSHIM after: window.*root=NULL' "$shell_log" || true)"
shim_after_nonnull="$(grep -c '^APEXSHIM after: window.*root=NON-NULL' "$shell_log" || true)"

if [ "$shim_before_null" -gt 0 ] && [ "$shim_before_nonnull" -eq 0 ]; then
    ok "IN-PROCESS: before the install, accessibleRoot() is null for ALL $shim_before_null top-level windows"
else
    bad "IN-PROCESS: before the install, accessibleRoot() is null for ALL top-level windows" \
        "$shim_before_null null and $shim_before_nonnull non-null; this is the direct read of the cleared factory list and it disagrees with FOUND 20"
fi

if [ "$shim_after_nonnull" -gt 0 ] && [ "$shim_after_null" -eq 0 ]; then
    ok "IN-PROCESS: after it, accessibleRoot() is non-null for ALL $shim_after_nonnull of them"
else
    bad "IN-PROCESS: after it, accessibleRoot() is non-null for ALL of them" \
        "$shim_after_nonnull non-null and $shim_after_null still null"
fi

if grep -q '^APEXSHIM before: appChildCount=0' "$shell_log"; then
    ok "IN-PROCESS: and QAccessibleApplication::childCount() was 0 before — the bus symptom, from inside"
else
    bad "IN-PROCESS: and QAccessibleApplication::childCount() was 0 before — the bus symptom, from inside" \
        "got $(grep -m1 '^APEXSHIM before: appChildCount=' "$shell_log" || echo '<nothing>')"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "§6 the read-back the roadmap asked for, now that it can fail"
# ─────────────────────────────────────────────────────────────────────────────

sleep 3
python3 "$WALK" --dump >"$W/tree-after.txt" 2>/dev/null
after_nodes="$(grep -c . "$W/tree-after.txt" 2>/dev/null || echo 0)"
echo "  note: $before_nodes node(s) before the install, $after_nodes after:"
sed 's/^/        /' "$W/tree-after.txt"

if [ "$after_nodes" -gt "$before_nodes" ]; then
    ok "restoring the factory alone makes the shell publish a tree ($before_nodes → $after_nodes nodes)"
else
    bad "restoring the factory alone makes the shell publish a tree" \
        "$before_nodes → $after_nodes; the factory is not the whole cause and FOUND 20 is incomplete"
fi

# The lock surface. A frame with `showing` and `visible`: FOUND 16 — an UNMAPPED
# Qt Quick window publishes its whole subtree too, with `enabled,sensitive` and
# neither of those two states, so the states are the only discriminator between
# "a window is on screen" and "a window object exists".
lock_frame="$(grep -E '^  [0-9]+ \| role=frame .*states=[^|]*showing[^|]*visible' "$W/tree-after.txt" | tail -1)"
if [ -n "$lock_frame" ]; then
    ok "a MAPPED frame reaches the bus — states=showing,visible, not merely an existing window object"
else
    bad "a MAPPED frame reaches the bus — states=showing,visible, not merely an existing window object" \
        "no top-level frame carries both showing and visible"
fi

field="$(grep -E '^ +[0-9]+ \| role=text \|' "$W/tree-after.txt" | head -1)"
if [ -n "$field" ]; then
    ok "the password field reaches the bus at all"
else
    bad "the password field reaches the bus at all" \
        "no node with role=text anywhere in the tree; Accessible.role: Accessible.EditableText should map to it"
fi

# Qt returns an EMPTY name for any item with Accessible.passwordEdit set
# (qquickaccessibleattached_p.h), so the suppression is observable from the bus
# and is the only way to observe it. Lockscreen.qml sets Accessible.name to
# "Password"; a field whose name arrived would mean the flag did not.
if [ -n "$field" ]; then
    case "$field" in
        *"| name= |"*)
            ok "Accessible.passwordEdit reaches the tree — Qt suppresses the field's NAME, which is how it is observable" ;;
        *)  bad "Accessible.passwordEdit reaches the tree — Qt suppresses the field's NAME, which is how it is observable" \
                "the name arrived: ${field}. Lockscreen.qml sets Accessible.name to \"Password\", so a name on the bus means passwordEdit did NOT take." ;;
    esac
else
    nope "Accessible.passwordEdit reaches the tree" "there is no field node to read it off"
fi

if [ -n "$field" ]; then
    case "$field" in
        *"desc=$IDLE_DESC"*)
            ok "the field's live description reaches the bus, verbatim" ;;
        *)  bad "the field's live description reaches the bus, verbatim" \
                "expected desc=$IDLE_DESC; got ${field}" ;;
    esac
else
    nope "the field's live description reaches the bus, verbatim" "there is no field node"
fi

# Reachability, not decoration. A reader that cannot focus the field cannot use
# it, and `editable` is what tells the reader it is a text entry rather than a
# label that happens to have the text role.
if [ -n "$field" ]; then
    miss=""
    for st in editable focusable; do
        case "$field" in *"$st"*) : ;; *) miss="$miss $st" ;; esac
    done
    case "$field" in *"actions=SetFocus"*) : ;; *) miss="$miss SetFocus-action" ;; esac
    if [ -z "$miss" ]; then
        ok "a screen reader can reach the field: editable, focusable, and a SetFocus action"
    else
        bad "a screen reader can reach the field: editable, focusable, and a SetFocus action" \
            "missing:$miss in ${field}"
    fi
else
    nope "a screen reader can reach the field" "there is no field node"
fi

# The status line. Its Accessible.name is the ERROR or the Caps Lock warning and
# is deliberately EMPTY in the idle state this run measures — asserted as that
# equality with its reason, because "it is empty" would also be true of a node
# that never got its binding.
status="$(grep -E '^ +[0-9]+ \| role=label \|' "$W/tree-after.txt" | head -1)"
if [ -n "$status" ]; then
    ok "the status line reaches the bus as a label, so a reader reads it instead of skipping it"
else
    bad "the status line reaches the bus as a label, so a reader reads it instead of skipping it" \
        "no node with role=label; Accessible.role: Accessible.StaticText should map to it"
fi

if [ -n "$status" ]; then
    case "$status" in
        *"| name= |"*)
            ok "and its name is empty in THIS state, which is what Lockscreen.qml binds with no error and no Caps Lock" ;;
        *)  bad "and its name is empty in THIS state, which is what Lockscreen.qml binds with no error and no Caps Lock" \
                "got ${status}; nothing in this run set an error or Caps Lock, so a name here is a binding that does not match the source" ;;
    esac
else
    nope "the status line's name in the idle state" "there is no label node"
fi

# Private-use codepoints, over the WHOLE tree rather than the two nodes above.
# The rule is about the class: a reader that reaches one says "private use
# character" out loud before the words it was supposed to read.
pua="$(python3 - "$W/tree-after.txt" <<'PY'
import re, sys
# BOTH private-use planes AND the BMP one, and written as escapes rather than
# as the characters themselves. The first draft of this line carried the BMP
# bounds as literal characters, they did not survive being written to disk, the
# class silently became "a hyphen plus the two supplementary planes", and a
# mutant that put a BMP private-use glyph into an accessible string SURVIVED.
# An unprintable character in a source file is not reviewable; an escape is.
pua = re.compile('[\ue000-\uf8ff\U000f0000-\U000ffffd\U00100000-\U0010fffd]')
hits = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    for field in ("name=", "desc="):
        i = line.find(field)
        if i < 0:
            continue
        v = line[i + len(field):].split(" | ")[0]
        if pua.search(v):
            hits.append(field + v)
print(len(hits))
for h in hits:
    print("   ", h)
PY
)"
if [ "$(printf '%s\n' "$pua" | head -1)" = "0" ]; then
    ok "neither private-use icon reaches the bus as a named node"
else
    bad "neither private-use icon reaches the bus as a named node" \
        "$(printf '%s\n' "$pua" | head -1) accessible string(s) carry one"
    printf '%s\n' "$pua" | tail -n +2 | sed 's/^/      /'
fi

# The one thing still genuinely unmeasurable, kept a SKIP with its reason.
nope "Accessible.announce() produces an AT-SPI announcement" \
     "with WLR_LIBINPUT_NO_DEVICES=1 nothing can type, so neither fail() nor the Caps Lock transition can be triggered to emit one; this is a could-not-run, not a pass"

echo
echo "  This suite does NOT claim the shell is accessible. The factory was put"
echo "  back by a test-only LD_PRELOAD; on a real machine a screen reader still"
echo "  gets one node. What it claims is that the markup is correct all the way"
echo "  to the bus, so the entire remaining defect is the upstream one."

totals
[ "$fail" -eq 0 ] || exit 1
exit 0
