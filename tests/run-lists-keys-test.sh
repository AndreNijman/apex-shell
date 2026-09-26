#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-lists-keys-test.sh — the notification centre and the clipboard history
#  on the keyboard (UI/UX roadmap v3 Phase 21), after the network panes'
#  template: each list one Tab stop, Up/Down to move, keys for the actions.
#
#  The real shell in a headless labwc, typed into with wtype, on a PRIVATE
#  session bus (it re-executes itself under dbus-run-session): it owns
#  org.freedesktop.Notifications there, and the notifications are sent with
#  gdbus, so nothing reaches the desktop. What the shell tells the sender is
#  read off the bus with gdbus monitor:
#
#    Notifications  three sent; Tab ×2 reaches the cards (Clear all, list);
#                   Delete dismisses the highlighted one  → NotificationClosed …, 2
#                   Down, Return on the one with a default action
#                                                         → ActionInvoked …, 'default'
#    Clipboard      (the history is tests/lib/fake-cliphist — the real one is
#                   the user's clipboard); Delete removes the highlighted entry,
#                   Return copies the next one back.
#
#  Skips (status 0) without quickshell, labwc, wtype, gdbus or dbus-run-session.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
if [ "${APEX_CAPTURE_BUS:-}" != private ]; then
    command -v dbus-run-session >/dev/null 2>&1 || { echo "SKIP: dbus-run-session is not installed"; exit 0; }
    exec env -u WAYLAND_DISPLAY -u DISPLAY dbus-run-session -- env APEX_CAPTURE_BUS=private "$0" "$@"
fi
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"
headless_require quickshell labwc wtype gdbus python3

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

headless_begin
ln -sf "$here/lib/fake-cliphist" "$HEADLESS_W/bin/cliphist"
ln -sf "$here/lib/fake-wl-copy" "$HEADLESS_W/bin/wl-copy"
export FAKE_CLIPHIST_LOG="$HEADLESS_W/cliphist.log" FAKE_WLCOPY_LOG="$HEADLESS_W/wlcopy.log"
: > "$FAKE_CLIPHIST_LOG"; : > "$FAKE_WLCOPY_LOG"
qs=""; mon=""
cleanup() {
    [ -n "$mon" ] && kill "$mon" 2>/dev/null
    [ -n "$qs" ] && kill "$qs" 2>/dev/null
    headless_cleanup
}
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
seen() {   # seen <file> <extended regex> <seconds>
    local _
    for _ in $(seq 1 $(( $3 * 4 ))); do grep -qE -- "$2" "$1" && return 0; sleep 0.25; done
    return 1
}
notify() {   # notify <summary> <actions json> — prints the id
    gdbus call --session --dest org.freedesktop.Notifications \
        --object-path /org/freedesktop/Notifications \
        --method org.freedesktop.Notifications.Notify \
        "Keytest" 0 "" "$1" "a body line" "$2" '{}' 0 | sed -E 's/.*uint32 ([0-9]+).*/\1/'
}
wtype -k Shift_L; sleep 0.3          # the first wtype key of a session is lost

# ── Notifications ────────────────────────────────────────────────────────────
gdbus monitor --session --dest org.freedesktop.Notifications > "$HEADLESS_W/bus.log" 2>&1 &
mon=$!
idA="$(notify "Has a default action" '["default","Open"]')"
idB="$(notify "Second" '[]')"
idC="$(notify "Newest" '[]')"
sleep 1
[ -n "$idA" ] && [ -n "$idC" ] || { bad "notifications were accepted (ids: $idA $idB $idC)"; }
ipc notification-toggle toggle; sleep 1.5
keys Tab Tab Delete
seen "$HEADLESS_W/bus.log" "NotificationClosed \(uint32 $idC, uint32 2\)" 5 \
    && ok "Tab ×2 reaches the cards; Delete dismisses the highlighted (newest) one" \
    || bad "Delete on the first card — the bus saw: $(grep -o 'NotificationClosed[^)]*)' "$HEADLESS_W/bus.log" | tr '\n' '|')"
sleep 1
keys Down Return
seen "$HEADLESS_W/bus.log" "ActionInvoked \(uint32 $idA, 'default'\)" 5 \
    && ok "Down, Return on the card with a default action invokes it" \
    || bad "Return on the oldest card — the bus saw: $(grep -o 'ActionInvoked[^)]*)' "$HEADLESS_W/bus.log" | tr '\n' '|')"
keys Escape; sleep 1

# ── Clipboard ────────────────────────────────────────────────────────────────
ipc clipboard-toggle toggle; sleep 1.5
keys Tab Tab Delete
seen "$FAKE_CLIPHIST_LOG" '^delete 12$' 5 \
    && ok "Tab ×2 reaches the history (Clear, list); Delete removes the highlighted entry" \
    || bad "Delete on the first entry — cliphist was asked: $(tr '\n' '|' < "$FAKE_CLIPHIST_LOG")"
sleep 1.5
keys Return
seen "$FAKE_WLCOPY_LOG" '^COPY second entry text$' 5 \
    && ok "the highlight moved to the next entry, and Return copied it back" \
    || bad "Return — the clipboard was given: $(tr '\n' '|' < "$FAKE_WLCOPY_LOG")"
[ "$(grep -c . "$FAKE_CLIPHIST_LOG")" = 1 ] && ok "and the history was asked for nothing else (no wipe)" \
    || bad "cliphist was also asked: $(tr '\n' '|' < "$FAKE_CLIPHIST_LOG")"

grep -E 'TypeError|ReferenceError|is not a type|Cannot assign' "$log" | head -3
printf '\nrun-lists-keys-test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
