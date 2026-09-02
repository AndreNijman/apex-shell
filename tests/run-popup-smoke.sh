#!/usr/bin/env bash
# Functional smoke test: start this checkout's shell, drive every page and popup
# open and closed over IPC, and fail on any runtime error.
#
# This exists because the dashboard pages and the popup fleet are lazily
# constructed. Loading the shell proves the QML compiles; it does NOT prove a
# page works, because nothing instantiates it until it is first shown. Without
# this, a broken binding inside a lazily-loaded page ships silently.
#
# Requires a Wayland session. Skips cleanly (status 0) without one so it does not
# fail a CI run that has no compositor.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

command -v quickshell >/dev/null 2>&1 || { echo "SKIP: quickshell not installed"; exit 0; }
[[ -n "${WAYLAND_DISPLAY:-}" ]] || { echo "SKIP: no WAYLAND_DISPLAY"; exit 0; }

log="$(mktemp)"
qs_pid=""
cleanup() {
    [[ -n "$qs_pid" ]] && kill "$qs_pid" 2>/dev/null
    rm -f "$log"
    return 0
}
trap cleanup EXIT INT TERM

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
nexus_pages=(appearance layout input display keybinds data misc)
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
# Qt's own Wayland text-input chatter and the notification-server contention
# (another shell already owns the name in a live session) are not ours.
noise='qt.qpa.wayland.textinput|Could not register notification server|Registration will be attempted'
grep -E "ERROR|WARN" "$log" | grep -vE "$noise" | sort -u | head -20

errors="$(grep -c 'ERROR' "$log")"
echo "--- ERROR count: $errors ---"
[[ "$errors" -eq 0 ]] || { echo "RESULT: runtime errors present"; exit 1; }
echo "RESULT: all pages and popups opened cleanly"
