#!/usr/bin/env bash
# Run the display apply transaction suite (P0-018) against a real wlroots
# session with two virtual outputs.
#
#     ./tests/run-display-transaction-test.sh
#
# ── Why headless, and why virtual outputs ────────────────────────────────────
#
# The bug is about what happens to the confirmation when the apply changes the
# outputs underneath it. That cannot be tested against a session whose outputs
# are somebody's actual monitors, and it cannot be tested against a mock either
# — the question is whether Quickshell.screens loses an entry, which only a
# compositor can answer. WLR_BACKENDS=headless gives wlroots outputs that are
# real to every layer of the stack and attached to no hardware.
#
# The two outputs are shaped like the desk this was reported from: 1920x1200 at
# 0,0 and 2560x1080 at 1920,0.
#
# ── Why this can never touch the developer's session ─────────────────────────
#
# `apply` reaches the RUNNING compositor, and neither hyprctl nor wlr-randr
# cares what HOME is. Four independent things stop that here, in order of how
# much they would have to fail together:
#
#   1. WAYLAND_DISPLAY is the nested socket, so wlr-randr speaks to the headless
#      labwc and nothing else.
#   2. HYPRLAND_INSTANCE_SIGNATURE and NIRI_SOCKET are removed from the
#      environment, and XDG_CURRENT_DESKTOP says labwc, so the engine's
#      compositor detection cannot land on Hyprland.
#   3. PATH is prefixed with a shim directory holding a `hyprctl` that exits
#      127. Even a wrong detection reaches nothing.
#   4. HOME is a sandbox, so the generated kanshi profile and Hyprland conf are
#      written there.
#
# 3 is the one that matters. A developer running this on a Hyprland desktop has
# a live hyprctl on PATH, and the engine falls back to `pgrep -x Hyprland` when
# the environment gives no hint.
#
# ── The three phases ─────────────────────────────────────────────────────────
#
#   service   tests/display-transaction-test.qml — confirm, manual revert,
#             timeout, invalid mode, disconnected output.
#   restart   tests/display-restart-arm.qml — applies, gets SIGKILLed mid
#             countdown, and the layout has to come back anyway.
#   dialog    the whole shell — the confirmation has to be mapped on an output
#             that is still on after an apply that turned off the one the
#             settings window was on.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

for tool in quickshell labwc wlr-randr md5sum; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool not installed"; exit 0; }
done

engine="${APEX_DISPLAY_ENGINE_REAL:-/usr/libexec/apex-display-apply}"
[ -x "$engine" ] || { echo "SKIP: no display engine at $engine (it ships with APEX-OS)"; exit 0; }

# Short, because three scenarios sit through a whole one. The default of 15 is
# asserted statically by tests/check-display-transaction.sh, which can read the
# constant without waiting for it.
timeout_s="${APEX_TEST_CONFIRM_SECONDS:-5}"

sandbox="$(mktemp -d)"
cfg="$sandbox/labwc"
shim="$sandbox/shim"
mkdir -p "$cfg" "$shim" "$sandbox/home"
cp "$here/labwc-test-rc.xml" "$cfg/rc.xml"

# ── The engine wrapper ───────────────────────────────────────────────────────
# Forwards everything to the real engine. Its ONE behaviour of its own: while
# $sandbox/hide-headless-2 exists, `list` drops that output — the unplug a
# headless backend cannot perform. Every other verb, including every apply, is
# the real program with the real arguments.
cat > "$shim/apex-display-apply" <<WRAP
#!/usr/bin/env bash
if [ "\${1:-}" = "list" ] && [ -e "$sandbox/hide-headless-2" ]; then
    "$engine" list | python3 -c 'import json,sys; print(json.dumps([o for o in json.load(sys.stdin) if o["name"] != "HEADLESS-2"]))'
    exit \$?
fi
exec "$engine" "\$@"
WRAP
chmod +x "$shim/apex-display-apply"

# Nothing may reach a real Hyprland from here. See 3 above.
printf '#!/bin/sh\necho "hyprctl is not available in the display transaction test" >&2\nexit 127\n' \
    > "$shim/hyprctl"
