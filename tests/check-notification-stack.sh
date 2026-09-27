#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-notification-stack.sh — the notification centre's cards can arrive and
#  leave (UI/UX roadmap v3 Phase 11, STACK_REFLOW).
#
#  src/services/notifications/NotificationList.qml animates cards in and out of
#  a ListView. Four Qt behaviours each silently turned that into "cards appear
#  and vanish", with nothing logged; each was measured in a headless probe
#  before the construct that avoids it was chosen, and each construct is
#  asserted here:
#
#   MODEL     a ListView given a replaced JS array resets and rebuilds every
#             delegate, so nothing can arrive or leave: the model is a
#             ScriptModel (identity diff → real inserts/removes) …
#   WRAPPED   … over plain JS wrappers (`root.entries`), not the notifications:
#             a model value that is a DESTROYED QObject — which closing a
#             notification does — has its delegate torn down with no exit;
#   GUARDED   the card's notification is a `QtObject` property, so it nulls and
#             notifies when destroyed and the card switches to its own copy;
#   EXTENT    the ListView is not sized to its content: a ListView releases a
#             card whose exit is still running as soon as the card is outside
#             its extent, and a content-sized one shrinks the instant a card is
#             removed — every exit ran 0 ms;
#   TARGETED  animations nested in a group inside the remove Transition name
#             their target: nested ones do not inherit the transition's item,
#             and the exit ran in 0 ms;
#   HEIGHT    the card's height is not a positioner's implicitHeight (a
#             Column's is computed at polish time, after the list has laid a new
#             card out — the others made room for too little and stayed there).
#   SHOWN     …and it counts its lines by the conditions they are shown on,
#             never by `visible`: that is the effective visibility, false while
#             the centre is closed, so cards that arrived then took the icon's
#             height and sat jammed together at rest.
#
#  Each rule is mutated on a copy to prove it can fail.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
F=src/services/notifications/NotificationList.qml

pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

check_file() {   # check_file <path> — one verdict line per rule
    python3 - "$1" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
code = "\n".join(l.split("//", 1)[0] for l in s.split("\n"))
lv = re.search(r'ListView\s*\{\s*id:\s*contentList(.*?)\n        \}', code, re.S)
lv = lv.group(1) if lv else ""
print("MODEL",    "PASS" if re.search(r'model:\s*ScriptModel\s*\{\s*values:\s*root\.entries\s*\}', lv) else "FAIL")
print("WRAPPED",  "PASS" if re.search(r'\{\s*note:\s*n\s*\}', code) and re.search(r'notification:\s*modelData\.note\b', code) else "FAIL")
print("GUARDED",  "PASS" if re.search(r'required property QtObject notification\b', code) else "FAIL")
h = re.search(r'^\s*height:\s*(.+)$', lv, re.M)
print("EXTENT",   "PASS" if h and "contentHeight" not in h.group(1) and "listArea.height" not in h.group(1)
                     and not re.search(r'anchors\.fill:\s*parent', lv) else "FAIL")
rm = re.search(r'remove:\s*Transition\s*\{(.*?)\n            \}', lv, re.S)
rm = rm.group(1) if rm else ""
anims = re.findall(r'NumberAnimation\s*\{(.*?)\}', rm, re.S)
print("TARGETED", "PASS" if anims and all(re.search(r'target:\s*removeTrans\.ViewTransition\.item', a) for a in anims) else "FAIL")
row = re.search(r'id:\s*cardRow(.*?)height:\s*([^\n]+)', code, re.S)
print("HEIGHT",   "PASS" if row and "implicitHeight" not in row.group(2) else "FAIL")
th = re.search(r'readonly property real textHeight:\s*\{(.*?)\n        \}', code, re.S)
print("SHOWN",    "PASS" if th and ".visible" not in th.group(1) and "text" in th.group(1) else "FAIL")
PY
}

label() {
    case "$1" in
        MODEL)    echo "the list's model is a ScriptModel over root.entries (real inserts and removes)" ;;
        WRAPPED)  echo "its values are JS wrappers, not the notifications a close destroys" ;;
        GUARDED)  echo "a card's notification is a guarded QtObject property" ;;
        EXTENT)   echo "the ListView is not sized to its content (exits are not released early)" ;;
        TARGETED) echo "every animation in the remove transition names its target" ;;
        HEIGHT)   echo "a card's height is not a positioner's polish-time implicitHeight" ;;
        SHOWN)    echo "a card counts its lines by their show conditions, not effective visibility" ;;
    esac
}

