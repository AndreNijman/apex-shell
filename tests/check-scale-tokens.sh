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
# The scalers, as the tree actually spells them. `Theme.` is the global set and
# `theme.` is a per-output one (P1-040) — src/windows/DisplayConfirm.qml and
# src/windows/ConfirmDialog.qml build their own ThemeSet from their own screen
# and read it under that name. A rule that knows only `Theme\.` stops checking a
# file the moment it is migrated, which would have retired this guard one file
# at a time. The self-test below mutates through BOTH names.
SCALER='(Theme|Metrics|theme)'

GEOM='(radius|spacing|padding|margins|leftMargin|rightMargin|topMargin|bottomMargin'
GEOM+='|implicitHeight|implicitWidth|height|width|border\.width|columnSpacing|rowSpacing'
GEOM+='|anchors\.leftMargin|anchors\.rightMargin|anchors\.topMargin|anchors\.bottomMargin'
GEOM+='|anchors\.margins)'

geom_fs=$(grep -rnE "^[^/]*\b${GEOM}:[[:space:]]*${SCALER}\.fs\(" --include="*.qml" "$SRC" 2>/dev/null)
if [ -z "$geom_fs" ]; then
    ok "no geometric property uses fs() — the 7px legibility floor cannot clamp a layout"
else
    printf '%s\n' "$geom_fs" | head -20
    bad "no geometric property uses fs()"
fi

font_px=$(grep -rnE "^[^/]*font\.pixelSize:[[:space:]]*${SCALER}\.px\(" --include="*.qml" "$SRC" 2>/dev/null)
if [ -z "$font_px" ]; then
    ok "no font size uses px() — text keeps its legibility floor"
else
    printf '%s\n' "$font_px" | head -20
    bad "no font size uses px()"
fi

# The two scalers must remain different, or this whole check is theatre. If
# someone removes the floor from fs(), the check should stop claiming to
# protect anything.
# fs() lives in theme/ThemeSet.qml since P1-040 made the token table a component
# that Metrics is one instance of. The file is not hardcoded blindly: the check
# FINDS every definition and requires exactly one, because a second definition
# is how the per-output set and the global set would drift apart.
# A DEFINITION is an fs() that does the arithmetic; Theme.qml's
# `function fs(v) { return Metrics.fs(v) }` forwards to one and is not a second
# copy. The distinction matters: forwarders are how the tree keeps reading
# `Theme.fs()` unchanged, and a second real definition is how the global set and
# a per-output set would come to floor text differently.
fs_defs=""
for f in $(grep -rlE '^[[:space:]]*function fs\(' --include="*.qml" "$SRC/theme" 2>/dev/null); do
    grep -A3 -E '^[[:space:]]*function fs\(' "$f" | grep -qE 'Math\.max\([0-9]+' \
        && fs_defs="$fs_defs $f"
done
fs_count=$(printf '%s' "$fs_defs" | wc -w)
if [ "$fs_count" -eq 1 ]; then
    ok "fs() is defined exactly once (${fs_defs# }) and every other fs() forwards to it"
else
    bad "fs() carries the floor in $fs_count places:$fs_defs — one table, or the sets drift"
fi

if [ "$fs_count" -eq 1 ]; then
    ok "fs() still has a floor, so the distinction this check enforces is real"
else
    bad "fs() no longer has a floor — either it changed, or the token set moved"
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
    hit=$(grep -rnE "^[^/]*\b${GEOM}:[[:space:]]*${SCALER}\.fs\(" --include="*.qml" "$TMP/src" 2>/dev/null)
    if [ -n "$hit" ]; then
        ok "self-test $label: caught"
    else
        bad "self-test $label: SURVIVED — the check does not detect it"
    fi
    printf '%s' "$before" > "$target"
}

mutate_and_expect_fail "radius via fs()" \
    "src/services/agents/SessionRow.qml" "radius: Theme.px(" "radius: Theme.fs("

# The same mutation in the per-output spelling. Without this the rule could be
# narrowed back to `Theme\.` and the self-test would still say "caught".
mutate_and_expect_fail "radius via a PER-OUTPUT fs()" \
    "src/windows/DisplayConfirm.qml" "radius: theme.notchRadius" "radius: theme.fs(3)"

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

# ── One breakpoint table (P1-040) ───────────────────────────────────────────
#
# The table lived inside Metrics.qml, where nothing but a running quickshell
# could reach it, so tests/scaling-test.qml kept a copy called `bucket()` and
# asserted the copy against its own literals. Measured: moving the 1440p
# breakpoint from 1600 to 1500 in Metrics.qml left that suite at 25 passed, 0
# failed. It is now src/theme/scaling.js, and this keeps it there.

if [ -f "$SRC/theme/scaling.js" ]; then
    ok "the breakpoint table is a module both the shell and node can read"