chmod +x "$shim/hyprctl"

labwc_pid=""
shell_pid=""
cleanup() {
    [ -n "$shell_pid" ] && { kill -9 "$shell_pid" 2>/dev/null; wait "$shell_pid" 2>/dev/null; }
    [ -n "$labwc_pid" ] && { kill "$labwc_pid" 2>/dev/null; wait "$labwc_pid" 2>/dev/null; }
    rm -f "$root/.display-transaction-test.qml" "$root/.display-restart-arm.qml"
    rm -rf "$sandbox"
    return 0
}
trap cleanup EXIT INT TERM

# Real sockets only: this drops the .lock file and the per-app sockets for free.
list_sockets() {
    local f name suffix
    for f in "${XDG_RUNTIME_DIR:?}"/wayland-*; do
        [ -S "$f" ] || continue
        name="${f##*/}"
        suffix="${name#wayland-}"
        case "$suffix" in '' | *[!0-9]*) continue ;; esac
        printf '%s\n' "$name"
    done | sort
}

before="$(list_sockets)"

env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u NIRI_SOCKET -u DISPLAY \
    WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=2 WLR_RENDERER=pixman \
    XDG_CURRENT_DESKTOP=labwc:wlroots \
    labwc -C "$cfg" >"$sandbox/labwc.log" 2>&1 &
labwc_pid=$!

nested=""
for _ in $(seq 1 60); do
    nested="$(comm -13 <(echo "$before") <(list_sockets) | head -1)"
    [ -n "$nested" ] && break
    sleep 0.25
done
if [ -z "$nested" ]; then
    echo "FAIL: headless labwc did not come up"
    tail -20 "$sandbox/labwc.log"
    exit 1
fi
echo "headless labwc on $nested (labwc $(labwc --version 2>&1 | head -1))"

# The environment every process that speaks to the nested session gets. Kept as
# an array rather than a function so a backgrounded shell can `exec` it: a
# `( ... ) &` around a function call leaves $! naming the SUBSHELL, and killing
# that leaves quickshell running as an orphan. The restart scenario then passes
# because the orphan's own timer reverted — which is the thing being tested.
ENVV=(env -u HYPRLAND_INSTANCE_SIGNATURE -u NIRI_SOCKET -u DISPLAY
      WAYLAND_DISPLAY="$nested"
      XDG_CURRENT_DESKTOP=labwc:wlroots
      HOME="$sandbox/home"
      PATH="$shim:$PATH"
      APEX_DISPLAY_ENGINE="$shim/apex-display-apply"
      APEX_DISPLAY_TXN_DIR="$sandbox/txn"
      APEX_DISPLAY_CONFIRM_SECONDS="$timeout_s"
      APEX_DISPLAY_GUARD_POLL=0.1
      APEX_TEST_SANDBOX="$sandbox")

# run <args...> — anything that has to speak to the nested session.
run() { "${ENVV[@]}" "$@"; }

# Give the virtual outputs the reporter's geometry. A headless output reports
# exactly one mode, so --custom-mode is how it gets a resolution worth
# restoring; without it every output is 1280x720 and "the exact mode came back"
# is a claim about a single possibility.
run wlr-randr \
    --output HEADLESS-1 --custom-mode 1920x1200@60Hz --pos 0,0    --scale 1 \
    --output HEADLESS-2 --custom-mode 2560x1080@60Hz --pos 1920,0 --scale 1 \
    >/dev/null 2>&1 \
    || { echo "FAIL: could not shape the virtual outputs"; exit 1; }

geometry="$(run wlr-randr --json)"
case "$geometry" in
    *1920*1200*2560*1080*) echo "outputs: HEADLESS-1 1920x1200 + HEADLESS-2 2560x1080" ;;
    *) echo "FAIL: the virtual outputs are not the shape this suite assumes"; echo "$geometry"; exit 1 ;;
esac

