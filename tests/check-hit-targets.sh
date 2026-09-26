#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-hit-targets.sh — every button is big enough to hit (UI/UX roadmap v3
#  Phase 21: "generous hit targets").
#
#  The sizes are the design system's, not this file's: ThemeSet.hitMin (32 px,
#  the smallest target outside the bar) and hitBar (24 px, inside it — the
#  WCAG 2.2 AA minimum, and the floor everywhere). A control's visual size and
#  its hit size are separate: ApexPressable's `hitMargin` grows the pointer
#  target past the drawn control on every side, so a 20 px glyph with
#  hitMargin 6 is a 32 px target.
#
#  It reads every ApexPressable and ApexIconButton in src/ whose width, height
#  and hitMargin are written as numbers (or theme.px(n), theme.hitMin,
#  theme.hitBar), and computes  min(width, height) + 2 × hitMargin.
#
#    FAIL  anything under 24 px — too small by any measure;
#    RATCHET  the count under hitMin outside the bar may not grow. Some sit in
#          rows packed tighter than 32 px, where a larger margin would steal
#          its neighbour's clicks; each fix lowers EXPECT_BELOW_GOAL.
#
#  Sizes written as bindings (parent.width, an expression) are not measured and
#  are counted as such — the runtime half is the live keyboard runners. The
#  scanner strips comments and strings first, so a size named in prose cannot
#  satisfy or trip it; the self-test at the bottom proves both directions.
#
#  Point it at another tree with APEX_HIT_SRC=/path/to/src.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${APEX_HIT_SRC:-$here/../src}"

# Under hitMin outside the bar, each bounded by a neighbour's visual (a margin
# may meet another margin or empty space, never another control's glyph):
#   KanbanBoard clear-time ✕ 28 px (the minute ▲'s corner), clear-due ✕ 26 px
#   (Due, 6 px away).
EXPECT_BELOW_GOAL="${EXPECT_BELOW_GOAL:-2}"

pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

scan() {   # scan <src dir> — one line per measured control: <px> <file>:<line> <in-bar 0|1>, then "unmeasured <n>"
    python3 - "$1" <<'PY'
import os, re, sys
root = sys.argv[1]
HIT_MIN, HIT_BAR = 32, 24

def strip(src):
    # comments and strings out, newlines kept so line numbers hold
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i); j = n if j < 0 else j
            i = j; continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2); j = n if j < 0 else j + 2
            out.append("\n" * src.count("\n", i, j)); i = j; continue
        if c in "\"'`":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            out.append('""' + "\n" * src.count("\n", i, j)); i = j + 1; continue
        out.append(c); i += 1
    return "".join(out)

def value(expr):
    expr = expr.strip().rstrip(";").strip()
    m = re.fullmatch(r"(\d+(?:\.\d+)?)", expr)
    if m: return float(m.group(1))
    m = re.fullmatch(r"theme\.px\(\s*(\d+(?:\.\d+)?)\s*\)", expr)
    if m: return float(m.group(1))
    if expr == "theme.hitMin": return HIT_MIN
    if expr == "theme.hitBar": return HIT_BAR
    return None

opener = re.compile(r"\b(ApexPressable|ApexIconButton)\s*\{")
unmeasured = 0
for dp, _, fs in os.walk(root):
    for f in sorted(fs):
        if not f.endswith(".qml"): continue
        path = os.path.join(dp, f)
        rel = os.path.relpath(path, root)
        if rel.startswith("components/controls/"): continue   # the primitives themselves
        src = strip(open(path, encoding="utf-8").read())
        in_bar = rel.startswith("modules/")
        for m in opener.finditer(src):
            start = m.end(); depth = 1; i = start
            while i < len(src) and depth:
                depth += {"{": 1, "}": -1}.get(src[i], 0); i += 1
            body = src[start:i - 1]
            # top-level statements only: drop nested blocks
            top, d = [], 0
            for ch in body:
                if ch == "{": d += 1
                elif ch == "}": d -= 1
                elif d == 0: top.append(ch)
            props = {}
            for stmt in re.split(r"[;\n]", "".join(top)):
                mm = re.match(r"\s*(width|height|hitMargin|size)\s*:\s*(.+)$", stmt)
                if mm: props[mm.group(1)] = mm.group(2)
            line = src.count("\n", 0, m.start()) + 1
            kind = m.group(1)
            if kind == "ApexIconButton":
                if "width" not in props and "height" not in props and "size" not in props:
                    continue   # its own default: hitMin, or hitBar in the bar — measured in the primitive
                if "size" in props and "width" not in props:
                    props["width"] = props["height"] = props["size"]
            w = value(props.get("width", "")); h = value(props.get("height", ""))
            hm = value(props["hitMargin"]) if "hitMargin" in props else 0.0
            if w is None or h is None or hm is None:
                unmeasured += 1; continue
            print(f"{int(min(w, h) + 2 * hm)} {rel}:{line} {int(in_bar)}")
print(f"unmeasured {unmeasured}")
PY
}

report="$(scan "$SRC")"
measured="$(grep -vc '^unmeasured' <<<"$report")"
unmeasured="$(sed -n 's/^unmeasured //p' <<<"$report")"
under_floor="$(awk '$1 < 24 && $1 != "unmeasured"' <<<"$report")"
below_goal="$(awk '$1 != "unmeasured" && $3 == 0 && $1 < 32' <<<"$report")"
n_below="$(grep -c . <<<"$below_goal")"

[ -z "$under_floor" ] && ok "no button under 24 px ($measured measured, $unmeasured sized by bindings)" \
    || bad "under the 24 px floor:$(printf '\n        %s' $(awk '{print $2"="$1"px"}' <<<"$under_floor"))"

if [ "$n_below" -eq "$EXPECT_BELOW_GOAL" ]; then
    ok "$n_below outside the bar under hitMin (32 px), unchanged"
elif [ "$n_below" -lt "$EXPECT_BELOW_GOAL" ]; then
    bad "under hitMin dropped to $n_below; lower EXPECT_BELOW_GOAL to $n_below"
else
    bad "under hitMin rose to $n_below from $EXPECT_BELOW_GOAL:$(printf '\n        %s' $(awk '{print $2"="$1"px"}' <<<"$below_goal"))"
fi

# ── self-test: the scanner measures code, not prose, in both directions ─────
st="$(mktemp -d)"; trap 'rm -rf "$st"' EXIT
mkdir -p "$st/services"
cat > "$st/services/Small.qml" <<'QML'
Item {
    // ApexPressable { width: 4; height: 4 }  — prose, must not count
    ApexPressable { width: 20; height: 20; hitMargin: 1 }
    ApexPressable { width: 20; height: 20; hitMargin: 6 }
    ApexPressable { width: parent.width; height: 28 }
    ApexPressable { width: 22; height: 22; Text { width: 400; text: "hitMargin: 40" } }
}
QML
got="$(scan "$st" | sort)"
want="$(printf '%s\n' "22 services/Small.qml:3 0" "22 services/Small.qml:6 0" "32 services/Small.qml:4 0" "unmeasured 1" | sort)"
[ "$got" = "$want" ] && ok "self-test: a comment and a string are ignored, a nested child's width is not the button's, a binding is unmeasured" \
    || bad "self-test: scanner read $(tr '\n' '|' <<<"$got") (wanted $(tr '\n' '|' <<<"$want"))"

printf '\ncheck-hit-targets: passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
