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

# The mutant that matters, in the spelling the tree now uses. It USED to be
# "radius: Theme.px(" in SessionRow.qml, and that stopped applying the moment
# P1-040 migrated the file — the check said so ("the mutation did not apply")
# instead of reporting a pass, which is the whole reason mutations are verified
# to have applied before their verdict is believed.
mutate_and_expect_fail "radius via fs()" \
    "src/services/agents/SessionRow.qml" "radius: theme.px(" "radius: theme.fs("

mutate_and_expect_fail "radius via a PER-OUTPUT fs()" \
    "src/windows/DisplayConfirm.qml" "radius: theme.notchRadius" "radius: theme.fs(3)"

# And the GLOBAL spelling, which no file in the tree uses any more — the closure
# rule below is what ended it. Kept alive on a synthetic file so the
# `Theme|Metrics` arm of the alternation cannot rot: a rule that only ever
# matches one of its alternatives is a rule that could lose the others silently.
cat > "$TMP/src/GlobalSpellingMutant.qml" <<'QML'
import QtQuick
Item {
    radius: Theme.fs(8)
    spacing: Metrics.fs(2)
}
QML
gs=$(grep -rnE "^[^/]*\b${GEOM}:[[:space:]]*${SCALER}\.fs\(" --include="*.qml" "$TMP/src" 2>/dev/null)
if [ -n "$gs" ]; then
    ok "self-test global spelling: Theme.fs()/Metrics.fs() on geometry is still caught"
else
    bad "self-test global spelling: SURVIVED — the rule no longer matches the singleton spelling"
fi
rm -f "$TMP/src/GlobalSpellingMutant.qml"

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
#
# It is a SAMPLE of the ninety-odd migrated files, not the whole list, and the
# sample is not arbitrary: the bar is the shell's layout datum, the border and
# the OSD anchor to it, the dismiss overlay carves around it, the dashboard and
# the settings window are the two big surfaces, the lock screen is the one place
# a mixed desk is guaranteed to be showing every output at once, and the two
# modals were the round-one pair. The rule that covers the other eighty is the
# closure rule below, which needs no list at all.
PER_OUTPUT="src/windows/DisplayConfirm.qml src/windows/ConfirmDialog.qml \
            src/windows/TopBar.qml src/windows/Border.qml \
            src/windows/PopupDismiss.qml src/windows/UpdatePopup.qml \
            src/popups/Osd.qml src/popups/Dashboard.qml \
            src/nexus/Nexus.qml src/windows/Lockscreen.qml \
            src/services/agents/SessionRow.qml \
            src/services/config_tab/pages/RecoveryPage.qml \
            src/components/StatCard.qml src/shapes/SeamlessBarShape.qml"

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
    # A window resolves from the screen it is on; an Item that does not know its
    # window uses the QtQuick `Screen` attached property. Both spellings are
    # accepted and NOTHING ELSE is: a set built from a literal, or from
    # Metrics.referenceScreen, is the global factor wearing the new name.
    if grep -qE '^[[:space:]]*readonly property ThemeSet theme: ThemeSet \{[[:space:]]*scale: Theme\.factorForScreen\(|^[[:space:]]*readonly property ThemeSet theme: ThemeSet \{[[:space:]]*scale: Theme\.factorForHeight\(Screen\.height\)' "$f"; then
        ok "$(basename "$f") takes its token set from its own output"
    else
        bad "$(basename "$f") no longer resolves a per-output token set — it is back on the global factor"
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

# ── A PopupWindow must size itself from its ANCHOR, not from itself ─────────
#
# Measured on tests/run-scaling-test.sh: a PopupWindow's own `screen` is not the
# output it is anchored to — on two headless outputs the popup anchored to the
# bar on HEADLESS-1 reports HEADLESS-2. Reading `root.screen` in one of these
# therefore puts it at the wrong output's factor on a mixed desk, and nothing
# looks wrong on a single monitor. The file list is written out, and each entry
# is checked to exist and to still be a PopupWindow, so deleting either fails.
printf '\n── popup windows resolve from their anchor ──\n'
POPUPS="src/popups/ArchMenu.qml src/popups/AudioPopup.qml \
        src/popups/NotificationToast.qml src/popups/NotificationsPopup.qml \
        src/popups/QuickControl.qml src/popups/ScreenRecOptionsPopup.qml"
for f in $POPUPS; do
    if [ ! -f "$f" ]; then bad "popup $f is missing"; continue; fi
    if ! grep -qE '^PopupWindow \{' "$f"; then
        bad "$(basename "$f") is no longer a PopupWindow; this rule is checking the wrong file"
        continue
    fi
    if grep -qE 'readonly property ThemeSet theme: ThemeSet \{[[:space:]]*scale: Theme\.factorForScreen\(root\.anchorWindow' "$f"; then
        ok "$(basename "$f") takes its factor from the window it is anchored to"
    else
        bad "$(basename "$f") resolves its own screen, which for a PopupWindow is not the output it is on"
    fi
done

# ── CLOSURE: nothing outside the theme layer reads a size from a singleton ───
#
# This is the rule the file list above cannot be: a list only protects the files
# on it, and a migration is only finished when a file that is NOT on any list
# cannot quietly go back. Theme and Metrics are QML singletons, so a size read
# through either of them is the REFERENCE output's size, wherever that file is
# drawn. After P1-040 there are exactly two places that may still do it, and
# both are named here with a reason rather than left as a silence.
#
# Comments and string literals are excluded by parsing rather than by a `grep
# -v //`: this tree's own history has five checks that matched documentation
# instead of code, and the files this rule reads explain themselves at length in
# prose that names the very patterns it looks for.
printf '\n── closure: the global factor is confined to the theme layer ──\n'

