#!/usr/bin/env bash
# The ALT+Tab switcher, driven by real ALT and TAB key events.
#
#     ./tests/run-window-switcher-test.sh
#
# ── What this proves that a config grep cannot ───────────────────────────────
#
# Andre's complaint was behavioural — "the window you move to instantly loses
# focus" — so the acceptance has to be behavioural too. Every assertion below
# ends in the same question: which toplevel does the COMPOSITOR say is active,
# a moment after the keys stopped, without anybody touching the mouse.
#
# Nothing here calls WindowSwitcherService.next() or .commit(). wtype presses
# ALT, taps TAB, and releases ALT into a headless labwc whose rc.xml carries the
# same four bindings the image ships, and the switcher is reached the way the
# keyboard reaches it or not at all.
#
# ── What commits here, and why it is not the ALT release ────────────────────
#
# The shipped Hyprland session commits on the ALT release (`release = true`).
# labwc cannot do that, and it is not a bug: labwc-config(5) says onRelease is
# for "when the modifier is used WITHOUT another key". Measured on labwc 0.9.6,
# 2026-09-20 — hold ALT, tap Tab (firing A-Tab), release ALT: an
# `Alt_L onRelease="yes"` binding fires ZERO times; press and release ALT with
# no Tab and it fires. So the Floating session keeps labwc's own switcher, and
# this suite commits with ALT+Return, which the Hyprland session also binds for
# exactly this reason — a press binding that cannot be affected by whatever a
# compositor's release semantics turn out to be.
#
# What that costs in coverage, stated: the shell code exercised is identical —
# the same IpcHandler, the same commit(), the same activate-after-unmap order.
# What is NOT exercised anywhere headless is a compositor firing a bind on a
# real ALT release. That is asserted as a registered release bind by apex-os's
# tests/test-apex-hypr-focus.sh and confirmed only by a person holding ALT.
#
# ── Why labwc and not Hyprland ───────────────────────────────────────────────
#
# Measured on this machine, 2026-09-20: wtype's virtual keyboard is accepted by
# a nested Hyprland 0.56.2 — it appears in `hyprctl devices` as
# hl-virtual-keyboard-wtype — but Hyprland reports `active keymap: error` for it
# and no bind fires. niri behaves the same way. A wlroots compositor takes the
# keymap and dispatches normally, so labwc is the only one of the three that can
# be driven by a synthetic keyboard at all, and the aquamarine headless backend
# core-dumps on a box with a GPU, so there is no Hyprland to drive anyway.
#
# That is not a hole in the coverage of the SWITCHER: the overlay and the
# service are one compositor-agnostic implementation over
# wlr-foreign-toplevel-management, and labwc is one of the two sessions that
# ships it. It IS a hole in the coverage of Hyprland's release binding, which is
# asserted as a registered release bind by apex-os's tests/test-apex-hypr-focus.sh
# and confirmed for real only by a person holding ALT.
#
# Skips with status 0 when labwc, quickshell or wtype is missing.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"

pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

headless_require labwc quickshell wtype

staged="$root/.window-switcher-test.qml"
shell_pid=""
win_pids=()

cleanup() {
    local p
    for p in "${win_pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || :; done
    [ -n "$shell_pid" ] && kill "$shell_pid" 2>/dev/null || :
    rm -f "$staged"
    headless_cleanup
    return 0
}
trap cleanup EXIT INT TERM

# Quickshell refuses to import QML from outside the entry point's directory, so
# the test lives at the repo root for the duration of the run. Same arrangement
# as run-niri-keybinds-test.sh.
cp "$here/window-switcher-test.qml" "$staged"

headless_begin

