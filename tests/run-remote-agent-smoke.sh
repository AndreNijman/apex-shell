#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Functional smoke test for §20's remote agent status (P2 phase 9.3).
#
#  Loading the shell proves the QML compiles. It does NOT prove this works, for
#  the same reason run-agent-center-smoke.sh gives: the Agent Center is lazily
#  built, so a broken binding inside it ships silently until somebody opens the
#  tab — and a section with no registered devices exercises only the path where
#  it does not exist, which was always going to work.
#
#  So this stands up FOUR fixture devices covering all four dispositions, and
#  then measures three things the design claims:
#
#      1. only devices a probe has shown to have the agent runtime are queried
#         — an unprobed device costs zero ssh connections
#      2. closing the page stops the queries COMPLETELY, not "slows them down"
#      3. tabbing in and out repeatedly does not open a connection per toggle
#
#  ── How the remote side is faked, and what is real ──────────────────────────
#
#  `apex host` does not exist in every apex-os checkout (it lands on the P2
#  branch), and `apex host run` execs real ssh to a real machine, which a test
#  cannot have. So a shim `apex` goes first on PATH. It implements exactly two
#  things and delegates everything else to the real binary by absolute path:
#
#      host list --json   prints the fixture registry
#      host run N -- ...  katana → runs the argv against the REAL local runtime
#                         laptop → exits 255, which is what ssh returns when it
#                                  cannot get there
#
#  Everything the shell then parses as "the desktop's sessions" is genuine
#  SessionInfo JSON produced by a real apex-agentd from real sessions — not a
#  hand-written fixture of what a session might look like. The registry JSON is
#  the one hand-written part, and its shape is transcribed from the OS side's
#  own serialiser rather than imagined: apexd/apex/src/host.rs builds that
#  object in its `HostCmd::List { json: true }` arm and apexd-core/src/host.rs
#  declares which HostCaps keys are omitted when absent. Read on the apex-os
#  branch `p2/base` at commit 77cbf68.
#
#  The shim records every invocation with one argument per tab, which is also
#  how the argv-boundary assertion is made: `apex host run` must receive the
#  remote command as separate arguments, because that is the whole reason the
#  shell calls `apex host run` instead of building an ssh line itself.
#
#  ── What this does NOT verify ───────────────────────────────────────────────
#
#  It does not look at pixels. "The rows rendered correctly" is asserted only
#  as "every delegate was instantiated against real records and nothing errored
#  or warned", which is the same bar run-agent-center-smoke.sh sets.
#
#  ISOLATION. The daemon runs with its own XDG_RUNTIME_DIR, XDG_STATE_HOME and
#  XDG_CONFIG_HOME, so the developer's own sessions and their real
#  ~/.config/apex/hosts.toml are never read or written. The real runtime dir is
#  mirrored in with symlinks, because every socket the shell needs to draw at
#  all lives there.
#
#  Skips cleanly without a Wayland session or without the runtime built.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
osroot="${APEX_OS_ROOT:-$(cd "$root/../apex-os" 2>/dev/null && pwd)}"

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
# want <description> <command...>. Deliberately not `cmd; check $?`: ShellCheck
# SC2319 is right that a $? read after a `[ ]` is a trap waiting for someone to
# insert a line between them. Same convention as check-compositor-backends.sh.
want() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

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
REAL_APEX="$BIN/apex"

