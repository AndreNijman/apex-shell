#!/usr/bin/env bash
# Measure what the shell costs the machine while idle, as process creations per
# second attributable to the shell itself.
#
# ── Why not `perf stat -e sched:sched_process_exec` ─────────────────────────────
# That needs perf installed and either root or perf_event_paranoid <= -1. On a
# stock APEX-OS install perf is absent and paranoid is 2, so the documented
# command cannot run at all. The kernel's own cumulative fork counter,
# /proc/stat "processes", answers exactly the same question with no privileges
# and no tooling: its delta over a window IS the number of process creations in
# that window.
#
# ── Why it is paired and alternating ──────────────────────────────────────────
# /proc/stat is system-wide, so a reading includes the whole desktop session.
# On a real machine that background rate is both large and NON-STATIONARY: a
# single "floor" window followed by a single "shell" window produces nonsense,
# including negative attributions, because the floor drifted between them.
#
# So the shell is stopped and started repeatedly, ON/OFF/ON/OFF, and the result
# is the MEDIAN of the paired differences. Slow drift affects both halves of
# each pair almost equally and cancels; the median then discards the pairs that
# straddled a burst. SIGSTOP is used rather than SIGKILL because a stopped
# process cannot fork but keeps its windows mapped and its state intact.
#
# Keep the machine otherwise quiet, including the terminal you launch this from:
# anything you do lands in the same counter.
#
# usage: tests/measure-idle-cost.sh [target] [pairs] [seconds-per-window]
#   target: "packaged" (the installed shell) or "worktree" (this checkout)
set -uo pipefail

target="${1:-worktree}"
pairs="${2:-8}"
secs="${3:-8}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# No forks inside the sampling path: $(<file) is a bash builtin read.
forks() { local s; s=$(</proc/stat); s="${s#*processes }"; echo "${s%%$'\n'*}"; }

pid=""
worktree_pid=""

cleanup() {
    [[ -n "$pid" ]] && kill -CONT "$pid" 2>/dev/null
    [[ -n "$worktree_pid" ]] && kill "$worktree_pid" 2>/dev/null
    return 0
}
trap cleanup EXIT INT TERM

case "$target" in
packaged)
    pid="$(pgrep -f 'quickshell -c /usr/share/apex-shell' | head -1 || true)"
    [[ -z "$pid" ]] && { echo "no packaged shell running"; exit 1; }
    ;;
worktree)
    mkdir -p /tmp/opencode
    quickshell -p "$repo/shell.qml" >/tmp/opencode/measure-shell.log 2>&1 &
    worktree_pid=$!
    pid=$worktree_pid
    for _ in $(seq 1 60); do
        grep -q "Configuration Loaded" /tmp/opencode/measure-shell.log 2>/dev/null && break
        sleep 0.25
    done
    grep -q "Configuration Loaded" /tmp/opencode/measure-shell.log || {
        echo "worktree shell failed to load"; tail -5 /tmp/opencode/measure-shell.log; exit 1; }

    # Build every page and popup once, then close them. The old shell built all
    # of this at startup, so this is the honest state to compare against: what
    # must differ is the RUNNING cost after everything is closed again, which is
    # what the refcount gating is for.
    if [[ "${4:-}" != "fresh" ]]; then
        for t in dashboard-home dashboard-stats dashboard-kanban dashboard-launcher \
                 dashboard-config notification-toggle clipboard-toggle \
                 wallpaper-toggle wifi-toggle bluetooth-toggle audioOut-toggle; do
            quickshell -p "$repo/shell.qml" ipc call "$t" toggle >/dev/null 2>&1
            sleep 0.4
            quickshell -p "$repo/shell.qml" ipc call "$t" toggle >/dev/null 2>&1
            sleep 0.2
        done
    fi
    ;;
*)
    echo "usage: $0 [packaged|worktree] [pairs] [seconds] [fresh]"; exit 1 ;;
esac

echo "target=$target pid=$pid pairs=$pairs window=${secs}s"
echo

diffs=()
for i in $(seq 1 "$pairs"); do
    # ON
    kill -CONT "$pid"
    sleep 2                      # let it settle after resuming
    a0=$(forks); sleep "$secs"; a1=$(forks)
    on=$(( a1 - a0 ))

    # OFF
    kill -STOP "$pid"
    sleep 1
    b0=$(forks); sleep "$secs"; b1=$(forks)
    off=$(( b1 - b0 ))

    d=$(awk -v on="$on" -v off="$off" -v s="$secs" 'BEGIN{printf "%.3f", (on-off)/s}')
    diffs+=("$d")
    printf 'pair %-2s  on=%-6s off=%-6s  attributable=%8s forks/s\n' "$i" "$on" "$off" "$d"
done

kill -CONT "$pid"

printf '%s\n' "${diffs[@]}" | sort -n | awk '
{ v[NR] = $1 }
END {
    n = NR
    med = (n % 2) ? v[(n+1)/2] : (v[n/2] + v[n/2+1]) / 2
    printf "\nmedian attributable = %.3f forks/s   (min %.3f, max %.3f, n=%d)\n", med, v[1], v[n], n
}'
