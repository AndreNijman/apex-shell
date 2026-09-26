#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-dashboard-keys-test.sh — the Dashboard's Home and Tasks tabs on the
#  keyboard (UI/UX roadmap v3 Phase 21).
#
#  The real shell in a headless labwc, the Dashboard opened over IPC and typed
#  into with wtype, on headless.sh's private session bus. Everything a key
#  could change on the machine is a fake that logs instead of acting:
#  tests/lib/fake-mpris.py (a paused track, 3:00 long, at 1:00),
#  fake-brightnessctl (a panel at 50 of 100) and fake-nmcli. The logs, and the
#  board's own tasks.json, are the observable:
#
#    Home   Tab order is reading order — left column, centre, right:
#             the tab bar, the calendar's ‹ ›, the clock's mode tabs, then the
#             player's ⏮ ⏯ ⏭ and seek bar, then brightness and the tiles;
#           Return on ⏯                       → Play
#           Tab ×2 to the seek bar, Right      → SetPosition … 65000000 (+5 s)
#           Home                               → SetPosition … 0
#           Tab to brightness, Up / End / Home → set 55 / set 100 / set 2
#                                                (the service's floor, not black)
#           Tab to the Wi-Fi tile, Space       → radio wifi off
#    Clock  Right ×2 on the mode tabs to Alarm; Tab to +, Return; the HH:MM
#           spin boxes Up; Set; Tab to the new alarm's switch, Space; Tab to
#           its ✕, Return — and no script error (each edit rebuilds the list)
#    Tasks  three seeded cards; the first has id 0, which the board must not
#           read as "no card":
#           Tab ×3 reaches the To Do list (tab bar, +, list) on card 0;
#           Ctrl+Right, Ctrl+Right             → card 0 in Ongoing, then Done
#           Delete, Return                     → card 0 gone
#           reopen; Tab ×3 lands on card 1; Return opens it; Tab ×5 to the
#           High chip, Space                   → urgency high
#           Tab to Due, Return; Home, Right, Return in the day grid
#                                              → due the 2nd of this month
#    and nothing else was asked of the player, the backlight, NetworkManager
#    or BlueZ, and card 2 is untouched.
#
#  PROBE=1 grabs a frame after every Tab on Home instead, to re-derive the
#  stop counts. Skips (status 0) without quickshell, labwc, wtype, grim or
#  python3 with PyGObject.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"
headless_require quickshell labwc wtype grim python3
python3 -c 'from gi.repository import Gio' 2>/dev/null || { echo "SKIP: python3 PyGObject is not installed"; exit 0; }

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

headless_begin
ln -sf "$here/lib/fake-nmcli" "$HEADLESS_W/bin/nmcli"
ln -sf "$here/lib/fake-bluetoothctl" "$HEADLESS_W/bin/bluetoothctl"
ln -sf "$here/lib/fake-brightnessctl" "$HEADLESS_W/bin/brightnessctl"
for n in nmtui blueman-manager rfkill hyprshade hyprsunset systemd-inhibit; do
    ln -sf "$HEADLESS_W/bin/_stub" "$HEADLESS_W/bin/$n"
done
export FAKE_NMCLI_LOG="$HEADLESS_W/nmcli.log" FAKE_BLUETOOTHCTL_LOG="$HEADLESS_W/bt.log" \
       FAKE_BRIGHTNESSCTL_LOG="$HEADLESS_W/bright.log"
MPRIS_LOG="$HEADLESS_W/mpris.log"
: > "$FAKE_NMCLI_LOG"; : > "$FAKE_BLUETOOTHCTL_LOG"; : > "$FAKE_BRIGHTNESSCTL_LOG"; : > "$MPRIS_LOG"
qs=""; player=""
cleanup() {
    [ -n "$qs" ] && kill "$qs" 2>/dev/null
    [ -n "$player" ] && kill "$player" 2>/dev/null
    headless_cleanup
}
trap cleanup EXIT INT TERM
case "${DBUS_SESSION_BUS_ADDRESS:-}" in
    *"$HEADLESS_W"*) ;;
    *) echo "RESULT: not on a private session bus — refusing to put a player on the desktop's"; exit 1 ;;
esac
[ -e /dev/dri/renderD128 ] && export HEADLESS_WLR_RENDERER=gles2
headless_start labwc 1920x1080 || exit 0

python3 "$here/lib/fake-mpris.py" "$MPRIS_LOG" &
player=$!

ud="$HOME/.config/apex-shell/src/user_data"; mkdir -p "$ud" "$HOME/.cache/apex-shell"
printf '{"barEnabled":false,"animDuration":320,"motionScale":1,"dashboardWidth":900,"dashboardHeight":520}' > "$ud/settings.json"
printf '%s' '{"background":"#171210","active":"#fab898","text":"#ece0dc","subtext":"#d6c2ba","border":"#52443e","iconFont":"#be8366"}' \
    > "$HOME/.cache/apex-shell/colors.json"