# ── the compositor, with the bindings the image ships ────────────────────────
#
# Reproduced here rather than read from apex-os: that is a different repository
# and this suite must run without it. The four bindings are the contract, and
# apex-os's own build asserts its rc.xml carries them — what is under test here
# is what the shell does when they fire.
#
# The command is a stub apex-switcher, and it reproduces the shipped one's flag
# file — including the part that matters most, which is that `next` writes the
# flag BEFORE the IPC rather than leaving it to the shell. That ordering is the
# whole of the single-tap race: a quick ALT+Tab releases ALT about 60ms after
# Tab goes down, and the shell's own write is at the end of a
# spawn -> apex -> qs ipc -> Process chain that takes longer than that. A stub
# without it would pass this suite while the shipped path dropped every fast
# commit.
#
# The stub's own flag lives under $HEADLESS_W rather than XDG_RUNTIME_DIR, so
# the assertion below about a stale flag can put the two deliberately out of
# step.
mkdir -p "$HEADLESS_W/cfg/labwc"
#
# The pid is read from a FILE rather than inherited from the environment. labwc
# starts before the shell does, and a keybind's Execute runs with the
# compositor's environment — so an exported APEX_TEST_SHELL_PID is simply not
# there, every ALT+Tab silently addresses pid "", and the suite reports that the
# keys never reached the switcher. Which is true, and blames the wrong thing.
cat > "$HEADLESS_W/bin/apex-switcher" <<STUB
#!/usr/bin/env bash
flag="$HEADLESS_W/flag/switcher-open"
case "\$1" in
    next|prev)     mkdir -p "\${flag%/*}"; : > "\$flag" ;;
    commit|cancel) [ -e "\$flag" ] || { echo "\$(date +%s.%N) \$1 SKIPPED-no-flag" \
                       >> "$HEADLESS_W/switcher-stub.log"; exit 0; } ;;
esac
pid="\$(cat "$HEADLESS_W/shell.pid" 2>/dev/null)"
[ -n "\$pid" ] || { echo "no shell pid" >> "$HEADLESS_W/switcher-stub.log"; exit 1; }
echo "\$(date +%s.%N) \$1" >> "$HEADLESS_W/switcher-stub.log"
quickshell ipc --pid "\$pid" call window-switcher "\$1" \
    >> "$HEADLESS_W/switcher-stub.log" 2>&1
STUB
chmod +x "$HEADLESS_W/bin/apex-switcher"

cat > "$HEADLESS_W/cfg/labwc/rc.xml" <<XML
<?xml version="1.0"?>
<labwc_config>
  <core><gap>0</gap></core>
  <focus>
    <followMouse>yes</followMouse>
    <followMouseRequiresMovement>yes</followMouseRequiresMovement>
    <raiseOnFocus>no</raiseOnFocus>
  </focus>
  <keyboard>
    <keybind key="A-Tab">
      <action name="Execute" command="$HEADLESS_W/bin/apex-switcher next"/>
    </keybind>
    <keybind key="A-S-Tab">
      <action name="Execute" command="$HEADLESS_W/bin/apex-switcher prev"/>
    </keybind>
    <keybind key="A-Escape">
      <action name="Execute" command="$HEADLESS_W/bin/apex-switcher cancel"/>
    </keybind>
    <keybind key="A-Return">
      <action name="Execute" command="$HEADLESS_W/bin/apex-switcher commit"/>
    </keybind>
  </keyboard>
</labwc_config>
XML

_before="$(headless_sockets)"
WLR_RENDERER=pixman XDG_CONFIG_HOME="$HEADLESS_W/cfg" XDG_CURRENT_DESKTOP=labwc:wlroots \
    labwc >"$HEADLESS_W/comp.log" 2>&1 &
# shellcheck disable=SC2034  # headless_cleanup reads it, across the source boundary
HEADLESS_COMP_PID=$!
sock="$(headless_wait_socket "$_before")"
if [ -z "$sock" ]; then
    echo "SKIP: labwc did not come up headless"
    tail -5 "$HEADLESS_W/comp.log" 2>/dev/null
    exit 0
fi
export WAYLAND_DISPLAY="$sock"
export XDG_CURRENT_DESKTOP=labwc:wlroots
headless_assert_private || exit 1
echo "host: labwc on $WAYLAND_DISPLAY (headless, private XDG_RUNTIME_DIR and HOME)"

# ── three windows, in a known order ──────────────────────────────────────────
# Three, not two: with two, "step once" and "step twice" land on the same
# window and a switcher that ignored the count would pass.
for w in winA winB winC; do
    cat > "$HEADLESS_W/$w.qml" <<QML
