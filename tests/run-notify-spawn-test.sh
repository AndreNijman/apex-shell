#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Run tests/notify-spawn-test.qml — what a busy Quickshell Process does with a
#  second command (roadmap P1-022).
#
#  ── What is being settled ───────────────────────────────────────────────────
#
#  AgentService routed every desktop notification through one `Process` running
#  `notify-send --wait`, which does not exit until the notification is
#  dismissed. Whether the ones raised in the meantime were queued, started or
#  thrown away is the difference between an untidy implementation and one that
#  silently loses the thing it exists to deliver. The type information does not
#  say, so the engine is asked, and the answer is asserted rather than
#  remembered in somebody's comment.
#
#  The answer: a Process holds one pending command and a new assignment
#  overwrites it. Two notifications raised in one tick run only the second;
#  everything raised while one is blocked is destroyed except the newest, which
#  then waits for the blocking one to be dismissed. Six agents needing
#  attention while nobody is at the desk produce one notification.
#
#  ── It brings its own compositor, always ────────────────────────────────────
#
#  Not "if there is no WAYLAND_DISPLAY". Always. The same rule as
#  tests/run-agent-state-render-test.sh, and for the same reason: nesting in
#  whatever session happens to be running puts a test one mistake away from
#  drawing on somebody's desktop. A headless wlroots compositor in a private
#  XDG_RUNTIME_DIR also makes this runnable on a build box with no display.
#
#  Nothing here sends a desktop notification. Both phases run `sh -c` writing a
#  marker file: what is under test is Process, not notify-send, and a test that
#  raised real toasts on a developer's session would be the exact disruption
#  this repository has a rule against.
#
#  Skips cleanly (status 0) without quickshell or without a headless
#  compositor.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

command -v quickshell >/dev/null 2>&1 || { echo "SKIP: quickshell not installed"; exit 0; }

comp=""
for c in labwc sway; do
    command -v "$c" >/dev/null 2>&1 && { comp="$c"; break; }
done
[[ -n "$comp" ]] || { echo "SKIP: no wlroots compositor (labwc or sway) to host the test"; exit 0; }

W="$(mktemp -d)"
# Quickshell refuses to import QML from outside the directory holding the entry
# point, so the test is staged into the repo root for the run — the same
# arrangement tests/run-scaling-test.sh and run-agent-state-render-test.sh use.
staged="$root/.notify-spawn-test.qml"
comp_pid=""
cleanup() {
    [[ -n "$comp_pid" ]] && kill "$comp_pid" 2>/dev/null
    sleep 0.2
    [[ -n "$comp_pid" ]] && kill -9 "$comp_pid" 2>/dev/null
    rm -f "$staged"
    rm -rf "$W"
    return 0
}
trap cleanup EXIT INT TERM

cp "$here/notify-spawn-test.qml" "$staged"

# A runtime dir of its own, so the compositor's socket cannot collide with a
# real session's and nothing here can reach one. XDG_STATE_HOME and
# XDG_CONFIG_HOME move with it: a suite that wrote to the real state directory
# truncated three of this machine's PTY transcripts once already.
export XDG_RUNTIME_DIR="$W/run"
export XDG_STATE_HOME="$W/state"
export XDG_CONFIG_HOME="$W/config"
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME"
chmod 0700 "$XDG_RUNTIME_DIR"
unset WAYLAND_DISPLAY
unset DISPLAY
export WLR_BACKENDS=headless
export WLR_LIBINPUT_NO_DEVICES=1
export WLR_RENDERER=pixman
export XDG_SESSION_TYPE=wayland
export QT_QPA_PLATFORM=wayland

export APEX_NOTIFY_TEST_DIR="$W"

case "$comp" in
    labwc)
        mkdir -p "$XDG_CONFIG_HOME/labwc"
        cp "$here/labwc-test-rc.xml" "$XDG_CONFIG_HOME/labwc/rc.xml" 2>/dev/null || true
        "$comp" > "$W/comp.log" 2>&1 &
        ;;
    sway)
        printf 'output HEADLESS-1 mode 1920x1080\n' > "$W/sway.cfg"
        "$comp" -c "$W/sway.cfg" > "$W/comp.log" 2>&1 &
        ;;
esac
comp_pid=$!

sock=""
for _ in $(seq 1 60); do
    for f in "$XDG_RUNTIME_DIR"/wayland-*; do
        [[ -S "$f" ]] || continue
        sock="$(basename "$f")"
        break
    done
    [[ -n "$sock" ]] && break
    sleep 0.25
done
[[ -n "$sock" ]] || {
    echo "SKIP: $comp did not come up headless"; tail -5 "$W/comp.log"; exit 0; }
export WAYLAND_DISPLAY="$sock"
echo "host: $comp on $WAYLAND_DISPLAY (headless, private XDG_RUNTIME_DIR)"

out="$(QT_LOGGING_RULES="qml=true" timeout 90 quickshell -p "$staged" 2>&1 \
       | sed 's/\x1b\[[0-9;]*m//g')"

echo "$out" | grep -E "PASS|FAIL|one Process|execDetached:|passed=" || true

if echo "$out" | grep -q "Failed to load configuration"; then
    echo "$out" | tail -25
    echo "RESULT: the test config failed to load"
    exit 1
fi
if ! echo "$out" | grep -q "notify-spawn: passed="; then
    echo "$out" | tail -25
    echo "RESULT: the test did not run to completion"
    exit 1
fi
if echo "$out" | grep -q "  FAIL"; then
    echo "RESULT: failing assertions"
    exit 1
fi

echo "RESULT: one Process carries one notification — the rest are destroyed or"
echo "        held until somebody dismisses the one blocking them. execDetached does not."