else
    bad "src/theme/scaling.js is missing; the table is unreachable from a node test again"
fi

# An import STATEMENT, not the word. Metrics.qml explains itself at length and
# names the module in its own prose, so `grep -q scaling.js` passed on the
# comment after the import had been removed — the same shape as five earlier
# checks in this tree that matched documentation instead of code.
if grep -qE '^[[:space:]]*import[[:space:]]+"scaling\.js"' "$SRC/theme/Metrics.qml"; then
    ok "Metrics reads the table rather than carrying one"
else
    bad "Metrics.qml no longer imports theme/scaling.js"
fi

# A second copy of the arithmetic, wherever it is written, is the defect. The
# factors are distinctive enough to find on their own: a file outside
# theme/scaling.js that contains three or more of them is re-implementing it.
copies=""
for f in $(grep -rl '0\.85' --include='*.qml' --include='*.js' "$SRC" tests 2>/dev/null); do
    case "$f" in *theme/scaling.js) continue ;; esac
    n=0
    for v in '0\.85' '1\.20' '1\.35' '1\.50'; do
        grep -qE "return[[:space:]]+$v|\[[0-9]+,[[:space:]]*$v" "$f" && n=$((n+1))
    done
    [ "$n" -ge 3 ] && copies="$copies $f"
done
if [ -z "$copies" ]; then
    ok "nothing outside theme/scaling.js re-implements the breakpoint table"
else
    bad "the breakpoint table is duplicated in:$copies"
fi

# ── A migrated surface stays migrated (P1-040) ──────────────────────────────
#
# These files size themselves from their OWN output. A single `Theme.px(...)`
# reintroduced into one of them puts that one size back on the reference
# output's factor, which on a mixed desk is the original bug in a single
# property — and nothing would look wrong on a one-monitor machine, which is
# every machine a developer tests on.
#
# The file list is written out rather than discovered. Discovering it (say, by
# grepping for `ThemeSet {`) would mean that deleting the ThemeSet declaration
# removes the file from the list and the rule stops applying to it — an
# assertion that vanishes instead of failing. Each name is checked to exist and
# to still declare a per-output set, so deleting either fails the run.
PER_OUTPUT="src/windows/DisplayConfirm.qml src/windows/ConfirmDialog.qml"

# The scaled token names come from ThemeSet.qml itself: every property it
# defines through px(). Reading them from the source of truth means a token
# added there is covered here without anyone remembering to add it.
scaled_tokens=$(grep -oE '^[[:space:]]*property[[:space:]]+[a-z]+[[:space:]]+([a-zA-Z]+):[[:space:]]*px\(' \
                    "$SRC/theme/ThemeSet.qml" 2>/dev/null \
                | sed -E 's/.*[[:space:]]([a-zA-Z]+):.*/\1/' | sort -u | tr '\n' '|' | sed 's/|$//')
if [ -n "$scaled_tokens" ]; then
    ok "the scaled token names are read from ThemeSet.qml ($(printf '%s' "$scaled_tokens" | tr '|' ' ' | wc -w) of them)"
else
    bad "no scaled tokens found in $SRC/theme/ThemeSet.qml — this rule would check nothing"
fi

for f in $PER_OUTPUT; do
    if [ ! -f "$f" ]; then
        bad "per-output surface $f is missing"
        continue
    fi
    if grep -qE '^[[:space:]]*readonly property ThemeSet theme: ThemeSet \{' "$f" \
       && grep -qE 'scale:[[:space:]]*Theme\.factorForScreen\(' "$f"; then
        ok "$(basename "$f") builds its own ThemeSet from its own screen"
    else
        bad "$(basename "$f") no longer declares a per-output ThemeSet — it is back on the global factor"
    fi

    leak=$(grep -nE "Theme\.(px|fs)\(|Theme\.(${scaled_tokens})\b" "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*//')
    if [ -z "$leak" ]; then
        ok "$(basename "$f") reads no size from the global Theme"
    else
        printf '%s\n' "$leak" | head -10
        bad "$(basename "$f") reads a size from the global Theme, so that size ignores its output"
    fi
done

# And prove THAT rule can fail, with the mutation it exists to catch.
probe="$TMP/leakmutant.qml"
cp "src/windows/DisplayConfirm.qml" "$probe"
python3 - "$probe" <<'PY2'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); t = p.read_text()
p.write_text(t.replace("width:  theme.px(400)", "width:  Theme.px(400)", 1))
PY2
if grep -qE "Theme\.(px|fs)\(|Theme\.(${scaled_tokens})\b" "$probe"; then
    ok "self-test: one size put back on the global Theme is caught"
else
    bad "self-test: a global-Theme size SURVIVED — this rule does not detect it"
fi
rm -f "$probe"

printf '\ncheck-scale-tokens: passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
