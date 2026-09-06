#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Run tests/labwc-matrix-test.qml — the Floating/labwc session's own defects,
#  measured under a real labwc (roadmap §21, P1-038).
#
#  ── Why labwc needs its own suite ───────────────────────────────────────────
#  Three branches of August fixes were all labwc defects, and every one of them
#  was found by a person running the session rather than by CI. They share a
#  shape: the shell renders correctly and silently ignores input. A popup whose
#  input region sits outside its own surface, a dismiss overlay stacked above
#  the menu it is meant to dismiss, a bar whose input mask covers the titlebars
#  labwc draws — none of them log anything, so a smoke test that only checks for
#  runtime errors exits zero over all three.
#
#  Hyprland hid them. It clamps an out-of-bounds input region leniently enough
#  that enough of it still overlapped the buttons, so the same bugs were
#  invisible on the primary compositor. labwc clips strictly.
#
#  ── It brings its own compositor, and its own home directory ────────────────
#  A headless wlroots labwc in a private XDG_RUNTIME_DIR, always — never nested
#  in the developer's session, which would put windows on their desktop.
#  HOME, XDG_CONFIG_HOME, XDG_STATE_HOME and XDG_CACHE_HOME are private too:
#  the shell persists settings under HOME, and a crash midway through a run
#  would otherwise leave the developer's live shell holding the test's state.
#
#  Fonts are the one thing borrowed back, read-only, because fontconfig finds
#  user fonts through HOME and a run that cannot see them measures .notdef boxes
#  — every width the suite reports would be fiction.
#
#  ── And a filler toplevel ───────────────────────────────────────────────────
#  A nested compositor with nothing running inside it is not a session. The app
#  dock lists windows, so with no window its model is empty, and every assertion
#  over it is a loop that passes without testing anything. The QML declares the
#  toplevel a precondition and fails rather than skips if it is missing.
#
#  Skips cleanly (status 0) without quickshell or without labwc, so CI on a
#  runner with neither does not fail the build.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

command -v quickshell >/dev/null 2>&1 || { echo "SKIP: quickshell not installed"; exit 0; }
command -v labwc      >/dev/null 2>&1 || { echo "SKIP: labwc not installed"; exit 0; }

W="$(mktemp -d)"
staged="$root/.labwc-matrix-test.qml"
comp_pid=""
filler_pid=""
# Killed by pid, never by name: a pkill for a compositor on a developer's
# machine takes down the session they are working in.
cleanup() {
    [[ -n "$filler_pid" ]] && kill "$filler_pid" 2>/dev/null
    [[ -n "$comp_pid" ]]   && kill "$comp_pid"   2>/dev/null
    sleep 0.3
    [[ -n "$filler_pid" ]] && kill -9 "$filler_pid" 2>/dev/null
    [[ -n "$comp_pid" ]]   && kill -9 "$comp_pid"   2>/dev/null
    rm -f "$staged"
    rm -rf "$W"
    return 0
}
trap cleanup EXIT INT TERM

# Quickshell refuses to import QML from outside the directory holding the entry
# point, so the test is staged into the repo root for the run and removed
# afterwards — the same arrangement tests/run-nav-geometry-test.sh uses.
cp "$here/labwc-matrix-test.qml" "$staged"

# ── Stubs for everything a shell component shells out to ─────────────────────
# The suite builds real popups and a real bar, and those ask the real machine:
# hyprctl, wlr-randr, brightnessctl, playerctl, nmcli. Left alone this suite
# would interrogate the developer's desktop while measuring rectangles.
mkdir -p "$W/bin"
cat > "$W/bin/_stub" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
    *--json*|*-j*|*json*) echo "{}" ;;
    *)                    : ;;
esac
exit 0
FAKE
chmod +x "$W/bin/_stub"
for n in apex hyprctl wlr-randr niri matugen xdg-open playerctl wpctl \
         brightnessctl pkcheck notify-send swww nmcli bluetoothctl \
         systemd-inhibit grimblast grim slurp wl-copy; do
    ln -sf "$W/bin/_stub" "$W/bin/$n"
done
cat > "$W/bin/git" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
    *describe*) echo "v0.0.0-test" ;;
    *)          : ;;
esac
exit 0
FAKE
chmod +x "$W/bin/git"
export PATH="$W/bin:$PATH"

real_home="$(getent passwd "$(id -u)" | cut -d: -f6)"

export XDG_RUNTIME_DIR="$W/run"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"
export HOME="$W/home"
mkdir -p "$HOME/.config/apex-shell/src/user_data" "$HOME/.local/share" \
         "$HOME/Pictures/Wallpapers"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$W/state"
