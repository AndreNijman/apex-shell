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
#  ── AND §43's HELP SURFACES ─────────────────────────────────────────────────
#
#  The second half of this script covers the guide and the first-run card. They
#  need a functional test rather than a grep for the same reason the rows do:
#  both are built by a lazily constructed page, and the interesting property is
#  a dismissal that OUTLIVES THE PROCESS. So the shell is started, the card is
#  observed, the dismissal is made over IPC, the shell is killed, a second shell
#  is started against the same XDG_STATE_HOME, and the card must not come back
#  while the permanent entry must.
#
#  A grep over the QML could not tell you any of that. It would pass against a
#  dismissal written to a variable.
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
log2="$(mktemp)"
qs_pid=""
daemon_pid=""
# Killed BY PID, never by name. A pkill for quickshell on a developer's machine
# takes down the shell they are working in.
cleanup() {
    [[ -n "$qs_pid" ]]     && kill "$qs_pid" 2>/dev/null
    [[ -n "$daemon_pid" ]] && kill "$daemon_pid" 2>/dev/null
    sleep 0.3
    [[ -n "$daemon_pid" ]] && kill -9 "$daemon_pid" 2>/dev/null
    rm -rf "$W"
    rm -f "$log" "$log2"
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

# ─────────────────────────────────────────────────────────────────────────────
#  §43: the help strip, and a dismissal that survives a restart
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "--- §43 Agents & Workspaces help ---"

ipc() { quickshell -p "$root/shell.qml" ipc call "$@" 2>&1; }
fail() { echo "FAIL: $1"; exit 1; }

state_file="$XDG_STATE_HOME/apex-shell/agent-help.json"

# The state directory is this run's own, so the shell under test has never been
# opened by anybody. If a dismissal is already on disk the rest of this phase
# is testing the wrong thing, so say so rather than passing quietly.
[[ ! -e "$state_file" ]] || fail "the fixture state directory already holds $state_file"

# 1. First run. Opening the tab must build BOTH surfaces.
grep -q 'AgentHelp: entry row shown' "$log" \
    || fail "the permanent help entry was never built on the Agents page"
echo "first run: entry row built"
grep -q 'AgentHelp: first-run card shown' "$log" \
    || fail "the first-run card did not appear on a machine that has never seen it"
echo "first run: first-run card shown"

# 2. The guide opens, on the section asked for, and closes again.
#    `toggle` takes no argument and `open` takes one; quickshell refuses a call
#    that omits a declared parameter, so both arities are exercised here.
out="$(ipc agent-help toggle)"
[[ "$out" == *"agent help open at start"* ]] \
    || fail "agent-help toggle did not open the guide (got: $out)"
sleep 0.6
grep -q 'AgentHelp: guide opened at start' "$log" || fail "the guide never logged an open"
echo "guide opens:          $out"

out="$(ipc agent-help open sandbox)"
[[ "$out" == *"agent help open at sandbox"* ]] \
    || fail "agent-help could not open a named section (got: $out)"
echo "named section:        $out"

out="$(ipc agent-help open nosuchsection)"
[[ "$out" == *"unknown section"* ]] \
    || fail "agent-help accepted a section that does not exist (got: $out)"

# Every id the guide draws must be one the IPC accepts, or the two lists have
# already drifted.
for s in $(ipc agent-help sections); do
    out="$(ipc agent-help open "$s")"
    [[ "$out" == *"agent help open at $s"* ]] \
        || fail "the guide lists a section the IPC rejects: $s (got: $out)"
done
echo "sections agree:       $(ipc agent-help sections)"

ipc agent-help close >/dev/null 2>&1

# 3. Dismissal reaches the disk, not just a property.
out="$(ipc agent-help dismiss)"
[[ "$out" == *"dismissed"* ]] || fail "agent-help dismiss failed (got: $out)"
for _ in $(seq 1 40); do
    [[ -f "$state_file" ]] && break
    sleep 0.1
done
[[ -f "$state_file" ]] || fail "dismissing wrote no state file at $state_file"
grep -q '"onboardingDismissed":true' "$state_file" \
    || fail "the state file does not record the dismissal: $(cat "$state_file")"
echo "dismissal persisted:  $state_file"

# 4. Restart. THIS is the assertion the whole phase exists for.
kill "$qs_pid" 2>/dev/null
for _ in $(seq 1 40); do
    kill -0 "$qs_pid" 2>/dev/null || break
    sleep 0.1
done
kill -9 "$qs_pid" 2>/dev/null
qs_pid=""
sleep 0.5

quickshell -p "$root/shell.qml" >"$log2" 2>&1 &
qs_pid=$!
for _ in $(seq 1 60); do
    grep -q "Configuration Loaded" "$log2" && break
    sleep 0.25
done
grep -q "Configuration Loaded" "$log2" || {
    echo "FAIL: the shell did not come back up"; tail -20 "$log2"; exit 1; }

quickshell -p "$root/shell.qml" ipc call dashboard-agents toggle >/dev/null 2>&1
sleep 3
quickshell -p "$root/shell.qml" ipc call dashboard-agents toggle >/dev/null 2>&1
sleep 0.5

grep -q 'AgentHelp: onboarding dismissed = true' "$log2" \
    || fail "the restarted shell did not read the dismissal back"
grep -q 'AgentHelp: entry row shown' "$log2" \
    || fail "the permanent help entry vanished after the first-run card was dismissed"
if grep -q 'AgentHelp: first-run card shown' "$log2"; then
    fail "the first-run card came back after a restart"
fi
echo "after restart:        card gone, entry still there"

# 5. And the guide is still reachable, which is the other half of §43's
#    "dismissible first-run guidance, permanently available help".
out="$(ipc agent-help open review)"
[[ "$out" == *"agent help open at review"* ]] \
    || fail "the guide stopped opening once the card was dismissed (got: $out)"
out="$(ipc agent-help state)"
[[ "$out" == *"first-run card dismissed"* ]] \
    || fail "agent-help state disagrees with the file it just read (got: $out)"
echo "still reachable:      $out"

# 6. Reset brings the card back, so a dismissal is recoverable.
ipc agent-help reset >/dev/null 2>&1
out="$(ipc agent-help state)"
[[ "$out" == *"first-run card shown"* ]] \
    || fail "agent-help reset did not restore the first-run card (got: $out)"
grep -q '"onboardingDismissed":false' "$state_file" \
    || fail "reset did not reach the state file: $(cat "$state_file")"
echo "reset restores it:    $out"

errors2="$(grep -c 'ERROR' "$log2")"
echo "--- restarted shell ERROR count: $errors2 ---"
grep -E "ERROR" "$log2" | grep -vE "$noise" | sort -u | head -10
[[ "$errors2" -eq 0 ]] || { echo "RESULT: runtime errors in the restarted shell"; exit 1; }

echo
echo "RESULT: the Agent Center rendered ${sessions} session(s) and ${requests} request(s) cleanly,"
echo "        and §43's help entry, first-run card and guide behaved across a restart"