verdicts="$(check_file "$F")"
while read -r rule verdict; do
    [ -n "$rule" ] || continue
    if [ "$verdict" = PASS ]; then ok "$(label "$rule")"; else bad "$(label "$rule")"; fi
done <<<"$verdicts"
[ "$(grep -c . <<<"$verdicts")" -eq 7 ] && ok "all seven rules were evaluated" || bad "expected seven verdicts: $verdicts"

# ── self-test ────────────────────────────────────────────────────────────────
MW="$(mktemp -d)"; trap 'rm -rf "$MW"' EXIT INT TERM
mutant() {   # mutant <label> <python old> <new> <rule that must fail>
    cp "$F" "$MW/f.qml"
    if ! python3 - "$MW/f.qml" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if old not in s: sys.exit(3)
open(p, "w").write(s.replace(old, new, 1))
PY
    then bad "self-test $1: the mutation did not apply"; return; fi
    if check_file "$MW/f.qml" | grep -q "^$4 FAIL"; then ok "self-test $1: caught"
    else bad "self-test $1: SURVIVED"; fi
}
mutant "the model back to the raw array" 'model:          ScriptModel { values: root.entries }' 'model:          NotificationService.list' MODEL
mutant "the notifications themselves as values" 'notification: modelData.note' 'notification: modelData' WRAPPED
mutant "an unguarded var" 'required property QtObject notification' 'required property var notification' GUARDED
mutant "a content-sized list" 'height:         listArea.maxListHeight' 'height:         Math.min(contentHeight, listArea.maxListHeight)' EXTENT
mutant "an untargeted nested exit" 'target: removeTrans.ViewTransition.item
                            property: "opacity"' 'property: "opacity"' TARGETED
mutant "the Column's implicitHeight" 'height:  Math.max(iconArea.height, card.textHeight)' 'height:  Math.max(iconArea.height, textCol.implicitHeight)' HEIGHT
mutant "lines counted by effective visibility" 'if (t.text !== "")' 'if (t.visible)' SHOWN

# ── the cards' timestamps (UI/UX Phase 17) ───────────────────────────────────
# The arrival time comes from NotificationService.arrivedAt(); what a card says
# about it is notiftime.js, pure, so node drives its boundaries (now / minutes /
# today / yesterday / a date, and nothing for a missing or future time).
if command -v node >/dev/null 2>&1; then
    if node tests/notif-time-test.js >/dev/null 2>&1; then
        ok "tests/notif-time-test.js: the arrival-time formatter"
    else
        bad "tests/notif-time-test.js failed — run it for the cases"
    fi
else
    echo "  skip tests/notif-time-test.js: node not installed"
fi
# A notification that arrives under Do Not Disturb must still leave the list
# when it closes. The close handler was connected AFTER the DND early return,
# so those were never removed and the centre kept cards for things already
# gone. Order is the whole rule, so it is asserted as order — and self-tested
# on a copy with the two swapped back.
S=src/services/notifications/NotificationService.qml
closes_before_dnd() {
    python3 - "$1" <<'PY2'
import sys
s = open(sys.argv[1]).read()
i, j = s.find("onClosed.connect"), s.find("if (ShellState.dnd) return")
sys.exit(0 if 0 <= i < j else 1)
PY2
}
closes_before_dnd "$S" && ok "a notification's close handler is connected before the DND return" \
    || bad "NotificationService connects onClosed after the DND return: cards that arrive under DND never leave"
MS="$(mktemp)"; python3 - "$S" "$MS" <<'PY2'
import sys
s = open(sys.argv[1]).read()
dnd = "        if (ShellState.dnd) return\n"
s = s.replace(dnd, "", 1)
s = s.replace("        const id = n.id\n", "        const id = n.id\n" + dnd, 1)
open(sys.argv[2], "w").write(s)
PY2
if cmp -s "$S" "$MS" || ! grep -q 'if (ShellState.dnd) return' "$MS"; then bad "self-test DND-ORDER: the mutation did not apply"
elif closes_before_dnd "$MS"; then bad "self-test DND-ORDER: the swapped copy SURVIVED"; else ok "self-test DND-ORDER: caught"; fi
rm -f "$MS"
grep -q 'TimeFmt.ago(card.tTime' "$F" \
    && ok "the card says when it arrived, through the formatter" \
    || bad "the card no longer shows its arrival time through notiftime.js"

printf '\ncheck-notification-stack: passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
