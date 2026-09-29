#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-frame-fillets.sh — the frame's corners merge into its strips.
#
#  The frame is three layer surfaces (windows/Border.qml: left, right, bottom)
#  under the bar. Each strip's fillet reaches thickness + radius from its
#  corner, but the surfaces were sized to the radius alone: every fillet was
#  cut off short of its tangent and met the straight strip with a step, and the
#  bar's hairline ran across the top ones (Andre, 2026-09-27: "the corners
#  fillets dont merge properly"). So:
#
#   SIDES   a side strip is thickness + radius wide (its flare fits)
#   BOTTOM  the bottom strip is thickness + radius tall (its fillets fit)
#   TILE    a side strip ends thickness + radius above the bottom, where the
#           bottom strip's fillet takes over
#   JOIN    a side strip starts one row inside the bar (margins.top − overlap),
#           so its flare meets the bar's edge
#   RIM     the bar's hairline stops at the strips (SeamlessBarShape passes
#           frameInset = borderWidth + cornerRadius), and Border strokes the
#           rim on
#   LEAD    …and the bar draws the rim's first pixels itself: the strip's
#           first row is the bar's last, under the bar's surface, so the rim
#           was hidden there and the line ended in a ledge with the rim a row
#           lower (Andre, 2026-09-29: "theres a little weird bump"). The bar
#           passes frameRadius = cornerRadius (Border's radius) to
#           barHairline, which carries each end round the rim's circle
#   INPUT   the input region stays the strips' old footprint (a radius): the
#           wider box is drawing only, over the edges of the windows beside it
#   WINDOWS Hyprland's window rounding follows the frame (HyprlandBackend
#           syncWindowCorners → Geo.windowRounding): at start, after a config
#           reload, after a gaps write, and when the corner radius or strip
#           width changes
#
#  Each rule is mutated on a copy to prove it can fail.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

check_tree() {   # check_tree <root> — "RULE PASS|FAIL detail" per rule
    python3 - "$1" <<'PY'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
def code(p):
    return "\n".join(l.split("//", 1)[0] for l in (root / p).read_text().split("\n"))
def verdict(rule, good, detail=""):
    print(rule, "PASS" if good else "FAIL", detail)
b = code("src/windows/Border.qml")
def prop(name):
    m = re.search(r'^\s*' + re.escape(name) + r'\s*:\s*(.+)$', b, re.M)
    return m.group(1).strip() if m else ""
iw, ih = prop("implicitWidth"), prop("implicitHeight")
verdict("SIDES", "thickness + radius" in iw, "implicitWidth: " + iw)
verdict("BOTTOM", "thickness + radius" in ih, "implicitHeight: " + ih)
mb = re.search(r'margins\s*\{(.*?)\n\s*\}', b, re.S)
margins = mb.group(1) if mb else ""
bot = re.search(r'bottom\s*:\s*([^\n]+)', margins)
verdict("TILE", bool(bot) and "thickness + radius" in bot.group(1), "margins.bottom: " + (bot.group(1).strip() if bot else "(none)"))
top = re.search(r'top\s*:\s*([^\n]+)', margins)
verdict("JOIN", bool(top) and "overlap" in top.group(1) and re.search(r'overlap\s*:\s*1\b', b) is not None,
        "margins.top: " + (top.group(1).strip() if top else "(none)"))
sb = code("src/shapes/SeamlessBarShape.qml")
fi = re.search(r'property\s+int\s+frameInset\s*:\s*([^\n]+)', sb)
passes = re.search(r'frameInset\s*:\s*root\.frameInset', sb) is not None
stroke = "ctx.stroke()" in b and "rimColor" in b
verdict("RIM", bool(fi) and "borderWidth" in fi.group(1) and "cornerRadius" in fi.group(1) and passes and stroke,
        "frameInset: " + (fi.group(1).strip() if fi else "(none)") + (", passed" if passes else ", NOT passed")
        + (", rim stroked" if stroke else ", no rim"))
fr = re.search(r'property\s+int\s+frameRadius\s*:\s*([^\n]+)', sb)
fr_passed = re.search(r'frameRadius\s*:\s*root\.frameRadius', sb) is not None
brad = re.search(r'property\s+int\s+radius\s*:\s*([^\n]+)', b)
same = bool(fr) and bool(brad) and fr.group(1).strip() == brad.group(1).strip()
verdict("LEAD", same and fr_passed,
        "bar frameRadius: " + (fr.group(1).strip() if fr else "(none)") + ", Border radius: "
        + (brad.group(1).strip() if brad else "(none)") + (", passed" if fr_passed else ", NOT passed"))
ia = re.search(r'id:\s*inputArea(.*?)\n\s*\}', b, re.S)
body = ia.group(1) if ia else ""
masked = re.search(r'mask\s*:\s*Region\s*\{\s*item\s*:\s*inputArea\s*\}', b) is not None
footprint = "root.radius" in body and "thickness" not in body
verdict("INPUT", masked and footprint, ("masked" if masked else "NO mask") + ("; a radius wide" if footprint else "; footprint wider than a radius"))
h = code("src/services/compositor/HyprlandBackend.qml")
reload = re.search(r'"configreloaded"\)\s*\{[^}]*syncWindowCorners\(\)', h, re.S) is not None
start = re.search(r'Component\.onCompleted\s*:\s*\{[^}]*syncWindowCorners\(\)', h, re.S) is not None
gaps = re.search(r'_gapsWriteProc\s*:\s*Process\s*\{[^}]*syncWindowCorners\(\)', h, re.S) is not None
theme = "onCornerRadiusChanged() { root.syncWindowCorners() }" in h and "onBorderWidthChanged()  { root.syncWindowCorners() }" in h
rule = "Geo.windowRounding(t.cornerRadius, t.borderWidth" in h and "decoration = { rounding = " in h and "ThemeSet { scale: Theme.factorForScreen(root._cornersScreen) }" in h
miss = [n for n, ok in (("reload", reload), ("start", start), ("gaps", gaps), ("theme", theme), ("rule", rule)) if not ok]
verdict("WINDOWS", not miss, "missing: " + ",".join(miss) if miss else "all five")
PY
}