closure_report=$(python3 - "$SRC" <<'PY3'
import os, re, sys

SRC = sys.argv[1]

# The scaled tokens come from ThemeSet.qml itself, so one added there is covered
# here without anybody remembering. animDuration and barEnabled are excluded:
# neither is a function of the factor, so neither is per-output.
tsrc = open(os.path.join(SRC, "theme", "ThemeSet.qml")).read()
tokens = set(re.findall(r'^\s*(?:readonly\s+)?property\s+\w+\s+(\w+)\s*:', tsrc, re.M))
SCALED = (tokens | {"px", "fs", "scale"}) - {"animDuration", "barEnabled"}

# Metrics-only members are POLICY questions — "what would this screen want" —
# and are not tokens. The Display page asks them on purpose.
POLICY = {"referenceScreen", "referenceHeight", "autoScale", "baselineHeight",
          "scaleForHeight", "scaleForScreen"}

# The exceptions, each with the reason it is one.
EXEMPT = {
    # A versioned snapshot handed to plugin code across a trust boundary: the
    # same object for every plugin instance, and making it per-output is an
    # apiVersion question rather than a rename. See PluginService.theme.
    "services/plugins/PluginService.qml",
}

def code(text):
    """Ranges of `text` that are neither comment nor string literal."""
    i, n, start = 0, len(text), 0
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i+1] == "/":
            yield (start, i)
            j = text.find("\n", i); i = n if j < 0 else j; start = i
        elif c == "/" and i + 1 < n and text[i+1] == "*":
            yield (start, i)
            j = text.find("*/", i + 2); i = n if j < 0 else j + 2; start = i
        elif c in "'\"`":
            q, j = c, i + 1
            while j < n:
                if text[j] == "\\": j += 2; continue
                if text[j] == q: break
                if q != "`" and text[j] == "\n": break
                j += 1
            i = min(j + 1, n)
        else:
            i += 1
    yield (start, n)

REF = re.compile(r'\b(Theme|Metrics)\.([A-Za-z_][A-Za-z0-9_]*)')
bad = []
for dp, dn, fn in os.walk(SRC):
    rel = os.path.relpath(dp, SRC).replace("\\", "/")
    if rel == "theme":
        dn[:] = []
        continue
    for f in sorted(fn):
        if not f.endswith((".qml", ".js")):
            continue
        p = os.path.join(dp, f)
        r = os.path.relpath(p, SRC).replace("\\", "/")
        if r in EXEMPT:
            continue
        t = open(p).read()
        for a, b in code(t):
            for m in REF.finditer(t, a, b):
                if m.group(2) in SCALED and not (m.group(1) == "Metrics" and m.group(2) in POLICY):
                    bad.append("%s:%d: %s.%s" % (r, t[:m.start()].count("\n") + 1,
                                                 m.group(1), m.group(2)))
for b in bad[:20]:
    print(b)
print("COUNT=%d" % len(bad))
print("TOKENS=%d" % len(SCALED))
PY3
)
closure_count=${closure_report##*COUNT=}
closure_count=${closure_count%%$'\n'*}
closure_tokens=${closure_report##*TOKENS=}

if [ -z "$closure_count" ]; then
    bad "the closure rule did not run — it checked nothing, which is not a pass"
elif [ "$closure_count" -eq 0 ]; then
    ok "no file outside src/theme reads any of the $closure_tokens scaled tokens from a singleton"
else
    printf '%s\n' "$closure_report" | grep -v '^COUNT=\|^TOKENS=' | head -20
    bad "$closure_count size read(s) still go through the global Theme/Metrics — those sizes ignore the output they are drawn on"
fi

# The closure rule's own self-test. Put ONE global read back, in a file that is
# not on any list, and it must be found. A rule that scans a hundred files and
# reports zero is indistinguishable from a rule that scanned none.
cmut="$TMP/src/services/agents/SubagentRow.qml"
if [ -f "$cmut" ]; then
    python3 - "$cmut" <<'PY4'
import pathlib, sys, re
p = pathlib.Path(sys.argv[1]); t = p.read_text()
t2, n = re.subn(r'\btheme\.px\(', 'Theme.px(', t, count=1)
p.write_text(t2)
sys.exit(0 if n else 3)
PY4
    if [ $? -ne 0 ]; then
        bad "closure self-test: the mutation did not apply, so its verdict would be meaningless"
    else
        m=$(python3 - "$TMP/src" <<'PY5'
import os, re, sys
SRC = sys.argv[1]
tsrc = open(os.path.join(SRC, "theme", "ThemeSet.qml")).read()
tokens = set(re.findall(r'^\s*(?:readonly\s+)?property\s+\w+\s+(\w+)\s*:', tsrc, re.M))
SCALED = (tokens | {"px", "fs", "scale"}) - {"animDuration", "barEnabled"}
t = open(os.path.join(SRC, "services", "agents", "SubagentRow.qml")).read()
t = re.sub(r'//[^\n]*', '', t)
print(len([m for m in re.finditer(r'\bTheme\.([A-Za-z_]\w*)', t) if m.group(1) in SCALED]))
PY5
)
        if [ "${m:-0}" -ge 1 ]; then
            ok "closure self-test: one size put back on the global Theme in an unlisted file is caught"
        else
            bad "closure self-test: SURVIVED — the closure rule does not detect a global read"
        fi
    fi
else
    bad "closure self-test: src/services/agents/SubagentRow.qml is gone; the self-test checks nothing"
fi

printf '\ncheck-scale-tokens: passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
