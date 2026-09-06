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
#  So this stands up a THROWAWAY agent runtime with real content — one session
#  in each of the five states the roadmap names, plus a pending privilege
#  request — then opens the page against it and fails on any runtime error.
#  Every row delegate, the request card, the sort comparator and the
#  elapsed-time formatter are instantiated with real records rather than with
#  fixtures that happen to have the right shape.
#
#  ── WHY ALL FIVE STATES, AND HOW THEY ARE INDUCED ───────────────────────────
#
#  P0-021 was a state the page could not draw, not a page it could not build,
#  and a fixture of "one running and one exited" never reaches four of the
#  seven. Every state below is produced by making the runtime observe it, never
#  by writing a record:
#
#      working             a child that prints, so the output detector sees it
#      waiting_for_user    a child that prints nothing, past the runtime's own
#                          IDLE_TO_WAITING_SECS of 10
#      permission_request  `apex agent event`, which is the ONLY way — apexd
#                          refuses to infer this one from output, on the
#                          grounds that guessing it wrong is worse than not
#                          guessing
#      complete            exit 0
#      failed              exit 3
#
#  The colours those states resolve to are measured in
#  tests/run-agent-state-render-test.sh and tests/agent-state-test.js. What is
#  proved HERE is the other half: that the runtime can actually reach all five,
#  and that the page draws each of them against a live daemon without a runtime
#  error. A colour test over states the daemon never emits would be a test of a
#  fixture.
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
#  touched. It is never `pkill`ed either: this starts a daemon on a socket of
#  its own and kills that pid, because a stray `pkill apex-agentd` in here once
#  took down a developer's live runtime mid-session.
#
#  ── TWO WAYS TO GET A COMPOSITOR ────────────────────────────────────────────
#
#  Nested, when there is a session to nest in: the real runtime dir is mirrored
#  in with symlinks, because every socket the shell needs — Wayland, pipewire,
#  the compositor's own, the session bus — lives there, and overriding it
#  wholesale would cut the shell off from the compositor it has to draw on.
#
#  Self-hosted otherwise: a headless wlroots compositor started inside the
#  private runtime dir. That is what makes this runnable on a build box with no
#  display, which is where it wants to run — a smoke test that only works on a
#  developer's own desktop is a smoke test that gets run once.
#
#  Skips cleanly without quickshell, without any compositor at all, or without
#  the runtime built.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
# The OS repo sits beside the shell checkout in the normal layout.
osroot="${APEX_OS_ROOT:-$(cd "$root/../apex-os" 2>/dev/null && pwd)}"

command -v quickshell >/dev/null 2>&1 || { echo "SKIP: quickshell not installed"; exit 0; }
[[ -n "$osroot" && -d "$osroot/apexd" ]] || { echo "SKIP: apex-os checkout not found (set APEX_OS_ROOT)"; exit 0; }

nested=0
host_comp=""
if [[ -n "${WAYLAND_DISPLAY:-}" && -n "${XDG_RUNTIME_DIR:-}" ]]; then
    nested=1
else
    for c in labwc sway; do
        command -v "$c" >/dev/null 2>&1 && { host_comp="$c"; break; }
    done
    [[ -n "$host_comp" ]] || {
        echo "SKIP: no Wayland session and no headless compositor to host one"; exit 0; }
fi

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
comp_pid=""
# Killed BY PID, never by name. A pkill for quickshell on a developer's machine
# takes down the shell they are working in.
cleanup() {
    [[ -n "$qs_pid" ]]     && kill "$qs_pid" 2>/dev/null
    [[ -n "$daemon_pid" ]] && kill "$daemon_pid" 2>/dev/null
    [[ -n "$comp_pid" ]]   && kill "$comp_pid" 2>/dev/null
    sleep 0.3
    [[ -n "$daemon_pid" ]] && kill -9 "$daemon_pid" 2>/dev/null
    [[ -n "$comp_pid" ]]   && kill -9 "$comp_pid" 2>/dev/null
    rm -rf "$W"
    rm -f "$log" "$log2"
    return 0
}
trap cleanup EXIT INT TERM

# ── an isolated runtime that can still reach a compositor ────────────────────
REAL_RUNTIME="${XDG_RUNTIME_DIR:-}"
export XDG_RUNTIME_DIR="$W/run"
export XDG_STATE_HOME="$W/state"
export XDG_CONFIG_HOME="$W/config"
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME"
chmod 0700 "$XDG_RUNTIME_DIR"

