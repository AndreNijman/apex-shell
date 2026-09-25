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
    esac
}

verdicts="$(check_file "$F")"
while read -r rule verdict; do
    [ -n "$rule" ] || continue
    if [ "$verdict" = PASS ]; then ok "$(label "$rule")"; else bad "$(label "$rule")"; fi
done <<<"$verdicts"
[ "$(grep -c . <<<"$verdicts")" -eq 6 ] && ok "all six rules were evaluated" || bad "expected six verdicts: $verdicts"

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

printf '\ncheck-notification-stack: passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
