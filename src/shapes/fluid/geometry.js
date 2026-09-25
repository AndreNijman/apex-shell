// ─── geometry.js ─────────────────────────────────────────────────────────────
// APEX's fluid surface geometry, as pure functions of named parameters.
//
// A surface's silhouette is never tweened as a path. Each family below takes a
// progress value (0 = the bar's own notch, 1 = the finished surface) and the
// geometry it connects to, derives a small set of MEANINGFUL parameters from
// them — neck width, body width, depth, shoulder radius, corner radius — each on
// its own curve, and builds the path from those. The path is then drawn by one
// QtQuick.Shapes CurveRenderer shape (see FluidShape.qml).
//
// Every family returns the same record:
//
//   path      SVG path data, for PathSvg
//   segs      the same path as a segment list, for tests/fluid-geometry-test.js
//             (continuity at joins, self-intersection, bounds)
//   bounds    {x, y, w, h}: the painted extent — the input mask and the
//             window's needed size come from it
//   clip      {x, y, w, h}: the rectangle content may show through right now.
//             Content keeps its FINAL layout and is revealed by this, so a
//             morphing body never relays out what is inside it.
//   bar       what the bar must draw in step (e.g. a notch corner radius), for
//             families whose silhouette crosses the bar/popup seam
//
// No `.pragma library`: node reads this file too, and it keeps no state.
// ─────────────────────────────────────────────────────────────────────────────

// A quarter circle drawn with one cubic. The classic constant; the radial error
// is 0.027 % of the radius — invisible at any size a shell draws.
var KAPPA = 0.5522847498;

function clamp01(t) { return t < 0 ? 0 : (t > 1 ? 1 : t); }
function lerp(a, b, t) { return a + (b - a) * t; }
// t remapped so it runs 0..1 across [a, b] of the parent progress.
function span(t, a, b) { return clamp01((t - a) / (b - a)); }
function smooth(t) { t = clamp01(t); return t * t * (3 - 2 * t); }
// A decelerating ramp: fast out of 0, settling into 1. pow gives the knob.
function decel(t, k) { t = clamp01(t); return 1 - Math.pow(1 - t, k || 2); }
function accel(t, k) { t = clamp01(t); return Math.pow(t, k || 2); }

// ── Path builder ────────────────────────────────────────────────────────────
function Path() {
    this.d = [];
    this.segs = [];
    this.x = 0; this.y = 0;
    this.x0 = 0; this.y0 = 0;
}
function _n(v) { return (Math.round(v * 100) / 100).toString(); }
Path.prototype.move = function (x, y) {
    this.d.push("M " + _n(x) + " " + _n(y));
    this.x = this.x0 = x; this.y = this.y0 = y;
    return this;
};
Path.prototype.line = function (x, y, sharp) {
    if (Math.abs(x - this.x) < 1e-6 && Math.abs(y - this.y) < 1e-6) return this;
    this.d.push("L " + _n(x) + " " + _n(y));
    this.segs.push({ t: "L", p: [[this.x, this.y], [x, y]], sharp: !!sharp });
    this.x = x; this.y = y;
    return this;
};
// A deliberately sharp edge: one that meets its neighbours at a corner by
// design (a step up into the bar strip, where the bar covers the corner). The
// continuity suite skips the joins on either side of it, and only those.
Path.prototype.step = function (x, y) { return this.line(x, y, true); };
Path.prototype.cubic = function (c1x, c1y, c2x, c2y, x, y) {
    this.d.push("C " + _n(c1x) + " " + _n(c1y) + " " + _n(c2x) + " " + _n(c2y)
                + " " + _n(x) + " " + _n(y));
    this.segs.push({ t: "C", p: [[this.x, this.y], [c1x, c1y], [c2x, c2y], [x, y]] });
    this.x = x; this.y = y;
    return this;
};
// A quarter-circle corner from the current point to (x, y), turning from the
// current direction `dirIn` ("h" or "v") into the other axis. Works for convex
// and concave corners alike: the arc's control points follow the tangents, so
// which side is filled is decided by the direction of travel, not by a flag.
Path.prototype.corner = function (x, y, dirIn) {
    var dx = x - this.x, dy = y - this.y;
    if (Math.abs(dx) < 1e-6 && Math.abs(dy) < 1e-6) return this;
    if (dirIn === "h")
        return this.cubic(this.x + dx * KAPPA, this.y, x, y - dy * KAPPA, x, y);
    return this.cubic(this.x, this.y + dy * KAPPA, x - dx * KAPPA, y, x, y);
};
// A vertical S from the current point to (x, y): leaves and arrives vertically,
// so a neck that differs in width from the body below it joins both with a
// tangent-continuous curve. Degenerates to a straight line when x is equal.
Path.prototype.sVert = function (x, y, tension) {
    var k = tension === undefined ? 0.5 : tension;
    var dy = y - this.y;
    if (Math.abs(x - this.x) < 0.01) return this.line(x, y);
    return this.cubic(this.x, this.y + dy * k, x, y - dy * k, x, y);
};
// The horizontal counterpart: leaves and arrives horizontally.
Path.prototype.sHorz = function (x, y, tension) {
    var k = tension === undefined ? 0.5 : tension;
    var dx = x - this.x;
    if (Math.abs(y - this.y) < 0.01) return this.line(x, y);
    return this.cubic(this.x + dx * k, this.y, x - dx * k, y, x, y);
};
Path.prototype.close = function () {
    if (Math.abs(this.x - this.x0) > 1e-6 || Math.abs(this.y - this.y0) > 1e-6)
        this.segs.push({ t: "L", p: [[this.x, this.y], [this.x0, this.y0]], sharp: true });
    this.d.push("Z");
    this.x = this.x0; this.y = this.y0;
    return this;
};
Path.prototype.toString = function () { return this.d.join(" "); };

