#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-netpanes-keys-test.sh — the VPN, Bluetooth and hotspot panes on the
#  keyboard (UI/UX roadmap v3 Phase 21), after the Wi-Fi template
#  (run-wifi-keys-test.sh).
#
#  The real shell in a headless labwc, typed into with wtype, with
#  NetworkManager and BlueZ replaced by tests/lib/fake-nmcli and
#  fake-bluetoothctl: canned connections and devices, and every command that
#  would change something written to a log instead of run. The harness
#  otherwise reaches the machine's REAL NetworkManager and BlueZ — Return on a
#  row would drop the laptop's tunnel or unpair its mouse. systemctl is the
#  harness's own stub. The logs are the observable:
#
#    VPN       Tab ×3 reaches the list (kill switch, refresh, list), which
#              highlights the active tunnel (HomeVPN — UI/UX Phase 17 put
#              ACTIVE first, then AVAILABLE, then TUNNEL/sing-box last, so
#              the list no longer opens on sing-box); Return on it →
#              con down HomeVPN; Down, Return on the other → con up WorkVPN.
#    Bluetooth Tab to the device list; Return on the connected mouse →
#              disconnect; Down to the paired headphones, Return → connect.
#    Hotspot   Tab to the name field and type; Tab past the password and the
#              show-password button to Save, Return → the file holds it.
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
ln -sf "$here/lib/fake-nmcli" "$HEADLESS_W/bin/nmcli"
ln -sf "$here/lib/fake-bluetoothctl" "$HEADLESS_W/bin/bluetoothctl"
for n in nmtui blueman-manager rfkill sing-box; do ln -sf "$HEADLESS_W/bin/_stub" "$HEADLESS_W/bin/$n"; done
export FAKE_NMCLI_LOG="$HEADLESS_W/nmcli.log" FAKE_BLUETOOTHCTL_LOG="$HEADLESS_W/bt.log"
: > "$FAKE_NMCLI_LOG"; : > "$FAKE_BLUETOOTHCTL_LOG"
qs=""
cleanup() { [ -n "$qs" ] && kill "$qs" 2>/dev/null; headless_cleanup; }
trap cleanup EXIT INT TERM
[ -e /dev/dri/renderD128 ] && export HEADLESS_WLR_RENDERER=gles2
headless_start labwc 1920x1080 || exit 0

ud="$HOME/.config/apex-shell/src/user_data"; mkdir -p "$ud" "$HOME/.cache/apex-shell"
printf '{"barEnabled":false,"animDuration":320,"motionScale":1}' > "$ud/settings.json"
printf '%s' '{"background":"#171210","active":"#fab898","text":"#ece0dc","subtext":"#d6c2ba","border":"#52443e","iconFont":"#be8366"}' \
    > "$HOME/.cache/apex-shell/colors.json"
log="$HEADLESS_W/shell.log"
quickshell -p "$root/shell.qml" > "$log" 2>&1 &
qs=$!
for _ in $(seq 1 120); do grep -q "Configuration Loaded" "$log" && break; sleep 0.25; done
grep -q "Configuration Loaded" "$log" || { echo "RESULT: the shell did not load"; tail -20 "$log"; exit 1; }
sleep 3

ipc()  { quickshell -p "$root/shell.qml" ipc call "$@" >/dev/null 2>&1; }
keys() { local k; for k in "$@"; do wtype -k "$k"; sleep 0.3; done; }
logged() {   # logged <file> <text> <seconds>
    local _
    for _ in $(seq 1 $(( $3 * 4 ))); do grep -qF -- "$2" "$1" && return 0; sleep 0.25; done
    return 1
}
wtype -k Shift_L; sleep 0.3          # the first wtype key of a session is lost

