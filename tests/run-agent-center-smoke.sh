#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Functional smoke test for the Agent Center (roadmap §3/§7).
#
#  Loading the shell proves the QML compiles. It does NOT prove the page works:
#  dashboard pages are lazily constructed, so a broken binding inside one ships
#  silently until somebody opens the tab. And an Agent Center with no sessions
#  exercises only its empty state — which is the one path that was always going
#  to work.
#
#  So this stands up a THROWAWAY agent runtime with real content:
#
#      * one running session
#      * one exited-non-zero session
#      * one pending privilege request
#
#  then opens the page against it and fails on any runtime error. Every row
#  delegate, the request card, the sort comparator and the elapsed-time
#  formatter are instantiated with real records rather than with fixtures that
#  happen to have the right shape.
#
#  ISOLATION. The daemon runs with its own XDG_RUNTIME_DIR and XDG_STATE_HOME,
#  so the developer's own sessions, requests, grants and audit log are never
#  touched. The real runtime dir is mirrored in with symlinks — every socket the
#  shell needs (Wayland, pipewire, Hyprland, the session bus) lives there, so
#  overriding it wholesale would cut the shell off from the compositor it has to
#  draw on.
#
#  Skips cleanly without a Wayland session or without the runtime built.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
# The OS repo sits beside the shell checkout in the normal layout.
osroot="${APEX_OS_ROOT:-$(cd "$root/../apex-os" 2>/dev/null && pwd)}"

command -v quickshell >/dev/null 2>&1 || { echo "SKIP: quickshell not installed"; exit 0; }
[[ -n "${WAYLAND_DISPLAY:-}" ]] || { echo "SKIP: no WAYLAND_DISPLAY"; exit 0; }
[[ -n "${XDG_RUNTIME_DIR:-}" ]] || { echo "SKIP: no XDG_RUNTIME_DIR"; exit 0; }
[[ -n "$osroot" && -d "$osroot/apexd" ]] || { echo "SKIP: apex-os checkout not found (set APEX_OS_ROOT)"; exit 0; }

BIN="$osroot/apexd/target/debug"
if [[ ! -x "$BIN/apex-agentd" || ! -x "$BIN/apex" ]]; then
    echo "building the runtime..."
    cargo build --manifest-path "$osroot/apexd/Cargo.toml" \
        --bin apex-agentd --bin apex >/dev/null 2>&1 \
        || { echo "SKIP: cannot build the agent runtime"; exit 0; }
fi

W="$(mktemp -d)"
log="$(mktemp)"
qs_pid=""
daemon_pid=""
cleanup() {
    [[ -n "$qs_pid" ]]     && kill "$qs_pid" 2>/dev/null
    [[ -n "$daemon_pid" ]] && kill "$daemon_pid" 2>/dev/null
    sleep 0.3
    [[ -n "$daemon_pid" ]] && kill -9 "$daemon_pid" 2>/dev/null
    rm -rf "$W"
    rm -f "$log"
    return 0
}
trap cleanup EXIT INT TERM

# ── an isolated runtime that can still reach the compositor ──────────────────
REAL_RUNTIME="$XDG_RUNTIME_DIR"
export XDG_RUNTIME_DIR="$W/run"
export XDG_STATE_HOME="$W/state"
export XDG_CONFIG_HOME="$W/config"
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME"
chmod 0700 "$XDG_RUNTIME_DIR"