tasks="$ud/tasks.json"
printf '%s' '{"tasks":[{"id":0,"title":"Card zero","column":0,"urgency":"","dueDate":""},{"id":1,"title":"Card one","column":0,"urgency":"","dueDate":""},{"id":2,"title":"Card two","column":1,"urgency":"low","dueDate":""}],"nextId":3}' > "$tasks"
log="$HEADLESS_W/shell.log"
quickshell -p "$root/shell.qml" > "$log" 2>&1 &
qs=$!
for _ in $(seq 1 120); do grep -q "Configuration Loaded" "$log" && break; sleep 0.25; done
grep -q "Configuration Loaded" "$log" || { echo "RESULT: the shell did not load"; tail -20 "$log"; exit 1; }
sleep 3

ipc()  { quickshell -p "$root/shell.qml" ipc call "$@" >/dev/null 2>&1; }
keys() { local k; for k in "$@"; do wtype -k "$k"; sleep 0.3; done; }
ctrl() { wtype -M ctrl -k "$1" -m ctrl; sleep 0.4; }
logged() {   # logged <file> <line, exactly> <seconds>
    local _
    for _ in $(seq 1 $(( $3 * 4 ))); do grep -qxF -- "$2" "$1" && return 0; sleep 0.25; done
    return 1
}
task() {     # task <id> — "column urgency dueDate", or "gone"
    python3 - "$tasks" "$1" <<'PY'
import json, sys
t = {x["id"]: x for x in json.load(open(sys.argv[1]))["tasks"]}
x = t.get(int(sys.argv[2]))
print("gone" if x is None else f'{x["column"]} {x.get("urgency") or "-"} {x.get("dueDate") or "-"}')
PY
}
becomes() {  # becomes <id> <expected, a regex on `task`> <seconds>
    local _
    for _ in $(seq 1 $(( $3 * 4 ))); do [[ "$(task "$1")" =~ ^$2$ ]] && return 0; sleep 0.25; done
    return 1
}
shot() {     # SHOTS=<dir>: a frame of the Dashboard at each named step
    [ -n "${SHOTS:-}" ] && mkdir -p "$SHOTS" && grim -g "480,0 960x600" "$SHOTS/$1.png"
}
wtype -k Shift_L; sleep 0.3          # the first wtype key of a session is lost

# ── Home ─────────────────────────────────────────────────────────────────────
ipc dashboard-home toggle; sleep 1.5

if [ "${PROBE:-0}" = 1 ]; then
    out="${PROBE_OUT:-/var/lab-scratch/uiux/home-probe}"; mkdir -p "$out"
    for i in $(seq 1 "${PROBE_TABS:-24}"); do
        wtype -k Tab; sleep 0.45; grim -g "${PROBE_GEOM:-480,0 960x600}" "$out/tab-$(printf %02d "$i").png"
    done
    echo "PROBE: frames in $out"; exit 0
fi

keys Tab Tab Tab Tab Tab Tab Return
logged "$MPRIS_LOG" "Play" 5 \
    && ok "Tab ×6 reaches ⏯ in reading order (after ‹ › and the clock); Return plays" \
    || bad "Return on ⏯ — the player was asked: $(tr '\n' '|' < "$MPRIS_LOG")"
keys Tab Tab Right
logged "$MPRIS_LOG" "SetPosition /apex/track/1 65000000" 5 \
    && ok "Tab ×2 to the seek bar; Right seeks 5 s on" \
    || bad "Right on the seek bar — the player was asked: $(tr '\n' '|' < "$MPRIS_LOG")"
sleep 0.4
keys Home
logged "$MPRIS_LOG" "SetPosition /apex/track/1 0" 5 && ok "Home seeks to the start" \
    || bad "Home on the seek bar — the player was asked: $(tr '\n' '|' < "$MPRIS_LOG")"

keys Tab Up
logged "$FAKE_BRIGHTNESSCTL_LOG" "set 55" 5 \
    && ok "Tab on to the brightness slider; Up steps it 5 %" \
    || bad "Up on the slider — the backlight was asked: $(tr '\n' '|' < "$FAKE_BRIGHTNESSCTL_LOG")"
sleep 0.4
keys End
logged "$FAKE_BRIGHTNESSCTL_LOG" "set 100" 5 && ok "End takes it to full" \
    || bad "End — the backlight was asked: $(tr '\n' '|' < "$FAKE_BRIGHTNESSCTL_LOG")"
sleep 0.4
keys Home
logged "$FAKE_BRIGHTNESSCTL_LOG" "set 2" 5 && ok "Home takes it to the floor, not to black" \
    || bad "Home — the backlight was asked: $(tr '\n' '|' < "$FAKE_BRIGHTNESSCTL_LOG")"

