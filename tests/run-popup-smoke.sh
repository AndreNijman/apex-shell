#!/usr/bin/env bash
# Functional smoke test: start this checkout's shell, drive every page and popup
# open and closed over IPC, and fail on any runtime error.
#
# This exists because the dashboard pages and the popup fleet are lazily
# constructed. Loading the shell proves the QML compiles; it does NOT prove a
# page works, because nothing instantiates it until it is first shown. Without
# this, a broken binding inside a lazily-loaded page ships silently.
#
# ── On a compositor of its own, which is not a detail here ───────────────────
#
# This runner opens the entire shell — a bar, a dock, every popup in the fleet
# and seven settings pages — and it used to open all of that on the inherited
# WAYLAND_DISPLAY. That is the single worst offender in tests/: on a
# workstation it puts the whole shell on top of whatever the person running it
# was doing, twice per target, for about a minute.
#
# It now runs on a headless labwc from tests/lib/headless.sh with a private
# HOME and a private XDG_RUNTIME_DIR. The private runtime dir is doing real work
# beyond politeness: the shell looks for apex-agentd's control socket there, and
# on the ambient one it would find the live daemon and start driving the agent
# sessions somebody has open.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"

headless_require quickshell

qs_pid=""
cleanup() {
    [[ -n "$qs_pid" ]] && kill "$qs_pid" 2>/dev/null
    headless_cleanup
}
trap cleanup EXIT INT TERM

headless_begin
headless_start || exit 0

log="$HEADLESS_W/shell.log"
quickshell -p "$root/shell.qml" >"$log" 2>&1 &
qs_pid=$!

for _ in $(seq 1 60); do
    grep -q "Configuration Loaded" "$log" && break
    sleep 0.25
done
grep -q "Configuration Loaded" "$log" || {
    echo "FAIL: the shell never loaded"; tail -20 "$log"; exit 1; }

targets=(
    dashboard-home dashboard-stats dashboard-agents dashboard-kanban
    dashboard-launcher
    dashboard-config notification-toggle clipboard-toggle wallpaper-toggle
    wifi-toggle bluetooth-toggle audioOut-toggle
    context-menu
)

# The Config tab's own sub-pages are lazily built as well, and toggling the tab
# only ever builds its FIRST page. Nexus addresses each by id, so every settings
# page gets instantiated — which is the only way a broken binding inside one is
# caught before a user finds it.
nexus_pages=(appearance layout input display keybinds data privacy misc)
for p in "${nexus_pages[@]}"; do
    out="$(quickshell -p "$root/shell.qml" ipc call nexus open "$p" 2>&1)"
    rc=$?
    printf 'nexus:%-12s rc=%s %s\n' "$p" "$rc" "$out"
    [[ "$rc" -eq 0 ]] || { echo "FAIL: nexus open $p failed"; exit 1; }
    case "$out" in
        *"unknown page"*) echo "FAIL: $p is not in PageRegistry"; exit 1 ;;
    esac
    sleep 0.8
done
quickshell -p "$root/shell.qml" ipc call nexus close >/dev/null 2>&1
sleep 0.3

for t in "${targets[@]}"; do
    quickshell -p "$root/shell.qml" ipc call "$t" toggle >/dev/null 2>&1
    rc=$?
    printf '%-22s rc=%s\n' "$t" "$rc"
    [[ "$rc" -eq 0 ]] || { echo "FAIL: IPC call to $t failed"; exit 1; }
    sleep 0.7
    quickshell -p "$root/shell.qml" ipc call "$t" toggle >/dev/null 2>&1
    sleep 0.3
done

echo "--- diagnostics ---"
# Two classes of noise, and the second is a consequence of the isolation above
# rather than something to fix:
#
#   * Qt's own Wayland text-input chatter, and the notification-server name
#     already being owned when a live shell is running.
#   * PipeWire. Its socket lives in the SESSION's XDG_RUNTIME_DIR, and this run
#     deliberately has its own, so the audio service cannot connect. Bridging
#     the real socket in would give the shell under test a route to the volume
#     of whoever is logged in, which is exactly the kind of reach this runner
#     was changed to remove. No popup in the fleet is audio-gated, so the
#     coverage cost is nil.
noise='qt.qpa.wayland.textinput|Could not register notification server|Registration will be attempted|Failed to connect pipewire context'
grep -E "ERROR|WARN" "$log" | grep -vE "$noise" | sort -u | head -20

errors="$(grep -E 'ERROR' "$log" | grep -cvE "$noise")"
echo "--- ERROR count: $errors ---"
[[ "$errors" -eq 0 ]] || { echo "RESULT: runtime errors present"; exit 1; }
echo "RESULT: all pages and popups opened cleanly"