export XDG_CACHE_HOME="$W/cache"
mkdir -p "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
ln -sfn "$real_home/.local/share/fonts" "$HOME/.local/share/fonts" 2>/dev/null
ln -sfn "$real_home/.config/fontconfig" "$HOME/.config/fontconfig" 2>/dev/null

# Nested labwc must not inherit another compositor's identity, or the shell
# under test detects the wrong one and every labwc branch takes its other arm.
unset WAYLAND_DISPLAY
unset DISPLAY
unset HYPRLAND_INSTANCE_SIGNATURE
unset NIRI_SOCKET
export XDG_CURRENT_DESKTOP=labwc:wlroots
export WLR_BACKENDS=headless
export WLR_LIBINPUT_NO_DEVICES=1
export WLR_HEADLESS_OUTPUTS=1
export XDG_SESSION_TYPE=wayland
export QT_QPA_PLATFORM=wayland

# labwc announces its display nowhere, so find the socket by diffing the private
# runtime dir rather than scraping a log.
list_sockets() {
    local f b
    for f in "$XDG_RUNTIME_DIR"/wayland-*; do
        [[ -S "$f" ]] || continue
        b="${f##*/}"
        case "${b#wayland-}" in '' | *[!0-9]*) continue ;; esac
        printf '%s\n' "$b"
    done | sort
}

before="$(list_sockets)"
mkdir -p "$XDG_CONFIG_HOME/labwc"
cp "$here/labwc-test-rc.xml" "$XDG_CONFIG_HOME/labwc/rc.xml" 2>/dev/null || true
WLR_RENDERER=pixman labwc > "$W/comp.log" 2>&1 &
comp_pid=$!

sock=""
for _ in $(seq 1 60); do
    sock="$(comm -13 <(printf '%s\n' "$before") <(list_sockets) | head -1)"
    [[ -n "$sock" ]] && break
    sleep 0.25
done
[[ -n "$sock" ]] || {
    echo "SKIP: labwc did not come up headless"
    tail -5 "$W/comp.log"
    exit 0; }
export WAYLAND_DISPLAY="$sock"

# Whatever this suite maps must land on the compositor above and nowhere else.
[[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]] || {
    echo "FAIL: WAYLAND_DISPLAY does not name a socket in the private runtime dir"
    exit 1; }

echo "host: labwc $(labwc --version 2>&1 | head -1) on $WAYLAND_DISPLAY (headless, private XDG_RUNTIME_DIR and HOME)"

# ── The filler ───────────────────────────────────────────────────────────────
# quickshell rather than a terminal emulator: it is already a hard requirement
# of this harness, so the filler adds no dependency.
filler_qml="$W/filler.qml"
cat > "$filler_qml" <<'FILLER'
import Quickshell
import QtQuick

ShellRoot {
    FloatingWindow {
        title:          "apex-labwc-matrix-filler"
        visible:        true
        implicitWidth:  360
        implicitHeight: 240
        Rectangle { anchors.fill: parent; color: "#1b1b1b" }
    }
}
FILLER

quickshell -p "$filler_qml" >"$W/filler.log" 2>&1 &
filler_pid=$!

# The window has to be mapped and published over foreign-toplevel before the
# suite reads the window list, and nothing announces either step. A fixed wait
# is the honest option; the check afterwards is what matters, because a filler
# that died turns every dock assertion into an empty loop.
sleep 2
kill -0 "$filler_pid" 2>/dev/null || {
    echo "FAIL: the filler toplevel did not stay up; dock assertions would be vacuous"
    tail -10 "$W/filler.log"
    exit 1; }

out="$(QT_LOGGING_RULES="qml=true" timeout 180 quickshell -p "$staged" 2>&1 \
       | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^[[:space:]]*DEBUG qml: //')"

echo "$out" | grep -E "^(  PASS|  FAIL|  ....|──|labwc-matrix:)" || true

if echo "$out" | grep -q "Failed to load configuration"; then
    echo "$out" | tail -25
    echo "RESULT: the test config failed to load"
    exit 1
fi

summary="$(echo "$out" | grep -o 'labwc-matrix: passed=[0-9]* failed=[0-9]*' | tail -1)"
if [[ -z "$summary" ]]; then
    echo "$out" | tail -25
    echo "RESULT: the test did not run to completion"
    exit 1
fi

# Graded on the count the run reported, never on whether a FAIL line survived a
# grep: a summary that says failed=9 and a filter that prints none of them is
# how a red run gets reported green.
failed="${summary##*failed=}"
if [[ "$failed" -ne 0 ]]; then
    echo "RESULT: $failed assertion(s) failed under labwc"
    exit 1
fi

echo "RESULT: the Floating session's input regions, dismiss surface, bar mask and dock all hold"
