#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-traymenu-keys-test.sh — an application's tray menu on the keyboard
#  (UI/UX roadmap v3 Phase 21; src/modules/Right/TrayMenu.qml).
#
#  The REAL TrayMenu on a real StatusNotifierItem with a real DBusMenu
#  (tests/lib/fake-tray-item.py: First / Second / — / Third) in a headless
#  labwc. The item reports which row it was told was chosen, so this asserts
#  the ROW that reached the application:
#
#    step +1 ×3, choose   → Third   (the separator is skipped)
#    step +1, +1, −1      → First   (up walks back)
#
#  driven through the functions the menu's key handler calls, over IPC, and a
#  static check pins the handler to them (Down/Up → _step, Return/Enter/Space
#  → the current row, Right into a submenu, Left/Backspace out, Escape closes).
#  Keys are NOT typed: a grabbing popup opened without a pointer click's serial
#  is dismissed at once (measured: 62-135 ms after it maps), and the harness
#  has no pointer. That last step — a real key into a real grab — is not
#  measured here.
#
#  Runs on a PRIVATE session bus, always: on the desktop's bus the fake item
#  would register in the real tray. It re-executes itself under
#  dbus-run-session, with the display variables unset.
#
#  Skips (status 0) without quickshell, labwc or python3-gobject.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
if [ "${APEX_CAPTURE_BUS:-}" != private ]; then
    command -v dbus-run-session >/dev/null 2>&1 || { echo "SKIP: dbus-run-session is not installed"; exit 0; }
    exec env -u WAYLAND_DISPLAY -u DISPLAY dbus-run-session -- env APEX_CAPTURE_BUS=private "$0" "$@"
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"
headless_require quickshell labwc wtype python3
python3 -c 'import gi; gi.require_version("Gio", "2.0")' 2>/dev/null \
    || { echo "SKIP: python3-gobject is not installed"; exit 0; }

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

staged="$root/.traymenu-keys-test.qml"
qs=""; tray=""
headless_begin
cleanup() {
    [ -n "$tray" ] && kill "$tray" 2>/dev/null
    [ -n "$qs" ] && kill "$qs" 2>/dev/null
    rm -f "$staged"
    headless_cleanup
}
trap cleanup EXIT INT TERM
headless_start labwc 1920x1080 || exit 0

cp "$here/traymenu-keys-test.qml" "$staged"
log="$HEADLESS_W/shell.log"; tlog="$HEADLESS_W/tray.log"
quickshell -p "$staged" > "$log" 2>&1 &
qs=$!
FAKE_TRAY_TRACE="${FAKE_TRAY_TRACE:-}" python3 "$here/lib/fake-tray-item.py" > "$tlog" 2>&1 &
tray=$!

wait_for() {   # wait_for <file> <pattern> <seconds>
    local _
    for _ in $(seq 1 $(( $3 * 4 ))); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.25; done
    return 1
}
wait_for "$tlog" REGISTERED 20 || { echo "SKIP: the fake tray item could not register (no watcher)"; tail -5 "$tlog"; exit 0; }
wait_for "$log" "TRAYTEST ITEM" 20 || { bad "the shell saw the fake tray item"; tail -20 "$log"; exit 1; }
ipc() { quickshell -p "$staged" ipc call traytest "$@" 2>/dev/null | tail -1; }

ipc open >/dev/null
wait_for "$log" "TRAYTEST OPEN" 10 || bad "the tray menu opened"
for _ in $(seq 1 20); do [ "$(ipc rows)" = 3 ] && break; sleep 0.25; done
n="$(ipc rows)"
[ "$n" = 3 ] && ok "three rows can be chosen (the separator is not one)" || bad "rows that can be chosen: $n, expected 3"

ipc step 1 >/dev/null; ipc step 1 >/dev/null; got="$(ipc step 1)"
[ "$got" = Third ] && ok "three steps down land on Third, past the separator" || bad "three steps down landed on: $got"
ipc choose >/dev/null
if wait_for "$tlog" "CLICKED Third" 5; then ok "choosing it told the application Third"
else bad "choosing it — the application was told: $(grep CLICKED "$tlog" | tail -1)"; fi

wait_for "$log" "TRAYTEST CLOSED" 5 || bad "choosing a row closed the menu"
ipc open >/dev/null; sleep 0.8
ipc step 1 >/dev/null; ipc step 1 >/dev/null; got="$(ipc step -1)"
[ "$got" = First ] && ok "down, down, up lands on First — and a reopened menu starts from nothing" || bad "down, down, up landed on: $got"
ipc choose >/dev/null
if wait_for "$tlog" "CLICKED First" 5; then ok "choosing it told the application First"
else bad "choosing it — the application was told: $(grep CLICKED "$tlog" | tail -1)"; fi

# The key handler calls exactly these.
python3 - "$root/src/modules/Right/TrayMenu.qml" <<'PYCHK' && ok "the key handler maps Down/Up, Return/Enter/Space, Right, Left/Backspace and Escape onto them" || bad "the key handler no longer maps the keys onto the menu model"
import re, sys
s = open(sys.argv[1]).read()
need = [r"Key_Down\)\s*root\._step\(1\)", r"Key_Up\)\s*root\._step\(-1\)",
        r"Key_Return[\s\S]{0,120}Key_Space\)\s*&&\s*cur\)\s*cur\.activated\(\)",
        r"Key_Right\s*&&\s*cur\s*&&\s*cur\.chevron\)\s*cur\.activated\(\)",
        r"Key_Backspace\)[\s\S]{0,60}root\.pop\(\)", r"Keys\.onEscapePressed:\s*root\.close\(\)"]
sys.exit(0 if all(re.search(p, s) for p in need) else 1)
PYCHK

grep -E 'TypeError|ReferenceError|is not a type' "$log" | head -3
[ -n "${FAKE_TRAY_TRACE:-}" ] && { echo "--- tray"; cat "$tlog"; echo "--- shell"; grep -E "TRAYTEST|WARN" "$log" | tail -20; }
printf '\nrun-traymenu-keys-test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
