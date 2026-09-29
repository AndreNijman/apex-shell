#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-overview.sh — the workspace overview (SUPER+Tab) is the notch's own
#  surface, captures only while it is up, and survives its own window list.
#
#  Andre, 2026-09-29: "make our own version of end4s super+tab workspace
#  overview … come from the top notch like dashboard, but its not a tab in the
#  top notch". popups/Overview.qml + modules/Overview/. So:
#
#   BIND      SUPER+Tab is a shell default, UNTYPED (so it becomes
#             `qs ipc call overview-toggle toggle` on Hyprland and niri alike)
#   IPC       IpcManager's `overview-toggle` opens it on the focused output,
#             and asks niri for its own overview where Rime's cannot run
#   NOTCH     the body is the centre notch's CENTER_BLOOM (notchW is the bar's
#             live cWidth) on its own lifecycle — and it is NOT a Dashboard tab
#   CAPTURE   a window's picture captures only while the overview is live:
#             the source drops to null and `live` to false with it, and the
#             capture is sized to the tile
#   REF       the window list is held only while the overview is mapped (a
#             ServiceRef on `live`, never Item visibility)
#   KEYED     a cell's windows are a ScriptModel of HANDLES, so a refresh of
#             the list (a fresh `hyprctl clients` parse on every event) keeps
#             each tile and its capture instead of rebuilding them mid-drag
#   DISPATCH  close and move use the Lua names Hyprland 0.56.2 has
#             (hl.dsp.window.close, hl.dsp.window.move{follow=false}); the old
#             hl.dsp.close / hl.dsp.window.move_to_workspace were nil there
#   RESET     closing hands focus back to the content item, so Escape reaches
#             the handler on every open, not only the first
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
    return "\n".join(l.split("//", 1)[0] for l in (root / p).read_text().split("\n"))
def verdict(rule, good, detail=""):
    print(rule, "PASS" if good else "FAIL", detail)

kb = code("src/services/config_tab/KeybindService.qml")
m = re.search(r'"overview-toggle"\s*:\s*\{([^}]*)\}', kb)
body = m.group(1) if m else ""
verdict("BIND", bool(m) and re.search(r'mods\s*:\s*"SUPER"', body) is not None
        and re.search(r'key\s*:\s*"TAB"', body) is not None and "type" not in body,
        "entry: " + (body.strip() or "(none)"))

ipc = code("src/state/IpcManager.qml")
h = re.search(r'target\s*:\s*"overview-toggle"(.*?)\n    \}', ipc, re.S)
fn = re.search(r'function toggleOverview\(\)\s*\{(.*?)\n    \}', ipc, re.S)
f = fn.group(1) if fn else ""
verdict("IPC", bool(h) and "toggleOverview()" in h.group(1) and "CompositorService.toggleOverview()" in f
        and "focusedScreenName()" in f and "overviewSupported" in f,
        "handler " + ("found" if h else "missing"))

ov = code("src/popups/Overview.qml")
dlf = re.search(r'readonly property var tabs\s*:\s*\[(.*?)\]', code("src/state/DashboardLayout.qml"), re.S)
dl = dlf.group(1) if dlf else "(no tabs list found)overview"
notch = ('family:   "centerBloom"' in ov or re.search(r'family\s*:\s*"centerBloom"', ov) is not None) \
    and re.search(r'notchW\s*:\s*root\.anchorWindow\s*\?\s*root\.anchorWindow\.cWidth', ov) is not None \
    and re.search(r'SurfaceLifecycle\s*\{[^}]*name\s*:\s*"overview"', ov, re.S) is not None
verdict("NOTCH", notch and "overview" not in dl.lower(),
        "centerBloom from the notch: %s, a Dashboard tab: %s" % (notch, "overview" in dl.lower()))

tile = code("src/modules/Overview/OverviewWindowTile.qml")
verdict("CAPTURE", re.search(r'captureSource\s*:\s*root\.live\s*\?\s*root\.source\s*:\s*null', tile) is not None
        and re.search(r'\blive\s*:\s*root\.live\b', tile) is not None and "constraintSize" in tile,
        "ScreencopyView bindings")

verdict("REF", re.search(r'ServiceRef\s*\{\s*service\s*:\s*CompositorService\.windowsRef\s*active\s*:\s*root\.live\s*\}', ov) is not None
        and re.search(r'readonly property bool live\s*:\s*life\.mapped', ov) is not None,
        "windowsRef held on live (mapped)")

