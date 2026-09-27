#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-notch-osd.sh — the level in the centre notch does not stretch.
#
#  Volume and brightness show IN the centre notch (TopBar's NotchOsd), which
#  widens 300 -> 360 px on its spring as the level scrolls in. Sized to the
#  notch's live width, the row stretched through the back half of that: the
#  glyph drifted left ~13 px, the value slid right ~23 px and the bar's end
#  crept (Andre, 2026-09-27: "the osd shows up in the notch, and the thumb
#  slides"). So:
#
#   1. FIXED  — NotchOsd's width is the width the notch widens TO
#      (theme.cNotchMaxWidth, less its padding), never root.cWidth.
#   2. CUT    — a switch between volume and brightness cuts the bar rather
#      than sliding it from one quantity's level to the other's.
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

top = code("src/windows/TopBar.qml")
m = re.search(r'NotchOsd\s*\{(.*?)\n\s*\}', top, re.S)
body = m.group(1) if m else ""
w = re.search(r'^\s*width\s*:\s*(.+)$', body, re.M)
wexpr = w.group(1).strip() if w else ""
verdict("FIXED", bool(m) and "cNotchMaxWidth" in wexpr and "cWidth" not in wexpr.replace("cNotchMaxWidth", ""),
        "NotchOsd width: " + (wexpr or "(none)"))

osd = code("src/modules/Center/NotchOsd.qml")
beh = re.search(r'Behavior\s+on\s+width\s*\{(.*?)\}', osd, re.S)
en = re.search(r'enabled\s*:\s*([^\n]+)', beh.group(1)) if beh else None
verdict("CUT", bool(en) and "_cut" in en.group(1) and re.search(r'on_KindChanged\s*:.*_cut\s*=\s*true', osd) is not None,
        "the bar's width Behavior must be off across a kind change")
PY
}

label() {
    case "$1" in
        FIXED) echo "the level row is laid out at the notch's final width, not its live one" ;;
        CUT)   echo "a volume <-> brightness switch cuts the bar instead of sliding it" ;;
    esac
}

echo "── the level in the notch ──"
verdicts="$(check_tree .)"
while read -r rule verdict detail; do
    [ -n "$rule" ] || continue
    if [ "$verdict" = PASS ]; then ok "$(label "$rule")"; else bad "$(label "$rule") — $detail"; fi
done <<<"$verdicts"
[ "$(grep -c . <<<"$verdicts")" -eq 2 ] && ok "both rules were evaluated" || bad "expected two verdicts, got: $verdicts"

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
mutant "the row sized to the live notch" src/windows/TopBar.qml \
    "width:   theme.cNotchMaxWidth - theme.notchPadding * 2" "width:   root.cWidth - theme.notchPadding * 2" FIXED
mutant "a kind switch that slides" src/modules/Center/NotchOsd.qml \
    "root.settled && !root._cut" "root.settled" CUT

echo
echo "check-notch-osd: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
