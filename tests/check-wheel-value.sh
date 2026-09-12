#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-wheel-value.sh — the wheel navigates and scrolls. It never sets a value.
#
#  ── Why this check exists ───────────────────────────────────────────────────
#  Reported as UI-004: "Scrolling over sliders changes values." Every settings
#  page is read by scrolling, the shared CfgSlider carried a WheelHandler, and
#  so reading a page edited it. The user asked for the absolute rule rather than
#  a tuning: a value bar never reads the wheel; scrolling scrolls; a value moves
#  on click, drag or a key.
#
#  It was not one control. The same handler had been copied onto five:
#
#      CfgSlider              every settings page  inside CfgScroll
#      AudioControl columns   audio popup          inside PopupPage
#      QuickControl columns   quick-control popup  no scroll container
#      QuickSettings bright.  dashboard card       no scroll container
#      TimeInput HH/MM        timer and alarm      accepted the event too
#
#  Two of those sat in a Flickable, so the bug reproduced literally. The other
#  three did not, and that is the argument for a check rather than a fix: the
#  idiom spreads to wherever a bar gets drawn next, and the day that bar lands
#  in a scrolling page nobody re-reads the wheel handler underneath it.
#
#  ── Two lists, not one ──────────────────────────────────────────────────────
#  The wheel is a legitimate input. Cycling workspaces, flipping a tab, moving a
#  carousel, forwarding to a tray icon, turning a vertical wheel into horizontal
#  scroll — all of those are navigation, and all of them stay. So there is an
#  ALLOWLIST of the sites that remain, each with what it does and why it is not
#  an edit.
#
#  An allowlist alone would be too weak here, because the fix is re-broken by
#  adding a row to it. So the value bars are named separately in a DENYLIST that
#  no allowlist entry can override: those files may hold no wheel site at all.
#  Each denylist row also names the call that sets the value, and that call must
#  still be present — otherwise the list quietly becomes a set of filenames that
#  no longer describe anything, which is how a guard stops guarding.
#
#  ── What it does NOT do ─────────────────────────────────────────────────────
#  It reads source, not behaviour. Whether the wheel actually reaches the page
#  is a runtime question, and tests/run-slider-wheel-test.sh answers it by
#  posting a real QWheelEvent at a real CfgSlider inside a real CfgScroll. This
#  check is the half that scales: it covers the four value bars that need
#  Pipewire, a backlight and a compositor to instantiate, which no headless
#  runner can stand up.
#
#  Wheel sites are found with a comment- and string-aware scanner, so neither a
#  WheelHandler named in a `//` or `/* */` comment nor one quoted inside a
#  string can satisfy or trip this check. Five checks in this project have been
#  satisfied by their own prose; the self-test at the bottom proves this one
#  cannot be, in both directions.
#
#  PASS = the set of wheel sites in code equals the allowlist exactly, and no
#         value-bar file holds one.
#
#  Run from anywhere: ./tests/check-wheel-value.sh
#  Point it at another tree with APEX_WHEEL_SRC=/path/to/src (used to prove it
#  fails on the code as it was before UI-004 was fixed).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
set +e
cd "$(dirname "$0")/.." || exit 2

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

SRC="${APEX_WHEEL_SRC:-src}"
[ -d "$SRC" ] || { echo "FATAL: no $SRC directory" >&2; exit 2; }

# ── The allowlist: wheel sites that are navigation or scrolling ─────────────
# file | what the wheel does there | why that is not a value edit
ALLOW_RAW="
src/modules/Left/Workspaces.qml|cycles the occupied workspaces|moving focus between workspaces, the way a wheel over a taskbar has always worked; nothing is stored
src/components/TabSwitcher.qml|flips to the next or previous page|page selection inside a popup, the same wheel a browser tab strip takes; disabled outright when the settings column has more rows than room, so there the wheel scrolls the column instead
src/modules/Center/CenterContent.qml|advances the status carousel|the handler drives statusList.contentY, so this IS the scroll of the thing under the pointer
src/modules/Right/SysTray.qml|forwards the delta to the tray item|the StatusNotifierItem protocol defines wheel-over-icon; the value, if any, belongs to the other application
src/popups/WallpaperPopup.qml|turns a vertical wheel into horizontal scroll|the grid scrolls sideways and a mouse has no sideways wheel; this is scrolling, spelled differently
"