grid = code("src/modules/Overview/OverviewGrid.qml")
verdict("KEYED", re.search(r'model\s*:\s*ScriptModel\s*\{\s*values\s*:\s*cellItem\.handles\s*\}', grid) is not None
        and re.search(r'required property string modelData', grid) is not None,
        "tile model")

hy = code("src/services/compositor/HyprlandBackend.qml")
cw = re.search(r'function closeWindow\(handle\)\s*\{(.*?)\n    \}', hy, re.S)
mw = re.search(r'function moveWindowToWorkspace\(handle, ws\)\s*\{(.*?)\n    \}', hy, re.S)
verdict("DISPATCH", bool(cw) and "hl.dsp.window.close(" in cw.group(1)
        and bool(mw) and "hl.dsp.window.move(" in mw.group(1) and "follow = false" in mw.group(1)
        and "hl.dsp.close(" not in hy and "move_to_workspace" not in hy,
        "close/move Lua names")

oc = re.search(r'onOpenChanged\s*:\s*\{(.*?)\n    \}', ov, re.S)
verdict("RESET", bool(oc) and re.search(r'else\s*\{[^}]*content\.forceActiveFocus\(\)', oc.group(1), re.S) is not None,
        "close path")
PY
}

label() {
    case "$1" in
        BIND)     echo "SUPER+Tab is an untyped shell default (overview-toggle)" ;;
        IPC)      echo "overview-toggle opens it on the focused output, or niri's own" ;;
        NOTCH)    echo "it grows out of the centre notch on its own lifecycle, not as a Dashboard tab" ;;
        CAPTURE)  echo "window pictures capture only while the overview is live, at tile size" ;;
        REF)      echo "the window list is held only while the overview is mapped" ;;
        KEYED)    echo "tiles are keyed by window handle, so a list refresh keeps them" ;;
        DISPATCH) echo "close and move use Lua names Hyprland 0.56.2 has" ;;
        RESET)    echo "closing hands focus back to the content, so Escape works every time" ;;
    esac
}

echo "── the workspace overview ──"
verdicts="$(check_tree .)"
while read -r rule verdict detail; do
    [ -n "$rule" ] || continue
    if [ "$verdict" = PASS ]; then ok "$(label "$rule")"; else bad "$(label "$rule") — $detail"; fi
done <<<"$verdicts"
[ "$(grep -c . <<<"$verdicts")" -eq 8 ] && ok "all eight rules were evaluated" || bad "expected eight verdicts, got: $verdicts"

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
mutant "a typed exec bind instead of the untyped IPC form" src/services/config_tab/KeybindService.qml \
    'label: "Workspace Overview",   group: "Workspaces" }' 'label: "Workspace Overview",   group: "Workspaces", type: "exec", command: "$qsIpc overview-toggle toggle" }' BIND
mutant "no fallback to niri's overview" src/state/IpcManager.qml \
    '            CompositorService.toggleOverview()
            return' '            return' IPC
mutant "a body that does not start at the notch" src/popups/Overview.qml \
    'notchW:      root.anchorWindow ? root.anchorWindow.cWidth : theme.cNotchMinWidth,' 'notchW:      theme.cNotchMinWidth,' NOTCH
mutant "the overview made a Dashboard tab" src/state/DashboardLayout.qml \
    'readonly property var tabs: [' $'readonly property var tabs: [\n        { key: "overview", label: "Overview" },' NOTCH
mutant "a capture that runs with the overview closed" src/modules/Overview/OverviewWindowTile.qml \
    'captureSource: root.live ? root.source : null' 'captureSource: root.source' CAPTURE
mutant "the window list held for the whole session" src/popups/Overview.qml \
    $'service: CompositorService.windowsRef\n        active:  root.live' $'service: CompositorService.windowsRef\n        active:  true' REF
mutant "tiles modelled on the records themselves" src/modules/Overview/OverviewGrid.qml \
    'model: ScriptModel { values: cellItem.handles }' 'model: cellItem.handles' KEYED
mutant "the nil close name back" src/services/compositor/HyprlandBackend.qml \
    '`hl.dsp.window.close({ window = "address:${handle}" })`' '`hl.dsp.close({ window = "address:${handle}" })`' DISPATCH
mutant "a move that follows the window" src/services/compositor/HyprlandBackend.qml \
    'follow = false, window = "address:${handle}"' 'window = "address:${handle}"' DISPATCH
mutant "a close that leaves focus where it was" src/popups/Overview.qml \
    $'            focusGrabTimer.stop()\n            content.forceActiveFocus()' '            focusGrabTimer.stop()' RESET

echo
echo "check-overview: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