keys Tab space
logged "$FAKE_NMCLI_LOG" "radio wifi off" 5 \
    && ok "Tab to the Wi-Fi tile, Space turns the radio off" \
    || bad "Space on the Wi-Fi tile — NetworkManager was asked: $(tr '\n' '|' < "$FAKE_NMCLI_LOG")"
sleep 1
ipc dashboard-home toggle; sleep 1.2

# ── The clock's alarms ───────────────────────────────────────────────────────
# Kept in memory only (ClockState), so the observable is the shell's log: every
# alarm edit rebuilds the list, and a handler that touches its row after the
# edit dies with it ("… is not defined"). Frames with SHOTS=.
errs_before="$(grep -cE 'ReferenceError|TypeError' "$log")"
ipc dashboard-home toggle; sleep 1.5
keys Tab Tab Tab Tab Right Right; sleep 0.6; shot clock-1-alarm-mode
keys Tab Return; sleep 0.5; shot clock-2-add
keys Tab Up Tab Up; shot clock-3-time
keys Tab Return; sleep 0.6; shot clock-4-set
keys Tab space; sleep 0.6; shot clock-5-toggled
keys Tab Return; sleep 0.6; shot clock-6-deleted
errs_after="$(grep -cE 'ReferenceError|TypeError' "$log")"
[ "$errs_after" = "$errs_before" ] \
    && ok "an alarm added (Tab to +, the HH:MM spin boxes, Set), toggled and deleted from the keyboard, with no script error" \
    || bad "the alarm edits logged: $(grep -E 'ReferenceError|TypeError' "$log" | tail -n +"$((errs_before + 1))" | head -3 | tr '\n' '|')"
ipc dashboard-home toggle; sleep 1.2

# ── Tasks ────────────────────────────────────────────────────────────────────
ipc dashboard-kanban toggle; sleep 1.5
keys Tab Tab Tab
ctrl Right
becomes 0 "1 - -" 5 && ok "Tab ×3 reaches the To Do list on card 0; Ctrl+Right moves it to Ongoing" \
    || bad "Ctrl+Right on card 0 — it is: $(task 0)"
ctrl Right
becomes 0 "2 - -" 5 && ok "the moved card kept the highlight; Ctrl+Right again moves it to Done" \
    || bad "a second Ctrl+Right — card 0 is: $(task 0)"
keys Delete Return
becomes 0 "gone" 5 && ok "Delete asks, Return deletes it" || bad "Delete, Return — card 0 is: $(task 0)"
ipc dashboard-kanban toggle; sleep 1.2
ipc dashboard-kanban toggle; sleep 1.5

keys Tab Tab Tab Return; shot kanban-1-open
keys Tab Tab Tab Tab Tab; shot kanban-2-high
keys space; sleep 0.4; shot kanban-3-urgency
becomes 1 "0 high -" 5 && ok "reopened: Tab ×3 lands on card 1; Return opens it; Tab ×5 to High, Space" \
    || bad "the High chip on card 1 — it is: $(task 1)"
keys Tab; shot kanban-4-due
keys Return
sleep 0.6; shot kanban-5-picker
keys Home Right; shot kanban-6-day
keys Return; sleep 0.4; shot kanban-7-done
becomes 1 "0 high $(date +%Y-%m)-02" 5 \
    && ok "Tab to Due, Return opens the picker on its day grid; Home, Right, Return — due the 2nd" \
    || bad "the date picker by keyboard — card 1 is: $(task 1)"

[ "$(task 2)" = "1 low -" ] && ok "card 2 was not touched" || bad "card 2 changed: $(task 2)"
extra_mp="$(grep -vxF -e 'Play' -e 'SetPosition /apex/track/1 65000000' -e 'SetPosition /apex/track/1 0' "$MPRIS_LOG")"
extra_nm="$(grep -vxF 'radio wifi off' "$FAKE_NMCLI_LOG")"
extra_bl="$(grep -vxF -e 'set 55' -e 'set 100' -e 'set 2' "$FAKE_BRIGHTNESSCTL_LOG")"
[ -z "$extra_mp$extra_nm$extra_bl$(cat "$FAKE_BLUETOOTHCTL_LOG")" ] \
    && ok "and nothing else was asked of the player, the backlight, NetworkManager or BlueZ" \
    || bad "also asked — player: $(printf '%s' "$extra_mp" | tr '\n' '|') backlight: $(printf '%s' "$extra_bl" | tr '\n' '|') NetworkManager: $(printf '%s' "$extra_nm" | tr '\n' '|') BlueZ: $(tr '\n' '|' < "$FAKE_BLUETOOTHCTL_LOG")"

keys Escape; sleep 1
grep -E 'TypeError|ReferenceError|is not a type|Cannot assign' "$log" | head -5
printf '\nrun-dashboard-keys-test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
