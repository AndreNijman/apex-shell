#!/usr/bin/env bash
# What the ALT+Tab switcher's COMMIT actually does to a compositor.
#
#     ./tests/run-switcher-activate-test.sh
#
# ── The half run-window-switcher-test.sh cannot see ─────────────────────────
#
# That suite drives the switcher with real ALT and TAB keys on a headless labwc
# and proves every keystroke reaches it. What it cannot prove is the last step:
# whether committing actually focuses the window. Measured 2026-09-20, a
# foreign-toplevel `activate()` request in a headless labwc is accepted and
# changes nothing — with and without a virtual keyboard on the seat. A
# compositor with no real seat devices does not move keyboard focus that way.
#
# So the commit is measured here instead, in a nested Hyprland, where focus and
# the pointer can both be read back out of `hyprctl`. That matters twice over,
# because Hyprland is the session that actually binds this switcher.
#
# ── Driven over IPC, not by keys, and that is not a gap ─────────────────────
#
# Hyprland will not take a synthetic keyboard: wtype's virtual-keyboard-v1
# device is accepted and then reported with `active keymap: error`, and no bind
# fires from it. The keyboard half is covered by the labwc suite; what is
# covered here is everything downstream of `window-switcher next|commit`
# arriving, which is exactly what those keybinds send.
#
# ── What it asserts ─────────────────────────────────────────────────────────
#
#   * every window is in the list, including one on another WORKSPACE;
#   * committing focuses the window that was selected;
#   * the POINTER ends up inside it — the same rule SUPER+arrow follows, and
#     without it a follow-mouse session takes the focus straight back;
#   * committing to a window on another workspace switches workspace;
#   * focus survives a pointer nudge afterwards.
#
# Nothing is drawn on the machine running this: labwc on the wlroots headless
# backend, Hyprland nested inside it, private runtime dir and HOME, and every
# hyprctl addressed by the nested signature.
#
# Skips with status 0 when labwc, Hyprland or quickshell is missing.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"

pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

headless_require labwc Hyprland hyprctl quickshell python3

staged="$root/.switcher-activate-test.qml"
shell_pid=""
win_pids=()
SIG=""

cleanup() {
    local p
    for p in "${win_pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || :; done
    [ -n "$shell_pid" ] && kill "$shell_pid" 2>/dev/null || :
    rm -f "$staged"
    headless_cleanup
    return 0
}
trap cleanup EXIT INT TERM

cp "$here/window-switcher-test.qml" "$staged"

headless_begin
# The shell under test talks to the nested Hyprland through hyprctl, so it must
# be the real binary and not headless.sh's stub — the stub answers "{}" to
# everything, which would make the compositor facade report an empty window list
# and the switcher's compositor-side focus path a silent no-op.
headless_unstub hyprctl

# ── the host: labwc, NOT on the pixman renderer ──────────────────────────────
# Aquamarine asks the host for a dmabuf and a software-rendered host has none to
# give; the only symptom is CBackend::create() failing with nothing else said.
mkdir -p "$HEADLESS_W/cfg/labwc"
cp "$here/labwc-test-rc.xml" "$HEADLESS_W/cfg/labwc/rc.xml" 2>/dev/null || true
_before="$(headless_sockets)"
XDG_CONFIG_HOME="$HEADLESS_W/cfg" XDG_CURRENT_DESKTOP=labwc:wlroots \
    labwc >"$HEADLESS_W/comp.log" 2>&1 &
# shellcheck disable=SC2034  # headless_cleanup reads it, across the source boundary
HEADLESS_COMP_PID=$!
host_sock="$(headless_wait_socket "$_before")"
if [ -z "$host_sock" ]; then
    echo "SKIP: the host labwc did not come up headless"
    tail -5 "$HEADLESS_W/comp.log" 2>/dev/null
    exit 0
fi
export WAYLAND_DISPLAY="$host_sock"
headless_assert_private || exit 1

# ── the nested Hyprland ──────────────────────────────────────────────────────
mkdir -p "$HOME/.config/hypr"
cat > "$HOME/.config/hypr/hyprland.lua" <<'LUA'
-- The two settings this suite is about, and nothing else. The SEEDED tree is
-- apex-os's to test (tests/test-apex-hypr-focus.sh); what is under test here is
-- the shell's switcher against a compositor configured the way APEX configures
-- it.
hl.config({
    general = { gaps_in = 0, gaps_out = 0, border_size = 2 },
    input   = { follow_mouse = 1 },
    cursor  = { no_warps = false },
    misc    = { disable_hyprland_logo = true, disable_splash_rendering = true },
})
LUA

