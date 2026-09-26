#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# fluid-harness.sh — render a fluid shape family at 11 progress values, at each
# of the three prototype scales (Fluid roadmap §33: 0.85 / 1.0 / 1.5), in the
# private headless compositor, then lay each scale out as one sheet.
#
#   tests/visual/fluid-harness.sh OUTDIR family [family...]
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="${1:?usage: $0 OUTDIR family...}"; shift
mkdir -p "$out"; out="$(cd "$out" && pwd)"
# shellcheck source=../lib/headless.sh
. "$root/tests/lib/headless.sh"
headless_require quickshell labwc
headless_begin
staged="$root/.fluid-harness.qml"
cleanup() { rm -f "$staged"; headless_cleanup; }
trap cleanup EXIT INT TERM
[ -e /dev/dri/renderD128 ] && export HEADLESS_WLR_RENDERER=gles2
headless_start labwc 1920x1080 || exit 0
cp "$here/fluid-harness.qml" "$staged"
mkdir -p "$HOME/.cache/apex-shell"
headless_apex_palette dark   # the APEX-OS default look (tests/lib/headless.sh)
for fam in "$@"; do
    for sc in ${HARNESS_SCALES:-0.85 1.0 1.5}; do
        HARNESS_FAMILY="$fam" HARNESS_OUT="$out" HARNESS_SCALE="$sc" \
        HARNESS_BG="${HARNESS_BG:-$HEADLESS_WALLPAPER}" \
            timeout 60 quickshell -p "$staged" > "$HEADLESS_W/h-$fam-$sc.log" 2>&1
        grep -E 'TypeError|ReferenceError|is not a type|Error' "$HEADLESS_W/h-$fam-$sc.log" | head -5
        # Crops scale with the output scale, in the 1920x1080 stage: at a fixed
        # size the 1.5x bodies ran out of the tile.
        crop="$(python3 -c "
import sys
sc = float('$sc'); W, H = 1920, 1080
def box(x, y, w, h):
    x, y = max(0, int(x)), max(0, int(y)); w, h = min(W - x, int(w)), min(H - y, int(h))
    print(f'{x},{y},{w},{h}')
f = '$fam'
if   f == 'centerBloom':    box(W/2 - 520*sc, 0, 1040*sc, 640*sc)
elif f == 'rightPour':      box(W - 620*sc, 0, 620*sc, 700*sc)
elif f == 'leftSpill':      box(0, 400*sc - 220*sc, 440*sc, 440*sc)
elif f == 'edgeSpillRight': box(W - 380*sc, 400*sc - 260*sc, 380*sc, 520*sc)
else:                       box(0, 0, W, H)
")"
        python3 "$here/contact-sheet.py" "$out" "$fam-s$(printf %g "$sc")-" "$out/sheet-$fam-s$sc.png" \
            --crop "$crop" --scale 0.42 --cols 6 >/dev/null
        echo "sheet: $out/sheet-$fam-s$sc.png"
    done
done
