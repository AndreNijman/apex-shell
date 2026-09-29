#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-layout-menu.sh — the window-layout button says what each layout does,
#  and a layout chosen from it stays chosen.
#
#  The bar's layout button showed `><`, `M`, `|n|` or `<n>` and jumped to the
#  next layout on a click, the previous on a right click (Andre, 2026-09-29:
#  "its so hard to understand what each option does, it has to be intuitive").
#  Now it is a picture of the layout (LayoutGlyph) that opens a menu naming
#  every layout with a line on what it does (LayoutMenu). So:
#
#   1. NAMED     — every layout the Hyprland backend offers has a name and a
#                  description in layouts.js.
#   2. CHOSEN    — the button opens the menu; nothing cycles layouts blind (no
#                  cycleLayout, no right-click or wheel path to setLayout), and
#                  the only setLayout call is the menu's choice.
#   3. KEPT      — the choice is a SettingsService key (windowLayout, default ""
#                  = the config's own), its choices are exactly "" plus the
#                  backend's layouts, it is saved on change, and the facade's
#                  setLayout writes it.
#   4. REAPPLIED — Hyprland drops a runtime layout at every config reload and
#                  login: the facade hands the kept one to the backend, and the
#                  backend's configreloaded branch puts it back.
#   5. WAY OUT   — monocle's description names Alt+Tab. SUPER+arrow moves
#                  nothing in monocle (measured, nested Hyprland 0.56.2), so
#                  without it the layout reads as every other window lost.
#   6. OWN WRITE — setLayout has its own Process, not the shared _keywordProc:
#                  the kept layout is put back at the moments the accent border
#                  is written, and a shared Process kills the earlier write.
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
    # Comments out; strings kept (the rules read string literals).
    return "\n".join(l.split("//", 1)[0] for l in (root / p).read_text().split("\n"))
def verdict(rule, good, detail=""):
    print(rule, "PASS" if good else "FAIL", detail)

hypr = code("src/services/compositor/HyprlandBackend.qml")
m = re.search(r'readonly property var layouts\s*:\s*\[([^\]]*)\]', hypr)
layouts = re.findall(r'"([^"]+)"', m.group(1)) if m else []

js = code("src/modules/Left/layouts.js")
named = []
for l in layouts:
    e = re.search(r'\b' + re.escape(l) + r'\s*:\s*\{\s*name\s*:\s*"([^"]+)"\s*,\s*detail\s*:\s*"([^"]+)"', js)
    if not e: named.append(l)
verdict("NAMED", bool(layouts) and not named,
        "layouts " + str(layouts) + ", without words: " + str(named))

disp = code("src/modules/Left/LayoutDisplayer.qml")
menu = code("src/modules/Left/LayoutMenu.qml")
calls = len(re.findall(r'setLayout\s*\(', disp))
chosen = re.search(r'onChosen\s*:[^\n]*setLayout\s*\(', disp) is not None
blind = [w for w in ("cycleLayout", "RightButton", "onWheel", "WheelHandler") if w in disp]
verdict("CHOSEN", "menu.toggle()" in disp and chosen and calls == 1 and not blind
        and re.search(r'signal\s+chosen\s*\(', menu) is not None,
        "setLayout calls: %d, from onChosen: %s, blind paths: %s" % (calls, chosen, blind))

st = code("src/services/SettingsService.qml")
keys = re.search(r'readonly property var _keys\s*:\s*\[(.*?)\]', st, re.S)
dflt = re.search(r'\bwindowLayout\s*:\s*""', re.search(r'_defaults\s*:\s*\(\{(.*?)\}\)', st, re.S).group(1)) \
    if re.search(r'_defaults\s*:\s*\(\{(.*?)\}\)', st, re.S) else None
ch = re.search(r'\bwindowLayout\s*:\s*\[([^\]]*)\]', st)
choices = re.findall(r'"([^"]*)"', ch.group(1)) if ch else None
saved = re.search(r'onWindowLayoutChanged\s*:\s*_scheduleSave\(\)', st) is not None
fac = code("src/services/compositor/CompositorService.qml")
fs = re.search(r'function setLayout\s*\([^)]*\)\s*\{(.*?)\n    \}', fac, re.S)
writes = bool(fs) and 'SettingsService.set("windowLayout"' in fs.group(1)
verdict("KEPT", bool(keys) and '"windowLayout"' in keys.group(1) and dflt is not None
        and choices is not None and sorted(choices) == sorted([""] + layouts) and saved and writes,
        "choices %s vs %s, saved %s, facade writes %s" % (choices, [""] + layouts, saved, writes))

