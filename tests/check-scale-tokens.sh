#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-scale-tokens.sh — geometry uses Theme.px(), text uses Theme.fs().
#
#  ── Why this check exists ───────────────────────────────────────────────────
#  Theme exposes two scalers and they are NOT interchangeable:
#
#      px(v) = Math.round(v * scale)
#      fs(v) = Math.max(7, Math.round(v * scale))     <- legibility floor
#
#  The floor exists because text below about 7px is illegible at any DPI. It is
#  correct for a font size and wrong for everything else, because it silently
#  CLAMPS every small geometric value up to 7.
#
#  This was not hypothetical. The Agent Center was built using `Theme.fs()` for
#  radius, spacing, margins and heights — 42 call sites. Sixteen of them were
#  under the floor, so on screen:
#
#      spacing: Theme.fs(2)   rendered as 7px   (3.5x too loose)
#      spacing: Theme.fs(3)   rendered as 7px
#      leftMargin: Theme.fs(4) rendered as 7px  (nearly 2x)
#      radius: Theme.fs(3)    rendered as 7px   (more than 2x too round)
#
#  The result was a tab whose spacing rhythm and corner radii matched nothing
#  else in the shell — reported by the developer as "the agent tab didn't match
#  apex shell at all". Every unit test passed throughout: nothing was broken,
#  the wrong function was simply being called, and no check looked.
#
#  It also spread. When a later change added a remote-agents section, it copied
#  the surrounding idiom and introduced twelve more.  A wrong local convention
#  reproduces itself, which is the argument for a check rather than a fix.
#
#  ── What it does NOT do ─────────────────────────────────────────────────────
#  It does not care about the numbers, only about which scaler wraps them, and
#  it says nothing about a literal — `radius: 8` is a separate question this
#  check deliberately leaves alone.
#
#  PASS = no geometric property is wrapped in Theme.fs(), and no font size is
#         wrapped in Theme.px().
#
#  Run from anywhere: ./tests/check-scale-tokens.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
set +e
cd "$(dirname "$0")/.." || exit 2

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

SRC=src
[ -d "$SRC" ] || { echo "FATAL: no $SRC directory" >&2; exit 2; }

# Geometric properties, as they are actually written in this codebase. Anchored
# to a property assignment so a mention in a comment or a string cannot match —
# the failure mode this repository has hit five times.
GEOM='(radius|spacing|padding|margins|leftMargin|rightMargin|topMargin|bottomMargin'
GEOM+='|implicitHeight|implicitWidth|height|width|border\.width|columnSpacing|rowSpacing'
GEOM+='|anchors\.leftMargin|anchors\.rightMargin|anchors\.topMargin|anchors\.bottomMargin'
GEOM+='|anchors\.margins)'

geom_fs=$(grep -rnE "^[^/]*\b${GEOM}:[[:space:]]*Theme\.fs\(" --include="*.qml" "$SRC" 2>/dev/null)
if [ -z "$geom_fs" ]; then
    ok "no geometric property uses Theme.fs() — the 7px legibility floor cannot clamp a layout"
else
    printf '%s\n' "$geom_fs" | head -20
    bad "no geometric property uses Theme.fs()"
fi

font_px=$(grep -rnE "^[^/]*font\.pixelSize:[[:space:]]*Theme\.px\(" --include="*.qml" "$SRC" 2>/dev/null)
if [ -z "$font_px" ]; then
    ok "no font size uses Theme.px() — text keeps its legibility floor"
else
    printf '%s\n' "$font_px" | head -20
    bad "no font size uses Theme.px()"
fi

# The two scalers must remain different, or this whole check is theatre. If
# someone removes the floor from fs(), the check should stop claiming to
# protect anything.
if grep -qE 'function fs\(' "$SRC/theme/Metrics.qml" 2>/dev/null \
   && grep -A3 -E 'function fs\(' "$SRC/theme/Metrics.qml" | grep -qE 'Math\.max\([0-9]+'; then
    ok "fs() still has a floor, so the distinction this check enforces is real"
else
    bad "fs() no longer has a floor — either it changed, or Metrics.qml moved"
fi

# ── the self-test: prove each check can actually fail ───────────────────────
# Mutations are applied to a COPY, and each is verified to have changed the
# file before its verdict is believed. A mutant that failed to apply must be
# reported as such, never as caught — this repository has produced exactly that
# false verdict before.
printf '\n── self-test: can these checks fail? ──\n'
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cp -r "$SRC" "$TMP/src"

mutate_and_expect_fail() {
    local label="$1" file="$2" from="$3" to="$4"
    local target="$TMP/$file"
    [ -f "$target" ] || { bad "self-test $label: no such file $file"; return; }
    local before after
    before=$(cat "$target")
    python3 - "$target" "$from" "$to" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); t = p.read_text()
p.write_text(t.replace(sys.argv[2], sys.argv[3], 1))
PY
    after=$(cat "$target")
    if [ "$before" = "$after" ]; then
        bad "self-test $label: the mutation did not apply, so its verdict would be meaningless"
        return
    fi
    # Re-run the geometry check against the mutated copy only.
    local hit
    hit=$(grep -rnE "^[^/]*\b${GEOM}:[[:space:]]*Theme\.fs\(" --include="*.qml" "$TMP/src" 2>/dev/null)
    if [ -n "$hit" ]; then
        ok "self-test $label: caught"
    else
        bad "self-test $label: SURVIVED — the check does not detect it"
    fi
    printf '%s' "$before" > "$target"
}

mutate_and_expect_fail "radius via fs()" \
    "src/services/agents/SessionRow.qml" "radius: Theme.px(" "radius: Theme.fs("

# And the inverse mutant: a COMMENT naming the forbidden pattern must NOT trip
# the check. Without this, the check could be passing on prose.
cat > "$TMP/src/InverseMutant.qml" <<'QML'
import QtQuick
// A comment that mentions radius: Theme.fs(8) and spacing: Theme.fs(2)
// deliberately, because this file proves prose cannot fail the check.
Item {
    // padding: Theme.fs(4)
    radius: Theme.px(4)
}
QML
inv=$(grep -rnE "^[^/]*\b${GEOM}:[[:space:]]*Theme\.fs\(" --include="*.qml" "$TMP/src" 2>/dev/null)
if [ -z "$inv" ]; then
    ok "self-test inverse: a comment naming the pattern does not cause a false failure"
else
    printf '%s\n' "$inv" | head -5
    bad "self-test inverse: prose tripped the check"
fi
rm -f "$TMP/src/InverseMutant.qml"

printf '\ncheck-scale-tokens: passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