label() {
    case "$1" in
        SIDES)  echo "a side strip is wide enough for its whole flare" ;;
        BOTTOM) echo "the bottom strip is tall enough for its whole fillets" ;;
        TILE)   echo "a side strip ends where the bottom strip's fillet begins" ;;
        JOIN)   echo "a side strip starts one row inside the bar, its flare meeting the bar's edge" ;;
        RIM)    echo "the bar's hairline stops at the strips and the strips carry it on" ;;
        LEAD)   echo "the bar draws the rim's first pixels, the ones under its own surface" ;;
        INPUT)  echo "the input region stays a radius wide: the wider box only draws" ;;
        WINDOWS) echo "Hyprland's window rounding follows the frame, and is re-applied whenever it could drift" ;;
    esac
}

echo "── the frame's corners ──"
verdicts="$(check_tree .)"
while read -r rule verdict detail; do
    [ -n "$rule" ] || continue
    if [ "$verdict" = PASS ]; then ok "$(label "$rule")"; else bad "$(label "$rule") — $detail"; fi
done <<<"$verdicts"
[ "$(grep -c . <<<"$verdicts")" -eq 8 ] && ok "all eight rules were evaluated" || bad "expected eight verdicts, got: $verdicts"

echo "── self-test: can these checks fail? ──"
MW="$(mktemp -d)"; trap 'rm -rf "$MW"' EXIT INT TERM
mutant() {   # mutant <label> <file> <old> <new> <rule that must FAIL>
    rm -rf "$MW/t"; mkdir -p "$MW/t"; cp -r src "$MW/t/src"
    if ! python3 - "$MW/t/$2" "$3" "$4" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if old not in s: sys.exit(3)
open(p, "w").write(s.replace(old, new, 1))
PY
    then bad "self-test $1: the mutation did not apply"; return; fi
    if check_tree "$MW/t" | grep -q "^$5 FAIL"; then ok "self-test $1: caught"
    else bad "self-test $1: SURVIVED"; fi
}
mutant "side strips sized to the radius" src/windows/Border.qml \
    '? thickness + radius : 0
    implicitHeight' '? radius : 0
    implicitHeight' SIDES
mutant "the bottom strip sized to the radius" src/windows/Border.qml \
    'implicitHeight: (edge === "bottom") ? thickness + radius : 0' 'implicitHeight: (edge === "bottom") ? radius : 0' BOTTOM
mutant "side strips ending a radius up" src/windows/Border.qml \
    'bottom: (edge !== "bottom") ? thickness + radius : 0' 'bottom: (edge !== "bottom") ? radius : 0' TILE
mutant "side strips starting below the bar" src/windows/Border.qml \
    ' - root.overlap : 0' ' : 0' JOIN
mutant "the bar's line drawn to the screen edge" src/shapes/SeamlessBarShape.qml \
    'frameInset:    root.frameInset' 'frameInset:    0' RIM
mutant "the bar leaving the rim's first pixels to a surface it covers" src/shapes/SeamlessBarShape.qml \
    $',\n        frameRadius:   root.frameRadius' '' LEAD
mutant "a lead-in on a different radius than the strips'" src/shapes/SeamlessBarShape.qml \
    'property int frameRadius: theme.cornerRadius' 'property int frameRadius: theme.radiusM' LEAD
mutant "no input mask: the whole box takes clicks" src/windows/Border.qml \
    'mask: Region { item: inputArea }' '' INPUT
mutant "a config reload leaves the windows' rounding to the config" src/services/compositor/HyprlandBackend.qml \
    $'                root._pushLayerRules()\n                root.syncWindowCorners()' '                root._pushLayerRules()' WINDOWS

echo
echo "check-frame-fillets: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
