#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Run tests/agent-graph-render-test.qml — the session graph as Qt builds it,
#  rather than as the source reads (P1-020).
#
#  ── It brings its own compositor, always ────────────────────────────────────
#
#  Not "if there is no WAYLAND_DISPLAY". Always. quickshell needs a compositor,
#  and the obvious shortcut — nest inside whatever session is running — puts the
#  test one mistake away from drawing on the developer's actual desktop. So this
#  starts a headless wlroots compositor in a private XDG_RUNTIME_DIR and points
#  quickshell at that, which also makes the test runnable on a build box with no
#  display at all.
#
#  The QML does open one window, and it has to: a Column lays its children out
#  in a polish pass, a polish pass is driven by a QQuickWindow, and without one
#  the expanded child list measures zero and the test reports a defect that is
#  not there. tests/run-nav-geometry-test.sh opens one for the same reason. It
#  is a FloatingWindow inside the private compositor below — WAYLAND_DISPLAY
#  and DISPLAY are unset before quickshell starts, so there is no session for
#  it to reach.
#
#  Quickshell refuses to import QML from outside the directory holding the entry
#  point, so the test is staged into the repo root for the run and removed
#  afterwards — the same arrangement tests/run-scaling-test.sh uses.
#
#  Skips cleanly (status 0) without quickshell or without a headless compositor,
#  so CI on a machine with neither does not fail the build.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

command -v quickshell >/dev/null 2>&1 || { echo "SKIP: quickshell not installed"; exit 0; }

# Say what is wrong rather than letting QML report it as a missing type.
if [[ ! -f "$root/src/services/agents/SubagentRow.qml" ]]; then
    echo "FAIL: this tree has no SubagentRow — a session's subagents and the"
    echo "      processes it forked have nowhere to be drawn, which is the"
    echo "      defect this test measures. Nothing to render."
    exit 1
fi
grep -q "^SubagentRow " "$root/src/services/qmldir" || {
    # SessionRow is loaded THROUGH src/services/qmldir, so its directory is not
    # on the import path and a sibling that is not registered there is invisible
    # to it — with the whole shell failing to load, not just the page.
    echo "FAIL: SubagentRow is not registered in src/services/qmldir, so"
    echo "      SessionRow cannot see it and the whole shell fails to load."
    exit 1; }

comp=""
for c in labwc sway; do
    command -v "$c" >/dev/null 2>&1 && { comp="$c"; break; }
done
[[ -n "$comp" ]] || { echo "SKIP: no wlroots compositor (labwc or sway) to host the test"; exit 0; }

W="$(mktemp -d)"
staged="$root/.agent-graph-render-test.qml"
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

cp "$here/agent-graph-render-test.qml" "$staged"

# A runtime dir of its own, so the compositor's socket cannot collide with a
# real session's and nothing here can reach one.
export XDG_RUNTIME_DIR="$W/run"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"
unset WAYLAND_DISPLAY
unset DISPLAY
export WLR_BACKENDS=headless
export WLR_LIBINPUT_NO_DEVICES=1
export WLR_RENDERER=pixman
export XDG_SESSION_TYPE=wayland
export QT_QPA_PLATFORM=wayland

case "$comp" in
    labwc)
        mkdir -p "$W/labwc"
        cp "$here/labwc-test-rc.xml" "$W/labwc/rc.xml" 2>/dev/null || true
        XDG_CONFIG_HOME="$W" "$comp" > "$W/comp.log" 2>&1 &
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

# Colour codes stripped: quickshell decorates its log level, and the per-state
# table below is meant to be readable in a CI log as well as in a terminal.
out="$(QT_LOGGING_RULES="qml=true" timeout 90 quickshell -p "$staged" 2>&1 \
       | sed 's/\x1b\[[0-9;]*m//g')"

echo "$out" | grep -E "PASS|FAIL|background=|passed=" || true

if echo "$out" | grep -q "Failed to load configuration"; then
    echo "$out" | tail -25
    echo "RESULT: the test config failed to load"
    exit 1
fi
if ! echo "$out" | grep -q "agent-graph-render: passed="; then
    echo "$out" | tail -25
    echo "RESULT: the test did not run to completion"
    exit 1
fi
if echo "$out" | grep -q "  FAIL"; then
    echo "RESULT: failing assertions"
    exit 1
fi

echo "RESULT: the graph rows resolve, grow the card, and stay out of its tap target"