W="$(mktemp -d)"
log="$W/shell.log"
qs_pid=""
daemon_pid=""
cleanup() {
    [[ -n "$qs_pid" ]]     && kill "$qs_pid" 2>/dev/null
    [[ -n "$daemon_pid" ]] && kill "$daemon_pid" 2>/dev/null
    sleep 0.3
    [[ -n "$daemon_pid" ]] && kill -9 "$daemon_pid" 2>/dev/null
    rm -rf "$W"
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

shopt -s nullglob dotglob
for entry in "$REAL_RUNTIME"/*; do
    name="$(basename "$entry")"
    [[ "$name" == "apex-agentd" ]] && continue
    ln -sfn "$entry" "$XDG_RUNTIME_DIR/$name"
done
shopt -u nullglob dotglob
[[ -e "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]] || {
    echo "SKIP: the Wayland socket is not in XDG_RUNTIME_DIR"; exit 0; }

"$BIN/apex-agentd" > "$W/agentd.log" 2>&1 &
daemon_pid=$!
for _ in $(seq 1 50); do
    [[ -S "$XDG_RUNTIME_DIR/apex-agentd/control.sock" ]] && break
    sleep 0.1
done
[[ -S "$XDG_RUNTIME_DIR/apex-agentd/control.sock" ]] || {
    echo "FAIL: the agent runtime never came up"; tail -10 "$W/agentd.log"; exit 1; }

# ── real sessions, so the "remote" device answers with real records ──────────
mkdir -p "$W/proj"
git -C "$W/proj" init -q 2>/dev/null
git -C "$W/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null

"$REAL_APEX" agent run --agent generic --sandbox unrestricted --cwd "$W/proj" -d \
    -- /bin/sh -c 'sleep 600' >/dev/null 2>&1
"$REAL_APEX" agent run --agent generic --sandbox unrestricted --cwd "$W/proj" -d \
    -- /bin/sh -c 'exit 3' >/dev/null 2>&1
sleep 1
sessions="$("$REAL_APEX" agent list --all --json 2>/dev/null | grep -c '"id"')"
echo "fixture: ${sessions} real session(s) behind the fake remote"
[[ "$sessions" -ge 2 ]] || { echo "FAIL: the fixture sessions were not created"; exit 1; }

# ── the fixture registry ─────────────────────────────────────────────────────
# Four devices, one per disposition the design distinguishes.
export APEX_SMOKE_FIXTURE="$W/hosts.json"
cat > "$APEX_SMOKE_FIXTURE" <<'JSON'
{
  "katana": {
    "ssh": "katana",
    "port": null,
    "note": "build box",
    "caps": {
      "probed_at": 4000000000,
      "apex_version": "0.1.0",
      "variant": "daily",
      "cpus": 20,
      "memory_mib": 63488,
      "gpus": ["NVIDIA GeForce RTX 3070 Mobile"],
      "accel": ["cuda", "vulkan"],
      "agentd": true,
      "ai": true,
      "podman": true
    }
  },
  "laptop": {
    "ssh": "andre@10.0.0.5",
    "port": 2222,
    "note": null,
    "caps": {
      "probed_at": 4000000000,
      "apex_version": "0.1.0",
      "variant": "daily",
      "cpus": 8,
      "memory_mib": 16384,
      "agentd": true,
      "ai": false,
      "podman": true
    }
  },
  "fileserver": {
    "ssh": "fileserver",
    "port": null,
    "note": "no apex on it",
    "caps": {
      "probed_at": 4000000000,
      "os": "Fedora Linux 43",
      "cpus": 4,
      "memory_mib": 8192,
      "agentd": false,
      "ai": false,
      "podman": true
    }
  },
  "newbox": { "ssh": "newbox", "port": null, "note": null, "caps": null }
}
JSON

# ── the shim ─────────────────────────────────────────────────────────────────
export APEX_SMOKE_CALLS="$W/calls.log"
export APEX_SMOKE_REAL="$REAL_APEX"
: > "$APEX_SMOKE_CALLS"

mkdir -p "$W/bin"
cat > "$W/bin/apex" <<'SHIM'
#!/usr/bin/env bash
# One line per invocation, one argument per tab. The tabs are what lets the
# argv-boundary assertion be made at all: `ssh host a b c` joins its remote
# arguments with spaces, which is the bug `apex host run` exists to avoid, so a
# log that also joined them could not tell the two apart.
{ printf '%s\t' "$@"; printf '\n'; } >> "$APEX_SMOKE_CALLS"

if [[ "${1:-}" == "host" && "${2:-}" == "list" ]]; then
    cat "$APEX_SMOKE_FIXTURE"
    exit 0
fi

if [[ "${1:-}" == "host" && "${2:-}" == "run" ]]; then
    name="${3:-}"
    shift 3 || true
    [[ "${1:-}" == "--" ]] && shift
    case "$name" in
        katana)
            # Reachable: run the argv against the real local runtime, so what
            # comes back is genuine SessionInfo JSON.
            #
            # argv[0] is `apex` — the name the command has on the FAR side —
            # and it is rewritten to the real binary's absolute path rather
            # than exec'd as-is. `exec "$@"` would find this shim again on
            # PATH and recurse; `exec "$REAL" "$@"` would run
            # `apex apex agent list`. The rewrite keeps every later argument
            # exactly where it was, which is what the boundary assertion below
            # is checking.
            cmd=("$@")
            [[ "${cmd[0]:-}" == "apex" ]] && cmd[0]="$APEX_SMOKE_REAL"
            exec "${cmd[@]}" ;;
        laptop)
            # ssh's own exit code for "could not get there". A laptop off the
            # LAN is the normal case, not an error case.
            exit 255 ;;
        *)
            exit 255 ;;
    esac
fi

exec "$APEX_SMOKE_REAL" "$@"
SHIM
chmod +x "$W/bin/apex"
export PATH="$W/bin:$BIN:$PATH"

# ── the shell ────────────────────────────────────────────────────────────────
quickshell -p "$root/shell.qml" >"$log" 2>&1 &
qs_pid=$!
for _ in $(seq 1 60); do
    grep -q "Configuration Loaded" "$log" && break
    sleep 0.25
done
grep -q "Configuration Loaded" "$log" || {
    echo "FAIL: the shell never loaded"; tail -20 "$log"; exit 1; }

toggle() { quickshell -p "$root/shell.qml" ipc call dashboard-agents toggle >/dev/null 2>&1; }
runs()   { grep -c $'^host\trun\t' "$APEX_SMOKE_CALLS"; }
lists()  { grep -c $'^host\tlist\t' "$APEX_SMOKE_CALLS"; }
runs_to() { grep -c "^host"$'\t'"run"$'\t'"$1"$'\t' "$APEX_SMOKE_CALLS"; }

# Nothing may have been queried before the page was ever opened. The service is
# a lazily constructed singleton, so this also asserts that merely loading the
# shell does not construct it.
want "no device is queried before the page is opened" test "$(runs)" -eq 0
want "the registry is not even read before the page is opened" test "$(lists)" -eq 0

# ── phase 1: one sweep ───────────────────────────────────────────────────────
toggle
rc=$?
[[ "$rc" -eq 0 ]] || { echo "FAIL: IPC call to dashboard-agents failed (rc=$rc)"; exit 1; }
sleep 4
toggle
sleep 0.6

p1_lists="$(lists)"
p1_runs="$(runs)"
echo "phase 1: ${p1_lists} registry read(s), ${p1_runs} device quer(ies)"

want "opening the page reads the registry"            test "$p1_lists" -ge 1
want "the device with a proven runtime is queried"    test "$(runs_to katana)" -ge 1
want "a second device with a proven runtime is too"   test "$(runs_to laptop)" -ge 1

# THE "do not invent capability" ASSERTION.
#
# fileserver was probed and reported agentd=false: known, so it is not asked.
# newbox has caps=null: nothing is known about it, and guessing would cost an
# 8-second ssh timeout per sweep to discover something `apex host probe`
# answers properly and once. Neither may be queried.
want "a device known NOT to have the runtime is never queried" \
    test "$(runs_to fileserver)" -eq 0
want "a device that has NEVER been probed is never queried" \
    test "$(runs_to newbox)" -eq 0

# The argv boundaries survive. This is the reason the shell calls
# `apex host run <name> -- <argv…>` rather than assembling an ssh command line.
# Built with $'\t' rather than typed as literal tabs: a literal tab in a
# source file is one editor away from becoming spaces, and this assertion
# is entirely about the difference between a tab and a space.
expected_argv="host"$'\t'"run"$'\t'"katana"$'\t'"--"$'\t'"apex"$'\t'"agent"$'\t'"list"$'\t'"--all"$'\t'"--json"$'\t'
want "the remote argv arrives as separate arguments" \
    grep -qF "$expected_argv" "$APEX_SMOKE_CALLS"

# The page must have actually READ the remote, not merely rendered without
# complaint. A section that never queried anything produces no errors at all
# and would otherwise pass.
seen="$(grep -o 'RemoteAgentService: [0-9]* host(s), [0-9]* with the agent runtime, [0-9]* reachable, [0-9]* remote session(s)' "$log" | head -1)"
if [[ -z "$seen" ]]; then
    bad "the page announced no sweep at all"
else
    ok "the page announced its sweep"
    echo "        observed: $seen"
    read -r n_hosts n_rt n_reach n_sess <<<"$(printf '%s' "$seen" | grep -oE '[0-9]+' | tr '\n' ' ')"
    want "all four registered devices were seen"       test "$n_hosts" -eq 4
    want "exactly two have a proven agent runtime"     test "$n_rt" -eq 2
    want "exactly one answered"                        test "$n_reach" -eq 1
    want "the answering device's real sessions arrived" test "$n_sess" -ge 2
fi

# ── phase 2: refcount churn must not be one connection per toggle ───────────
# AgentService refreshes on every refCount>0 transition, which is right for a
# local subprocess and a defect for an ssh. Six toggles inside the anti-churn
# window must not produce six sweeps.
before_lists="$(lists)"
before_runs="$(runs)"
for _ in 1 2 3; do toggle; sleep 0.15; toggle; sleep 0.15; done
sleep 1.2
churn_lists=$(( $(lists) - before_lists ))
churn_runs=$(( $(runs) - before_runs ))
echo "phase 2: 6 toggles added ${churn_lists} registry read(s) and ${churn_runs} device quer(ies)"
want "six rapid toggles do not sweep six times" test "$churn_lists" -le 2
want "six rapid toggles do not query per toggle" test "$churn_runs" -le 4

# ── phase 3: idle is zero, measured ─────────────────────────────────────────
# The page is closed. The sweep interval is 15 s, so a window comfortably
# longer than that must add nothing at all. This is the assertion the whole
# service is shaped around, and it is a measurement rather than a code review.
idle_lists="$(lists)"
idle_runs="$(runs)"
echo "phase 3: waiting 22s with the page closed (sweep interval is 15s)..."
sleep 22
after_lists="$(lists)"
after_runs="$(runs)"
echo "phase 3: registry reads ${idle_lists} → ${after_lists}, device queries ${idle_runs} → ${after_runs}"
want "no device is queried while nobody is looking" test "$after_runs" -eq "$idle_runs"
want "the registry is not even read while nobody is looking" \
    test "$after_lists" -eq "$idle_lists"

# ── the shell stayed clean throughout ───────────────────────────────────────
kill "$qs_pid" 2>/dev/null
qs_pid=""
sleep 0.5

echo "--- diagnostics ---"
noise='qt.qpa.wayland.textinput|Could not register notification server|Registration will be attempted'
grep -E "ERROR|WARN" "$log" | grep -vE "$noise" | sort -u | head -20
errors="$(grep -c 'ERROR' "$log")"
echo "--- ERROR count: $errors ---"
want "no runtime errors while the remote rows were built" test "$errors" -eq 0

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