_hypr_before="$(ls "$XDG_RUNTIME_DIR/hypr" 2>/dev/null | tr '\n' ' ')"
env -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u WLR_BACKENDS -u WLR_RENDERER \
    AQ_BACKENDS=wayland AQ_NO_MODIFIERS=1 \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$host_sock" \
    HOME="$HOME" XDG_CURRENT_DESKTOP=Hyprland \
    Hyprland -c "$HOME/.config/hypr/hyprland.lua" >"$HEADLESS_W/hypr.log" 2>&1 &
# shellcheck disable=SC2034  # same: headless_cleanup kills it on the way out
HEADLESS_NESTED_PID=$!

for _ in $(seq 1 40); do
    for s in "$XDG_RUNTIME_DIR"/hypr/*; do
        [ -e "$s" ] || continue
        s="${s##*/}"
        case " $_hypr_before " in *" $s "*) continue ;; esac
        SIG="$s"
    done
    [ -n "$SIG" ] && [ -S "$XDG_RUNTIME_DIR/hypr/$SIG/.socket.sock" ] && break
    kill -0 "$HEADLESS_NESTED_PID" 2>/dev/null || break
    sleep 0.5
done
if [ -z "$SIG" ] || [ ! -S "$XDG_RUNTIME_DIR/hypr/$SIG/.socket.sock" ]; then
    echo "SKIP: the nested Hyprland did not come up"
    grep -iE "backend|abort|what\(\)|Fatal" "$HEADLESS_W/hypr.log" | tail -6 | sed 's/^/        /'
    exit 0
fi
headless_assert_not_ambient_signature "$SIG" || exit 1

H() { hyprctl -i "$SIG" "$@" 2>&1; }

# A nested Hyprland comes up with NO output, and a compositor with no output has
# nowhere to put a window — every assertion below would be over an empty list.
H output create headless >/dev/null 2>&1
sleep 1
mons="$(H monitors -j | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(0)')"
if [ "${mons:-0}" -lt 1 ]; then
    echo "SKIP: the nested Hyprland has no output to place windows on"
    exit 0
fi
echo "host: labwc on $host_sock; nested Hyprland $SIG with $mons output(s)"

# `wayland-<digits>` only: the nested instance's own children put other sockets
# in this directory (wayland-N-awww-daemon.sock among them), and taking the last
# match hands a client a wallpaper daemon as its display.
nest_sock=""
for f in "$XDG_RUNTIME_DIR"/wayland-*; do
    [ -S "$f" ] || continue
    b="${f##*/}"
    case "${b#wayland-}" in '' | *[!0-9]*) continue ;; esac
    [ "$b" = "$host_sock" ] && continue
    nest_sock="$b"
done
if [ -z "$nest_sock" ]; then
    echo "SKIP: the nested Hyprland published no wayland socket"
    exit 0
fi

# ── windows, on two workspaces ───────────────────────────────────────────────
spawn() {   # spawn TITLE
    cat > "$HEADLESS_W/$1.qml" <<QML
import Quickshell
import QtQuick
ShellRoot { FloatingWindow { title: "$1"; visible: true; implicitWidth: 400; implicitHeight: 300
    Rectangle { anchors.fill: parent; color: "#1b1b1b" } } }
QML
    HYPRLAND_INSTANCE_SIGNATURE="$SIG" WAYLAND_DISPLAY="$nest_sock" \
        quickshell -p "$HEADLESS_W/$1.qml" >"$HEADLESS_W/$1.log" 2>&1 &
    win_pids+=($!)
    sleep 2
}

spawn winA
spawn winB
H dispatch 'hl.dsp.focus({ workspace = 2 })' >/dev/null 2>&1
sleep 0.6
spawn winFar                       # the one on the other workspace
H dispatch 'hl.dsp.focus({ workspace = 1 })' >/dev/null 2>&1
sleep 0.8

for p in "${win_pids[@]}"; do
    if ! kill -0 "$p" 2>/dev/null; then
        echo "FAIL: a filler window died; every assertion below would be vacuous"
        exit 1
    fi
done

# ── the shell ────────────────────────────────────────────────────────────────
HYPRLAND_INSTANCE_SIGNATURE="$SIG" WAYLAND_DISPLAY="$nest_sock" \
    XDG_CURRENT_DESKTOP=Hyprland \
    quickshell -p "$staged" >"$HEADLESS_W/shell.log" 2>&1 &
shell_pid=$!
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
sleep 3

ipc()    { quickshell ipc --pid "$shell_pid" call "$@" 2>/dev/null | tail -1; }
probe()  { ipc probe "$1"; }
switch() { ipc window-switcher "$1"; }

active() { H activewindow -j | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("title") or "<none>")
except Exception: print("<none>")'; }
geo()    { H activewindow -j | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin); x, y = d.get("at", [0, 0]); w, h = d.get("size", [0, 0])
    print(x, y, w, h)
except Exception: print(0, 0, 0, 0)'; }
curpos() { H cursorpos | tr -d ' '; }
ws()     { H activeworkspace -j | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("id"))
except Exception: print(-1)'; }

