#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  stress-matrix.sh — UI/UX roadmap v3 Phase 24, the parts a headless host can
#  drive: the shell in the private labwc (tests/lib/headless.sh), abused, and
#  then asked whether every surface came back to rest.
#
#      tests/visual/stress-matrix.sh OUTDIR
#
#  With APEX_PACING_LOG=1 every SurfaceLifecycle logs each map and unmap
#  ("APEX pacing: <name> mapped=true|false") and the lock logs its engagement
#  ("lock secure=true"). A surface that ends a scenario still mapped — a window
#  that would eat clicks, or keep a pour on screen — is the failure this looks
#  for, together with any QML error in the log.
#
#  Scenarios:
#    spam        every transient surface toggled 24 times, 0–150 ms apart (an
#                even count, so each must end CLOSED)
#    tab-switch  the Dashboard's page changed twice while it is still blooming
#    focus-mode  focus mode flipped while the Dashboard is open
#    lock        the screen locked with the Dashboard and a right pane open:
#                the lock must engage
#    notify      a burst of 12 notifications on the private bus, then closed
#
#  Not driven here, and why (stated, so a green report is not read as more):
#  immediate launcher typing and keyboard focus — run-dashboard-keys-test;
#  reversal at arbitrary progress — run-surface-lifecycle-test; monitor
#  disconnect — run-display-unplug-test; different scales — run-nav-geometry-
#  test; held volume keys (no PipeWire on the headless host), mixed refresh
#  rates and fullscreen games need hardware. A QA report, not a CI gate.
#
#  Writes OUTDIR/report.txt and OUTDIR/shell.log.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
. "$root/tests/lib/headless.sh"
headless_require quickshell labwc python3 gdbus

out="${1:-}"; [ -n "$out" ] || { echo "usage: $0 OUTDIR"; exit 2; }
mkdir -p "$out"; out="$(cd "$out" && pwd)"

headless_begin
ln -sf "$root/tests/lib/fake-nmcli" "$HEADLESS_W/bin/nmcli"
ln -sf "$root/tests/lib/fake-bluetoothctl" "$HEADLESS_W/bin/bluetoothctl"
ln -sf "$root/tests/lib/fake-brightnessctl" "$HEADLESS_W/bin/brightnessctl"
[ -e /dev/dri/renderD128 ] && export HEADLESS_WLR_RENDERER=gles2
headless_start labwc 1920x1080 || exit 0
python3 "$root/tests/lib/fake-mpris.py" /dev/null & player=$!
qs=""
trap 'kill $player $qs 2>/dev/null; headless_cleanup' EXIT

ud="$HOME/.config/apex-shell/src/user_data"; mkdir -p "$ud"
printf '%s' '{"barEnabled":true,"motionScale":1,"dashboardWidth":900,"dashboardHeight":520}' > "$ud/settings.json"
printf '{"currentWall":"%s","mode":"dark"}' "$HEADLESS_WALLPAPER" > "$ud/wallpaper.json"
headless_apex_palette dark

log="$out/shell.log"
env APEX_PACING_LOG=1 quickshell -p "$root/shell.qml" > "$log" 2>&1 & qs=$!
for _ in $(seq 1 120); do grep -q "Configuration Loaded" "$log" && break; sleep 0.25; done
grep -q "Configuration Loaded" "$log" || { echo "FAIL: the shell did not load"; tail -20 "$log"; exit 1; }
sleep 3

ipc() { quickshell -p "$root/shell.qml" ipc call "$@" >/dev/null 2>&1; }
rnd() { python3 -c "import random; print(random.randint(0, $1) / 1000)"; }
mark() { echo "APEX stress: $1" >> "$log"; }
# Every surface that is mapped right now, from the log (name → last state).
still_mapped() {
    python3 - "$log" <<'PY'
import re, sys
state = {}
for line in open(sys.argv[1], errors="replace"):
    m = re.search(r"APEX pacing: (\S+) mapped=(true|false)", line)
    if m: state[m.group(1)] = m.group(2) == "true"
print(" ".join(sorted(k for k, v in state.items() if v)))
PY
}
report="$out/report.txt"; : > "$report"
verdict() {   # verdict <scenario> <ok?> <detail>
    if [ "$2" = 1 ]; then printf 'PASS  %s\n' "$1" | tee -a "$report"
    else printf 'FAIL  %s — %s\n' "$1" "$3" | tee -a "$report"; fi
}
settle_and_check() {   # settle_and_check <scenario>
    sleep 1.6
    local m; m="$(still_mapped)"
    if [ -z "$m" ]; then verdict "$1: every surface came back to rest" 1 ""
    else verdict "$1: every surface came back to rest" 0 "still mapped: $m"; fi
}