// ── CENTER_BLOOM ────────────────────────────────────────────────────────────
// The Dashboard: the centre notch becomes the surface.
//
//   g.cx        centre x of the notch, in the surface's window
//   g.strip     y of the bar strip's bottom edge (the border width)
//   g.notchW    the notch's width right now (TopBar cWidth, without shoulders)
//   g.notchH    the notch's height (bar height)
//   g.shoulder  the notch's concave shoulder radius (notchRadius)
//   g.notchR    the notch's bottom corner radius (notchRadius)
//   g.w         the finished body width (the page's width)
//   g.h         the finished body's bottom edge, in window y
//   g.r         the finished body's bottom corner radius (radius XL)
//   g.shoulder1 the finished body's shoulder radius
//
// Character (roadmap Fluid §4): width leads depth; the neck — where the body
// leaves the strip — stays tight while the body below it swells, so the early
// silhouette is a bell hanging from the notch rather than a rectangle scaling;
// then the neck opens, the shoulders broaden into the finished join, and the
// corners settle. No part of it overshoots.
function centerBloom(p, g) {
    p = clamp01(p);
    var b = g.strip;
    // Parameter curves. Each is a function of p; together they are the motion.
    var tBody  = decel(span(p, 0.00, 0.62), 2.4);   // body width: leads, fast out
    var tNeck  = smooth(span(p, 0.12, 0.92));        // neck width: lags the body
    var tDepth = decel(span(p, 0.06, 0.86), 1.9);    // depth: starts a beat later
    var tCorner = smooth(span(p, 0.25, 1.00));        // corners settle last

    var wb = lerp(g.notchW, g.w, tBody);
    var wn = lerp(g.notchW, g.w, tNeck);
    var hb = lerp(g.notchH, g.h, tDepth);
    // The shoulder opens from the notch's radius to the finished one on its
    // own ramp. It never overshoots its end value: a shoulder that flares past
    // its final radius and pulls back in is a rebound, however small.
    var rs = lerp(g.shoulder, g.shoulder1, smooth(span(p, 0.10, 0.90)));
    var rc = lerp(g.notchR, g.r, tCorner);

    // Never let geometry cross itself: the corner and shoulder must fit the side.
    var sideTop = b + rs;
    var room = Math.max(0, hb - sideTop);
    rc = Math.min(rc, room, wb / 2);
    // The S that carries the narrower neck out to the wider body. It spans the
    // upper part of the side while the two differ, and nothing once they agree.
    var neckSpan = Math.min(Math.max(0, room - rc), Math.max(rs * 2.2, (hb - b) * 0.38));

    var L = new Path();
    var xnL = g.cx - wn / 2, xnR = g.cx + wn / 2;
    var xbL = g.cx - wb / 2, xbR = g.cx + wb / 2;
    // Start one pixel up inside the strip so the join never shows a seam.
    L.move(xnL - rs, b - 1);
    L.step(xnL - rs, b);
    L.corner(xnL, b + rs, "h");                        // left shoulder (concave)
    L.sVert(xbL, b + rs + neckSpan);                   // neck → body
    L.line(xbL, hb - rc);
    L.corner(xbL + rc, hb, "v");                       // bottom-left (convex)
    L.line(xbR - rc, hb);
    L.corner(xbR, hb - rc, "h");                       // bottom-right (convex)
    L.line(xbR, b + rs + neckSpan);
    L.sVert(xnR, b + rs);                              // body → neck
    L.corner(xnR + rs, b, "v");                        // right shoulder (concave)
    L.step(xnR + rs, b - 1);
    L.close();

    var wMin = Math.min(wn, wb);
    return {
        path: L.toString(),
        segs: L.segs,
        bounds: { x: Math.min(xnL - rs, xbL), y: b - 1,
                  w: Math.max(wn + 2 * rs, wb), h: hb - b + 1 },
        clip: { x: g.cx - wMin / 2, y: b, w: wMin, h: Math.max(0, hb - b) },
        params: { wb: wb, wn: wn, hb: hb, rs: rs, rc: rc, neckSpan: neckSpan },
        bar: {}
    };
}

if (typeof module !== "undefined" && module.exports)
    module.exports = {
        KAPPA: KAPPA,
        Path: Path,
        clamp01: clamp01, lerp: lerp, span: span, smooth: smooth, decel: decel, accel: accel,
        centerBloom: centerBloom
    };