inside() {  # inside "x,y" "ax ay w h"
    python3 - "$1" "$2" <<'PY'
import sys
try:
    cx, cy = (int(v) for v in sys.argv[1].split(","))
    ax, ay, w, h = (int(v) for v in sys.argv[2].split())
except Exception:
    sys.exit(2)
sys.exit(0 if (ax <= cx <= ax + w and ay <= cy <= ay + h) else 1)
PY
}

# ── 1. every window is in the list, including the one on workspace 2 ────────
windows="$(probe windows)"
echo "windows: $windows"
missing=""
for w in winA winB winFar; do
    case ",$windows," in *",$w,"*) : ;; *) missing="$missing $w" ;; esac
done
if [ -z "$missing" ]; then
    ok "every window is in the switcher's list, including one on another workspace"
else
    bad "every window is in the switcher's list (missing:$missing, got: $windows)"
    sed 's/\x1b\[[0-9;]*m//g' "$HEADLESS_W/shell.log" | grep -viE 'libEGL|MESA' | tail -20
fi

# ── 2. committing focuses the window that was selected ──────────────────────
before="$(active)"
state="$(switch next)"
sel="${state##* }"
switch commit >/dev/null
sleep 1.2
after="$(active)"
if [ "$after" = "$sel" ] && [ "$sel" != "$before" ]; then
    ok "committing focuses the selected window ($before -> $after)"
else
    bad "committing focuses the selected window (selected $sel, $before -> $after)"
fi

# ── 3. and the pointer is inside it ─────────────────────────────────────────
#
# The same rule SUPER+arrow follows. Without it, a follow-mouse session takes
# focus straight back the moment the mouse is touched — which is the defect this
# whole unit exists to remove, and a switcher that reintroduced it one keystroke
# later would be no better.
cur="$(curpos)"; g="$(geo)"
if inside "$cur" "$g"; then
    ok "the pointer ended up INSIDE the window the switcher activated (cursor $cur, window $g)"
else
    bad "the pointer ended up inside the window the switcher activated (cursor $cur, window $g)"
fi

# ── 4. it is still focused a moment later, and after a pointer nudge ────────
sleep 1.2
still="$(active)"
cx="${cur%%,*}"; cy="${cur##*,}"
H dispatch "hl.dsp.cursor.move({ x = $((cx + 1)), y = $cy })" >/dev/null 2>&1
sleep 0.8
nudged="$(active)"
if [ "$still" = "$after" ] && [ "$nudged" = "$after" ]; then
    ok "it is still focused 1.2s later and after a one-pixel pointer nudge ($nudged)"
else
    bad "it is still focused after a nudge ($after -> $still -> $nudged)"
fi

# ── 5. committing to a window on ANOTHER workspace switches workspace ───────
ws_before="$(ws)"
tries=0; sel=""
while [ "$tries" -lt 6 ]; do
    state="$(switch next)"
    case "$state" in
        *" winFar") sel=winFar; break ;;
        closed)     break ;;
    esac
    tries=$((tries + 1))
done
if [ "$sel" = "winFar" ]; then
    switch commit >/dev/null
    sleep 1.5
    if [ "$(active)" = "winFar" ] && [ "$(ws)" != "$ws_before" ]; then
        ok "committing a window on another workspace focuses it AND switches workspace (ws $ws_before -> $(ws))"
    else
        bad "committing a window on another workspace focuses it and switches workspace (active $(active), ws $ws_before -> $(ws))"
    fi
    cur="$(curpos)"; g="$(geo)"
    if inside "$cur" "$g"; then
        ok "and the pointer followed it there (cursor $cur, window $g)"
    else
        bad "and the pointer followed it there (cursor $cur, window $g)"
    fi
else
    bad "the window on another workspace could be selected (never reached it in 6 steps)"
    switch cancel >/dev/null
fi

# ── 6. a commit with nothing open is harmless ───────────────────────────────
before="$(active)"
said="$(switch commit)"
sleep 0.8
if [ "$(active)" = "$before" ] && [ "$said" = "closed" ]; then
    ok "a commit arriving with nothing open changes nothing (said: $said)"
else
    bad "a commit arriving with nothing open changes nothing ($before -> $(active), said $said)"
fi

if [ "$fail" -ne 0 ]; then
    echo
    echo "--- shell ---"
    sed 's/\x1b\[[0-9;]*m//g' "$HEADLESS_W/shell.log" | grep -viE 'libEGL|MESA-LOADER' | tail -20
    echo "--- clients ---"
    H clients -j | python3 -c 'import json,sys
for c in json.load(sys.stdin): print("   ", repr(c["title"]), c["at"], c["size"], "ws", c["workspace"]["id"])' 2>/dev/null
fi

echo
printf 'switcher activate: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
