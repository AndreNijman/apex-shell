// ─── The workspace overview's layout ────────────────────────────────────────
// Pure arithmetic for popups/Overview.qml and OverviewGrid.qml, kept out of QML
// so tests/overview-test.js drives the file the shell loads.
//
// The grid is ten workspaces, two rows of five (end-4's overview has the same
// shape, and so does the workspace capsule's 1–10), showing the group of ten
// that holds the focused workspace: 1–10, 11–20, and so on. Every workspace in
// the group gets a cell whether or not it holds a window, because an empty one
// is where a window is dragged to.
//
// A cell is its monitor, scaled: a window is drawn where it sits on its own
// output, at that output's scale to the cell. Windows on a workspace are laid
// out inside that workspace's monitor even while it is not the visible one
// (Hyprland keeps their positions), so "the screen whose rectangle holds the
// window's centre" is its monitor. Parts that lie outside it (a scrolling
// layout's off-screen columns) fall outside the cell, and the cell clips them,
// which is what the monitor shows too.
// ────────────────────────────────────────────────────────────────────────────

var COLS = 5;
var ROWS = 2;
var PER_GROUP = COLS * ROWS;

function _id(v) {
    var n = Math.floor(Number(v));
    return isFinite(n) ? n : 0;
}

// The group (0-based) that holds workspace `activeId`. Special workspaces
// (negative ids) and "none" count as the first group.
function groupOf(activeId) {
    var a = _id(activeId);
    return a >= 1 ? Math.floor((a - 1) / PER_GROUP) : 0;
}

// The workspace id in cell `index` (0-based, row-major) of `group`.
function workspaceAt(group, index) {
    return _id(group) * PER_GROUP + _id(index) + 1;
}

// The cell a workspace occupies in `group`, or -1 when it is not in it.
function indexOf(group, wsId) {
    var i = _id(wsId) - _id(group) * PER_GROUP - 1;
    return (i >= 0 && i < PER_GROUP) ? i : -1;
}

// A cell's size: the screen at `scale` (end-4's is 0.18), shrunk as far as it
// takes for the whole grid to fit `maxW` × `maxH`. Whole pixels, so the cells'
// edges are crisp; `scale` is what was actually used.
function cellSize(screenW, screenH, maxW, maxH, gap, scale) {
    var sw = Math.max(1, screenW), sh = Math.max(1, screenH);
    var s = Math.max(0, scale);
    s = Math.min(s, Math.max(0, maxW - gap * (COLS - 1)) / COLS / sw);
    s = Math.min(s, Math.max(0, maxH - gap * (ROWS - 1)) / ROWS / sh);
    return { w: Math.floor(sw * s), h: Math.floor(sh * s), scale: s };
}

// The grid's own size for a cell size and gap.
function gridSize(cell, gap) {
    return { w: COLS * cell.w + (COLS - 1) * gap, h: ROWS * cell.h + (ROWS - 1) * gap };
}

// A cell's top-left inside the grid.
function cellOrigin(index, cell, gap) {
    var i = _id(index);
    return { x: (i % COLS) * (cell.w + gap), y: Math.floor(i / COLS) * (cell.h + gap) };
}

// The cell under a point in grid coordinates, or -1 (a gap, or outside).
function cellAt(x, y, cell, gap) {
    if (x < 0 || y < 0) return -1;
    var c = Math.floor(x / (cell.w + gap)), r = Math.floor(y / (cell.h + gap));
    if (c >= COLS || r >= ROWS) return -1;
    if (x - c * (cell.w + gap) >= cell.w || y - r * (cell.h + gap) >= cell.h) return -1;
    return r * COLS + c;
}

// The monitor a window is on: the screen holding its centre; failing that
// (a window dragged across an edge), the screen nearest to it; failing that,
// `fallback`. Screens are { x, y, width, height } in the same logical
// coordinates as the window.
function monitorFor(win, screens, fallback) {
    var cx = win.x + win.width / 2, cy = win.y + win.height / 2;
    var best = null, bestD = Infinity;
    for (var i = 0; i < (screens ? screens.length : 0); i++) {
        var s = screens[i];
        if (!s || !(s.width > 0) || !(s.height > 0)) continue;
        var dx = Math.max(s.x - cx, 0, cx - (s.x + s.width));
        var dy = Math.max(s.y - cy, 0, cy - (s.y + s.height));
        var d = dx * dx + dy * dy;
        if (d < bestD) { bestD = d; best = s; }
    }
    return best || fallback || null;
}

// A window's rectangle inside its cell: where it sits on its monitor, scaled
// from that monitor to the cell. Not clamped (the cell clips).
function windowRect(win, mon, cell) {
    var sx = cell.w / Math.max(1, mon.width), sy = cell.h / Math.max(1, mon.height);
    return { x: (win.x - mon.x) * sx, y: (win.y - mon.y) * sy,
             w: Math.max(1, win.width * sx), h: Math.max(1, win.height * sy) };
}

// The windows of one group, back to front: the most recently focused window
// last, so it is drawn on top — in a monocle ("One at a time") workspace the
// one in front is the one you were using, as on the screen.
function stacked(windows, group) {
    var out = [];
    for (var i = 0; i < (windows ? windows.length : 0); i++) {
        var w = windows[i];
        if (w && indexOf(group, w.workspaceId) >= 0) out.push(w);
    }
    out.sort(function (a, b) {
        var ra = a.recency === undefined || a.recency < 0 ? 1e9 : a.recency;
        var rb = b.recency === undefined || b.recency < 0 ? 1e9 : b.recency;
        return rb - ra;   // larger focus-history index = longer ago = further back
    });
    return out;
}

// Keyboard: an arrow moves the selection one cell, and stops at the grid's
// edge rather than wrapping (a wrap on a 5 × 2 grid lands somewhere nobody
// pointed).
function step(index, key) {
    var i = _id(index), c = i % COLS, r = Math.floor(i / COLS);
    if (key === "left")  c = Math.max(0, c - 1);
    if (key === "right") c = Math.min(COLS - 1, c + 1);
    if (key === "up")    r = Math.max(0, r - 1);
    if (key === "down")  r = Math.min(ROWS - 1, r + 1);
    return r * COLS + c;
}

// The digit keys: 1–9 are the group's first nine cells and 0 its tenth, as
// SUPER+1 … SUPER+0 are workspaces 1–10. -1 for any other key.
function digitIndex(text) {
    if (typeof text !== "string" || text.length !== 1) return -1;
    if (text === "0") return 9;
    var n = text.charCodeAt(0) - 48;
    return (n >= 1 && n <= 9) ? n - 1 : -1;
}

if (typeof module !== "undefined" && module.exports)
    module.exports = { COLS: COLS, ROWS: ROWS, PER_GROUP: PER_GROUP, groupOf: groupOf,
                       workspaceAt: workspaceAt, indexOf: indexOf, cellSize: cellSize,
                       gridSize: gridSize, cellOrigin: cellOrigin, cellAt: cellAt,
                       monitorFor: monitorFor, windowRect: windowRect, stacked: stacked,
                       step: step, digitIndex: digitIndex };
