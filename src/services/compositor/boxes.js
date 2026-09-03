.pragma library

// ─── boxes.js ─────────────────────────────────────────────────────────────────
// Shell fragments that print one "x,y WxH" line per window or per output, for
// piping into slurp so a screenshot picker can be click-a-window / click-a-
// screen instead of drag-a-rectangle.
//
//     const s = CompositorService.windowBoxScript
//     cmd = s === "" ? ["slurp"] : ["bash", "-c", s + " | slurp"]
//
// A .js library rather than a QML type because the backends live in a directory
// that is not on the import path — they are reached through src/qmldir, so
// `SharedBoxes {}` would fail with "is not a type". A relative .js import is
// resolved against the importing file's own URL, so it works regardless.
//
// ── Why these use the compositor's own tools and not an APEX helper ──────────
// The obvious refactor is to put all of this behind `apex-display-apply boxes`.
// It is the wrong call *here*: apex-shell is a git checkout in $HOME that
// hot-reloads, and the OS image only updates when a new image is built. Pointing
// these at a helper that ships later means screenshot picking silently breaks
// for everyone who pulls the shell first. hyprctl and wlr-randr are already
// installed on every APEX image that can run this shell.
// ──────────────────────────────────────────────────────────────────────────────

// Hyprland. Kept byte-for-byte as it shipped in ScreenRecService — this was a
// relocation, and a "while I'm here" rewrite of working code is how a proven
// path acquires a new bug.
var HYPR_WINDOWS =
    "hyprctl clients -j | python3 -c \"" +
    "import sys,json; ws=json.load(sys.stdin); " +
    "[print(str(w['at'][0])+','+str(w['at'][1])+' '+str(w['size'][0])+'x'+str(w['size'][1])) " +
    "for w in ws if w['mapped']]\""

var HYPR_OUTPUTS =
    "hyprctl monitors -j | python3 -c \"" +
    "import sys,json; ms=json.load(sys.stdin); " +
    "[print(str(m['x'])+','+str(m['y'])+' '+str(m['width'])+'x'+str(m['height'])) for m in ms]\""

// niri and labwc share this one: both implement wlr-output-management and
// neither answers hyprctl. Deliberately identical rather than parameterised —
// it is the same protocol doing the same job, and the compositors differ only in
// that niri also has an IPC socket, which says nothing about outputs.
//
// slurp wants *logical* boxes, so the mode is divided by the scale, and a
// rotated output has its width and height swapped. Anything disabled, or with no
// current mode, is skipped rather than emitted at 0x0 — slurp treats a zero box
// as a target you can never hit.
var WLR_OUTPUTS =
    "wlr-randr --json | python3 -c '" +
    "import sys, json\n" +
    "for o in json.load(sys.stdin):\n" +
    "    if not o.get(\"enabled\"):\n" +
    "        continue\n" +
    "    cur = [m for m in o.get(\"modes\", []) if m.get(\"current\")]\n" +
    "    if not cur:\n" +
    "        continue\n" +
    "    scale = o.get(\"scale\") or 1.0\n" +
    "    w = int(round(cur[0][\"width\"] / scale))\n" +
    "    h = int(round(cur[0][\"height\"] / scale))\n" +
    "    if str(o.get(\"transform\", \"normal\")) in (\"90\", \"270\", \"flipped-90\", \"flipped-270\"):\n" +
    "        w, h = h, w\n" +
    "    pos = o.get(\"position\") or {}\n" +
    "    print(\"%d,%d %dx%d\" % (pos.get(\"x\", 0), pos.get(\"y\", 0), w, h))\n" +
    "'"
