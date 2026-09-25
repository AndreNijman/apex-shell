#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# capture-surfaces.sh — visual baseline of every major shell surface.
#
# Runs THIS worktree's shell.qml inside a private headless labwc (the same
# sandbox tests/lib/headless.sh builds for every behavioural suite: stub
# binaries, private HOME and XDG dirs, a socket proven not to be the desk's),
# opens each surface over IPC and grabs a burst of frames with grim while it
# opens and while it closes. contact-sheet.py lays the bursts out side by side.
#
# It is a QA artifact, not a pass/fail suite: the roadmap's Phase 0 asks for a
# visual baseline "to prove improvement or regression", and a before/after pair
# of sheets is that proof. It lives under tests/visual/ so the CI reachability
# check (tests/check-suites-run-in-ci.sh) does not demand a workflow step for a
# tool that has nothing to assert.
#
#   tests/visual/capture-surfaces.sh OUTDIR [surface...]
#
# Environment:
#   CAPTURE_ANIM_MS    the legacy animDuration written to settings.json
#                      (default 1200 — the slider's maximum — so a 70 ms grim
#                      cadence lands ~15 frames inside one open)
#   CAPTURE_MODE       output mode, default 1920x1080
#   CAPTURE_FRAMES     frames grabbed per open / per close burst (default 14)
#   CAPTURE_PALETTE    colors.json to seed (default: the shipped example is a
#                      template, so a fixed dark palette is written instead)
#   CAPTURE_WALLPAPER  image drawn behind the shell with swaybg, so contrast
#                      against a real wallpaper is visible (default: shipped 0)
#
# Rendering is on the GPU (HEADLESS_WLR_RENDERER=gles2) when a render node is
# available, because pixman makes Qt fall back to software rasterising and the
# frames would not show what a user's machine draws.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

out="${1:-}"
[ -n "$out" ] || { echo "usage: $0 OUTDIR [surface...]"; exit 2; }
shift
mkdir -p "$out"
out="$(cd "$out" && pwd)"

# shellcheck source=../lib/headless.sh
. "$root/tests/lib/headless.sh"
headless_require quickshell grim labwc

anim="${CAPTURE_ANIM_MS:-1200}"
frames="${CAPTURE_FRAMES:-14}"
mode="${CAPTURE_MODE:-1920x1080}"
wall="${CAPTURE_WALLPAPER:-$root/src/assets/wallpapers/apex-shell-default-0.png}"

headless_begin
qs_pid=""; bg_pid=""
cleanup() {
    [ -n "$qs_pid" ] && kill "$qs_pid" 2>/dev/null
    [ -n "$bg_pid" ] && kill "$bg_pid" 2>/dev/null
    headless_cleanup
}
trap cleanup EXIT INT TERM

[ -e /dev/dri/renderD128 ] && export HEADLESS_WLR_RENDERER="${HEADLESS_WLR_RENDERER:-gles2}"
headless_start labwc "$mode" || exit 0

# ── seed the sandbox HOME ────────────────────────────────────────────────────
ud="$HOME/.config/apex-shell/src/user_data"
mkdir -p "$ud" "$HOME/.cache/apex-shell"
cat > "$ud/settings.json" <<JSON
{"cornerRadius":17,"borderWidth":6,"notchRadius":15,"notchHeight":40,"barEnabled":false,"spacing":10,"exclusionGap":34,"animDuration":${anim},"reduceMotion":false,"dashboardWidth":900,"dashboardHeight":520,"notificationsWidth":400,"lockBackground":"","scaleMode":"auto","scaleManual":1,"scaleScreen":"","nightLightTemp":5600,"motionSpeed":"balanced","motionScale":$(python3 -c "print(round(${anim}/320, 3))")}
JSON
if [ -n "${CAPTURE_PALETTE:-}" ] && [ -f "$CAPTURE_PALETTE" ]; then
    cp "$CAPTURE_PALETTE" "$HOME/.cache/apex-shell/colors.json"
else
    cat > "$HOME/.cache/apex-shell/colors.json" <<'JSON'
{"background":"#171210","active":"#fab898","text":"#ece0dc","subtext":"#d6c2ba","border":"#52443e","iconFont":"#be8366"}
JSON
fi

if command -v swaybg >/dev/null 2>&1 && [ -f "$wall" ]; then
    swaybg -m fill -i "$wall" >/dev/null 2>&1 &
    bg_pid=$!
fi

log="$HEADLESS_W/shell.log"
quickshell -p "$root/shell.qml" > "$log" 2>&1 &
qs_pid=$!
for _ in $(seq 1 120); do
    grep -q "Configuration Loaded" "$log" 2>/dev/null && break
    sleep 0.25
done
grep -q "Configuration Loaded" "$log" || { echo "FAIL: shell did not load"; tail -30 "$log"; exit 1; }
sleep 2.5    # boot-grace timers (OSD 900 ms), first paint, lazy singletons

