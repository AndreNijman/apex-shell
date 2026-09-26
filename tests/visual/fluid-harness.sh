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
        case "$fam" in
            centerBloom)    crop="250,0,1000,640" ;;
            rightPour)      crop="900,0,600,700" ;;
            leftSpill)      crop="0,200,420,420" ;;
            edgeSpillRight) crop="1150,160,350,480" ;;
            *)              crop="0,0,1500,800" ;;
        esac
        python3 "$here/contact-sheet.py" "$out" "$fam-s$(printf %g "$sc")-" "$out/sheet-$fam-s$sc.png" \
            --crop "$crop" --scale 0.42 --cols 6 >/dev/null
        echo "sheet: $out/sheet-$fam-s$sc.png"
    done
done