bind = re.search(r'Binding\s*\{[^}]*property\s*:\s*"preferredLayout"[^}]*value\s*:\s*SettingsService\.windowLayout', fac, re.S)
rel = re.search(r'event\.name\s*===\s*"configreloaded"\s*\)\s*\{(.*?)\}', hypr, re.S)
verdict("REAPPLIED", bind is not None and bool(rel) and "_applyPreferredLayout()" in rel.group(1)
        and re.search(r'property string preferredLayout', hypr) is not None,
        "facade binding %s, reload branch re-applies %s" % (bind is not None, bool(rel) and "_applyPreferredLayout()" in rel.group(1)))

mono = re.search(r'\bmonocle\s*:\s*\{[^}]*detail\s*:\s*"([^"]*)"', js)
verdict("WAYOUT", bool(mono) and "Alt+Tab" in mono.group(1),
        "monocle: " + (mono.group(1) if mono else "(none)"))

sl = re.search(r'function setLayout\s*\([^)]*\)\s*\{(.*?)\n    \}', hypr, re.S)
body = sl.group(1) if sl else ""
verdict("OWNWRITE", bool(sl) and "_layoutWriteProc" in body and "_keyword" not in body
        and re.search(r'property Process _layoutWriteProc', hypr) is not None,
        "setLayout body uses: " + ", ".join(sorted(set(re.findall(r'_\w+Proc|_keyword\b', body)))))
PY
}

label() {
    case "$1" in
        NAMED)     echo "every layout the backend offers has a name and a description" ;;
        CHOSEN)    echo "the button opens the menu, and nothing cycles layouts blind" ;;
        KEPT)      echo "a chosen layout is a saved setting whose choices match the backend" ;;
        REAPPLIED) echo "the kept layout is handed to the backend and put back after a reload" ;;
        WAYOUT)    echo "monocle's description names Alt+Tab, its only way to the other windows" ;;
        OWNWRITE)  echo "the layout write has its own Process, not the shared keyword one" ;;
    esac
}

echo "── the window-layout button ──"
verdicts="$(check_tree .)"
while read -r rule verdict detail; do
    [ -n "$rule" ] || continue
    if [ "$verdict" = PASS ]; then ok "$(label "$rule")"; else bad "$(label "$rule") — $detail"; fi
done <<<"$verdicts"
[ "$(grep -c . <<<"$verdicts")" -eq 6 ] && ok "all six rules were evaluated" || bad "expected six verdicts, got: $verdicts"

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
mutant "a layout with no words" src/modules/Left/layouts.js \
    'master:    { name: "Main + stack",' 'mastr:     { name: "Main + stack",' NAMED
mutant "a right click that cycles again" src/modules/Left/LayoutDisplayer.qml \
    'onActivated: menu.toggle()' 'onActivated: menu.toggle()
        MouseArea { acceptedButtons: Qt.RightButton; onClicked: CompositorService.setLayout("master") }' CHOSEN
mutant "a click that applies instead of asking" src/modules/Left/LayoutDisplayer.qml \
    'onActivated: menu.toggle()' 'onActivated: CompositorService.setLayout("master")' CHOSEN
mutant "a choice that is not saved" src/services/compositor/CompositorService.qml \
    'SettingsService.set("windowLayout", name)' '/* not kept */' KEPT
mutant "a kept value the backend cannot take" src/services/SettingsService.qml \
    'windowLayout: ["", "dwindle", "master", "monocle", "scrolling"]' 'windowLayout: ["", "dwindle", "master"]' KEPT
mutant "a reload that forgets it" src/services/compositor/HyprlandBackend.qml \
    'root.syncWindowCorners()
                root._applyPreferredLayout()' 'root.syncWindowCorners()' REAPPLIED
mutant "monocle without its way out" src/modules/Left/layouts.js \
    'Alt+Tab switches between them' 'nothing else shows' WAYOUT
mutant "the layout on the shared keyword Process" src/services/compositor/HyprlandBackend.qml \
    'root._start(root._layoutWriteProc,
            ["hyprctl", "eval"' 'root._start(root._keywordProc,
            ["hyprctl", "eval"' OWNWRITE

echo
echo "check-layout-menu: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
