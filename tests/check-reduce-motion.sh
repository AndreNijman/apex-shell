#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-reduce-motion.sh — how much of the shell the Reduce Motion switch
#  actually reaches (roadmap P2-003).
#
#  ── Why this exists ─────────────────────────────────────────────────────────
#
#  "Reduce motion" is a real setting with a real UI: SettingsService.reduceMotion
#  persists, LayoutPage offers it, and `effectiveAnim` collapses to 0 when it is
#  on. It reads, from the outside, like a finished feature.
#
#  It reaches 39 of this tree's 450 animation durations. The other 402 are
#  integer literals written in place — `ColorAnimation { duration: 120 }` — and
#  no switch can touch them. A user who turns Reduce Motion on because motion
#  makes them ill still gets 89% of the animation, and nothing anywhere said so:
#  there was no test of this setting at all before this file.
#
#  This is that number, made durable. It is a measurement, not an aspiration, so
#  the counts are asserted EXACTLY and in both directions:
#
#    * literals going UP is the regression — somebody wrote another animation
#      the switch cannot reach;
#    * literals going DOWN without editing the constant means somebody fixed
#      some and the ratchet should be tightened to lock that in;
#    * the total moving means the scanner's idea of an animation changed, and a
#      scanner that quietly stops finding things is how an exact count turns
#      into a green light for nothing. check-color-tokens.sh's EXPECT_WHITE_FG
#      established this idiom for the same reason.
#
#  ── What it does NOT claim ──────────────────────────────────────────────────
#
#  It reads the source; it does not run the shell. The runtime half — turn the
#  setting on in a live shell and read a Behavior's duration back — needs the
#  Quickshell harness (SettingsService imports Quickshell, so qmltestrunner
#  cannot load it) and is NOT built. That assertion is named in
#  ROADMAP/state/agents/p2-b.md rather than pretended to here.
#
#  ── Why the scanner is not a grep ───────────────────────────────────────────
#
#  Two things a grep gets wrong, both measured:
#
#    * comments and strings. This tree documents its own animation decisions in
#      prose, and `// duration: 120` is not an animation.
#    * one level of indirection. `duration: root.animDuration` is invisible to a
#      grep for Theme.animDuration, and there are nine such sites; six of them
#      DO honour the setting through a local property, and three do not
#      (`index * 650` is a stagger, `root.timeout` a notification lifetime, and
#      PlayerCard's is a marquee whose speed is a width). Counting all nine
#      either way would be wrong either way, so local properties are resolved.
#
#  Run from the repository root.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2

pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }
section() { printf '\n── %s ──\n' "$1"; }

SS="src/services/SettingsService.qml"
MET="src/theme/Metrics.qml"
TH="src/theme/Theme.qml"
for f in "$SS" "$MET" "$TH"; do
    [ -f "$f" ] || { echo "FATAL: cannot find $f" >&2; exit 2; }
done