ipc() { quickshell -p "$root/shell.qml" ipc call "$@" >/dev/null 2>&1; }

grab() {    # grab NAME — one uncompressed frame of the whole output
    grim -l 0 "$out/$1.png" 2>/dev/null
}

# Frames are spread evenly over the animation plus a tail, and every file name
# carries the milliseconds since the IPC call, so a sheet shows WHEN each frame
# was taken rather than only its order. grim itself takes ~10-30 ms, which is
# why the cadence is a target and the stamp is the truth.
span="${CAPTURE_SPAN_MS:-$(( anim * 13 / 10 ))}"
burst() {   # burst PREFIX T0_NS
    local i now ms target
    for i in $(seq 0 $((frames - 1))); do
        target=$(( span * i / (frames - 1) ))
        now=$(date +%s%N); ms=$(( (now - $2) / 1000000 ))
        if [ "$ms" -lt "$target" ]; then
            sleep "$(python3 -c "print(($target - $ms) / 1000)")"
        fi
        now=$(date +%s%N); ms=$(( (now - $2) / 1000000 ))
        grab "$(printf '%s-%02d-%05dms' "$1" "$i" "$ms")"
    done
}

# Each surface: the IPC call that opens it and the one that closes it. A
# toggle is its own inverse; Escape-only surfaces close through closeAll by
# toggling the same entry.
declare -A OPEN CLOSE
OPEN[bar]="";                              CLOSE[bar]=""
OPEN[dashboard]="dashboard-home toggle";   CLOSE[dashboard]="dashboard-home toggle"
OPEN[dash-stats]="dashboard-stats toggle"; CLOSE[dash-stats]="dashboard-stats toggle"
OPEN[dash-launcher]="dashboard-launcher toggle"; CLOSE[dash-launcher]="dashboard-launcher toggle"
OPEN[network]="wifi-toggle toggle";        CLOSE[network]="wifi-toggle toggle"
OPEN[audio]="audioOut-toggle toggle";      CLOSE[audio]="audioOut-toggle toggle"
OPEN[notifications]="notification-toggle toggle"; CLOSE[notifications]="notification-toggle toggle"
OPEN[power]="PowerMenu-toggle toggle";     CLOSE[power]="PowerMenu-toggle toggle"
OPEN[clipboard]="clipboard-toggle toggle"; CLOSE[clipboard]="clipboard-toggle toggle"
OPEN[wallpaper]="wallpaper-toggle toggle"; CLOSE[wallpaper]="wallpaper-toggle toggle"
OPEN[context]="context-menu open";         CLOSE[context]="context-menu close"
OPEN[nexus]="nexus open appearance";       CLOSE[nexus]="nexus close"
ORDER=(bar dashboard dash-stats dash-launcher network audio notifications power clipboard wallpaper context nexus)

want=("$@")
[ "${#want[@]}" -gt 0 ] || want=("${ORDER[@]}")

# A page change inside an open Dashboard: the shared tab pill travelling and
# the pages crossing in the direction of the tab order.
tab_switch() {
    ipc dashboard-home toggle; sleep 1.2
    t0=$(date +%s%N); ipc dashboard-stats toggle; burst "tabs-forward" "$t0"
    sleep 0.6
    t0=$(date +%s%N); ipc dashboard-home toggle; burst "tabs-back" "$t0"
    sleep 0.6
    ipc dashboard-home toggle; sleep 1.2
    echo "captured tabs"
}

for s in "${want[@]}"; do
    if [ "$s" = tabs ]; then tab_switch; continue; fi
    [ -n "${OPEN[$s]+x}" ] || { echo "unknown surface: $s"; continue; }
    if [ -z "${OPEN[$s]}" ]; then
        grab "$s-static"
        echo "captured $s"
        continue
    fi
    # Two cycles. The first open after login BUILDS the popup (LazyPopup),
    # and that open is its own code path — it has been the broken one more
    # than once — so it is kept as "cold". The second is the steady state.
    for phase in cold warm; do
        pre="$s-$phase"
        t0=$(date +%s%N)
        # shellcheck disable=SC2086
        ipc ${OPEN[$s]}
        burst "$pre-open" "$t0"
        sleep 0.6
        grab "$pre-settled"
        t0=$(date +%s%N)
        # shellcheck disable=SC2086
        ipc ${CLOSE[$s]}
        burst "$pre-close" "$t0"
        sleep 1.2
    done
    echo "captured $s"
done

errs="$(grep -E 'qml: |TypeError|ReferenceError' "$log" | grep -v -e 'PipeWire' -e 'pipewire' | head -20)"
[ -n "$errs" ] && { echo "--- shell log errors ---"; echo "$errs"; }
cp "$log" "$out/shell.log"
echo "frames in $out"
