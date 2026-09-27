#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-wifi-keys-test.sh — the Wi-Fi pane on the keyboard (UI/UX roadmap v3
#  Phase 21; src/popups/WifiTab.qml, the template for the network panes).
#
#  The real shell in a headless labwc, the network panel opened over IPC and
#  typed into with wtype. NetworkManager is tests/lib/fake-nmcli: four canned
#  networks, and every command that would change something is written to a
#  log instead of run. The harness otherwise reads the machine's REAL
#  NetworkManager, and Return on a row would disconnect the laptop running
#  this. The log is the observable:
#
#    Tab ×4 reaches the list (power, settings, rescan, list — the tab bar at
#      the bottom comes after the content), and it highlights the connected one;
#    Down, Return connects to the next one    → con up id Cafe Corner
#    Up, Tab, Return: the row's Disconnect    → con down HomeNet
#    Tab, Tab, Return, Tab, Tab, Return: Forget, then the question's Forget
#                                             → connection delete HomeNet
#    and nothing else was asked of NetworkManager (a stray key turning the
#    radio off would show here). Escape closes the pane.
#
#  Skips (status 0) without quickshell, labwc, wtype or grim.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"
headless_require quickshell labwc wtype grim python3

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

headless_begin
# NetworkManager and BlueZ are the real ones unless stubbed: the fake answers
# the pane's queries, and the tools a button could launch do nothing.
ln -sf "$here/lib/fake-nmcli" "$HEADLESS_W/bin/nmcli"
for n in nmtui bluetoothctl blueman-manager rfkill; do ln -sf "$HEADLESS_W/bin/_stub" "$HEADLESS_W/bin/$n"; done
export FAKE_NMCLI_LOG="$HEADLESS_W/nmcli.log"; : > "$FAKE_NMCLI_LOG"
qs=""
cleanup() { [ -n "$qs" ] && kill "$qs" 2>/dev/null; headless_cleanup; }
trap cleanup EXIT INT TERM
[ -e /dev/dri/renderD128 ] && export HEADLESS_WLR_RENDERER=gles2
headless_start labwc 1920x1080 || exit 0

ud="$HOME/.config/apex-shell/src/user_data"; mkdir -p "$ud" "$HOME/.cache/apex-shell"
printf '{"barEnabled":false,"animDuration":320,"motionScale":1}' > "$ud/settings.json"
headless_apex_palette dark   # the APEX-OS default look (tests/lib/headless.sh)
log="$HEADLESS_W/shell.log"
quickshell -p "$root/shell.qml" > "$log" 2>&1 &
qs=$!
for _ in $(seq 1 120); do grep -q "Configuration Loaded" "$log" && break; sleep 0.25; done
grep -q "Configuration Loaded" "$log" || { echo "RESULT: the shell did not load"; tail -20 "$log"; exit 1; }
sleep 3

ipc()  { quickshell -p "$root/shell.qml" ipc call "$@" >/dev/null 2>&1; }
keys() { local k; for k in "$@"; do wtype -k "$k"; sleep 0.3; done; }
logged() {   # logged <text> <seconds> — the fake was asked for this
    local _
    for _ in $(seq 1 $(( $2 * 4 ))); do grep -qF -- "$1" "$FAKE_NMCLI_LOG" && return 0; sleep 0.25; done
    return 1
}

wtype -k Shift_L; sleep 0.3          # the first wtype key of a session is lost
grim -l 0 "$HEADLESS_W/rest.png"
ipc wifi-toggle toggle; sleep 1.5

keys Tab Tab Tab Tab Down Return
logged "con up id Cafe Corner" 5 \
    && ok "Tab ×4 reaches the list; Down, Return connects to the next network" \
    || bad "Down, Return on the list — NetworkManager was asked: $(tr '\n' '|' < "$FAKE_NMCLI_LOG")"
sleep 1

keys Up Tab Return
logged "con down HomeNet" 5 \
    && ok "Up, then Tab into the connected row: its Disconnect button, pressed with Return" \
    || bad "the row's Disconnect — NetworkManager was asked: $(tr '\n' '|' < "$FAKE_NMCLI_LOG")"
sleep 1

keys Tab Tab Return Tab Tab Return
logged "connection delete HomeNet" 5 \
    && ok "Tab to Forget, Return; Tab past Cancel to the question's Forget, Return" \
    || bad "the Forget question — NetworkManager was asked: $(tr '\n' '|' < "$FAKE_NMCLI_LOG")"
sleep 1

extra="$(grep -v -e 'con up id Cafe Corner' -e 'con down HomeNet' -e 'connection delete HomeNet' "$FAKE_NMCLI_LOG")"
[ -z "$extra" ] && ok "and NetworkManager was asked for nothing else" \
    || bad "NetworkManager was also asked: $(printf '%s' "$extra" | tr '\n' '|')"

keys Escape; sleep 1.2
grim -l 0 "$HEADLESS_W/after.png"
closed="$(python3 - "$HEADLESS_W/rest.png" "$HEADLESS_W/after.png" <<'PY'
import sys
from PIL import Image, ImageChops
a = Image.open(sys.argv[1]).convert("RGB").crop((1410, 60, 1920, 520))
b = Image.open(sys.argv[2]).convert("RGB").crop((1410, 60, 1920, 520))
h = ImageChops.difference(a, b).convert("L").histogram()
print("yes" if sum(i * c for i, c in enumerate(h)) / sum(h) < 4 else "no")
PY
)"
[ "$closed" = yes ] && ok "Escape closed the pane" || bad "Escape closed the pane (the panel area still differs from the desk)"

grep -E 'TypeError|ReferenceError|is not a type|Cannot assign' "$log" | head -3
printf '\nrun-wifi-keys-test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