# ── The denylist: files that draw a value bar ───────────────────────────────
# No wheel site, whatever the allowlist says.
# file | the call that sets the value | what the bar is
DENY_RAW="
src/components/config/CfgSlider.qml|root._apply(|the shared settings slider, on every settings page inside a CfgScroll — where UI-004 was reported
src/services/AudioControl.qml|col.volumeChanged(|output, input and mixer volume columns, inside a PopupPage that scrolls
src/popups/QuickControl.qml|col.volumeChanged(|volume, internal brightness and one column per DDC monitor
src/services/home/QuickSettings.qml|root._setBright(|the dashboard brightness bar
src/components/TimeInput.qml|root.incH()|the HH:MM spinners behind the sleep timer and the alarm
"

# Occurrences, not files, so a second handler added to a file that is already
# listed still fails. A WheelHandler and the onWheel inside it are one site.
EXPECT_TOTAL=5

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

# ── The extractor ───────────────────────────────────────────────────────────
cat > "$TMP/extract.py" <<'PY'
"""Emit `relpath|line` for every wheel site in CODE position.

A wheel site is a `WheelHandler {` declaration or an `onWheel` handler. Both are
counted, but a WheelHandler and the onWheel inside it are ONE site: the pair is
how a handler is written, and counting it twice would make the totals below say
something other than "this many places read the wheel".

Comments go, and so do string CONTENTS: a wheel handler cannot live inside a
string, and this file's own prose about them is quoted in places. The scanner
tracks string state either way, so a // inside a string does not start a
comment. Newlines survive so the reported lines are real.
"""
import re, sys, pathlib

root = pathlib.Path(sys.argv[1])

def strip_comments(t):
    out = []
    i, n, quote = 0, len(t), None
    while i < n:
        c = t[i]
        if quote:
            if c == "\\" and i + 1 < n:
                out.append("  "); i += 2; continue
            if c == quote:
                out.append(c); quote = None
            else:
                out.append("\n" if c == "\n" else " ")
            i += 1; continue
        if c in "\"'`":
            quote = c; out.append(c); i += 1; continue
        if c == "/" and i + 1 < n and t[i + 1] == "/":
            while i < n and t[i] != "\n":
                i += 1
            continue                      # leave the newline in place
        if c == "/" and i + 1 < n and t[i + 1] == "*":
            i += 2
            while i + 1 < n and not (t[i] == "*" and t[i + 1] == "/"):
                if t[i] == "\n":
                    out.append("\n")      # keep line numbers honest
                i += 1
            i += 2; continue
        out.append(c); i += 1
    return "".join(out)

DECL  = re.compile(r"\bWheelHandler\s*\{")
PROP  = re.compile(r"\bonWheel\s*:")

for p in sorted(root.rglob("*.qml")):
    rel = str(p.relative_to(root.parent) if root.name == "src" else p)
    code = strip_comments(p.read_text(errors="replace"))

    decls = [code[:m.start()].count("\n") + 1 for m in DECL.finditer(code)]
    props = [code[:m.start()].count("\n") + 1 for m in PROP.finditer(code)]

    # Pair each onWheel with the WheelHandler it belongs to: the nearest
    # declaration at or above it, within a few lines. What is left over is a
    # bare onWheel on a MouseArea, which is a site in its own right.
    sites = list(decls)
    for pl in props:
        owner = [d for d in decls if 0 <= pl - d <= 6]
        if not owner:
            sites.append(pl)

    for line in sorted(sites):
        print(f"{rel}|{line}")
PY

run_extract() { python3 "$TMP/extract.py" "$1" 2>/dev/null; }

norm_allow() { printf '%s\n' "$1" | sed '/^[[:space:]]*$/d' | cut -d'|' -f1 | sort -u; }
norm_files() { cut -d'|' -f1 | sort -u; }

found=$(run_extract "$SRC")
allow_files=$(norm_allow "$ALLOW_RAW")
found_files=$(printf '%s\n' "$found" | sed '/^[[:space:]]*$/d' | norm_files)

# ── 1. no wheel site outside the allowlist ──────────────────────────────────
unexpected=$(comm -23 <(printf '%s\n' "$found_files") <(printf '%s\n' "$allow_files"))
if [ -z "$unexpected" ]; then
    ok "every wheel site in code is on the allowlist"
else
    printf '%s\n' "$found" | grep -F -f <(printf '%s\n' "$unexpected") \
        | sed 's/^/       unexpected: /' | head -20
    bad "every wheel site in code is on the allowlist"
fi

# ── 2. no stale allowlist entry ─────────────────────────────────────────────
# A handler that goes away must force an edit to the list, or the list drifts
# into describing a tree that no longer exists.
stale=$(comm -13 <(printf '%s\n' "$found_files") <(printf '%s\n' "$allow_files"))
if [ -z "$stale" ]; then
    ok "no allowlist entry describes a wheel site that is already gone"
else
    printf '%s\n' "$stale" | sed 's/^/       stale: /'
    bad "no allowlist entry describes a wheel site that is already gone"
fi

# ── 3. the exact count, never -ge ───────────────────────────────────────────
# Per-file membership passes when someone adds a second handler to a file that
# is already listed. The occurrence count is what catches that.
n_found=$(printf '%s\n' "$found" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
if [ "$n_found" -eq "$EXPECT_TOTAL" ]; then
    ok "exactly $EXPECT_TOTAL wheel sites remain in code (asserted exactly, not >=)"
else
    bad "expected exactly $EXPECT_TOTAL wheel sites, found $n_found"
fi

# ── 4. every allowlist entry says what it does and why ──────────────────────
missing_reason=$(printf '%s\n' "$ALLOW_RAW" | sed '/^[[:space:]]*$/d' \
                 | awk -F'|' 'NF < 3 || length($2) < 10 || length($3) < 20 {print $1}')
if [ -z "$missing_reason" ]; then
    ok "every allowlisted wheel site states what it does and why that is not an edit"
else
    printf '%s\n' "$missing_reason" | sed 's/^/       no reason: /'
    bad "every allowlisted wheel site states what it does and why that is not an edit"
fi

# ── 5. no value bar reads the wheel ─────────────────────────────────────────
# The rule the user actually asked for, and the one an allowlist row cannot
# argue its way past.
deny_hits=""
while IFS='|' read -r f _marker _why; do
    [ -n "$f" ] || continue
    hit=$(printf '%s\n' "$found" | grep -F "$f|")
    [ -n "$hit" ] && deny_hits="$deny_hits$hit"$'\n'
done <<< "$(printf '%s\n' "$DENY_RAW" | sed '/^[[:space:]]*$/d')"

if [ -z "$deny_hits" ]; then
    ok "no value bar reads the wheel — scrolling over one scrolls the page"
else
    printf '%s' "$deny_hits" | sed 's/^/       value bar reading the wheel: /'
    bad "no value bar reads the wheel"
fi

# ── 5b. and no shared settings control does either ──────────────────────────
# Wider than the list above on purpose. Everything in this directory is a
# control on a settings page inside a CfgScroll, so the rule is the directory,
# not the five files that happen to draw a bar today.
cfg_hits=$(printf '%s\n' "$found" | grep "^src/components/config/")
if [ -z "$cfg_hits" ]; then
    ok "no shared settings control in components/config reads the wheel"
else
    printf '%s\n' "$cfg_hits" | sed 's/^/       settings control reading the wheel: /'
    bad "no shared settings control in components/config reads the wheel"
fi

# ── 6. and the value bars are still there to be protected ──────────────────
missing_bar=""
while IFS='|' read -r f marker _why; do
    [ -n "$f" ] || continue
    path="$SRC/${f#src/}"
    if [ ! -f "$path" ]; then
        missing_bar="$missing_bar $f(no such file)"
    elif ! grep -qF "$marker" "$path"; then
        missing_bar="$missing_bar $f(no '$marker')"
    fi
done <<< "$(printf '%s\n' "$DENY_RAW" | sed '/^[[:space:]]*$/d')"

if [ -z "$missing_bar" ]; then
    ok "every file on the value-bar list still draws one"
else
    printf '%s\n' "$missing_bar" | tr ' ' '\n' | sed '/^$/d;s/^/       gone: /'
    bad "every file on the value-bar list still draws one"
fi

# ── 7. CfgSlider is still reachable without a pointer ───────────────────────
# Removing the wheel took an input path away. Keyboard is what replaces it, and
# a focus ring is what makes keyboard usable, so both are asserted rather than
# left to the next refactor.
slider="$SRC/components/config/CfgSlider.qml"
missing_kbd=""
for needle in "activeFocusOnTab" "Keys.onPressed" "Qt.Key_Left" "Qt.Key_Right" "Qt.Key_Home" "Qt.Key_End" "root.activeFocus"; do
    grep -qF "$needle" "$slider" 2>/dev/null || missing_kbd="$missing_kbd $needle"
done
if [ -z "$missing_kbd" ]; then
    ok "CfgSlider still takes focus, steps on arrow keys and shows a focus ring"
else
    bad "CfgSlider is missing:$missing_kbd"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  the self-test: prove each check can actually fail
#
#  Mutations are applied to a COPY and each is verified to have CHANGED the file
#  before its verdict is believed. A mutant that failed to apply is reported as
#  such, never as caught — this repository has produced exactly that false
#  verdict before.
# ─────────────────────────────────────────────────────────────────────────────
printf '\n── self-test: can these checks fail? ──\n'
cp -r "$SRC" "$TMP/src" || exit 2
applied=0; noapply=0

mut_found() { run_extract "$TMP/src"; }

recheck_allow() {
    local f u s
    f=$(mut_found | sed '/^[[:space:]]*$/d' | norm_files)
    u=$(comm -23 <(printf '%s\n' "$f") <(printf '%s\n' "$allow_files"))
    s=$(comm -13 <(printf '%s\n' "$f") <(printf '%s\n' "$allow_files"))
    local n
    n=$(mut_found | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    [ -n "$u" ] || [ -n "$s" ] || [ "$n" -ne "$EXPECT_TOTAL" ]
}

recheck_deny() {
    local f hits=""
    f=$(mut_found)
    while IFS='|' read -r file _m _w; do
        [ -n "$file" ] || continue
        grep -qF "$file|" <<<"$f" && hits="x"
    done <<< "$(printf '%s\n' "$DENY_RAW" | sed '/^[[:space:]]*$/d')"
    [ -n "$hits" ]
}

mutate() {
    local label="$1" file="$2" from="$3" to="$4" verify="$5"
    local target="$TMP/src/${file#src/}" before after
    if [ ! -f "$target" ]; then
        bad "self-test $label: no such file $file"; return
    fi
    before=$(cat "$target")
    python3 - "$target" "$from" "$to" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); t = p.read_text()
p.write_text(t.replace(sys.argv[2], sys.argv[3], 1))
PY
    after=$(cat "$target")
    if [ "$before" = "$after" ]; then
        noapply=$((noapply+1))
        bad "self-test $label: the mutation did not apply, so its verdict is meaningless"
        return
    fi
    applied=$((applied+1))
    if "$verify"; then
        ok "self-test $label: caught"
    else
        bad "self-test $label: SURVIVED — the check does not detect it"
    fi
    printf '%s' "$before" > "$target"
}

# (a) the exact regression, put back the way it was written
mutate "the WheelHandler restored on CfgSlider" \
    "src/components/config/CfgSlider.qml" \
    "        MouseArea {" \
    "        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: function(e) { root._apply(root._frac + 0.01) }
        }
        MouseArea {" \
    recheck_deny

# (b) the same idiom on a different value bar
mutate "a wheel handler on the brightness bar" \
    "src/services/home/QuickSettings.qml" \
    "                    Rectangle {
                        width: btw.thumbD;" \
    "                    WheelHandler {
                        onWheel: function(e) { root._setBright(root._brightVal + 0.05) }
                    }
                    Rectangle {
                        width: btw.thumbD;" \
    recheck_deny

# (c) a bare onWheel on a MouseArea, which is the other spelling, on a settings
#     control that draws no bar — caught by the directory rule, not the list
recheck_cfg() { grep -q "^src/components/config/" < <(mut_found); }
mutate "a bare onWheel on a MouseArea in a settings control" \
    "src/components/config/CfgSwitch.qml" \
    "        onClicked:    { root.forceActiveFocus(); root.toggle() }" \
    "        onClicked:    { root.forceActiveFocus(); root.toggle() }
        onWheel:      function(w) { root.toggle() }" \
    recheck_cfg

# (d) a second handler in a file that is already allowlisted — membership alone
#     would wave this through, which is why the count is asserted exactly
mutate "a second wheel site inside an allowlisted file" \
    "src/components/TabSwitcher.qml" \
    "	WheelHandler {" \
    "	WheelHandler {
		onWheel: function(e) { }
	}
	WheelHandler {" \
    recheck_allow

# (e) an allowlisted handler removed — the list must be edited too
mutate "an allowlisted wheel site removed" \
    "src/popups/WallpaperPopup.qml" \
    "                onWheel: function(wheel) {" \
    "                function notWheel(wheel) {" \
    recheck_allow

# (f) the keyboard path deleted from CfgSlider
recheck_kbd() { ! grep -qF "activeFocusOnTab" "$TMP/src/components/config/CfgSlider.qml"; }
mutate "keyboard access deleted from CfgSlider" \
    "src/components/config/CfgSlider.qml" \
    "    activeFocusOnTab: true" "    // focus removed" recheck_kbd

# ── the inverse mutant: prose must NOT trip any of this ─────────────────────
# Without this, the check could be passing on comments rather than on code —
# and this repository's checks now carry prose about wheel handlers in five
# files, so the risk is not theoretical.
cat > "$TMP/src/InverseMutant.qml" <<'QML'
import QtQuick
// A comment naming WheelHandler { and onWheel: deliberately, the way the
// header of a fixed file explains what used to be there.
/* And a block comment doing the same across lines:
       WheelHandler {
           onWheel: function(e) { root._apply(0.5) }
       }
*/
Item {
    // WheelHandler { onWheel: ... }
    property string note: "the string 'onWheel:' must not match either"
}
QML
inv=$(run_extract "$TMP/src" | grep 'InverseMutant')
if [ -z "$inv" ]; then
    ok "self-test inverse: wheel handlers named in // and /* */ comments are invisible"
else
    printf '%s\n' "$inv" | sed 's/^/       tripped on: /'
    bad "self-test inverse: prose tripped the check"
fi

# And the other direction, or the comment scanner could be swallowing code.
cat > "$TMP/src/InverseMutant.qml" <<'QML'
import QtQuick
Item {
    // The URL below contains // inside a string. If the scanner mishandles it,
    // everything after it on this line vanishes and the check goes quiet.
    property string url: "https://example.invalid/x"
    WheelHandler { onWheel: function(e) { } }
}
QML
inv2=$(run_extract "$TMP/src" | grep 'InverseMutant')
if [ -n "$inv2" ]; then
    ok "self-test inverse: a // inside a string does not blind the scanner to code after it"
else
    bad "self-test inverse: the scanner missed a real wheel site — comment stripping is too greedy"
fi
rm -f "$TMP/src/InverseMutant.qml"

printf '\nself-test: mutants applied=%d, failed-to-apply=%d\n' "$applied" "$noapply"
printf 'check-wheel-value: passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
