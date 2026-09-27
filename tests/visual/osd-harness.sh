#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# osd-harness.sh — capture the OSD capsule (CAPSULE) in the private headless
# compositor: its entrance, a held key (the value bar tracking without the
# entrance replaying), and its exit after the hide timer.
#
#   tests/visual/osd-harness.sh OUTDIR
#
# Nothing here touches the desk: tests/lib/headless.sh gives it its own
# compositor, runtime dir and HOME.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="${1:?usage: $0 OUTDIR}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"
. "$root/tests/lib/headless.sh"
headless_require quickshell labwc grim
headless_begin
staged="$root/.osd-harness.qml"
cleanup() { rm -f "$staged"; headless_cleanup; }
trap cleanup EXIT INT TERM
[ -e /dev/dri/renderD128 ] && export HEADLESS_WLR_RENDERER=gles2
headless_start labwc 1920x1080 || exit 0
cp "$here/osd-harness.qml" "$staged"
mkdir -p "$HOME/.cache/apex-shell"
if [ -n "${CAPTURE_PALETTE:-}" ] && [ -f "$CAPTURE_PALETTE" ]; then
    cp "$CAPTURE_PALETTE" "$HOME/.cache/apex-shell/colors.json"
else
    headless_apex_palette dark   # the APEX-OS default look (tests/lib/headless.sh)
fi
command -v swaybg >/dev/null && swaybg -m fill -i "$HEADLESS_WALLPAPER" >/dev/null 2>&1 &

log="$HEADLESS_W/osd.log"
timeout 30 quickshell -p "$staged" > "$log" 2>&1 &
qs=$!

burst() {   # burst PREFIX T0_MS FRAMES SPAN_MS
    local i now target
    for i in $(seq 0 $(($3 - 1))); do
        target=$(( $2 + $4 * i / ($3 - 1) ))
        now=$(( $(date +%s%N) / 1000000 ))
        [ "$now" -lt "$target" ] && sleep "$(python3 -c "print(($target - $now) / 1000)")"
        now=$(( $(date +%s%N) / 1000000 ))
        grim -l 0 "$out/$(printf '%s-%02d-%05dms' "$1" "$i" "$((now - $2))").png" 2>/dev/null
    done
}
wait_for() {   # wait_for NAME — prints the epoch ms the harness stamped
    local t
    for _ in $(seq 1 200); do
        t="$(sed -nE "s/.*TRIGGER $1 ([0-9]+).*/\1/p" "$log" | head -1)"
        [ -n "$t" ] && { echo "$t"; return; }
        sleep 0.05
    done
}
t="$(wait_for show)";    [ -n "$t" ] && burst osd-show "$t" 12 600
t="$(wait_for held)";    [ -n "$t" ] && burst osd-held "$t" 12 1000
t="$(wait_for release)"; [ -n "$t" ] && burst osd-exit "$((t + 1300))" 10 500
wait "$qs" 2>/dev/null
grep -E 'TypeError|ReferenceError|is not a type|Binding loop' "$log" | head -5
echo "frames in $out"