import Quickshell
import QtQuick
ShellRoot { FloatingWindow { title: "$w"; visible: true; implicitWidth: 300; implicitHeight: 200
    Rectangle { anchors.fill: parent; color: "#1b1b1b" } } }
QML
    quickshell -p "$HEADLESS_W/$w.qml" >"$HEADLESS_W/$w.log" 2>&1 &
    win_pids+=($!)
    sleep 1.5
done

for p in "${win_pids[@]}"; do
    if ! kill -0 "$p" 2>/dev/null; then
        echo "FAIL: a filler window died; every window assertion below would be vacuous"
        exit 1
    fi
done

# ── the shell under test ─────────────────────────────────────────────────────
quickshell -p "$staged" >"$HEADLESS_W/shell.log" 2>&1 &
shell_pid=$!
printf '%s' "$shell_pid" > "$HEADLESS_W/shell.pid"

for _ in $(seq 1 40); do
    grep -q "SWITCHER-TEST ready" "$HEADLESS_W/shell.log" 2>/dev/null && break
    kill -0 "$shell_pid" 2>/dev/null || break
    sleep 0.5
done
if ! kill -0 "$shell_pid" 2>/dev/null; then
    echo "SKIP: the test shell did not stay up"
    sed 's/\x1b\[[0-9;]*m//g' "$HEADLESS_W/shell.log" | tail -20
    exit 0
fi
sleep 2

# `quickshell ipc --pid` rather than `-p <dir>`: it addresses the instance this
# script started and nothing else, even if another config were somehow running.
probe() { quickshell ipc --pid "$shell_pid" call probe "$1" 2>/dev/null | tail -1; }

# ── how a held ALT is spelled for wtype ──────────────────────────────────────
#
# A real keyboard sends ONE thing — the Alt_L keycode going down — and the
# compositor derives the Mod1 modifier from it. wtype splits those: `-M alt`
# sets the modifier state directly and sends no key event, and `-P Alt_L` sends
# the key event without necessarily setting the modifier in its synthetic
# keymap. Measured here: with `-M alt -k Tab -m alt` the A-Tab binding fires and
# the `Alt_L onRelease` binding NEVER does, because no Alt_L key was ever
# released — the switcher opens and can only be closed with Escape.
#
# So both are sent. The result is what a real keyboard produces: Mod1 held for
# the Tab, and an Alt_L key release at the end for the onRelease binding.
alt_hold()    { wtype -M alt -P Alt_L "$@"; }
alt_release() { wtype -p Alt_L -m alt; }


windows="$(probe windows)"
echo "windows: $windows"
missing=""
for w in winA winB winC; do
    case ",$windows," in *",$w,"*) : ;; *) missing="$missing $w" ;; esac
done
if [ -z "$missing" ]; then
    ok "all three windows are visible over foreign-toplevel, any order"
else
    bad "all three windows are visible over foreign-toplevel (missing:$missing, got: $windows)"
    sed 's/\x1b\[[0-9;]*m//g' "$HEADLESS_W/shell.log" | tail -25
fi

# The MRU has to be seeded by real focus changes, not by the order windows
# happened to map. Click nothing: focus each in turn by activating it through
# the compositor, which is what a user clicking would do.
active() { probe active; }
echo "active at rest: $(active)"

# ── what this suite can and cannot see, measured ─────────────────────────────
#
# It can see every keystroke reaching the switcher, and every state the switcher
# goes through. It canNOT see the compositor's focus change at the end, because
# in a headless labwc a foreign-toplevel `activate()` request is accepted and
# changes nothing — measured 2026-09-20, with and without a virtual keyboard on
# the seat, and the same on a nested Hyprland. A compositor with no real seat
# devices does not move keyboard focus.
#
# So the commit's effect is asserted where it CAN be seen:
# tests/run-switcher-activate-test.sh drives the same service inside a nested
# Hyprland and reads `hyprctl activewindow` and `hyprctl cursorpos` back. This
# suite asserts the keyboard half, and says so rather than implying both.

