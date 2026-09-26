#!/usr/bin/env bash
# password-shapes-harness.sh OUTDIR [motion-scale] [reduced 0/1]
# Renders the scripted typing session in the private headless compositor and
# lays the frames out as one sheet.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="${1:?usage: $0 OUTDIR [scale] [reduced]}"; mkdir -p "$out"; out="$(cd "$out" && pwd)"
# shellcheck source=../lib/headless.sh
. "$root/tests/lib/headless.sh"
headless_require quickshell labwc
headless_begin
staged="$root/.password-shapes-harness.qml"
cleanup() { rm -f "$staged"; headless_cleanup; }
trap cleanup EXIT INT TERM
[ -e /dev/dri/renderD128 ] && export HEADLESS_WLR_RENDERER=gles2
headless_start labwc 1280x720 || exit 0
cp "$here/password-shapes-harness.qml" "$staged"
HARNESS_OUT="$out" HARNESS_SCALE="${2:-1}" HARNESS_REDUCED="${3:-0}" \
    timeout 120 quickshell -p "$staged" > "$HEADLESS_W/h.log" 2>&1
grep -E 'TypeError|ReferenceError|is not a type|rror' "$HEADLESS_W/h.log" | head -5
python3 "$here/contact-sheet.py" "$out" "" "$out/sheet.png" --scale 1.0 --cols 5 >/dev/null && echo "sheet: $out/sheet.png"
