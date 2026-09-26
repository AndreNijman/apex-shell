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
#    Launcher opened after a close: "kqv", Return → Kqvkeytest runs (the
#           first key lost would be "qv" → Qvkeytest)
#    Clock  (reopened: every open starts at the tab bar) Right ×2 on the mode
#           tabs to Alarm; Tab into the panel, +, Return; the HH:MM spin boxes
#           Up; Set → a row in the list; Tab to its switch, Space → its time
#           dims; Tab to its ✕, Return → the list is empty again (read off
#           frames — the clock keeps no file) — and no script error
#    Tasks  three seeded cards; the first has id 0, which the board must not
#           read as "no card":
#           Tab ×3 reaches the To Do list (tab bar, +, list) on card 0;
#           Ctrl+Right, Ctrl+Right             → card 0 in Ongoing, then Done
#           Delete, Return                     → card 0 gone
#           reopen; Tab ×3 lands on card 1; Return opens it; Tab ×5 to the
#           High chip, Space                   → urgency high
#           Tab to Due, Return; Home, Right in the day grid; Tab ×4 wraps
#           to ‹, Return (a month back); Shift+Tab wraps to Done, Return
#                                              → due the 2nd of last month
#    and nothing else was asked of the player, the backlight, NetworkManager
#    or BlueZ, and card 2 is untouched.
#
#  REDUCE_MOTION=true runs it with Reduce Motion on (CI runs both).
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
# REDUCE_MOTION=true runs the same keys with Reduce Motion on: panels snap
# shut, so a handler that reads its own focus after closing its panel is caught.
printf '{"barEnabled":false,"animDuration":320,"motionScale":1,"reduceMotion":%s,"dashboardWidth":900,"dashboardHeight":520}' \
    "${REDUCE_MOTION:-false}" > "$ud/settings.json"
printf '%s' '{"background":"#171210","active":"#fab898","text":"#ece0dc","subtext":"#d6c2ba","border":"#52443e","iconFont":"#be8366"}' \
    > "$HOME/.cache/apex-shell/colors.json"
# Two applications for the launcher, told apart by the first key: "kqv" is
# Kqvkeytest's; lose the k and "qv" is Qvkeytest's prefix.
apps="$HOME/.local/share/applications"; mkdir -p "$apps"; LAUNCH_LOG="$HEADLESS_W/launched.log"; : > "$LAUNCH_LOG"
for a in Kqvkeytest Qvkeytest; do
    printf '#!/bin/sh\necho %s >> "%s"\n' "$a" "$LAUNCH_LOG" > "$HEADLESS_W/$a.sh"; chmod +x "$HEADLESS_W/$a.sh"
    printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s\n' "$a" "$HEADLESS_W/$a.sh" > "$apps/$a.desktop"
done
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

# ── The launcher after a close ───────────────────────────────────────────────
# A close puts the Dashboard's focus back at the top (so the next open starts
# there); the launcher must still own the keys the moment it opens.
ipc dashboard-launcher toggle; sleep 0.4
wtype "kqv"; sleep 0.8; keys Return
logged "$LAUNCH_LOG" "Kqvkeytest" 5 \
    && ok "opened after a close, the launcher's field has the keys: \"kqv\", Return launches Kqvkeytest" \
    || bad "the launcher after a close — launched: $(tr '\n' '|' < "$LAUNCH_LOG")"
sleep 1