# ── Phase 1: the service suite ───────────────────────────────────────────────
# Staged into the repo root because Quickshell refuses to import QML modules
# from outside the directory holding the entry point.
echo
echo "── service: confirm, manual revert, timeout, invalid mode, unplug ──"
cp "$here/display-transaction-test.qml" "$root/.display-transaction-test.qml"
service_log="$sandbox/service.log"
( cd "$root" && run env QT_LOGGING_RULES="qml=true" \
    timeout 300 quickshell -p "$root/.display-transaction-test.qml" ) >"$service_log" 2>&1
# Foreground, so nothing is orphaned and the exit status is the suite's own.
sed 's/\x1b\[[0-9;]*m//g' "$service_log" \
    | grep -E "PASS|FAIL|^\[|passed=" | sed 's/^/  /' || true

summary="$(grep -o "passed=[0-9]* failed=[0-9]*" "$service_log" | tail -1)"
if [ -z "$summary" ]; then
    bad "the service suite never reached its summary"
    tail -25 "$service_log" | sed 's/^/        /'
else
    svc_pass="$(echo "$summary" | sed 's/passed=\([0-9]*\).*/\1/')"
    svc_fail="$(echo "$summary" | sed 's/.*failed=\([0-9]*\)/\1/')"
    pass=$((pass + svc_pass))
    fail=$((fail + svc_fail))
fi

# ── Phase 2: the shell dies mid-countdown ────────────────────────────────────
echo
echo "── restart: SIGKILL during the countdown ──"
rm -rf "$sandbox/txn"
run wlr-randr --output HEADLESS-1 --scale 1 >/dev/null 2>&1
cp "$here/display-restart-arm.qml" "$root/.display-restart-arm.qml"
arm_log="$sandbox/arm.log"
: > "$arm_log"
( cd "$root" && exec "${ENVV[@]}" QT_LOGGING_RULES="qml=true" \
    quickshell -p "$root/.display-restart-arm.qml" ) >"$arm_log" 2>&1 &
shell_pid=$!
# $! is quickshell, not a subshell wrapping it. Asserted, because the whole
# restart scenario is a claim about killing that exact process.
kill -0 "$shell_pid" 2>/dev/null \
    && [ "$(tr -d "\0" < "/proc/$shell_pid/cmdline" 2>/dev/null | grep -c quickshell)" -ge 1 ] \
    && ok "the harness holds quickshell's own pid" \
    || bad "the harness is holding a wrapper pid; a kill would orphan the shell"

armed=0
for _ in $(seq 1 240); do
    grep -q "RESTART-READY" "$arm_log" && { armed=1; break; }
    kill -0 "$shell_pid" 2>/dev/null || break
    sleep 0.25
done

if [ "$armed" -ne 1 ]; then
    bad "the shell never reached a countdown to be killed during"
    tail -20 "$arm_log" | sed 's/^/        /'
else
    applied="$(run wlr-randr --json | python3 -c 'import json,sys; print([o["scale"] for o in json.load(sys.stdin) if o["name"]=="HEADLESS-1"][0])')"
    case "$applied" in
        2.0*) ok "the temporary layout is on screen before the shell is killed" ;;
        *)    bad "the temporary layout never reached the compositor (scale=$applied)" ;;
    esac

    # SIGKILL: no QML destructor, no onExited, no chance for the shell to tidy
    # up. Whatever restores the layout now is not the shell.
    kill -9 "$shell_pid" 2>/dev/null
    wait "$shell_pid" 2>/dev/null
    shell_pid=""
    ok "the shell is gone (SIGKILL) with the countdown still running"

    # The deadline, plus room for the engine's own run — and never less than the
    # shipped 15 seconds. A tree that ignores APEX_DISPLAY_CONFIRM_SECONDS still
    # gets its full countdown here, so "the layout did not come back" is a
    # verdict about the layout and not about how long this waited.
    sleep "$(( (timeout_s > 15 ? timeout_s : 15) + 6 ))"

    after="$(run wlr-randr --json | python3 -c 'import json,sys; print([o["scale"] for o in json.load(sys.stdin) if o["name"]=="HEADLESS-1"][0])')"
    case "$after" in
        1.0*) ok "the layout was restored by something that outlived the shell" ;;
        *)    bad "the unconfirmed layout survived the shell (scale=$after, wanted 1.0)" ;;
    esac

    state="$(cat "$sandbox/txn/state" 2>/dev/null | tr -d '[:space:]')"
    if [ "$state" = "reverted" ]; then
        ok "the guard recorded the revert"
    else
        bad "the guard did not settle the transaction (state=${state:-<none>})"
    fi