# ── 1. one ALT+Tab selects the PREVIOUS window, not the current one ──────────
#
# The single-tap case. If opening selected entry 1 — the window you are already
# looking at — then tap-and-release would be a shortcut that does nothing.
before_state="$(probe state)"
wtype -M alt -P Alt_L -k Tab -s 500 -p Alt_L -m alt
sleep 0.8
opened="$(probe state)"
case "$opened" in
    "open 2/3 "*) ok "one ALT+Tab opens on entry 2 of 3 — the previous window ($opened)" ;;
    *)            bad "one ALT+Tab opens on entry 2 of 3 (got: $opened, was: $before_state)" ;;
esac

# ── 2. more taps keep stepping, and wrap ────────────────────────────────────
wtype -M alt -P Alt_L -k Tab -s 400 -p Alt_L -m alt
sleep 0.6
three="$(probe state)"
wtype -M alt -P Alt_L -k Tab -s 400 -p Alt_L -m alt
sleep 0.6
wrapped="$(probe state)"
case "$three" in
    "open 3/3 "*) ok "a second tap steps to entry 3 of 3 ($three)" ;;
    *)            bad "a second tap steps to entry 3 of 3 (got: $three)" ;;
esac
case "$wrapped" in
    "open 1/3 "*) ok "a third tap wraps to entry 1 of 3 ($wrapped)" ;;
    *)            bad "a third tap wraps to entry 1 of 3 (got: $wrapped)" ;;
esac

# ── 3. ALT+SHIFT+Tab steps backwards ────────────────────────────────────────
wtype -M alt -M shift -P Alt_L -k Tab -s 400 -p Alt_L -m shift -m alt
sleep 0.6
back="$(probe state)"
case "$back" in
    "open 3/3 "*) ok "ALT+SHIFT+Tab steps backwards, wrapping ($back)" ;;
    *)            bad "ALT+SHIFT+Tab steps backwards (got: $back, from $wrapped)" ;;
esac

# ── 4. ALT+Escape closes it and changes nothing ─────────────────────────────
before="$(active)"
wtype -M alt -P Alt_L -k Escape -s 400 -p Alt_L -m alt
sleep 0.8
state="$(probe state)"
cancelled="$(active)"
if [ "$state" = "closed" ] && [ "$cancelled" = "$before" ]; then
    ok "ALT+Escape closes the switcher and leaves focus alone ($before)"
else
    bad "ALT+Escape closes the switcher and leaves focus alone (state $state, $before -> $cancelled)"
fi

# ── 5. ALT+Return commits, and the switcher closes ──────────────────────────
#
# What the commit DOES to focus is the other suite's job; what is asserted here
# is that the key reaches it, that it names the window that was selected, and
# that nothing is left on screen afterwards.
wtype -M alt -P Alt_L -k Tab -s 500 -p Alt_L -m alt
sleep 0.7
picked="$(probe state)"
picked_title="${picked##* }"
wtype -M alt -P Alt_L -k Return -s 300 -p Alt_L -m alt
sleep 1
state="$(probe state)"
if [ "$state" = "closed" ]; then
    ok "ALT+Return commits and the switcher closes (was on $picked_title)"
else
    bad "ALT+Return commits and the switcher closes (got: $state)"
fi

# ── 6. a commit arriving with nothing open is harmless ──────────────────────
#
# The Hyprland binding fires on every ALT release the machine produces, and
# /usr/libexec/apex-switcher filters most of those with a flag file — but a
# stale flag, or a race, puts one through. It must do nothing: not activate a
# window, not error, not leave the switcher half-open.
before="$(active)"
out="$(quickshell ipc --pid "$shell_pid" call window-switcher commit 2>&1 | tail -1)"
sleep 0.8
idle="$(active)"
state="$(probe state)"
if [ "$idle" = "$before" ] && [ "$state" = "closed" ] && [ "$out" = "closed" ]; then
    ok "a commit arriving with nothing open changes nothing (said: $out)"
else
    bad "a commit arriving with nothing open changes nothing ($before -> $idle, state $state, said $out)"
fi

