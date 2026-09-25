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
printf '%s' '{"background":"#171210","active":"#fab898","text":"#ece0dc","subtext":"#d6c2ba","border":"#52443e","iconFont":"#be8366"}' \
    > "$HOME/.cache/apex-shell/colors.json"
for fam in "$@"; do
    for sc in ${HARNESS_SCALES:-0.85 1.0 1.5}; do
        HARNESS_FAMILY="$fam" HARNESS_OUT="$out" HARNESS_SCALE="$sc" \
        HARNESS_BG="${HARNESS_BG:-$root/src/assets/wallpapers/apex-shell-default-0.png}" \
            timeout 60 quickshell -p "$staged" > "$HEADLESS_W/h-$fam-$sc.log" 2>&1
        grep -E 'TypeError|ReferenceError|is not a type|Error' "$HEADLESS_W/h-$fam-$sc.log" | head -5
        python3 "$here/contact-sheet.py" "$out" "$fam-s$sc-" "$out/sheet-$fam-s$sc.png" \
            --crop 150,0,1100,700 --scale 0.42 --cols 4 >/dev/null
        echo "sheet: $out/sheet-$fam-s$sc.png"
    done
done
