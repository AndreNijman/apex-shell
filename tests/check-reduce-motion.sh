#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-reduce-motion.sh — every animation takes its timing from the motion
#  system, and Reduce Motion therefore reaches all of them.
#
#  ── History ─────────────────────────────────────────────────────────────────
#
#  This began (roadmap P2-003) as a measurement of how little of the shell the
#  Reduce Motion switch reached: 41 of 453 animation durations. The other 403
#  were integer literals written in place — `ColorAnimation { duration: 120 }` —
#  that no setting could touch, so a user who turned Reduce Motion on because
#  motion makes them ill still got 89 % of it.
#
#  The UI/UX roadmap v3 (Phase 1) replaced the one global `animDuration` with
#  theme/Motion.qml: semantic tokens (`Motion.hover`, `Motion.selection`,
#  `Motion.morphEnter` …) whose spatial members are 0 under Reduce Motion and
#  whose effect members are kept but shortened. This file is now the lint that
#  holds the tree to it (roadmap §3.6, "No new raw motion literals").
#
#  ── The rules ───────────────────────────────────────────────────────────────
#
#   1. A `duration:` is a Motion token, a Motion* animation type, or a local
#      property that resolves to one. The legacy `Theme.animDuration` family
#      still honours Reduce Motion and is counted separately, as a ratchet that
#      only goes down: it is the last of the old single duration.
#   2. A literal duration is allowed ONLY with an entry in ALLOW below, which
#      names the file, the value, and why a role cannot express it (a countdown
#      that must match a timer is not motion). Everything else fails.
#   3. `Motion.spatial(…)` / `Motion.effect(…)` with a literal argument outside
#      src/theme/ is a literal in disguise, and fails the same way.
#   4. Named Qt easings (`Easing.OutCubic`, `Easing.InOutCubic`, `Easing.OutBack`
#      …) are the old vocabulary; motion curves come from Motion. They are a
#      ratchet too. `Easing.Linear` (countdowns, spinners) and `Easing.InOutSine`
#      (the breathing of a loop) are not counted.
#   5. An infinite loop must be gated on `Motion.loops` or `Motion.ambient`, or
#      turning motion off leaves it running.
#
#  Counts are asserted EXACTLY, both directions: going up is the regression;
#  going down without editing the constant means the ratchet should be tightened
#  to lock the improvement in; the total moving means the scanner's idea of an
#  animation changed, and a scanner that quietly stops finding things is how an
#  exact count becomes a green light for nothing (check-color-tokens.sh's
#  EXPECT_WHITE_FG established this idiom).
#
#  ── Why the scanner is not a grep ───────────────────────────────────────────
#
#   * comments and strings: this tree documents its own animation decisions in
#     prose, and `// duration: 120` is not an animation.
#   * one level of indirection: `duration: root.animDuration` resolves through a
#     local property, so local properties are followed once.
#
#  It reads the source; it does not run the shell. tests/motion-test.js proves
#  the token table's policy (spatial → 0, effects capped) in node.
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
MO="src/theme/Motion.qml"
MJ="src/theme/motion.js"
MET="src/theme/ThemeSet.qml"
TH="src/theme/Theme.qml"
for f in "$SS" "$MO" "$MJ" "$MET" "$TH"; do
    [ -f "$f" ] || { echo "FATAL: cannot find $f" >&2; exit 2; }
done

# ── Literal durations that are not motion ────────────────────────────────────
# file|value|reason (>= 20 characters). A literal here must say why no Motion
# role expresses it. Asserted as a set in both directions: an entry whose
# literal is gone is stale and fails too.
ALLOW="
src/popups/NotificationToast.qml|5000|the auto-dismiss countdown bar: it must drain in exactly the toast's 5000 ms autoTimer, so it is a lifetime, not motion
src/windows/DisplayConfirm.qml|240|one step of the keep-or-revert countdown bar, paced by the countdown's own one-second tick rather than by a motion role
"

