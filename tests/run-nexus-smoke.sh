#!/usr/bin/env bash
# Open, toggle and close the Nexus settings surface over IPC, and report what
# the shell logged while doing it.
#
# On a headless labwc from tests/lib/headless.sh, with a private HOME: this
# starts the whole shell, and it used to start it on the inherited
# WAYLAND_DISPLAY.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"

headless_require quickshell

pid=""
cleanup() {
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
    headless_cleanup
}
trap cleanup EXIT INT TERM

headless_begin
headless_start || exit 0

cd "$root" || exit 1
log="$HEADLESS_W/shell.log"
quickshell -p ./shell.qml >"$log" 2>&1 &
pid=$!

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
# PipeWire is in here for the reason tests/run-popup-smoke.sh spells out: its
# socket lives in the session's runtime dir and this run has its own.
noise='qt.qpa.wayland.textinput|Could not register notification server|Registration will be attempted|Failed to connect pipewire context'
grep -E "ERROR|WARN" "$log" | grep -vE "$noise" | sort -u | head -20
echo "--- ERROR count: $(grep -E ERROR "$log" | grep -cvE "$noise") ---"