# ── VPN ──────────────────────────────────────────────────────────────────────
# UI/UX Phase 17 reordered the pane to ACTIVE, then AVAILABLE, then TUNNEL
# (sing-box) last, so Tab ×3 now highlights the active WireGuard tunnel
# (HomeVPN) directly — no Down needed to skip past sing-box any more.
ipc vpn-toggle toggle; sleep 1.5
keys Tab Tab Tab Return
logged "$FAKE_NMCLI_LOG" "con down HomeVPN" 5 \
    && ok "VPN: Tab ×3 reaches the list, highlighting the active tunnel; Return drops it" \
    || bad "VPN: Return on the active tunnel — NetworkManager was asked: $(tr '\n' '|' < "$FAKE_NMCLI_LOG")"
sleep 1.5
before="$(wc -l < "$FAKE_NMCLI_LOG")"
keys Down Return
logged "$FAKE_NMCLI_LOG" "con up WorkVPN" 5 \
    && ok "VPN: Down, Return brings the other connection up" \
    || bad "VPN: Down, Return — NetworkManager was asked since: $(tail -n +"$((before + 1))" "$FAKE_NMCLI_LOG" | tr '\n' '|')"
keys Escape; sleep 1.2

# ── Bluetooth ────────────────────────────────────────────────────────────────
ipc bluetooth-toggle toggle; sleep 2
keys Tab Tab Tab Tab Return
logged "$FAKE_BLUETOOTHCTL_LOG" "disconnect AA:BB:CC:00:00:01" 5 \
    && ok "Bluetooth: Tab ×4 reaches the device list (power, settings, scan, list); Return on the connected mouse disconnects it" \
    || bad "Bluetooth: Return on the first device — BlueZ was asked: $(tr '\n' '|' < "$FAKE_BLUETOOTHCTL_LOG")"
sleep 1.5
keys Down Return
logged "$FAKE_BLUETOOTHCTL_LOG" "connect AA:BB:CC:00:00:02" 5 \
    && ok "Bluetooth: Down, Return connects the paired headphones" \
    || bad "Bluetooth: Down, Return — BlueZ was asked: $(tr '\n' '|' < "$FAKE_BLUETOOTHCTL_LOG")"
keys Escape; sleep 1.2

# ── Hotspot ──────────────────────────────────────────────────────────────────
ipc hotspot-toggle toggle; sleep 1.5
keys Tab
wtype "X"; sleep 0.3
keys Tab Tab Tab Return
sleep 1
if grep -q '"ssid":"ApexShellX"' "$HOME/.config/apex-shell/src/user_data/hotspot.json" 2>/dev/null; then
    ok "Hotspot: Tab to the name, type, Tab to Save, Return — saved"
else
    bad "Hotspot: saved file holds: $(cat "$HOME/.config/apex-shell/src/user_data/hotspot.json" 2>/dev/null)"
fi
keys Escape; sleep 1

# Nothing but what was asked for: no radio, no power, no pairing, no removal.
# Expected besides the keys' own: the VPN tab switches autoconnect off on
# every WireGuard profile when it loads, and bringing one tunnel up takes the
# active one down first.
extra_nm="$(grep -v -e 'con down HomeVPN' -e 'con up WorkVPN' \
                    -e '^con modify [A-Za-z]*VPN connection.autoconnect no$' \
                    -e '^connection down HomeVPN$' "$FAKE_NMCLI_LOG")"
extra_bt="$(grep -v -e '^disconnect AA:BB:CC:00:00:01$' -e '^connect AA:BB:CC:00:00:02$' "$FAKE_BLUETOOTHCTL_LOG")"
[ -z "$extra_nm$extra_bt" ] && ok "and nothing else was asked of NetworkManager or BlueZ" \
    || bad "also asked — NetworkManager: $(printf '%s' "$extra_nm" | tr '\n' '|') BlueZ: $(printf '%s' "$extra_bt" | tr '\n' '|')"

grep -E 'TypeError|ReferenceError|is not a type|Cannot assign' "$log" | head -3
printf '\nrun-netpanes-keys-test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