if [[ "$nested" -eq 1 ]]; then
    # Everything in the real runtime dir is mirrored in, EXCEPT apex-agentd —
    # which is the one thing being replaced.
    #
    # Mirrored wholesale rather than picked from a list. The first version
    # linked only the Wayland socket, and the shell then failed on pipewire
    # (errno 112) and on Hyprland's socket, both of which also live here. Every
    # such failure looks like a QML fault in the log, so a list that has to be
    # kept complete is a list that will send someone debugging the wrong file.
    shopt -s nullglob dotglob
    for entry in "$REAL_RUNTIME"/*; do
        name="$(basename "$entry")"
        [[ "$name" == "apex-agentd" ]] && continue
        ln -sfn "$entry" "$XDG_RUNTIME_DIR/$name"
    done
    shopt -u nullglob dotglob
    [[ -e "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]] || {
        echo "SKIP: the Wayland socket is not in XDG_RUNTIME_DIR"; exit 0; }
    echo "host: nested in the running session ($WAYLAND_DISPLAY)"
else
    unset WAYLAND_DISPLAY DISPLAY
    export WLR_BACKENDS=headless
    export WLR_LIBINPUT_NO_DEVICES=1
    export WLR_RENDERER=pixman
    export XDG_SESSION_TYPE=wayland
    export QT_QPA_PLATFORM=wayland
    case "$host_comp" in
        labwc)
            mkdir -p "$XDG_CONFIG_HOME/labwc"
            cp "$here/labwc-test-rc.xml" "$XDG_CONFIG_HOME/labwc/rc.xml" 2>/dev/null || true
            "$host_comp" > "$W/comp.log" 2>&1 & ;;
        sway)
            printf 'output HEADLESS-1 mode 1920x1080\n' > "$W/sway.cfg"
            "$host_comp" -c "$W/sway.cfg" > "$W/comp.log" 2>&1 & ;;
    esac
    comp_pid=$!
    for _ in $(seq 1 60); do
        for f in "$XDG_RUNTIME_DIR"/wayland-*; do
            [[ -S "$f" ]] || continue
            sock_name="$(basename "$f")"
            export WAYLAND_DISPLAY="$sock_name"
            break
        done
        [[ -n "${WAYLAND_DISPLAY:-}" ]] && break
        sleep 0.25
    done
    [[ -n "${WAYLAND_DISPLAY:-}" ]] || {
        echo "SKIP: $host_comp did not come up headless"; tail -5 "$W/comp.log"; exit 0; }
    echo "host: $host_comp headless on $WAYLAND_DISPLAY"
fi
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

run_agent() { apex agent run --agent generic --sandbox unrestricted \
                  --cwd "$W/proj" -d -- /bin/sh -c "$1" 2>/dev/null; }

# Ids are printed by `apex agent run -d`; captured so the event below can be
# aimed at one session rather than at whatever happens to be newest.
# Named rather than discarded: the names are what make the five states below
# readable, and two of them are never referenced again on purpose — the session
# only has to exist and stay in that state for the page to draw it.
# shellcheck disable=SC2034
id_working="$(run_agent 'while :; do echo working; sleep 1; done' | grep -o '[0-9]\+' | head -1)"
# shellcheck disable=SC2034
id_waiting="$(run_agent 'sleep 600'                                | grep -o '[0-9]\+' | head -1)"
id_blocked="$(run_agent 'sleep 600'                                | grep -o '[0-9]\+' | head -1)"
run_agent 'exit 0' >/dev/null
run_agent 'exit 3' >/dev/null

# The only way to reach permission_request: apexd will not infer it. See
# apex-agent-core/src/session.rs — "a wrong guess here is worse than no guess".
[[ -n "$id_blocked" ]] && apex agent event permission_request \
    --session "$id_blocked" --detail "install clang" >/dev/null 2>&1

apex request ask install clang --reason "Required to compile the project" \
    --no-wait >/dev/null 2>&1

# waiting_for_user is a TIMEOUT, not an event: the runtime promotes a silent
# session after IDLE_TO_WAITING_SECS. Waiting it out is the only honest way to
# get one, and a fixture that published the state instead would be testing the
# publisher rather than the detector.
echo "waiting out the runtime's idle-to-waiting timer..."
sleep 13

listing="$(apex agent list --all --json 2>/dev/null)"
sessions="$(printf '%s' "$listing" | grep -c '"id"')"
requests="$(apex request pending --json 2>/dev/null | grep -c '"id"')"

missing=""
for st in working waiting_for_user permission_request complete failed; do
    grep -q "\"$st\"" <<<"$listing" || missing="$missing $st"
done
echo "fixture: ${sessions} session(s), ${requests} pending request(s)"
printf 'fixture states:'
for st in working waiting_for_user permission_request complete failed; do
    grep -q "\"$st\"" <<<"$listing" && printf ' %s' "$st"
done
printf '\n'
[[ "$sessions" -ge 5 ]] || { echo "FAIL: the fixture sessions were not created"; exit 1; }
[[ "$requests" -ge 1 ]] || { echo "FAIL: the fixture request was not created"; exit 1; }
[[ -z "$missing" ]] || {
    echo "FAIL: the runtime never reported:$missing"
    echo "      the page cannot be shown drawing a state the daemon does not emit"
    exit 1; }

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

# ── what counts as an error ──────────────────────────────────────────────────
#
# Absent hardware and absent session services are not shell faults. A build box
# has no pipewire and no notification daemon, and this test exists to find QML
# errors — counting the machine's own missing pieces would make it unrunnable
# exactly where it is most useful.
#
# Matched on the logging CATEGORY, not on a word. Bare `pipewire` also hides
#   ERROR quickshell.qml: .../AudioService.qml:33: TypeError … the pipewire sink
# — one of the shell's own QML errors, filtered out because its message happens
# to contain the word. That is the only class of failure this script is here to
# find, so the filter names the category the absent socket logs under:
#   ERROR quickshell.service.pipewire.loop: Failed to connect pipewire context. Errno: 112
# which is the line, verbatim, that made this script red on the tip.
noise='qt.qpa.wayland.textinput|Could not register notification server'
noise="$noise"'|Registration will be attempted|quickshell\.service\.pipewire'

# ONE definition of the count, used for both shells.
#
# There were two, written out separately, and the second one had no filter:
#
#     errors2="$(grep -c 'ERROR' "$log2")"
#
# so the restarted shell failed on the very pipewire line the first shell was
# allowed to log — while the diagnostics printed under it, being filtered,
# listed nothing. A red gate everybody knows to ignore is worse than no gate.
# The comment on the first count already warned about exactly this divergence;
# the fix is for there to be nothing left to diverge.
count_errors() { grep -E 'ERROR' "$1" | grep -cvE "$noise"; }
show_errors()  { grep -E "$2" "$1" | grep -vE "$noise" | sort -u; }

# ── and a proof that the filter is specific ──────────────────────────────────
#
# The filter decides whether this whole script can fail, so it is checked
# against labelled lines before it is used on a real log. It costs nothing and
# it runs even on a machine where the rest of this script SKIPs.
selftest_noise() {
    local t rc=0
    t="$(mktemp)"
    cat > "$t" <<'LOG'
 ERROR quickshell.service.pipewire.loop: Failed to connect pipewire context. Errno: 112
 ERROR quickshell.qml: Could not register notification server
 WARN qt.qpa.wayland.textinput: no text input protocol
LOG
    [[ "$(count_errors "$t")" -eq 0 ]] || { echo "FAIL: the noise filter counts a build box's absent services"; rc=1; }
    cat >> "$t" <<'LOG'
 ERROR quickshell.qml: file:///x/AudioService.qml:33: TypeError: null is not an object, setting the pipewire sink
LOG
    [[ "$(count_errors "$t")" -eq 1 ]] || { echo "FAIL: a QML fault whose message says pipewire is filtered away"; rc=1; }
    cat >> "$t" <<'LOG'
 ERROR quickshell.qml: file:///x/SessionRow.qml:12: Unable to assign [undefined] to QColor
LOG
    [[ "$(count_errors "$t")" -eq 2 ]] || { echo "FAIL: an ordinary QML error is not counted"; rc=1; }
    rm -f "$t"
    return "$rc"
}
selftest_noise || { echo "RESULT: the error filter does not do what it claims"; exit 1; }
echo "error filter:         self-checked (3 cases)"

echo "--- diagnostics ---"
show_errors "$log" "ERROR|WARN" | head -20

errors="$(count_errors "$log")"
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
[[ "$count" -ge 5 ]] || {
    echo "FAIL: the page saw $count session(s), expected at least 5 — one per state"
    exit 1; }

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

errors2="$(count_errors "$log2")"
echo "--- restarted shell ERROR count: $errors2 ---"
show_errors "$log2" "ERROR" | head -10
[[ "$errors2" -eq 0 ]] || { echo "RESULT: runtime errors in the restarted shell"; exit 1; }

echo
echo "RESULT: the Agent Center rendered ${sessions} session(s) and ${requests} request(s) cleanly,"
echo "        and §43's help entry, first-run card and guide behaved across a restart"
