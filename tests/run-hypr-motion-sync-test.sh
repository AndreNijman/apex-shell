#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-hypr-motion-sync-test.sh — Hyprland's animations follow the shell's
#  Motion settings (UI/UX roadmap v3 Phase 21; HyprlandBackend.syncMotion,
#  hyprMotion.js).
#
#  The real shell, in a real Hyprland, nested in a headless labwc: nothing is
#  drawn on this machine, and every hyprctl here carries the NESTED instance's
#  signature under a private XDG_RUNTIME_DIR, so none can reach the desk.
#
#    1. a slower shell makes a slower compositor (every declared class × the
#       shell's scale);
#    2. a shell RESTART does not scale its own push again — the failure the
#       per-instance state file exists for;
#    3. Reduce Motion switches the spatial classes off and caps the fades;
#    4. `hyprctl reload` (which restores the config's values) is followed by a
#       fresh push;
#    and the control: with no shell running, the config's own values stand.
#
#  Nested Hyprland comes up with NO output until one is made
#  (`hyprctl output create headless`), and its DRM backend tries libseat
#  first: LIBSEAT_BACKEND=seatd with no seatd socket makes that fail at once
#  instead of asking logind to take control of the live session.
#
#  Skips (status 0) without labwc, Hyprland or quickshell.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"
headless_require quickshell labwc Hyprland hyprctl python3

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
finish() { printf '\nrun-hypr-motion-sync-test: %d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]; }

headless_begin
# The shell's backend must reach the nested Hyprland, so it gets the real
# hyprctl; the signature and runtime dir it would need for any other are not
# in this environment.
headless_unstub hyprctl
lw=""; hy=""; qs=""
cleanup() {
    [ -n "$qs" ] && kill "$qs" 2>/dev/null
    [ -n "$hy" ] && kill "$hy" 2>/dev/null
    sleep 0.5
    [ -n "$lw" ] && kill "$lw" 2>/dev/null
    wait 2>/dev/null
    headless_cleanup
}
trap cleanup EXIT INT TERM

mkdir -p "$HEADLESS_W/cfg/labwc"
: > "$HEADLESS_W/cfg/labwc/autostart"
printf '<?xml version="1.0"?>\n<labwc_config></labwc_config>\n' > "$HEADLESS_W/cfg/labwc/rc.xml"
before="$(headless_sockets)"
env -i HOME="$HOME" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" XDG_CONFIG_HOME="$HEADLESS_W/cfg" \
    WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 labwc > "$HEADLESS_W/labwc.log" 2>&1 &
lw=$!
host="$(headless_wait_socket "$before")"
[ -n "$host" ] || { echo "SKIP: labwc did not come up headless"; exit 0; }

# A config of its own: the test is about the shell's sync, not apex-os's numbers.
mkdir -p "$HOME/.config/hypr"
cat > "$HOME/.config/hypr/hyprland.lua" <<'LUA'
hl.curve("tDecel", { type = "bezier", points = { { 0.05, 0.7 }, { 0.1, 1.0 } } })
hl.curve("tFx",    { type = "bezier", points = { { 0.3, 0.7 }, { 0.3, 1.0 } } })
hl.animation({ leaf = "windowsIn",  enabled = true, speed = 2.4, bezier = "tDecel", style = "popin 87%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 1.6, bezier = "tDecel", style = "popin 87%" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 2.0, bezier = "tDecel", style = "slide" })
hl.animation({ leaf = "fadeIn",     enabled = true, speed = 1.2, bezier = "tFx" })
hl.animation({ leaf = "border",     enabled = true, speed = 0.4, bezier = "tFx" })
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1.0 })
LUA

before="$(headless_sockets)"
env -i HOME="$HOME" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$host" \
    XDG_CURRENT_DESKTOP=Hyprland LIBSEAT_BACKEND=seatd \
    Hyprland --i-am-really-stupid > "$HEADLESS_W/hypr.log" 2>&1 &
hy=$!
sock=""
for _ in $(seq 1 60); do
    for f in "$XDG_RUNTIME_DIR"/hypr/*/.socket.sock; do [ -S "$f" ] && sock="$f"; done
    [ -n "$sock" ] && break; sleep 0.5
done
[ -n "$sock" ] || { echo "SKIP: the nested Hyprland did not come up"; exit 0; }
SIG="$(basename "$(dirname "$sock")")"
nest="$(headless_wait_socket "$before")"
[ -n "$nest" ] || { echo "SKIP: the nested Hyprland published no wayland socket"; exit 0; }
HC() { env -i HOME="$HOME" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" HYPRLAND_INSTANCE_SIGNATURE="$SIG" hyprctl "$@"; }
sleep 1; HC output create headless >/dev/null 2>&1; sleep 1
echo "host: labwc $host → Hyprland $nest (headless, private runtime)"

# leaf NAME → "enabled speed" as Hyprland reports it now
leaf() { HC -j animations | python3 -c '
import json, sys
d = json.load(sys.stdin); a = d[0] if d and isinstance(d[0], list) else d
for x in a:
    if isinstance(x, dict) and x.get("name") == sys.argv[1]:
        print(("on" if x["enabled"] else "off"), format(round(float(x["speed"]), 2), "g")); break
else: print("missing")' "$1"; }

settings() {   # settings <motionSpeed> <motionScale> <reduceMotion>
    mkdir -p "$HOME/.config/apex-shell/src/user_data"
    printf '{"motionSpeed":"%s","motionScale":%s,"reduceMotion":%s,"barEnabled":false}' "$1" "$2" "$3" \
        > "$HOME/.config/apex-shell/src/user_data/settings.json"
}
start_shell() {
    local log="$HEADLESS_W/shell-$1.log"
    WAYLAND_DISPLAY="$nest" XDG_CURRENT_DESKTOP=Hyprland HYPRLAND_INSTANCE_SIGNATURE="$SIG" \
        quickshell -p "$root/shell.qml" > "$log" 2>&1 &
    qs=$!
    for _ in $(seq 1 120); do grep -q "Configuration Loaded" "$log" && break; sleep 0.25; done
    sleep 3          # the provider probe, the backend's ready, the debounce, the push
}
stop_shell() { [ -n "$qs" ] && kill "$qs" 2>/dev/null; wait "$qs" 2>/dev/null; qs=""; sleep 0.5; }

# ── control: the config's own values, with no shell ──────────────────────────
[ "$(leaf windowsIn)" = "on 2.4" ] && ok "control: with no shell the config's own values stand (windowsIn 2.4)" \
    || bad "control: config values — got $(leaf windowsIn)"

# ── 1. relaxed × 2 = 2.5 ─────────────────────────────────────────────────────
settings relaxed 2 false
start_shell a
w="$(leaf windowsIn)"; f="$(leaf fadeIn)"; b="$(leaf border)"
[ "$w" = "on 6" ] && [ "$f" = "on 3" ] && [ "$b" = "on 1" ] \
    && ok "a slower shell is a slower compositor: every class × 2.5 (windowsIn 6, fadeIn 3, border 1)" \
    || bad "scale 2.5 — windowsIn $w, fadeIn $f, border $b"

# ── 2. a restart does not compound ───────────────────────────────────────────
stop_shell
start_shell b
w="$(leaf windowsIn)"
[ "$w" = "on 6" ] && ok "a shell restart does not scale its own push again (still 6, not 15)" \
    || bad "restart compounded — windowsIn $w"

# ── 3. Reduce Motion ─────────────────────────────────────────────────────────
stop_shell
settings relaxed 2 true
start_shell c
w="$(leaf windowsIn)"; ws="$(leaf workspaces)"; f="$(leaf fadeIn)"; b="$(leaf border)"
if [ "${w%% *}" = "off" ] && [ "${ws%% *}" = "off" ]; then
    ok "Reduce Motion switches the spatial classes off (windowsIn, workspaces)"
else
    bad "Reduce Motion spatial — windowsIn $w, workspaces $ws"
fi
[ "$f" = "on 1.5" ] && [ "$b" = "on 1" ] \
    && ok "…and keeps the fades, capped at 150 ms (fadeIn 1.5; border 1 already under it)" \
    || bad "Reduce Motion effects — fadeIn $f, border $b"

# ── 4. a reload is followed by a fresh push ──────────────────────────────────
HC reload >/dev/null 2>&1
sleep 2
w="$(leaf windowsIn)"
[ "${w%% *}" = "off" ] && ok "after hyprctl reload the shell pushes again (windowsIn off under Reduce Motion)" \
    || bad "after reload — windowsIn $w (the config's own value came back and stayed)"

stop_shell
finish
