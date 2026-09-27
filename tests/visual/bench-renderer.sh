#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# bench-renderer.sh — CPU per frame of the shape renderers, on the real GPU.
#
#   tests/visual/bench-renderer.sh [variant...]    (default: idle shape geometry canvas busy)
#
# Runs bench-renderer.qml in the private headless labwc from tests/lib/headless.sh
# with WLR_RENDERER=gles2, so Qt renders through the machine's GPU while nothing
# appears on the desk. `busy` adds a 2 ms JavaScript spin per frame: it must read
# ~2 ms above `idle`, or the measurement is not measuring.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
# shellcheck source=../lib/headless.sh
. "$root/tests/lib/headless.sh"
headless_require quickshell labwc
headless_begin
trap headless_cleanup EXIT INT TERM
[ -e /dev/dri/renderD128 ] || { echo "SKIP: no GPU render node"; exit 0; }
export HEADLESS_WLR_RENDERER=gles2
headless_start labwc 1280x720 || exit 0

variants=("$@")
[ "${#variants[@]}" -gt 0 ] || variants=(idle shape geometry canvas busy)
tck="$(getconf CLK_TCK)"
cpu_tree() {
    local t=0 p kids
    kids="$(pgrep -P "$1")"
    for p in $1 $kids $(for c in $kids; do pgrep -P "$c"; done); do
        t=$((t + $(awk '{print $14+$15}' "/proc/$p/stat" 2>/dev/null || echo 0)))
    done
    echo "$t"
}
for v in "${variants[@]}"; do
    o="$HEADLESS_W/bench-$v.txt"
    : > "$o"
    BENCH_VARIANT="$v" timeout 60 quickshell -p "$here/bench-renderer.qml" > "$o" 2>&1 &
    qp=$!; c0=""; c1=""
    while kill -0 "$qp" 2>/dev/null; do
        [ -z "$c0" ] && grep -q MARK-START "$o" && c0="$(cpu_tree "$qp")"
        [ -n "$c0" ] && [ -z "$c1" ] && grep -q MARK-END "$o" && c1="$(cpu_tree "$qp")"
        sleep 0.02
    done
    [ -n "$c0" ] && [ -n "$c1" ] || { echo "$v: no measurement"; tail -5 "$o"; continue; }
    python3 -c "c=($c1-$c0)*1000/$tck; print('%-9s cpu=%5.0f ms  cpu/frame=%.3f ms' % ('$v', c, c/600))"
done