# Everything in the real runtime dir is mirrored in, EXCEPT apex-agentd — which
# is the one thing being replaced.
#
# Mirrored wholesale rather than picked from a list. The first version linked
# only the Wayland socket, and the shell then failed on pipewire (errno 112) and
# on Hyprland's socket, both of which also live here. Every such failure looks
# like a QML fault in the log, so a list that has to be kept complete is a list
# that will send someone debugging the wrong file.
shopt -s nullglob dotglob
for entry in "$REAL_RUNTIME"/*; do
    name="$(basename "$entry")"
    [[ "$name" == "apex-agentd" ]] && continue
    ln -sfn "$entry" "$XDG_RUNTIME_DIR/$name"
done
shopt -u nullglob dotglob
[[ -e "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]] || {
    echo "SKIP: the Wayland socket is not in XDG_RUNTIME_DIR"; exit 0; }
# The shell talks to the runtime by running `apex`, so the dev build has to win.
export PATH="$BIN:$PATH"

"$BIN/apex-agentd" > "$W/agentd.log" 2>&1 &
daemon_pid=$!
for _ in $(seq 1 50); do
    [[ -S "$XDG_RUNTIME_DIR/apex-agentd/control.sock" ]] && break
    sleep 0.1
done
[[ -S "$XDG_RUNTIME_DIR/apex-agentd/control.sock" ]] || {
    echo "FAIL: the agent runtime never came up"; tail -10 "$W/agentd.log"; exit 1; }

# ── content, so the page draws rows and not its empty state ─────────────────
mkdir -p "$W/proj"
git -C "$W/proj" init -q 2>/dev/null
git -C "$W/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null

apex agent run --agent generic --sandbox unrestricted --cwd "$W/proj" -d \
    -- /bin/sh -c 'sleep 600' >/dev/null 2>&1
apex agent run --agent generic --sandbox unrestricted --cwd "$W/proj" -d \
    -- /bin/sh -c 'exit 3' >/dev/null 2>&1
sleep 1
apex request ask install clang --reason "Required to compile the project" \
    --no-wait >/dev/null 2>&1

sessions="$(apex agent list --all --json 2>/dev/null | grep -c '"id"')"
requests="$(apex request pending --json 2>/dev/null | grep -c '"id"')"
echo "fixture: ${sessions} session(s), ${requests} pending request(s)"
[[ "$sessions" -ge 2 ]] || { echo "FAIL: the fixture sessions were not created"; exit 1; }
[[ "$requests" -ge 1 ]] || { echo "FAIL: the fixture request was not created"; exit 1; }

# ── the shell ────────────────────────────────────────────────────────────────
quickshell -p "$root/shell.qml" >"$log" 2>&1 &
qs_pid=$!
for _ in $(seq 1 60); do
    grep -q "Configuration Loaded" "$log" && break
    sleep 0.25
done
grep -q "Configuration Loaded" "$log" || {
    echo "FAIL: the shell never loaded"; tail -20 "$log"; exit 1; }

# Open the page, leave it up long enough for a poll to land and the rows to be
# built from real data, then close it.
quickshell -p "$root/shell.qml" ipc call dashboard-agents toggle >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 0 ]] || { echo "FAIL: IPC call to dashboard-agents failed (rc=$rc)"; exit 1; }
echo "dashboard-agents      rc=0"
sleep 3.5
quickshell -p "$root/shell.qml" ipc call dashboard-agents toggle >/dev/null 2>&1
sleep 0.5

echo "--- diagnostics ---"
noise='qt.qpa.wayland.textinput|Could not register notification server|Registration will be attempted'
grep -E "ERROR|WARN" "$log" | grep -vE "$noise" | sort -u | head -20

errors="$(grep -c 'ERROR' "$log")"
echo "--- ERROR count: $errors ---"
[[ "$errors" -eq 0 ]] || { echo "RESULT: runtime errors present"; exit 1; }

# The page must have actually READ the runtime, not merely rendered without
# complaint. AgentService announces its first successful poll, so this asserts
# the data path rather than the absence of errors — a page that never polled
# produces no errors at all and would otherwise pass.
seen="$(grep -o 'AgentService: runtime up, [0-9]* session' "$log" | head -1)"
if [[ -z "$seen" ]]; then
    echo "FAIL: the page never polled the runtime (no AgentService announcement)"
    exit 1
fi
echo "observed: $seen(s)"
count="$(printf '%s' "$seen" | grep -o '[0-9]\+')"
[[ "$count" -ge 2 ]] || {
    echo "FAIL: the page saw $count session(s), expected at least 2"; exit 1; }

echo "RESULT: the Agent Center rendered ${sessions} session(s) and ${requests} request(s) cleanly"