# ── The clock's alarms ───────────────────────────────────────────────────────
# Kept in memory only (ClockState: no file, no IPC), so the observable is the
# card itself, read off frames of the Dashboard (480,0 960x600): the alarm list
# (250,100 → 700,240) is "No alarms set" when empty; a new alarm is a row in the
# band above that text (250,108 → 700,150), whose time digits (266,122 →
# 318,138) are bright when on and dim when off — measured Δ 10.6 for the row,
# 67 → 51 for the digits, 0.1 for the list back to empty. Plus the
# shell's log: every edit rebuilds the list, and a handler that touches its row
# after the edit dies with it ("… is not defined").
grab() { grim -g "480,0 960x600" "$HEADLESS_W/$1.png"; [ -n "${SHOTS:-}" ] && mkdir -p "$SHOTS" && cp "$HEADLESS_W/$1.png" "$SHOTS/"; }
region() {   # region <a> <b> <x0,y0,x1,y1> — mean abs difference, then mean brightness of each
    python3 - "$HEADLESS_W/$1.png" "$HEADLESS_W/$2.png" "$3" <<'PY2'
import sys
from PIL import Image, ImageChops, ImageStat
box = tuple(int(v) for v in sys.argv[3].split(","))
a = Image.open(sys.argv[1]).convert("L").crop(box)
b = Image.open(sys.argv[2]).convert("L").crop(box)
print(f"{ImageStat.Stat(ImageChops.difference(a, b)).mean[0]:.2f} "
      f"{ImageStat.Stat(a).mean[0]:.2f} {ImageStat.Stat(b).mean[0]:.2f}")
PY2
}
LIST="250,100,700,240"; ROW="250,108,700,150"; LABEL="266,122,318,138"
TIMERBAND="380,170,580,240"   # presets + Start/Reset when shut, HH:MM + Set Timer when open (Δ 11.6)
errs_before="$(grep -cE 'ReferenceError|TypeError' "$log")"
ipc dashboard-home toggle; sleep 1.5
keys Tab Tab Tab Tab Right Right; sleep 0.8; grab clock-1-empty
keys Tab Return; sleep 0.6                       # the mode tabs → + (the panel follows its tabs)
keys Tab Up Tab Up; grab clock-2-time            # HH, MM
keys Tab Return; sleep 0.8; grab clock-3-added   # Set Alarm; focus back on +
read -r d _ _ <<<"$(region clock-1-empty clock-3-added "$ROW")"
awk -v d="$d" 'BEGIN { exit !(d > 5) }' \
    && ok "Tab to +, the HH:MM spin boxes, Set: an alarm is in the list (row band Δ $d)" \
    || bad "no alarm appeared (row band Δ $d)"
keys Tab space; sleep 0.8; grab clock-4-off      # its switch
read -r _ on off <<<"$(region clock-3-added clock-4-off "$LABEL")"
awk -v a="$on" -v b="$off" 'BEGIN { exit !(b < a * 0.85) }' \
    && ok "Tab to its switch, Space turns it off (its time dims: $on → $off)" \
    || bad "the alarm's switch (time label $on → $off)"
keys Tab Return; sleep 0.8; grab clock-5-gone    # its ✕
read -r d _ _ <<<"$(region clock-1-empty clock-5-gone "$LIST")"
awk -v d="$d" 'BEGIN { exit !(d < 1.5) }' \
    && ok "Tab to its ✕, Return deletes it: the list is empty again (Δ $d from the start)" \
    || bad "the delete (list region Δ $d from empty)"
# The timer's Set: its panel hides at once (visible:), so its button has lost
# focus by the handler's last line — it must read that first to hand focus
# back to +. Space on + then reopens the panel; with focus lost it does nothing.
wtype -M shift -k ISO_Left_Tab -m shift; sleep 0.3   # back to the mode tabs
keys Left; sleep 0.6                                  # Timer
keys Tab Return; sleep 0.5                            # its +, open
keys Tab Up Tab Tab Return; sleep 0.8; grab clock-6-timer-set   # HH up, MM, Set Timer
keys space; sleep 0.8; grab clock-7-timer-reopened
read -r d _ _ <<<"$(region clock-6-timer-set clock-7-timer-reopened "$TIMERBAND")"
awk -v d="$d" 'BEGIN { exit !(d > 5) }' \
    && ok "Set Timer hands the keys back to +: Space reopens the panel (Δ $d)" \
    || bad "after Set Timer, Space on + did nothing (Δ $d) — focus was lost"
errs_after="$(grep -cE 'ReferenceError|TypeError' "$log")"
[ "$errs_after" = "$errs_before" ] && ok "and no script error through the three edits (each rebuilds the list)" \
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
# Tab ×4 from the grid: Add time, Clear, Done — and wraps to ‹; Return there
# goes back a month; Shift+Tab wraps back to Done; Return saves.
keys Tab Tab Tab Tab Return; shot kanban-7-wrapped
# Shift+Tab as a keyboard sends it: the Tab key's shifted keysym ISO_Left_Tab,
# which Qt reads as Key_Backtab. `wtype -M shift -k Tab` is Tab with Shift held,
# a different event that KeyNavigation.backtab never sees.
wtype -M shift -k ISO_Left_Tab -m shift; sleep 0.3; keys Return; sleep 0.4; shot kanban-8-done
prev="$(date -d "$(date +%Y-%m-01) -1 month" +%Y-%m)"
becomes 1 "0 high $prev-02" 5 \
    && ok "Tab to Due, Return: the picker's day grid (Home, Right → the 2nd); Tab wraps Done → ‹ (Return: a month back), Shift+Tab wraps ‹ → Done, Return — due $prev-02" \
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
