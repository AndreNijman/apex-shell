#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-fluid-drop-test.sh — the Nexus extrusion's shader against its field.
#
#  Stages the REAL src/shapes/fluid (FluidDrop.qml, fluiddrop.frag.qsb,
#  geometry.js, FluidShape.qml) and runs tests/fluid-drop-test.qml under
#  qmltestrunner on a PRIVATE headless compositor (tests/lib/headless.sh):
#  a shader needs a hardware scene graph, which the offscreen platform does
#  not have — there ShaderEffect draws nothing. No window on anybody's desk.
# ─────────────────────────────────────────────────────────────────────────────
. "$(dirname "${BASH_SOURCE[0]}")/lib/private-bus.sh"   # the session bus is ours, not the desktop's
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"

runner=""
for c in qmltestrunner-qt6 qmltestrunner \
         /usr/lib64/qt6/bin/qmltestrunner /usr/lib/qt6/bin/qmltestrunner; do
    if command -v "$c" >/dev/null 2>&1; then runner="$c"; break; fi
done
[[ -n "$runner" ]] || { echo "SKIP: qmltestrunner not installed (qt6-qtdeclarative-devel)"; exit 0; }

stage="$(mktemp -d)"
cleanup() { rm -rf "$stage"; headless_cleanup; }
trap cleanup EXIT INT TERM

mkdir -p "$stage/shapes"
cp -r "$root/src/shapes/fluid" "$stage/shapes/fluid"
cp "$here/fluid-drop-test.qml" "$stage/"
: > "$stage/qmldir"
for f in FluidDrop.qml FluidShape.qml geometry.js fluiddrop.frag.qsb; do
    cmp -s "$root/src/shapes/fluid/$f" "$stage/shapes/fluid/$f" \
        || { echo "RESULT: the staged tree lost $f"; exit 1; }
done

headless_begin
headless_start || exit 0

out="$(QT_QPA_PLATFORM=wayland timeout 120 "$runner" -platform wayland \
       -input "$stage/fluid-drop-test.qml" 2>&1)"
rc=$?
echo "$out" | grep -E -A3 "^(PASS|FAIL|Totals)|QWARN|is not a type|Error" | grep -v "^PASS" | head -60

if grep -q 'is not a type\|module .* is not installed' <<<"$out"; then
    echo "RESULT: the staged drop did not load"; exit 1
fi
passed="$(sed -n 's/^Totals: \([0-9]*\) passed.*/\1/p' <<<"$out")"
[[ -n "$passed" && "$passed" -ge 6 ]] || { echo "RESULT: too few tests ran (${passed:-0})"; exit 1; }
[[ $rc -eq 0 ]] || { echo "RESULT: failing assertions"; exit 1; }

# ── Can it fail? A shader that drifts from the field must be caught. ────────
# Each mutant is compiled into the staged tree and must FAIL the test (repo
# idiom: a mutant that did not apply is reported as such, never as caught).
qsb=""
for c in qsb qsb-qt6 /usr/lib64/qt6/bin/qsb /usr/lib/qt6/bin/qsb; do
    command -v "$c" >/dev/null 2>&1 && { qsb="$c"; break; }
done
[[ -n "$qsb" ]] || { echo "RESULT: FAIL — qsb (qt6-shadertools) is needed to build the self-test mutants"; exit 1; }
selffail=0
mutant() {   # mutant <label> <old> <new> [<geometry.js old> <geometry.js new>]
    python3 - "$root/src/shapes/fluid/fluiddrop.frag" "$stage/mut.frag" "$2" "$3" <<'PY2' || { echo "  FAIL self-test $1: the mutation did not apply"; selffail=1; return; }
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
if old not in s: sys.exit(3)
open(dst, "w").write(s.replace(old, new, 1))
PY2
    if [[ $# -ge 5 ]]; then
        python3 - "$root/src/shapes/fluid/geometry.js" "$stage/shapes/fluid/geometry.js" "$4" "$5" <<'PY2' || { echo "  FAIL self-test $1: the geometry mutation did not apply"; selffail=1; return; }
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
if old not in s: sys.exit(3)
open(dst, "w").write(s.replace(old, new, 1))
PY2
    fi
    "$qsb" --glsl "100 es,120,150" --hlsl 50 --msl 12 -o "$stage/shapes/fluid/fluiddrop.frag.qsb" "$stage/mut.frag" >/dev/null \
        || { echo "  FAIL self-test $1: the mutant did not compile"; selffail=1; return; }
    if QT_QPA_PLATFORM=wayland timeout 120 "$runner" -platform wayland -input "$stage/fluid-drop-test.qml" >/dev/null 2>&1; then
        echo "  FAIL self-test $1: SURVIVED"; selffail=1
    else
        echo "  ok   self-test $1: caught"
    fi
    cp "$root/src/shapes/fluid/geometry.js" "$stage/shapes/fluid/geometry.js"
}
mutant "a meniscus twice the field's" "h * h * k * 0.25" "h * h * k * 0.5"
# Two guards keep the notch box off the bar: the shader item starts at the
# seam, and the shader discards above it. Either alone suffices, so the
# mutant removes both.
mutant "no seam: the notch box drawn over the bar" "if (p.y < notchBox.z) {" "if (p.y < -100000.0) {" \
       "bounds: { x: bx0, y: y0, w: bx1 - bx0, h: by1 - y0 }," "bounds: { x: bx0, y: 0, w: bx1 - bx0, h: by1 },"
mutant "the bell dropped" "float dl = lowerA.w > 0.5" "float dl = lowerA.w > 1.5"
mutant "the waist's blend ignored (a V where the neck meets the bell)" \
       "smin(dc, dl, blends.z), blends.w);" "smin(dc, dl, blends.z), 0.0);"
cp "$root/src/shapes/fluid/fluiddrop.frag.qsb" "$stage/shapes/fluid/fluiddrop.frag.qsb"
[[ $selffail -eq 0 ]] || { echo "RESULT: the test cannot tell a drifted shader from the field"; exit 1; }

echo "RESULT: the shader runs, draws the field it is held to at every stage of the extrusion, nothing above the seam and nothing when closed; four drifted shaders caught"