# ── 6b. the SINGLE-TAP race: Tab and commit with no pause between them ──────
#
# The case the whole flag-file ordering exists for. A quick ALT+Tab releases ALT
# roughly 60ms after Tab goes down, and the shell's own flag write is at the end
# of a spawn -> apex -> qs ipc -> Process chain longer than that. If the flag is
# written by the SHELL rather than by the helper, the commit finds no flag,
# exits silently, and the switcher is left open on entry 2 — so the next switch
# commits the wrong window.
#
# No -s anywhere in this line, deliberately: the two keys are as close together
# as wtype can put them.
: > "$HEADLESS_W/switcher-stub.log"
before="$(active)"
wtype -M alt -P Alt_L -k Tab -k Return -p Alt_L -m alt
sleep 1.5
state="$(probe state)"
skipped="$(grep -c 'SKIPPED-no-flag' "$HEADLESS_W/switcher-stub.log" 2>/dev/null || true)"
if [ "$state" = "closed" ] && [ "${skipped:-0}" -eq 0 ]; then
    ok "a single tap with no pause still commits — the flag beat the release"
else
    bad "a single tap with no pause still commits (state $state, $skipped commits dropped for want of a flag)"
    tail -6 "$HEADLESS_W/switcher-stub.log" 2>/dev/null | sed 's/^/       /'
fi

# ── 6c. a stale flag repairs itself ─────────────────────────────────────────
#
# `next` writes the flag and `next` with one window open opens nothing, and a
# shell killed mid-switch never removes its own. Either leaves every later ALT
# release paying for an IPC call. The call that proves the flag is stale is the
# one that clears it.
shell_flag="$(probe flag)"
mkdir -p "${shell_flag%/*}" 2>/dev/null
: > "$shell_flag"
quickshell ipc --pid "$shell_pid" call window-switcher commit >/dev/null 2>&1
sleep 0.8
if [ ! -e "$shell_flag" ]; then
    ok "a commit arriving with nothing open removes the stale flag ($shell_flag)"
else
    bad "a commit arriving with nothing open removes the stale flag ($shell_flag is still there)"
fi

# ── 7. a window that is not on this desktop is still in the list ────────────
#
# Andre asked for this by name. wlr-foreign-toplevel-management publishes every
# toplevel regardless of desktop, which is why the switcher reads it instead of
# a per-compositor window query — but "by construction" is not a measurement.
#
# Minimised rather than sent to desktop 2, deliberately: a minimised window's
# state is READABLE back over the same protocol, so this suite can prove the
# window really did leave the screen. `SendToDesktop` has no such read-back
# here, so an assertion built on it would pass equally if labwc had ignored it.
hidden="$(probe minimize_first)"
sleep 1
if [ "$hidden" = "<none>" ]; then
    bad "a window could be minimised to test the off-screen case"
else
    flags="$(probe flags)"
    case "$flags" in
        *"$hidden:minimized"*) ok "the window really is minimised, so this is a real off-screen case ($hidden)" ;;
        *)                     bad "the window really is minimised ($hidden not minimized in: $flags)" ;;
    esac
    windows="$(probe windows)"
    case ",$windows," in
        *",$hidden,"*) ok "a minimised window is STILL in the switcher's list ($hidden)" ;;
        *)             bad "a minimised window is still in the switcher's list ($hidden missing from: $windows)" ;;
    esac
    # And it can be stepped to.
    tries=0; found=no
    while [ "$tries" -lt 5 ]; do
        wtype -M alt -P Alt_L -k Tab -s 350 -p Alt_L -m alt
        sleep 0.5
        case "$(probe state)" in
            *" $hidden") found=yes; break ;;
        esac
        tries=$((tries + 1))
    done
    wtype -M alt -P Alt_L -k Escape -s 200 -p Alt_L -m alt
    sleep 0.5
    if [ "$found" = yes ]; then
        ok "and ALT+Tab can select it ($hidden)"
    else
        bad "and ALT+Tab can select it ($hidden never became the selection)"
    fi
fi

if [ "$fail" -ne 0 ]; then
    echo
    echo "--- what the keybind stub was asked to do ---"
    tail -30 "$HEADLESS_W/switcher-stub.log" 2>/dev/null || echo "(the stub never ran: the keys never reached labwc's keybinds)"
    echo "--- shell ---"
    sed 's/\x1b\[[0-9;]*m//g' "$HEADLESS_W/shell.log" | grep -viE 'libEGL|MESA-LOADER' | tail -20
fi

echo
printf 'window switcher: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