fi

# ── Phase 3: the confirmation, on an output the apply did not turn off ───────
echo
echo "── dialog: the confirmation survives losing its own output ──"
rm -rf "$sandbox/txn"
run wlr-randr \
    --output HEADLESS-1 --scale 1 \
    --output HEADLESS-2 --on --scale 1 >/dev/null 2>&1
sleep 1

shell_log="$sandbox/shell.log"
: > "$shell_log"
( cd "$root" && exec "${ENVV[@]}" QT_LOGGING_RULES="qml=true" \
    quickshell -p "$root/shell.qml" ) >"$shell_log" 2>&1 &
shell_pid=$!

loaded=0
for _ in $(seq 1 160); do
    grep -q "Configuration Loaded" "$shell_log" && { loaded=1; break; }
    kill -0 "$shell_pid" 2>/dev/null || break
    sleep 0.25
done

ipc() { ( cd "$root" && run quickshell -p "$root/shell.qml" ipc call display "$@" ) 2>&1; }

if [ "$loaded" -ne 1 ]; then
    bad "the shell did not load in the nested session"
    grep -E "ERROR|error:" "$shell_log" | head -10 | sed 's/^/        /'
else
    # Open Settings on HEADLESS-2 — the output the apply is about to switch
    # off. That is the arrangement the bug report describes: the confirmation
    # was inside this window, on this output.
    ( cd "$root" && run quickshell -p "$root/shell.qml" ipc call nexus open display ) >/dev/null 2>&1
    sleep 1

    echo "  ipc set    -> $(ipc set HEADLESS-2 enabled false)"
    echo "  ipc apply  -> $(ipc apply)"

    shown=0
    for _ in $(seq 1 80); do
        grep -q "apex-display-confirm: shown on" "$shell_log" && { shown=1; break; }
        sleep 0.25
    done

    if [ "$shown" -ne 1 ]; then
        bad "no confirmation was ever mapped after the apply"
        grep -E "apex-display|ERROR" "$shell_log" | tail -15 | sed 's/^/        /'
    else
        ok "a confirmation was mapped after the apply"
    fi

    # The output the settings window was on is gone. Quickshell.screens loses a
    # disabled output — verified, not assumed — so any surface parented there
    # went with it. The question has to be somewhere the user can still see.
    screens="$(run wlr-randr --json | python3 -c 'import json,sys; print(",".join(o["name"] for o in json.load(sys.stdin) if o["enabled"]))')"
    case "$screens" in
        HEADLESS-1) ok "the apply really did take HEADLESS-2 off" ;;
        *)          bad "HEADLESS-2 is still on; the scenario did not happen (on: $screens)" ;;
    esac

    if grep -q "apex-display-confirm: shown on HEADLESS-1" "$shell_log"; then
        ok "the confirmation is on HEADLESS-1, which the apply left on"
    else
        bad "the confirmation never reached an output that stayed on"
        grep "apex-display-confirm" "$shell_log" | sed 's/^/        /'
    fi

    status="$(ipc status)"
    echo "  ipc status -> $status"
    case "$status" in
        *"dialog on HEADLESS-1"*) ok "the shell reports the safe output it chose" ;;
        *) bad "the shell does not report a safe output for the dialog" ;;
    esac

    echo "  ipc revert -> $(ipc revert)"
    sleep 2
    back="$(run wlr-randr --json | python3 -c 'import json,sys; print(",".join(o["name"] for o in json.load(sys.stdin) if o["enabled"]))')"
    case "$back" in
        *HEADLESS-2*) ok "Revert brings the output back" ;;
        *)            bad "Revert left HEADLESS-2 off (on: $back)" ;;
    esac

    kill -9 "$shell_pid" 2>/dev/null
    wait "$shell_pid" 2>/dev/null
    shell_pid=""
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
