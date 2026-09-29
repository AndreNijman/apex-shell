// tests/overview-test.js — the workspace overview's layout (src/modules/Overview/overview.js).
//
//     node tests/overview-test.js
//
// Drives the file the shell loads. Numbers are the L16's (1920 × 1200) and a
// second 2560 × 1440 output to its right, as Hyprland lays them out.
"use strict";
const O = require("../src/modules/Overview/overview.js");

let pass = 0, fail = 0;
function check(name, ok, detail) {
    if (ok) { pass++; console.log("  ok   " + name); }
    else    { fail++; console.log("  FAIL " + name + (detail ? " — " + detail : "")); }
}

console.log("── groups and cells ──");
check("workspaces 1–10 are group 0, 11–20 group 1",
      O.groupOf(1) === 0 && O.groupOf(10) === 0 && O.groupOf(11) === 1 && O.groupOf(20) === 1);
check("a special workspace (negative id) or none counts as group 0",
      O.groupOf(-98) === 0 && O.groupOf(0) === 0 && O.groupOf(undefined) === 0);
check("cells map to workspaces row-major, and back",
      O.workspaceAt(0, 0) === 1 && O.workspaceAt(0, 9) === 10 && O.workspaceAt(1, 4) === 15
      && O.indexOf(1, 15) === 4 && O.indexOf(0, 11) === -1 && O.indexOf(0, -98) === -1);

const gap = 8;
const c = O.cellSize(1920, 1200, 1700, 600, gap, 0.18);
check("a cell keeps its monitor's aspect", Math.abs(c.w / c.h - 1920 / 1200) < 0.01, c.w + "×" + c.h);
const g = O.gridSize(c, gap);
check("the grid fits the width it was given", g.w <= 1700, "grid " + g.w + " wide");
check("the grid fits the height it was given", g.h <= 600, "grid " + g.h + " tall");
const wide = O.cellSize(1920, 1200, 9999, 9999, gap, 0.18);
check("with room to spare the cell is the requested scale", wide.w === Math.floor(1920 * 0.18), wide.w);
check("cell origins are row-major with the gap between",
      JSON.stringify(O.cellOrigin(6, c, gap)) === JSON.stringify({ x: c.w + gap, y: c.h + gap }));
check("cellAt finds a cell's interior and inverts cellOrigin",
      [0, 3, 5, 9].every(i => { const o = O.cellOrigin(i, c, gap); return O.cellAt(o.x + 1, o.y + 1, c, gap) === i
                                  && O.cellAt(o.x + c.w - 1, o.y + c.h - 1, c, gap) === i; }));
check("the gaps and the outside are no cell",
      O.cellAt(c.w + 1, 5, c, gap) === -1 && O.cellAt(5, c.h + 1, c, gap) === -1
      && O.cellAt(-1, 5, c, gap) === -1 && O.cellAt(g.w + 5, 5, c, gap) === -1);

console.log("── windows ──");
const screens = [{ name: "eDP-1", x: 0, y: 0, width: 1920, height: 1200 },
                 { name: "DP-1", x: 1920, y: 0, width: 2560, height: 1440 }];
const left = { x: 11, y: 51, width: 943, height: 1138 };
const onDP = { x: 1930, y: 50, width: 1270, height: 1380 };
check("a window is on the monitor that holds its centre",
      O.monitorFor(left, screens).name === "eDP-1" && O.monitorFor(onDP, screens).name === "DP-1");
check("a window straddling nothing is given the nearest monitor",
      O.monitorFor({ x: 5000, y: 10, width: 100, height: 100 }, screens).name === "DP-1");
check("no screens at all → the fallback", O.monitorFor(left, [], screens[0]) === screens[0]);
const r = O.windowRect(left, screens[0], c);
check("a window's rectangle is its place on its monitor, scaled to the cell",
      Math.abs(r.x - 11 * c.w / 1920) < 1e-9 && Math.abs(r.w - 943 * c.w / 1920) < 1e-9
      && Math.abs(r.h - 1138 * c.h / 1200) < 1e-9);
const r2 = O.windowRect(onDP, screens[1], c);
check("…from its own monitor, not the one the overview is on",
      Math.abs(r2.x - 10 * c.w / 2560) < 1e-9 && Math.abs(r2.w - 1270 * c.w / 2560) < 1e-9);
const off = O.windowRect({ x: -939, y: 11, width: 943, height: 1058 }, screens[0], c);
check("a scrolling layout's off-screen column lands outside the cell (the cell clips it)", off.x + off.w < 1);

const wins = [
    { handle: "a", workspaceId: 1, recency: 2 }, { handle: "b", workspaceId: 1, recency: 0 },
    { handle: "c", workspaceId: 3, recency: 1 }, { handle: "d", workspaceId: 12, recency: 3 },
    { handle: "e", workspaceId: -98, recency: 4 }, { handle: "f", workspaceId: 2 }];
const st = O.stacked(wins, 0).map(w => w.handle);
check("stacked keeps the group's windows only (not 12, not the scratchpad)",
      st.length === 4 && st.indexOf("d") < 0 && st.indexOf("e") < 0, st.join(","));
check("…back to front: the most recently focused last, drawn on top",
      st[st.length - 1] === "b" && st.indexOf("a") < st.indexOf("c") && st[0] === "f", st.join(","));

console.log("── keyboard ──");
check("arrows step one cell", O.step(0, "right") === 1 && O.step(1, "down") === 6 && O.step(6, "up") === 1
      && O.step(6, "left") === 5);
check("…and stop at the edge instead of wrapping",
      O.step(0, "left") === 0 && O.step(4, "right") === 4 && O.step(2, "up") === 2 && O.step(7, "down") === 7);
check("digits 1–9 and 0 pick cells 0–8 and 9, anything else nothing",
      O.digitIndex("1") === 0 && O.digitIndex("9") === 8 && O.digitIndex("0") === 9
      && O.digitIndex("a") === -1 && O.digitIndex("") === -1 && O.digitIndex("12") === -1);

console.log("");
console.log("overview: passed=" + pass + " failed=" + fail);
process.exit(fail === 0 ? 0 : 1);