# ── The scanner ──────────────────────────────────────────────────────────────
# Prints one line per finding, tab-separated: KIND FILE VALUE LINE
#   token | legacy | literal | disguised | unresolved | easing | loop-ungated | comp
scan() {   # scan <tree-root>
    python3 - "$1" <<'PY'
import re, sys, pathlib

def strip(src):
    """Blank out comments and string bodies, keeping line breaks so line
    numbers survive."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i+1] == '/':
            while i < n and src[i] != '\n':
                i += 1
        elif c == '/' and i + 1 < n and src[i+1] == '*':
            i += 2
            while i + 1 < n and not (src[i] == '*' and src[i+1] == '/'):
                if src[i] == '\n': out.append('\n')
                i += 1
            i += 2
        elif c in '"\'':
            q = c; out.append('""'); i += 1
            while i < n and src[i] != q:
                if src[i] == '\\':
                    i += 1
                i += 1
            i += 1
        else:
            out.append(c); i += 1
    return "".join(out)

# `MotionTable.` is theme/motion.js imported directly — the one way a file
# that runs before any session (the login screen's password shapes) can reach
# the table. It applies the same policy through spatial()/effect().
TOKEN  = re.compile(r'\bMotion(?:Table)?\s*[\.\[]')
LEGACY = re.compile(r'(Theme\.animDuration|Metrics\.animDuration'
                    r'|SettingsService\.effectiveAnim|SettingsService\.reduceMotion'
                    r'|Popups\.slideDuration|Popups\.hoverCloseDelay'
                    r'|\btheme\.animDuration\b)')
DISGUISE = re.compile(r'\bMotion(?:Table)?\.(?:spatial|effect)\s*\(\s*\d')
COMP = re.compile(r'\bMotion(?:Color|Fade|Move)\s*\{')
EASE = re.compile(r'\bEasing\.(\w+)')
EASE_OK = {"BezierSpline", "Linear", "InOutSine"}

root = pathlib.Path(sys.argv[1])
for p in sorted(root.rglob("*.qml")):
    rel = str(p.relative_to(root.parent)) if root.name == "src" else str(p)
    in_theme = "/theme/" in str(p)
    s = strip(p.read_text())
    lines = s.split("\n")
    props = {}
    for m in re.finditer(r'^\s*(?:readonly\s+)?property\s+\w+\s+(\w+)\s*:\s*([^\n]+)', s, re.M):
        props[m.group(1)] = m.group(2)
    def lineno(pos): return s.count("\n", 0, pos) + 1
    for m in re.finditer(r'\bduration\s*:\s*([^\n;}]+)', s):
        v = m.group(1).strip(); ln = lineno(m.start())
        if not in_theme and DISGUISE.search(v):
            print("disguised\t%s\t%s\t%d" % (rel, v, ln)); continue
        if TOKEN.search(v):
            print("token\t%s\t%s\t%d" % (rel, v, ln)); continue
        if LEGACY.search(v):
            print("legacy\t%s\t%s\t%d" % (rel, v, ln)); continue
        if re.match(r'^\d+$', v):
            print("literal\t%s\t%s\t%d" % (rel, v, ln)); continue
        ref = re.match(r'^(?:root\.)?(\w+)$', v)
        if ref and ref.group(1) in props:
            pv = props[ref.group(1)]
            if TOKEN.search(pv):
                print("token\t%s\t%s\t%d" % (rel, v, ln)); continue
            if LEGACY.search(pv):
                print("legacy\t%s\t%s\t%d" % (rel, v, ln)); continue
        print("unresolved\t%s\t%s\t%d" % (rel, v, ln))
    for m in COMP.finditer(s):
        print("comp\t%s\t%s\t%d" % (rel, m.group(0).rstrip("{ "), lineno(m.start())))
    for m in EASE.finditer(s):
        if m.group(1) not in EASE_OK and not in_theme:
            print("easing\t%s\t%s\t%d" % (rel, m.group(1), lineno(m.start())))
    # Infinite loops: the enclosing animation block must mention a Motion gate.
    for m in re.finditer(r'loops\s*:\s*Animation\.Infinite', s):
        ln = lineno(m.start())
        window = "\n".join(lines[max(0, ln - 12):ln + 6])
        if not re.search(r'Motion\.(loops|ambient)', window):
            print("loop-ungated\t%s\tInfinite\t%d" % (rel, ln))
PY
}

FIND="$(scan src)"
count() { printf '%s\n' "$FIND" | awk -F'\t' -v k="$1" '$1==k' | grep -c . ; }
TOK=$(count token); LEG=$(count legacy); LIT=$(count literal); DIS=$(count disguised)
UNRES=$(count unresolved); EAS=$(count easing); LOOPU=$(count loop-ungated); COMPN=$(count comp)
TOTAL=$(( TOK + LEG + LIT + DIS + UNRES + COMPN ))

section "the mechanism still exists"
grep -qE '^\s*property\s+bool\s+reduceMotion' "$SS" \
    && ok "SettingsService still has a reduceMotion setting" \
    || bad "SettingsService still has a reduceMotion setting"
grep -qE 'readonly\s+property\s+bool\s+reduced:\s*SettingsService\.reduceMotion' "$MO" \
    && ok "Motion.reduced reads the setting" \
    || bad "Motion.reduced reads the setting"
grep -qE 'function\s+spatial\(ms,\s*scale,\s*reduced\)\s*\{\s*$' "$MJ" \
    && grep -A2 -E 'function\s+spatial\(' "$MJ" | grep -qE 'if\s*\(reduced\)\s*return\s+0' \
    && ok "a spatial token is 0 under Reduce Motion" \
    || bad "a spatial token is 0 under Reduce Motion"
for t in pressIn pressOut selection page surfaceEnterSmall surfaceExitSmall morphEnter morphExit notificationShift hero valueFollow errorShake; do
    grep -qE "readonly\s+property\s+int\s+$t:\s*spatial\(" "$MO" \
        || bad "Motion.$t is not a spatial token — Reduce Motion would not remove it"
done
ok "every travel/size/morph token is built with spatial()"
grep -qE '^singleton Motion\s+theme/Motion\.qml' src/qmldir \
    && ! grep -qE '^singleton Motion\b' src/theme/qmldir \
    && ok "Motion is registered once (src/qmldir), so there is one instance" \
    || bad "Motion is registered once (src/qmldir), so there is one instance"
grep -qE 'readonly\s+property\s+int\s+effectiveAnim:\s*reduceMotion\s*\?\s*0\s*:' "$SS" \
    && ok "the legacy duration still collapses to 0 under Reduce Motion" \
    || bad "the legacy duration still collapses to 0 under Reduce Motion"
grep -qE 'property\s+int\s+animDuration:\s*SettingsService\.effectiveAnim' "$MET" \
    && grep -qE 'property\s+int\s+animDuration:\s*Metrics\.animDuration' "$TH" \
    && ok "the legacy chain SettingsService → ThemeSet → Theme is intact while callers remain" \
    || bad "the legacy chain SettingsService → ThemeSet → Theme is intact while callers remain"
grep -qE 'reduceMotion' src/services/config_tab/pages/LayoutPage.qml \
    && grep -qE 'motionSpeed' src/services/config_tab/pages/LayoutPage.qml \
    && ok "Reduce Motion and the speed preset are offered to the user" \
    || bad "Reduce Motion and the speed preset are offered to the user"

section "literal durations"
# The allowlist, as a set, against what the scanner found.
found_lit="$(printf '%s\n' "$FIND" | awk -F'\t' '$1=="literal"{print $2"|"$3}' | sort)"
allowed="$(printf '%s\n' "$ALLOW" | grep -v '^\s*$' | awk -F'|' '{print $1"|"$2}' | sort)"
short="$(printf '%s\n' "$ALLOW" | grep -v '^\s*$' | awk -F'|' 'length($3) < 20')"
[ -z "$short" ] && ok "every allowlisted literal gives a reason" \
    || bad "allowlist entries with no real reason: $short"
unlisted="$(comm -23 <(printf '%s\n' "$found_lit" | grep .) <(printf '%s\n' "$allowed" | grep .) | sort | uniq -c)"
stale="$(comm -13 <(printf '%s\n' "$found_lit" | grep . | sort -u) <(printf '%s\n' "$allowed" | grep . | sort -u))"
N_UNLISTED=$(printf '%s\n' "$FIND" | awk -F'\t' '$1=="literal"' | while IFS=$'\t' read -r _ f v _; do
    printf '%s\n' "$ALLOW" | grep -qF "$f|$v|" || echo x; done | grep -c .)

# ── THE RATCHETS ──
# Lower them as call sites move to Motion. Never raise one.
EXPECT_UNLISTED_LITERAL=0
EXPECT_LEGACY=4       # 14 → 12: SysTray (UI/UX design review 2); 12 → 5: the clipboard and wallpaper sheets onto SurfaceLifecycle (Phase 21d); 5 → 4: the window switcher's scrim onto DialogLifecycle (Phase 6)
EXPECT_UNRESOLVED=2
EXPECT_EASING=3       # 10 → 8: SysTray; 8 → 3: the clipboard and wallpaper sheets
EXPECT_LOOP_UNGATED=0

if [ "$N_UNLISTED" -eq "$EXPECT_UNLISTED_LITERAL" ]; then
    ok "exactly $EXPECT_UNLISTED_LITERAL literal durations remain to migrate"
elif [ "$N_UNLISTED" -gt "$EXPECT_UNLISTED_LITERAL" ]; then
    bad "$N_UNLISTED literal durations, was $EXPECT_UNLISTED_LITERAL — a new animation chose its own milliseconds. Use a Motion token (Motion.hover, Motion.state, Motion.selection …) or a MotionColor/MotionFade/MotionMove"
    printf '%s\n' "$unlisted" | tail -8 | sed 's/^/        /'
else
    bad "$N_UNLISTED literal durations, was $EXPECT_UNLISTED_LITERAL — some were migrated, which is the point; lower EXPECT_UNLISTED_LITERAL to $N_UNLISTED"
fi
[ -z "$stale" ] && ok "no allowlist entry is stale" || bad "stale allowlist entries: $stale"

if [ "$DIS" -eq 0 ]; then
    ok "no Motion.spatial()/effect() with a literal outside src/theme"
else
    bad "$DIS literal(s) disguised as Motion.spatial(N)/effect(N):"
    printf '%s\n' "$FIND" | awk -F'\t' '$1=="disguised"{print "        "$2":"$4"  "$3}'
fi

section "the rest of the old vocabulary"
[ "$LEG" -eq "$EXPECT_LEGACY" ] && ok "exactly $EXPECT_LEGACY durations still use the legacy single duration" \
    || { [ "$LEG" -gt "$EXPECT_LEGACY" ] && bad "$LEG legacy durations, was $EXPECT_LEGACY — new code reads Theme.animDuration; use a Motion role" \
         || bad "$LEG legacy durations, was $EXPECT_LEGACY — lower EXPECT_LEGACY to $LEG"; }
[ "$UNRES" -eq "$EXPECT_UNRESOLVED" ] && ok "exactly $EXPECT_UNRESOLVED durations resolve to neither (staggers, timeouts, a marquee)" \
    || { bad "expected $EXPECT_UNRESOLVED unresolved durations, found $UNRES"; printf '%s\n' "$FIND" | awk -F'\t' '$1=="unresolved"{print "        "$2":"$4"  "$3}' | head; }
[ "$EAS" -eq "$EXPECT_EASING" ] && ok "exactly $EXPECT_EASING named Qt easings remain to replace with Motion curves" \
    || { [ "$EAS" -gt "$EXPECT_EASING" ] && bad "$EAS named easings, was $EXPECT_EASING — use easing.type: Easing.BezierSpline with a Motion curve" \
         || bad "$EAS named easings, was $EXPECT_EASING — lower EXPECT_EASING to $EAS"; }
[ "$LOOPU" -eq "$EXPECT_LOOP_UNGATED" ] && ok "exactly $EXPECT_LOOP_UNGATED infinite loops still ungated by Motion.loops/ambient" \
    || { [ "$LOOPU" -gt "$EXPECT_LOOP_UNGATED" ] && bad "$LOOPU ungated infinite loops, was $EXPECT_LOOP_UNGATED — gate running: on Motion.ambient (decorative) or Motion.loops (busy spinner)" \
         || bad "$LOOPU ungated loops, was $EXPECT_LOOP_UNGATED — lower EXPECT_LOOP_UNGATED to $LOOPU"; }

section "the reach"
echo "  $TOK duration(s) on a Motion token, $COMPN Motion* animation(s), $LEG legacy, $LIT literal, $UNRES unresolved"
if [ "$TOTAL" -gt 300 ]; then
    ok "the scanner still finds the animations ($TOTAL)"
else
    bad "the scanner found only $TOTAL animations; it has stopped working and every count above is meaningless"
fi

# ── Self-test ────────────────────────────────────────────────────────────────
# Mutate a COPY, verify the mutation applied before believing the verdict —
# a mutant that did not apply is reported as such, never as caught.
section "self-test: can these checks fail?"

MW="$(mktemp -d)"
cleanup() { rm -rf "$MW"; }
trap cleanup EXIT INT TERM

mutate() {   # mutate <python regex> <replacement>  — first match in the first file that has one
    rm -rf "$MW/src"; cp -r src "$MW/src"
    python3 - "$MW/src" "$1" "$2" <<'PY'
import re, sys, pathlib
root, pat, rep = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
for p in sorted(root.rglob("*.qml")):
    if "/theme/" in str(p):
        continue
    s = p.read_text()
    t, n = re.subn(pat, rep, s, count=1)
    if n:
        p.write_text(t); sys.exit(0)
sys.exit(3)
PY
}
kinds() { scan "$MW/src" | awk -F'\t' -v k="$1" '$1==k' | grep -c . ; }

if mutate 'Behavior on opacity \{' 'Behavior on x { NumberAnimation { duration: 999 } }\nBehavior on opacity {'; then
    [ "$(kinds literal)" -gt "$LIT" ] && ok "self-test a new hardcoded animation: caught" \
        || bad "self-test a new hardcoded animation: SURVIVED"
else bad "self-test a new hardcoded animation: the mutation did not apply"; fi

if mutate 'duration:\s*Motion\.\w+' 'duration: Motion.spatial(250)'; then
    [ "$(kinds disguised)" -gt "$DIS" ] && ok "self-test a literal disguised as Motion.spatial(): caught" \
        || bad "self-test a literal disguised as Motion.spatial(): SURVIVED"
else
    # Before any caller has migrated there is no token to disguise; mutate a
    # legacy site instead so the rule is still exercised.
    if mutate 'duration:\s*Theme\.animDuration' 'duration: Motion.spatial(250)'; then
        [ "$(kinds disguised)" -gt "$DIS" ] && ok "self-test a literal disguised as Motion.spatial(): caught" \
            || bad "self-test a literal disguised as Motion.spatial(): SURVIVED"
    else bad "self-test a literal disguised as Motion.spatial(): the mutation did not apply"; fi
fi

if mutate 'Behavior on opacity \{' 'Behavior on y { NumberAnimation { easing.type: Easing.OutBack } }\nBehavior on opacity {'; then
    [ "$(kinds easing)" -gt "$EAS" ] && ok "self-test a new named easing: caught" \
        || bad "self-test a new named easing: SURVIVED"
else bad "self-test a new named easing: the mutation did not apply"; fi

if mutate 'Behavior on opacity \{' 'SequentialAnimation on scale { running: true; loops: Animation.Infinite; NumberAnimation { to: 2; duration: Motion.pulseHalf } }\nBehavior on opacity {'; then
    [ "$(kinds loop-ungated)" -gt "$LOOPU" ] && ok "self-test an ungated infinite loop: caught" \
        || bad "self-test an ungated infinite loop: SURVIVED"
else bad "self-test an ungated infinite loop: the mutation did not apply"; fi

# The inverse: prose must be invisible.
rm -rf "$MW/src"; cp -r src "$MW/src"
cat > "$MW/src/InverseMutant.qml" <<'QML'
import QtQuick
// duration: 120
// Behavior on x { NumberAnimation { duration: 9999; easing.type: Easing.OutBack } }
/* duration: 77  loops: Animation.Infinite */
Item { property string note: "duration: 4242 Easing.OutElastic" }
QML
if [ "$(kinds literal)" -eq "$LIT" ] && [ "$(kinds easing)" -eq "$EAS" ] && [ "$(kinds loop-ungated)" -eq "$LOOPU" ]; then
    ok "self-test inverse: durations, easings and loops named in comments and strings are invisible"
else
    bad "self-test inverse: prose was counted"
fi

# ── the dialogs are on a lifecycle (UI/UX Phase 6, finished) ────────────────
# The last five transient surfaces left on the old model — mapped on a flag
# (no exit motion), unmapped on a timer, or a scrim fade that never showed
# because its window went first. Each now maps its window from a lifecycle
# (`visible: life.mapped`, or `windowVisible: life.mapped`) and holds the
# keyboard on `life.open`, never on `visible`: a dialog that is leaving must
# not keep the keys through its exit. The confirm dialog cannot be driven
# from a harness — its confirm button takes focus on open and its action
# authenticates, then logs out or powers off — so this is the gate for it.
dialog_on_lifecycle() {   # dialog_on_lifecycle <file> — 0 when it follows the rule
    python3 - "$1" <<'PY2'
import re, sys
s = "\n".join(l for l in open(sys.argv[1]).read().splitlines() if not l.lstrip().startswith("//"))
mapped = re.search(r'^\s*(visible|readonly property bool windowVisible)\s*:\s*life\.mapped\s*$', s, re.M)
lifecycle = re.search(r'\b(DialogLifecycle|SurfaceLifecycle)\s*\{[^}]*\bid:\s*life\b', s)
keys_on_visible = re.search(r'keyboardFocus:\s*root\.visible', s)
sys.exit(0 if (mapped and lifecycle and not keys_on_visible) else 1)
PY2
}
for f in src/windows/ConfirmDialog.qml src/windows/DisplayConfirm.qml src/windows/UpdatePopup.qml \
         src/popups/WindowSwitcher.qml src/popups/ScreenRecOptionsPopup.qml; do
    dialog_on_lifecycle "$f" && ok "$(basename "$f" .qml) maps from its lifecycle and holds the keys only while open" \
        || bad "$(basename "$f" .qml) is off the lifecycle, or holds the keyboard on visible"
done
DLG="$(mktemp -d)"
sed 's/^    visible: life.mapped$/    visible: Popups.confirmOpen || Popups.confirmRunning/' "src/windows/ConfirmDialog.qml" > "$DLG/a.qml"
sed 's/keyboardFocus: life.open ?/keyboardFocus: root.visible ?/' "src/windows/ConfirmDialog.qml" > "$DLG/b.qml"
for m in a b; do
    if cmp -s "src/windows/ConfirmDialog.qml" "$DLG/$m.qml"; then bad "self-test DIALOG-$m: the mutation did not apply"
    elif dialog_on_lifecycle "$DLG/$m.qml"; then bad "self-test DIALOG-$m: SURVIVED"
    else case $m in a) why="mapped on the flag again";; b) why="keys held on visible";; esac
         ok "self-test DIALOG-$m: caught ($why)"; fi
done
rm -rf "$DLG"

printf '\ncheck-reduce-motion: passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
