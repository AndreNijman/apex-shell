#!/usr/bin/env bash
set -uo pipefail
command -v quickshell >/dev/null 2>&1 || { echo "SKIP: quickshell not installed"; exit 0; }
[[ -n "${WAYLAND_DISPLAY:-}" ]] || { echo "SKIP: no WAYLAND_DISPLAY"; exit 0; }
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
log="$(mktemp)"
quickshell -p ./shell.qml >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null; rm -f "$log"' EXIT

for _ in $(seq 1 60); do grep -q "Configuration Loaded" "$log" && break; sleep 0.25; done
grep -q "Configuration Loaded" "$log" || { echo "FAIL: never loaded"; tail -20 "$log"; exit 1; }

call() { quickshell -p ./shell.qml ipc call nexus "$@" 2>&1; }

echo "pages      -> $(call pages)"
echo "open       -> $(call open '')"
sleep 0.8
echo "toggle kb  -> $(call toggle keybinds)"
sleep 0.8
echo "toggle kb2 -> $(call toggle keybinds)"
sleep 0.8
echo "open data  -> $(call open data)"
sleep 1.2
echo "open bogus -> $(call open nonsense)"
echo "close      -> $(call close)"
sleep 0.6

echo "--- diagnostics ---"
grep -E "ERROR|WARN" "$log" \
  | grep -vE "qt.qpa.wayland.textinput|Could not register notification server|Registration will be attempted" \
  | sort -u | head -20
echo "--- ERROR count: $(grep -c ERROR "$log") ---"