# ── The scanner ──────────────────────────────────────────────────────────────
# Prints three integers: honouring, bare-literal, unresolved.
scan() {   # scan <tree-root>
    python3 - "$1" <<'PY'
import re, sys, pathlib

def strip(src):
    """Remove comments and string bodies. QML prose about animations is not an
    animation, and this tree carries a lot of it."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i+1] == '/':
            while i < n and src[i] != '\n':
                i += 1
        elif c == '/' and i + 1 < n and src[i+1] == '*':
            i += 2
            while i + 1 < n and not (src[i] == '*' and src[i+1] == '/'):
                i += 1
            i += 2
        elif c in '"\'':
            q = c; i += 1
            while i < n and src[i] != q:
                if src[i] == '\\':
                    i += 1
                i += 1
            i += 1
        else:
            out.append(c); i += 1
    return "".join(out)

# Every spelling that reaches SettingsService.reduceMotion.
HONOURS = re.compile(r'(Theme\.animDuration|Metrics\.animDuration'
                     r'|SettingsService\.effectiveAnim|SettingsService\.reduceMotion)')

hon = lit = unres = 0
for p in sorted(pathlib.Path(sys.argv[1]).rglob("*.qml")):
    s = strip(p.read_text())
    props = {}
    for m in re.finditer(r'^\s*(?:readonly\s+)?property\s+\w+\s+(\w+)\s*:\s*([^\n]+)',
                         s, re.M):
        props[m.group(1)] = m.group(2)
    for m in re.finditer(r'\bduration\s*:\s*([^\n;}]+)', s):
        v = m.group(1).strip()
        if HONOURS.search(v):
            hon += 1; continue
        if re.match(r'^\d+$', v):
            lit += 1; continue
        ref = re.match(r'^(?:root\.)?(\w+)$', v)
        if ref and ref.group(1) in props and HONOURS.search(props[ref.group(1)]):
            hon += 1; continue
        unres += 1
print(hon, lit, unres)
PY
}

read -r HON LIT UNRES <<<"$(scan src)"
TOTAL=$(( HON + LIT + UNRES ))

section "the mechanism still exists"
# Asserting the counts without asserting the mechanism would be measuring the
# reach of a switch that no longer connects to anything. Each link, named.
if grep -qE '^\s*property\s+bool\s+reduceMotion' "$SS"; then
    ok "SettingsService still has a reduceMotion setting"
else
    bad "SettingsService still has a reduceMotion setting"
fi
if grep -qE 'readonly\s+property\s+int\s+effectiveAnim:\s*reduceMotion\s*\?\s*0\s*:' "$SS"; then
    ok "effectiveAnim still collapses to 0 when reduce-motion is on"
else
    bad "effectiveAnim still collapses to 0 when reduce-motion is on"
fi
if grep -qE 'property\s+int\s+animDuration:\s*SettingsService\.effectiveAnim' "$MET"; then
    ok "Metrics.animDuration still reads effectiveAnim"
else
    bad "Metrics.animDuration still reads effectiveAnim"
fi
if grep -qE 'property\s+int\s+animDuration:\s*Metrics\.animDuration' "$TH"; then
    ok "Theme.animDuration still mirrors Metrics"
else
    bad "Theme.animDuration still mirrors Metrics"
fi
if grep -qE 'reduceMotion' src/services/config_tab/pages/LayoutPage.qml 2>/dev/null; then
    ok "the setting is still offered to the user"
else
    bad "the setting is still offered to the user"
fi

section "the reach, counted exactly"
# ── THE RATCHET ──
# Lower EXPECT_LITERAL when you convert some. Never raise it: a new
# `duration: 120` is a new animation Reduce Motion cannot switch off.
EXPECT_HONOUR=39
EXPECT_LITERAL=402
EXPECT_UNRESOLVED=9

echo "  reduce-motion reaches $HON of $TOTAL animation durations"
echo "  $LIT are integer literals no setting can touch; $UNRES resolve to neither"

if [ "$HON" -eq "$EXPECT_HONOUR" ]; then
    ok "exactly $EXPECT_HONOUR durations honour the setting"
else
    bad "expected $EXPECT_HONOUR durations honouring the setting, found $HON — if you converted some, raise EXPECT_HONOUR and lower EXPECT_LITERAL together"
fi

if [ "$LIT" -eq "$EXPECT_LITERAL" ]; then
    ok "exactly $EXPECT_LITERAL durations are literals the setting cannot reach"
elif [ "$LIT" -gt "$EXPECT_LITERAL" ]; then
    bad "$LIT hardcoded durations, was $EXPECT_LITERAL — a new animation was written that Reduce Motion cannot switch off. Bind it to Theme.animDuration"
else
    bad "$LIT hardcoded durations, was $EXPECT_LITERAL — some were converted, which is the point; lower EXPECT_LITERAL to $LIT to lock it in"
fi

if [ "$UNRES" -eq "$EXPECT_UNRESOLVED" ]; then
    ok "exactly $EXPECT_UNRESOLVED durations resolve to neither (staggers, timeouts, a marquee)"
else
    bad "expected $EXPECT_UNRESOLVED unresolved durations, found $UNRES"
fi

# The premise of every count above: the scanner can still see anything at all.
# An exact count that has quietly become 0/0/0 passes nothing but says nothing.
if [ "$TOTAL" -gt 300 ]; then
    ok "the scanner still finds the animation durations ($TOTAL)"
else
    bad "the scanner found only $TOTAL durations; it has stopped working and every count above is meaningless"
fi

# ── Self-test ────────────────────────────────────────────────────────────────
# The repo idiom (check-scale-tokens.sh, check-color-tokens.sh): mutate a COPY,
# verify the mutation actually applied before believing the verdict — a mutant
# that failed to apply must be reported as such, never as caught — then re-scan.
section "self-test: can these counts move?"

MW="$(mktemp -d)"
cleanup() { rm -rf "$MW"; }
trap cleanup EXIT INT TERM

selftest() {   # selftest <label> <python-mutation-over-s> <expect: honour|literal>
    local label="$1" py="$2" which="$3"
    rm -rf "$MW/src"; cp -r src "$MW/src"
    python3 - "$MW/src/popups/Dashboard.qml" <<PY
import sys
p = sys.argv[1]; s = open(p).read(); before = s
$py
if s == before:
    sys.exit(3)
open(p, "w").write(s)
PY
    if [ $? -ne 0 ]; then
        bad "self-test $label: the mutation did not apply, so its verdict is meaningless"
        return
    fi
    read -r mh ml _ <<<"$(scan "$MW/src")"
    case "$which" in
        literal) [ "$ml" -gt "$LIT" ] && ok "self-test $label: caught" \
                     || bad "self-test $label: SURVIVED (literals $ml, was $LIT)" ;;
        honour)  [ "$mh" -lt "$HON" ] && ok "self-test $label: caught" \
                     || bad "self-test $label: SURVIVED (honouring $mh, was $HON)" ;;
    esac
}

selftest "a new hardcoded animation" \
    's = s.replace("Behavior on opacity {", "Behavior on x { NumberAnimation { duration: 999 } }\nBehavior on opacity {", 1)' \
    literal

selftest "an existing binding replaced by a literal" \
    's = s.replace("duration: root.animDuration", "duration: 250", 1)' \
    honour

# The inverse: prose must be invisible. Without this the scanner could be
# counting the comments this tree writes about its own animations.
rm -rf "$MW/src"; cp -r src "$MW/src"
cat > "$MW/src/InverseMutant.qml" <<'QML'
import QtQuick
// duration: 120
// Behavior on x { NumberAnimation { duration: 9999 } }
/* duration: 77 */
Item { property string note: "duration: 4242" }
QML
read -r _ il _ <<<"$(scan "$MW/src")"
if [ "$il" -eq "$LIT" ]; then
    ok "self-test inverse: durations named in comments and strings are invisible"
else
    bad "self-test inverse: prose was counted ($il vs $LIT)"
fi

printf '\ncheck-reduce-motion: passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