# ── spam ─────────────────────────────────────────────────────────────────────
mark "spam"
for tgt in dashboard-home wifi-toggle notification-toggle audioOut-toggle \
           PowerMenu-toggle clipboard-toggle wallpaper-toggle quick-toggle; do
    for _ in $(seq 1 24); do ipc "$tgt" toggle; sleep "$(rnd 150)"; done
done
settle_and_check "spam (8 surfaces × 24 toggles, 0–150 ms apart)"

# ── tab switch during the bloom ──────────────────────────────────────────────
mark "tab-switch"
ipc dashboard-home toggle; sleep 0.08
ipc dashboard-launcher toggle; sleep 0.08
ipc dashboard-stats toggle; sleep 1.0
ipc dashboard-stats toggle
settle_and_check "tab switch twice while the Dashboard is blooming"

# ── focus mode while open ────────────────────────────────────────────────────
mark "focus-mode"
ipc dashboard-home toggle; sleep 0.3
ipc focus-toggle toggle; sleep 0.6
ipc focus-toggle toggle; sleep 0.4
ipc dashboard-home toggle
settle_and_check "focus mode flipped under an open Dashboard"

# ── notifications burst ──────────────────────────────────────────────────────
mark "notify"
ids=()
for i in $(seq 1 12); do
    r="$(gdbus call --session --dest org.freedesktop.Notifications \
         --object-path /org/freedesktop/Notifications \
         --method org.freedesktop.Notifications.Notify \
         "stress" 0 "" "Burst $i" "Notification number $i of twelve" '[]' '{}' 5000 2>/dev/null)"
    id="$(sed -n 's/^(uint32 \([0-9]*\),)$/\1/p' <<<"$r")"; [ -n "$id" ] && ids+=("$id")
    sleep "$(rnd 90)"
done
verdict "notify: the shell took all 12 notifications" "$([ ${#ids[@]} -eq 12 ] && echo 1 || echo 0)" "${#ids[@]} ids"
sleep 1.0
for id in "${ids[@]}"; do
    gdbus call --session --dest org.freedesktop.Notifications \
        --object-path /org/freedesktop/Notifications \
        --method org.freedesktop.Notifications.CloseNotification "$id" >/dev/null 2>&1
    sleep "$(rnd 60)"
done
sleep 5.5    # the last toast's own timeout
settle_and_check "notify: 12 in a burst, then closed"

# ── lock with surfaces open ──────────────────────────────────────────────────
# Last: nothing unlocks a headless lock (the only unlock is PAM).
mark "lock"
ipc dashboard-home toggle; sleep 0.25
ipc lockscreen lock
for _ in $(seq 1 40); do grep -q "APEX pacing: lock secure=true" "$log" && break; sleep 0.1; done
verdict "lock: the lock engages with the Dashboard open" \
        "$(grep -q 'APEX pacing: lock secure=true' "$log" && echo 1 || echo 0)" "no 'lock secure=true' in the log"

# ── errors ───────────────────────────────────────────────────────────────────
errs="$(grep -aE 'TypeError|ReferenceError|is not a type|Cannot assign|binding loop|non-existent property' "$log" | head -5)"
verdict "no QML error anywhere in the run" "$([ -z "$errs" ] && echo 1 || echo 0)" "$errs"

kill "$qs" "$player" 2>/dev/null
echo
fails="$(grep -c '^FAIL' "$report")"
echo "stress-matrix: $(grep -c '^PASS' "$report") passed, $fails failed — $report"
[ "$fails" -eq 0 ]
