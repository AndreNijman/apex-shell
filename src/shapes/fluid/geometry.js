// ─── geometry.js ─────────────────────────────────────────────────────────────
// Rime's fluid surface geometry, as pure functions of named parameters.
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
    // Under a thousandth of a pixel a corner is a point: a spring's last tail
    // (1e-6 px) must not become a cubic whose tangent is rounding noise.
    if (Math.abs(dx) < 1e-3 && Math.abs(dy) < 1e-3) return this;
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

// ── Curves used by the families ─────────────────────────────────────────────
// The same BezierSpline tables theme/motion.js exports, evaluated here so this
// file stays self-contained for node and for the greeter-free QML import.
function _bez1(a, b, c, d, s) { var u = 1 - s; return u*u*u*a + 3*u*u*s*b + 3*u*s*s*c + s*s*s*d; }
function curve(c, t) {
    t = clamp01(t);
    if (t === 0 || t === 1) return t;
    var lo = 0, hi = 1;
    for (var k = 0; k < 28; k++) {
        var m = (lo + hi) / 2;
        if (_bez1(0, c[0], c[2], 1, m) < t) lo = m; else hi = m;
    }
    return _bez1(0, c[1], c[3], 1, (lo + hi) / 2);
}
var FAST_DECEL      = [0, 0, 0.2, 1];
var STANDARD        = [0.2, 0, 0, 1];
var STANDARD_DECEL  = [0, 0, 0, 1];
var EMPHASIZED_DECEL = [0.05, 0.7, 0.1, 1];
function fastDecel(t)       { return curve(FAST_DECEL, t); }
function standard(t)        { return curve(STANDARD, t); }
function standardDecel(t)   { return curve(STANDARD_DECEL, t); }
function emphasizedDecel(t) { return curve(EMPHASIZED_DECEL, t); }

// A concave or convex corner whose control points sit τ of the way along each
// tangent: τ = KAPPA is a circular quadrant (what the bar's arcTo draws);
// larger is a fuller, squarer "squircle" corner. Never above 0.8 (it kinks).
Path.prototype.cornerT = function (x, y, dirIn, tau) {
    var dx = x - this.x, dy = y - this.y;
    // Under a thousandth of a pixel a corner is a point: a spring's last tail
    // (1e-6 px) must not become a cubic whose tangent is rounding noise.
    if (Math.abs(dx) < 1e-3 && Math.abs(dy) < 1e-3) return this;
    if (dirIn === "h")
        return this.cubic(this.x + dx * tau, this.y, x, y - dy * tau, x, y);
    return this.cubic(this.x, this.y + dy * tau, x - dx * tau, y, x, y);
};

// ── Channels ────────────────────────────────────────────────────────────────
// Since the springs (2026-09-26) a family may be driven by CHANNELS instead of
// one progress value: `g.ch = { w, d, n, fw, fd }`, straight from
// SurfaceLifecycle's liquid springs —
//
//   w, d   the width and depth channels, 0 at the notch and 1 finished. Raw
//          spring values: an underdamped spring passes 1 by a hair, and that
//          becomes a SWELL of a few pixels, soft-capped (size() below).
//   n      the trail: a critically damped follower, for radii, shoulders,
//          fillets. Never past 1 by construction.
//   fw, fd the width and depth FLOW: speed relative to a nominal open's peak,
//          about 1 at the fastest and exactly 0 at rest. Secondary motion — a
//          bowing edge, a sagging front, a bulging corner — is proportional to
//          it, so the finished shape is exact and a reversal bends the other way
//          by itself. That is what reads as liquid rather than as a tween.
//
// Without `g.ch` each family derives its channels from `p` on the curves it
// always had, so a single progress value still draws exactly what it drew
// before (tests/fluid-geometry-test.js sweeps both).
function softCap(x, cap) { return x <= 0 ? x : cap * Math.tanh(x / cap); }
// A size between a0 (channel 0) and a1 (channel 1): linear up to the target —
// the spring already supplies the easing, a curve here would ease twice — and
// past it a swell of at most `cap` px.
function size(a0, a1, c, cap) {
    c = Math.max(0, c);
    if (c <= 1) return a0 + (a1 - a0) * c;
    return a1 + softCap((a1 - a0) * (c - 1), cap);
}
function flow(ch, k) { var v = ch ? ch[k] : 0; return (typeof v === "number" && isFinite(v)) ? v : 0; }

// A rectangle with square top corners and round bottom ones, as SVG — the
// notch's content window, which a bloom leaves open while the bar's own label
// fades out underneath it (FluidShape.hole). Wound the same way as every
// silhouette; FluidShape fills odd-even, so inside the body it is a hole.
function notchHole(x, y, w, h, rb) {
    rb = Math.max(0, Math.min(rb, w / 2, h));
    var P = new Path();
    P.move(x, y);
    P.line(x + w, y);
    P.line(x + w, y + h - rb);
    if (rb > 0) P.corner(x + w - rb, y + h, "v");
    P.line(x + rb, y + h);
    if (rb > 0) P.corner(x, y + h - rb, "h");
    P.close();
    return P.toString();
}

// ── The bar's own notch ─────────────────────────────────────────────────────
// One notch hanging from the strip, as the bar draws it: concave shoulders out
// of the strip (circular, notchShoulder), convex bottom corners (notchBottom),
// either bottom corner squarable (0) for a surface attached below. Used by the
// prototype harness today and by the bar once it leaves Canvas.
//
//   g.x, g.w     the notch body's left edge and width (shoulders extend past)
//   g.strip, g.h the strip's bottom edge and the notch's height (the seam)
//   g.shoulder, g.bottomL, g.bottomR
//   g.edgeL / g.edgeR  true when that side is the screen edge (no shoulder)
function barNotch(g) {
    var b = g.strip, h = g.h, x0 = g.x, x1 = g.x + g.w, rs = g.shoulder;
    var rl = Math.min(g.bottomL, (h - b - rs), g.w / 2);
    var rr = Math.min(g.bottomR, (h - b - rs), g.w / 2);
    var P = new Path();
    if (g.edgeL) { P.move(x0, 0); }
    else { P.move(x0 - rs, 0); P.step(x0 - rs, b); P.corner(x0, b + rs, "h"); }
    P.line(x0, h - rl);
    if (rl > 0) P.corner(x0 + rl, h, "v");
    P.line(x1 - rr, h);
    if (rr > 0) P.corner(x1, h - rr, "h");
    if (g.edgeR) { P.line(x1, 0); }
    else { P.line(x1, b + rs); P.corner(x1 + rs, b, "v"); P.step(x1 + rs, 0); }
    P.close();
    return { path: P.toString(), segs: P.segs };
}

// ── The whole bar ───────────────────────────────────────────────────────────
// The top strip and its three notches as ONE silhouette — what
// SeamlessBarShape draws. It used to be a Canvas (arcTo corners, an 8x MSAA
// layer): measured, it repainted a frame or more behind the value it was
// given, so under RIGHT_POUR the notch trailed the body hanging from it by up
// to 77 px mid-pour, and it cost 2.28 ms a frame against a Shape's 0.80
// (BASELINE §3). This is the same geometry, corner for corner, for the same
// renderer the surfaces use, so the two now change in the same frame.
//
//   g.w                      the bar's width (the output's)
//   g.strip, g.h             strip bottom edge and notch height (the seam)
//   g.shoulder, g.bottom     the two notch radii (ThemeSet notchShoulder/Bottom)
//   g.leftW, g.centerW, g.rightW   the notches' widths; left and right sit on
//                            the screen edges, the centre is centred
//   g.rightBottomL           the right notch's bottom-left radius (0 while a
//                            pane hangs below it)
//
// Whole-pixel positions: the centre notch's edges round exactly as
// CENTER_BLOOM's do, so the Dashboard and the bar agree at progress 0.
function barSilhouette(g) {
    var w = g.w, b = g.strip, h = g.h, r = g.shoulder;
    var side = Math.max(0, h - b - r);                 // room on a notch's side
    function rb(v, notchW) { return Math.max(0, Math.min(v, side, notchW / 2)); }
    var lW = Math.round(g.leftW), rW = Math.round(g.rightW);
    var cS = Math.round(w / 2) - Math.round(g.centerW / 2);
    var cE = cS + Math.round(g.centerW);
    var rS = w - rW;
    var rbL = rb(g.bottom, lW), rbC = rb(g.bottom, cE - cS), rbR = rb(g.rightBottomL, rW);

    var P = new Path();
    P.move(0, h);
    // Left notch: along its bottom, up its right side, out along the strip.
    P.line(lW - rbL, h);
    P.corner(lW, h - rbL, "h");
    P.line(lW, b + r);
    P.corner(lW + r, b, "v");
    // Centre notch.
    P.line(cS - r, b);
    P.corner(cS, b + r, "h");
    P.line(cS, h - rbC);
    P.corner(cS + rbC, h, "v");
    P.line(cE - rbC, h);
    P.corner(cE, h - rbC, "h");
    P.line(cE, b + r);
    P.corner(cE + r, b, "v");
    // Right notch: down its left side, along its bottom to the screen edge.
    P.line(rS - r, b);
    P.corner(rS, b + r, "h");
    P.line(rS, h - rbR);
    if (rbR > 0) P.corner(rS + rbR, h, "v");
    else P.step(rS, h);
    P.line(w, h, true);
    P.step(w, 0);
    P.step(0, 0);
    P.close();
    return { path: P.toString(), segs: P.segs,
             params: { lW: lW, cS: cS, cE: cE, rS: rS, rbL: rbL, rbC: rbC, rbR: rbR } };
}

// ── The bar's hairline (brief §C.6 / §D.7) ─────────────────────────────────
// The one depth cue the bar has: a 1 px stroke along its wallpaper-facing edge
// — the strip's bottom and every notch's sides, shoulders and bottom — as an
// OPEN path (the screen edges and the top are not an edge anyone sees),
// inset half a pixel so a 1 px stroke lies wholly inside the fill and never
// touches the wallpaper. Same corners as barSilhouette, offset: shoulders
// (concave) at r + ½, bottom corners (convex) at rb − ½.
//
// Suppressed on a seam: with a pane attached under the right notch
// (g.rightAttached) the line stops where the strip meets that notch. The pane
// draws the notch's widened band and its side over the bar, but not the
// notch's own bottom edge, which is the seam — a line there would sit between
// the notch and the body hanging from it.
//
// And it stops where the frame's side strips attach (g.frameInset: the strip's
// thickness + its flare's radius from each screen edge). Under the left and
// right notches' outer ends the frame hangs on, and its strip carries this
// same line on round its flare and down (windows/Border.qml); drawn to the
// screen edge, the line cut straight across the flare instead (Andre,
// 2026-09-27: "the corners fillets dont merge properly").
//
// …but the strip's first row IS the bar's last one (Border's `overlap`), and
// the bar's surface is drawn over it: the rim's first few pixels, where it
// leaves the line, lay under the bar's fill and were never seen. On the panel
// the line ended in a flat ledge and the rim reappeared a row lower, 5 px
// further out — "a little weird bump" at both top corners (Andre, 2026-09-29).
// So with g.frameRadius given, each end of the line carries on round that same
// circle (centre (frameInset, h + frameRadius), radius frameRadius + ½) to a
// point a pixel below the bar's edge: the bar's surface clips it there, and
// the strip's own rim carries on from the row beneath.
function _rimLeadIn(cx, cy, R, yEnd, side) {
    // The rim's point at angle φ from its top, on `side` (−1 left, +1 right):
    // (cx + side·R·sin φ, cy − R·cos φ). φ is where that point is at yEnd, and
    // the arc from the top to it is one cubic with k = 4/3·tan(φ/4)·R (the
    // radial error is under a thousandth of a pixel for the ~24° drawn here).
    var phi = Math.acos(Math.max(-1, Math.min(1, (cy - yEnd) / R)));
    var k = 4 / 3 * Math.tan(phi / 4) * R;
    var ex = cx + side * R * Math.sin(phi), ey = cy - R * Math.cos(phi);
    // The circle's tangent at that point, pointing away from the top.
    var tx = side * Math.cos(phi), ty = Math.sin(phi);
    return { x: ex, y: ey, k: k,
             near: [ex - tx * k, ey - ty * k],     // the control point by the far end
             top:  [cx + side * k, cy - R] };      // …and the one by the top
}
function barHairline(g) {
    var w = g.w, b = g.strip, h = g.h, r = g.shoulder, i = 0.5;
    var fi = Math.max(0, g.frameInset || 0);
    var side = Math.max(0, h - b - r);
    function rb(v, notchW) { return Math.max(i, Math.min(v, side, notchW / 2)); }
    var lW = Math.round(g.leftW), rW = Math.round(g.rightW);
    var cS = Math.round(w / 2) - Math.round(g.centerW / 2);
    var cE = cS + Math.round(g.centerW);
    var rS = w - rW;
    var rbL = rb(g.bottom, lW), rbC = rb(g.bottom, cE - cS), rbR = rb(g.rightBottomL, rW);

    var fr = Math.max(0, g.frameRadius || 0);
    var leadL = fi > 0 && fr > 0 && fi <= lW - rbL;
    var P = new Path(), lead = null;
    if (leadL) {
        lead = _rimLeadIn(fi, h + fr, fr + i, h + 1, -1);
        P.move(lead.x, lead.y);
        P.cubic(lead.near[0], lead.near[1], lead.top[0], lead.top[1], fi, h - i);
    } else {
        P.move(Math.min(fi, lW - rbL), h - i);
    }
    var leadStart = leadL ? [lead.x, lead.y] : null;
    P.line(lW - rbL, h - i);
    P.corner(lW - i, h - rbL, "h");
    P.line(lW - i, b + r);
    P.corner(lW + r, b - i, "v");
    P.line(cS - r, b - i);
    P.corner(cS + i, b + r, "h");
    P.line(cS + i, h - rbC);
    P.corner(cS + rbC, h - i, "v");
    P.line(cE - rbC, h - i);
    P.corner(cE - i, h - rbC, "h");
    P.line(cE - i, b + r);
    P.corner(cE + r, b - i, "v");
    P.line(rS - r, b - i);
    if (!g.rightAttached) {
        P.corner(rS + i, b + r, "h");
        P.line(rS + i, h - rbR);
        P.corner(rS + rbR, h - i, "v");
        P.line(Math.max(w - fi, rS + rbR), h - i);
    }
    var end = P.x, leadEnd = null;
    if (!g.rightAttached && fi > 0 && fr > 0 && w - fi >= rS + rbR) {
        var rl = _rimLeadIn(w - fi, h + fr, fr + i, h + 1, 1);
        P.cubic(rl.top[0], rl.top[1], rl.near[0], rl.near[1], rl.x, rl.y);
        leadEnd = [rl.x, rl.y];
    }
    return { path: P.toString(), segs: P.segs,
             params: { rS: rS, start: Math.min(fi, lW - rbL), end: end,
                       leadStart: leadStart, leadEnd: leadEnd,
                       rim: fr > 0 ? { left: [fi, h + fr], right: [w - fi, h + fr], R: fr + i } : null } };
}

// ── Window corners, concentric with the frame ───────────────────────────────
// The frame's inner fillet (windows/Border.qml: radius frameRadius, strip
// `strip` wide) and a window's outer corner (Hyprland: rounding + its border,
// gapsOut from the screen's edge) are concentric — the band between them the
// same width round the corner as along the edges — exactly when their centres
// coincide: strip + frameRadius = gapsOut + (rounding + border). So the
// rounding a window needs (Andre, 2026-09-27: "make it exactly") is
//     frameRadius − (gapsOut − strip) − border,
// never below 0 (a band as wide as the fillet leaves a square window).
function windowRounding(frameRadius, strip, gapsOut, border) {
    var band = Math.max(0, gapsOut - strip);
    return Math.max(0, Math.round(frameRadius - band - border));
}

// ── CENTER_BLOOM ────────────────────────────────────────────────────────────
// The Dashboard: the centre notch BECOMES the surface. Drawn in the fullscreen
// Dashboard window, from y = 0, over the bar's own notch — at p = 0 it is that
// notch exactly (same tokens), so the bar needs no animation of its own and the
// body can unmap at p = 0 where the two coincide.
//
//   g.cx          centre x of the notch
//   g.strip       the strip's bottom edge (border width)
//   g.notchW      the notch's width RIGHT NOW (a live binding: a media title
//                 widening the notch while the Dashboard is up must be what the
//                 body shrinks back into)
//   g.notchH      bar height (the seam)
//   g.shoulder    notch shoulder radius (ThemeSet.notchShoulder)
//   g.notchBottom notch bottom corner radius (ThemeSet.notchBottom)
//   g.w           finished body width (the page's width)
//   g.h           finished bottom edge, from y = 0 (notchH + dashboard height)
//   g.r           finished bottom corners (radius XL)
//   g.shoulderW1, g.shoulderH1   finished shoulder (wider than tall)
//
// Character (Fluid §4, brief A.1): width leads on fastDecel; depth starts at
// 18 % on standard; the shoulders — the only neck in the shell that GROWS —
// open from the notch's to the finished join and fill out (τ .55 → .65); the
// corners land on XL. Symmetric, no part overshoots.
function centerBloom(p, g) {
    p = clamp01(p);
    var ch = g.ch || { w: fastDecel(p), d: standard(span(p, 0.18, 1.0)),
                       n: standard(span(p, 0.15, 0.75)), fd: 0 };
    var b = g.strip;
    var W  = size(g.notchW, g.w, ch.w, 4);
    var D  = size(g.notchH, g.h, ch.d, 6);
    var es = clamp01(ch.n);
    var sw = g.shoulder + (g.shoulderW1 - g.shoulder) * es;
    var sh = g.shoulder + (g.shoulderH1 - g.shoulder) * es;
    var tau = KAPPA + (0.65 - KAPPA) * es;
    var rb = g.notchBottom + (g.r - g.notchBottom) * es;
    // Degenerate guard: the corner and the shoulder must share the side.
    rb = Math.min(rb, Math.max(0, D - (b + sh)), W / 2);
    // The bottom edge bows with the depth's flow: its middle leads while the
    // body drops (a drop is rounder at its front) and trails while it rises,
    // up to 8 px at full speed and exactly 0 at rest. Never deeper than the
    // side it hangs from, so a rising edge cannot fold into the shoulders.
    var side = Math.max(0, D - (b + sh) - rb);
    var bow = 8 * Math.tanh(flow(ch, "fd"));
    bow = Math.max(-0.5 * side, Math.min(bow, 0.5 * (W - 2 * rb)));

    var xc = Math.round(g.cx);
    var L = xc - Math.round(W / 2), R = L + Math.round(W);
    var P = new Path();
    P.move(L - sw, 0);
    P.step(R + sw, 0);                        // across the top, inside the strip
    P.step(R + sw, b);
    P.cornerT(R, b + sh, "h", tau);           // right shoulder (concave)
    P.line(R, D - rb);
    P.corner(R - rb, D, "v");                 // bottom-right (convex)
    if (Math.abs(bow) >= 0.05 && R - L - 2 * rb > 2) {
        P.sHorz(xc, D + bow, 0.5);            // the bow, in two halves that
        P.sHorz(L + rb, D, 0.5);              // leave and arrive level
    } else {
        P.line(L + rb, D);
    }
    P.corner(L, D - rb, "h");                 // bottom-left (convex)
    P.line(L, b + sh);
    P.cornerT(L - sw, b, "v", tau);           // left shoulder (concave)
    P.close();

    var inset = Math.min(8, W / 4);
    return {
        path: P.toString(), segs: P.segs,
        bounds: { x: L - sw, y: 0, w: (R - L) + 2 * sw, h: D + Math.max(0, bow) },
        clip: { x: L + inset, y: b, w: Math.max(0, (R - L) - 2 * inset),
                h: Math.max(0, D - b - Math.max(0, -bow)) },
        params: { W: W, D: D, sw: sw, sh: sh, tau: tau, rb: rb, L: L, R: R, bow: bow },
        bar: {}
    };
}

// ── RIGHT_POUR ──────────────────────────────────────────────────────────────
// Network, the notification centre and the toast, out of the right notch.
// Drawn in the panel window, whose y = 0 is the SCREEN top and whose right
// edge is the screen's; the seam (the notch's bottom edge) is at y = g.seam.
//
// The panel draws everything that moves — the widened band of the notch, its
// shoulder out of the strip, and a cover over the bar's own bottom-left corner
// — and the bar draws only its natural notch, which never moves. The first
// version had the bar widen its notch in step, from the same width function;
// measured on the headless compositor, two layer surfaces present their frames
// independently, and the notch sat a frame off the body — a 35-42 px ledge —
// on a close and on a cold open. An edge drawn in one window cannot be a
// frame off itself. At p = 0 this silhouette over the bar's notch is exactly
// the bar's own (same shoulder, same corner), so mapping and unmapping it are
// invisible; the Dashboard covers the centre notch the same way.
//
//   g.winW        the panel window's width (its right edge is the screen's)
//   g.strip       the top/right strip's width (border width)
//   g.seam        the notch height (the seam's y)
//   g.shoulder    the notch shoulder radius (ThemeSet.notchShoulder)
//   g.notchBottom the notch's bottom corner radius (ThemeSet.notchBottom)
//   g.notchW      the notch's natural width right now (live; W0)
//   g.w           finished width (panel width + notch radius; W1)
//   g.h           finished depth below the seam (D1)
//   g.r           the panel's corner role (radius L)
//
// Character (brief A.2): anchored right, depth-first — the right edge drops at
// once on standard while a 12 px swell holds the stem to the notch — then the
// body pours LEFT on fastDecel after 22 %, its bottom-left corner trailing the
// right edge by a sagging lag (sin, so it is zero at both ends) and bulging
// rounder mid-pour before settling. The bottom-right melts into the screen's
// right strip with a concave fillet instead of floating beside it.
function rightPourWidth(p, w0, w1) {
    p = clamp01(p);
    var swell = Math.min(12, Math.max(0, w1 - w0));
    return Math.round(w0 + swell * standardDecel(span(p, 0, 0.22))
                         + (w1 - w0 - swell) * fastDecel(span(p, 0.22, 0.92)));
}
function rightPour(p, g) {
    p = clamp01(p);
    var b = g.strip, H = g.seam, rs = g.shoulder;
    var lagMax = Math.max(6, Math.min(28, 0.045 * g.h));
    var W, Dr, Dl, rbl;
    if (g.ch) {
        // Channels: depth leads (the right edge drops), width follows (the
        // body pours left). The 12 px swell that holds the stem to the notch
        // rides the depth's first third. The front of the pour is thinner the
        // faster it travels — the bottom-left trails the right edge by up to
        // lagMax — and its corner rounds out with the same speed; both are 0 at
        // rest, so the finished panel is exact.
        var ch = g.ch, cd = Math.max(0, ch.d), cw = Math.max(0, ch.w);
        var swell = Math.min(12, Math.max(0, g.w - g.notchW));
        var fwAbs = Math.abs(flow(ch, "fw"));
        W  = Math.round(size(g.notchW + swell * standardDecel(Math.min(1, cd / 0.3)), g.w, cw, 4));
        Dr = size(0, g.h, cd, 6);
        Dl = Math.max(0, Dr - Math.min(24, lagMax) * Math.tanh(fwAbs) * smooth(Math.min(1, cd / 0.2)));
        var bodyR1 = g.r + 14 * Math.tanh(fwAbs);
        rbl = lerp(g.notchBottom, bodyR1, smooth(Math.min(1, cd / 0.12)));
    } else {
        W  = rightPourWidth(p, g.notchW, g.w);
        Dr = g.h * standard(p);
        Dl = Math.max(0, Dr - lagMax * Math.sin(Math.PI * p));
        // Bottom-left: the notch's own corner at p = 0, the body's (bulging
        // 17 → 35 → 17) once it has depth; never more than its sides allow.
        var bodyR = g.r + 18 * Math.sin(Math.PI * p);
        rbl = lerp(g.notchBottom, bodyR, smooth(span(p, 0, 0.12)));
    }
    var f  = Math.min(g.r, Dr / 2);                     // the melt into the strip

    var X0 = g.winW - W, X1 = g.winW;
    // The band reaches over the bar's own notch by its corner radius, so the
    // bar's rounded bottom-left corner is covered from below the moment the
    // body has depth; the bar needs no state for it. notchPadding >= that
    // radius, so the cover never reaches the status icons.
    var cover = g.winW - g.notchW + g.notchBottom;
    rbl = Math.max(0, Math.min(rbl, H + Dl - b - rs, W / 2));

    var P = new Path();
    P.move(X0 - rs, 0);
    P.step(cover, 0);                                    // over the strip
    P.step(cover, H);                                    // (inside the bar's notch)
    P.step(X1, H);                                       // the seam, under it
    P.step(X1, H + Dr + f);                              // down the screen edge
    P.step(X1 - b, H + Dr + f);                          // (over the strip)
    P.corner(X1 - b - f, H + Dr, "v");                   // melt into the strip
    P.sHorz(X0 + rbl, H + Dl, 0.45);                     // bottom edge, sagging
    P.corner(X0, H + Dl - rbl, "h");                     // bottom-left
    P.line(X0, b + rs);                                  // up the left edge
    P.corner(X0 - rs, b, "v");                           // the shoulder
    P.close();                                           // up into the strip

    return {
        path: P.toString(), segs: P.segs,
        bounds: { x: X0 - rs, y: 0, w: X1 - X0 + rs, h: H + Dr + f },
        clip: { x: X0, y: H, w: Math.max(0, W - b), h: Math.max(0, Math.min(Dl, Dr)) },
        params: { W: W, Dr: Dr, Dl: Dl, f: f, rbl: rbl, X0: X0, cover: cover },
        bar: {}
    };
}

// ── LEFT_SPILL ──────────────────────────────────────────────────────────────
// The power menu, out of the LEFT screen strip at the trigger's height. Drawn in
// the popup window; `g.x0` is the strip's inner edge in window x (the fillets
// start there with a vertical tangent — starting them at the screen edge put a
// ~40° kink where they crossed the strip's inner edge, brief A.3).
//
//   g.x0      strip inner edge (window x)
//   g.cy      the trigger's centre (window y)
//   g.w       finished body width
//   g.h       finished body height
//   g.r       leading corners and fillets (radius L)
//   g.rm      the corners it starts from (radius M)
//
// Character: firm and horizontal first — a short full-width bar extrudes on
// emphasizedDecel — then it unfolds vertically, symmetric about the trigger,
// from 25 %. The leading (right) edge is the expressive one.
// The body's width alone, for a caller that needs only that (the ridge fade)
// and must not read a whole silhouette to get it. Never narrower than a fillet
// plus a corner of the same size: the ridge a spill leaves on the strip at
// p = 0 is still a rounded shape, not a slab.
function spillRidge(g) { return 2 * Math.min(8, g.r); }
// With channels the width is the lead channel (linear, a 4 px swell past it).
function leftSpillWidth(p, g) {
    if (g.ch) return Math.max(spillRidge(g), size(0, g.w, g.ch.w, 4));
    return Math.max(spillRidge(g), g.w * emphasizedDecel(span(clamp01(p), 0, 0.85)));
}
function edgeSpillWidth(p, g) {
    if (g.ch) return Math.max(spillRidge(g), size(0, g.w, g.ch.w, 4));
    return Math.max(spillRidge(g), g.w * standardDecel(span(clamp01(p), 0, 0.85)));
}
function leftSpill(p, g) {
    p = clamp01(p);
    var fMin = Math.min(8, g.r);
    // Channels: width leads, the height unfolds on the body channel (a 4 px
    // swell past it), the fillets and corners ride the trail.
    var eh = g.ch ? Math.max(0, g.ch.d) : standardDecel(span(p, 0.25, 0.85));
    var en = g.ch ? clamp01(g.ch.n) : eh;
    var hMin = Math.min(g.h, Math.max(2 * g.r + 24, 0.4 * g.h));
    var Wb = leftSpillWidth(p, g);
    var Hb = size(hMin, g.h, eh, 4);
    var f  = fMin + (g.r - fMin) * en;
    // The leading corner and the fillet share the top edge: while the body
    // is still narrower than both, the corner gives way — otherwise the edge
    // between them would run backwards into a cusp.
    var rb = Math.min(g.rm + (g.r - g.rm) * en, Math.max(0, Wb - f), Hb / 2 - 0.01);
    var top = Math.round(g.cy - Hb / 2), bottom = Math.round(g.cy + Hb / 2);
    var x0 = g.x0, xr = g.x0 + Wb;

    var P = new Path();
    P.move(0, top - f);
    P.step(x0, top - f);
    P.corner(x0 + f, top, "v");               // top fillet into the strip (concave)
    P.line(xr - rb, top);
    P.corner(xr, top + rb, "h");              // top-right (convex)
    P.line(xr, bottom - rb);
    P.corner(xr - rb, bottom, "v");           // bottom-right (convex)
    P.line(x0 + f, bottom);
    P.corner(x0, bottom + f, "h");            // bottom fillet into the strip
    P.step(0, bottom + f);
    P.close();
    return {
        path: P.toString(), segs: P.segs,
        bounds: { x: 0, y: top - f, w: xr, h: bottom - top + 2 * f },
        clip: { x: x0 + f * 0.5, y: top, w: Math.max(0, Wb - f * 0.5), h: Math.max(0, bottom - top) },
        params: { Wb: Wb, Hb: Hb, f: f, rb: rb, top: top, bottom: bottom },
        bar: {}
    };
}

// ── EDGE_SPILL (right) ──────────────────────────────────────────────────────
// Quick controls out of the RIGHT screen strip at mid-height. The same fillet
// and corner system as LEFT_SPILL, mirrored — and kept from being a mirror by
// its sequencing (brief A.4): a softer extrusion on standardDecel, the TOP edge
// settling early and the BOTTOM late, so the body arrives from the edge and
// drips down rather than unfolding symmetrically.
//
//   g.x1      strip inner edge (window x; the body extends LEFT of it)
//   g.cy, g.w, g.h, g.r, g.rm   as LEFT_SPILL
function edgeSpillRight(p, g) {
    p = clamp01(p);
    var fMin = Math.min(8, g.r);
    var Wb = edgeSpillWidth(p, g);
    var ot, ob, settle;
    if (g.ch) {
        // Channels: the top settles on the lead (width) channel, the bottom
        // drips on the body channel and may overhang by a 4 px swell before it
        // settles; the fillets and corners ride the trail.
        ot = 0.12 * g.h * (1 - standardDecel(Math.min(1, Math.max(0, g.ch.w))));
        ob = 0.46 * g.h - (size(0, 0.46 * g.h, g.ch.d, 4));
        settle = clamp01(g.ch.n);
    } else {
        ot = 0.12 * g.h * (1 - standardDecel(span(p, 0, 0.55)));
        ob = 0.46 * g.h * (1 - standard(span(p, 0.20, 1.0)));
        settle = 1 - ob / (0.46 * g.h);
    }
    var f  = fMin + (g.r - fMin) * settle;
    var top = Math.round(g.cy - g.h / 2 + ot), bottom = Math.round(g.cy + g.h / 2 - ob);
    var Hb = bottom - top;
    var rb = Math.min(g.rm + (g.r - g.rm) * settle, Math.max(0, Wb - f), Hb / 2 - 0.01);
    var x1 = g.x1, xl = g.x1 - Wb;

    var P = new Path();
    P.move(g.x1 + (g.edgeW || 0), top - f);
    P.step(x1, top - f);
    P.corner(x1 - f, top, "v");               // top fillet into the strip (concave)
    P.line(xl + rb, top);
    P.corner(xl, top + rb, "h");              // top-left (convex)
    P.line(xl, bottom - rb);
    P.corner(xl + rb, bottom, "v");           // bottom-left (convex)
    P.line(x1 - f, bottom);
    P.corner(x1, bottom + f, "h");            // bottom fillet into the strip
    P.step(g.x1 + (g.edgeW || 0), bottom + f);
    P.close();
    return {
        path: P.toString(), segs: P.segs,
        bounds: { x: xl, y: top - f, w: Wb + (g.edgeW || 0), h: Hb + 2 * f },
        clip: { x: xl, y: top, w: Math.max(0, Wb - f * 0.5), h: Math.max(0, Hb) },
        params: { Wb: Wb, Hb: Hb, f: f, rb: rb, top: top, bottom: bottom },
        bar: {}
    };
}

// ── BOTTOM_RISE ─────────────────────────────────────────────────────────────
// The wallpaper picker, out of the BOTTOM screen strip at the centre — the
// Dashboard's counterpart at the other edge, and built the same way: the
// width spreads along the strip first (a swelling of the strip), then the body
// rises; the top corners and the fillets into the strip trail, and the top
// edge's middle leads while it rises and trails while it sinks, in proportion
// to its speed. It replaced a rectangle scaled from the strip on a Canvas.
//
//   g.cx          centre x (window)
//   g.y1          the strip's inner edge (window y; the body extends UP)
//   g.edgeH       the strip's thickness below y1 (the path closes inside it)
//   g.w, g.h      finished width and height above y1
//   g.r           finished top corners and fillets (radius L)
//   g.rm          the corners it starts from (radius M)
//
// At rest on 0 it is a ridge 4·f wide and 2·f tall (f = min(8, r)) — still a
// rounded shape, not a slab; callers fade that ridge over the first 24 px of
// height, as the spills do over their width.
function riseRidge(g) { return 2 * Math.min(8, g.r); }
function bottomRiseHeight(p, g) {
    var ch = g.ch || { d: standard(span(clamp01(p), 0.2, 1.0)) };
    return size(riseRidge(g), g.h, ch.d, 4);
}
function bottomRise(p, g) {
    p = clamp01(p);
    var ch = g.ch || { w: standardDecel(span(p, 0, 0.7)), d: standard(span(p, 0.2, 1.0)),
                       n: standard(span(p, 0.2, 0.85)), fd: 0 };
    var fMin = Math.min(8, g.r), en = clamp01(ch.n);
    var W = size(2 * riseRidge(g), g.w, ch.w, 4);
    var H = bottomRiseHeight(p, g);
    var f = fMin + (g.r - fMin) * en;
    var xc = Math.round(g.cx), y1 = g.y1, bot = y1 + (g.edgeH || 0);
    var L = xc - Math.round(W / 2), R = L + Math.round(W), T = Math.round(y1 - H);
    // Clamped against the ROUNDED edges: a corner half a pixel taller than
    // its side runs the side backwards.
    var rb = g.rm + (g.r - g.rm) * en;
    rb = Math.max(0, Math.min(rb, (R - L) / 2, (y1 - T) - f));
    var side = Math.max(0, (y1 - T) - f - rb);
    var bow = 8 * Math.tanh(flow(ch, "fd"));
    bow = Math.max(-0.5 * side, Math.min(bow, 0.5 * (R - L - 2 * rb)));

    var P = new Path();
    P.move(L - f, bot);
    P.step(L - f, y1);
    P.corner(L, y1 - f, "h");                 // left fillet out of the strip (concave)
    P.line(L, T + rb);
    P.corner(L + rb, T, "v");                 // top-left (convex)
    if (Math.abs(bow) >= 0.05 && R - L - 2 * rb > 2) {
        P.sHorz(xc, T - bow, 0.5);            // the bow, in two level halves
        P.sHorz(R - rb, T, 0.5);
    } else {
        P.line(R - rb, T);
    }
    P.corner(R, T + rb, "h");                 // top-right (convex)
    P.line(R, y1 - f);
    P.corner(R + f, y1, "v");                 // right fillet into the strip (concave)
    P.step(R + f, bot);
    P.close();
    var top = T - Math.max(0, bow);
    return {
        path: P.toString(), segs: P.segs,
        bounds: { x: L - f, y: top, w: (R - L) + 2 * f, h: bot - top },
        clip: { x: L, y: T + Math.max(0, -bow), w: R - L, h: Math.max(0, y1 - T - Math.max(0, -bow)) },
        params: { W: W, H: H, f: f, rb: rb, L: L, R: R, T: T, bow: bow },
        bar: {}
    };
}

// ── CORNER_RISE ─────────────────────────────────────────────────────────────
// The clipboard history, out of the BOTTOM-RIGHT corner where the right and
// bottom strips meet — RIGHT_POUR turned upside down: the right edge rises up
// the right strip first, then the body pours LEFT along the bottom one. The
// front of the pour is thinner the faster it travels (its top-left sits lower
// than the top-right by up to 20 px) and its corner rounds out with the same
// speed; both are 0 at rest. Fillets meet both strips. It replaced a
// rectangle scaled out of the corner on a Canvas.
//
//   g.x1, g.y1       the right and bottom strips' inner edges (window coords)
//   g.edgeW, g.edgeH the strips' thicknesses (the path closes inside them)
//   g.w, g.h         finished width (left of x1) and height (above y1)
//   g.r, g.rm        finished corner/fillets (radius L); the starting corner
function cornerRiseWidth(p, g) {
    var ch = g.ch || { w: standard(span(clamp01(p), 0.2, 0.95)) };
    return size(2 * riseRidge(g), g.w, ch.w, 4);
}
function cornerRiseHeight(p, g) {
    var ch = g.ch || { d: standard(clamp01(p)) };
    return size(riseRidge(g), g.h, ch.d, 4);
}
function cornerRise(p, g) {
    p = clamp01(p);
    var ch = g.ch || { w: standard(span(p, 0.2, 0.95)), d: standard(p),
                       n: standard(span(p, 0.05, 0.8)), fw: 0 };
    var fMin = Math.min(8, g.r), en = clamp01(ch.n);
    var W = cornerRiseWidth(p, g), H = cornerRiseHeight(p, g);
    var f = fMin + (g.r - fMin) * en;
    var fwAbs = Math.abs(flow(ch, "fw"));
    var lag = Math.max(0, Math.min(20, 0.045 * g.h)) * Math.tanh(fwAbs);
    var Hl = Math.max(2 * f, H - lag);
    var x1 = g.x1, y1 = g.y1, ew = g.edgeW || 0, eh = g.edgeH || 0;
    var X0 = Math.round(x1 - W), T = Math.round(y1 - H), Tl = Math.round(y1 - Hl);
    // Clamped against the rounded edges, like BOTTOM_RISE.
    var rb = g.rm + (g.r - g.rm) * en + 10 * Math.tanh(fwAbs);
    rb = Math.max(0, Math.min(rb, (x1 - X0) - f, (y1 - Tl) - f));
    var P = new Path();
    P.move(x1 + ew, T - f);
    P.step(x1, T - f);
    P.corner(x1 - f, T, "v");                 // top fillet into the right strip (concave)
    P.sHorz(X0 + rb, Tl, 0.45);               // top edge: the thinner front, lower
    P.corner(X0, Tl + rb, "h");               // top-left (convex)
    P.line(X0, y1 - f);
    P.corner(X0 - f, y1, "v");                // left fillet into the bottom strip (concave)
    P.step(X0 - f, y1 + eh);
    P.step(x1 + ew, y1 + eh);
    P.close();
    var top = Math.max(T, Tl);
    return {
        path: P.toString(), segs: P.segs,
        bounds: { x: X0 - f, y: T - f, w: (x1 + ew) - (X0 - f), h: (y1 + eh) - (T - f) },
        clip: { x: X0, y: top, w: Math.max(0, x1 - X0), h: Math.max(0, y1 - top) },
        params: { W: W, H: H, Hl: Hl, f: f, rb: rb, X0: X0, T: T },
        bar: {}
    };
}

// ── NOTCH_EXTRUDE (the Nexus) ───────────────────────────────────────────────
// The settings window floats in the middle of the screen, not under the bar,
// so it cannot bloom out of the notch and stay attached the way the Dashboard
// does. It EXTRUDES (Andre, 2026-09-27, replacing the drip: "notch → viscous
// extrusion → broadening sheet → Nexus, rather than notch → teardrop →
// balloon → Nexus"): the notch's bottom sags; a broad neck comes down with a
// bulb on it; the bulb deepens and then widens, a flask flaring all the way
// down from the neck, and becomes the window; then the neck thins and draws
// back into the notch. Closing is not the open
// backwards: the content goes first, the window's top centre pinches up
// into a broad neck, and the mass is drawn up it into the notch rather than
// shrinking in place. Calmer than CENTER_BLOOM: viscous, no wobble, no
// splash, no giant round blob, and never the window at 60 % scale.
//
// It is a signed-distance FIELD, evaluated per pixel by FluidDrop.qml's
// shader (fluiddrop.frag), because every part of it is round and every join
// is a meniscus — which is what a smooth union of round primitives gives:
//
//   notch   a box from far above the screen down to the notch's flat bottom
//           (the seam), inset inside it, so it never shows past the notch;
//           only its meniscus shows, below the seam
//   card    the sheet, then the window: a rounded box (cx, cy, hw, hh, r)
//   upper   the neck: a ROUND CONE (two circles and their tangents) from
//           inside the notch down to the waist
//   lower   the bell: a round cone from the waist to the bulb while it is
//           one, then to the neck's widening end just inside the sheet
//
//   d = smin( smin(notch, upper, kN), smin(card, lower, kC), kW )
//
// kN is the meniscus under the notch, kC is the flare — the wide concave
// sweep from the neck out to the sheet — and kW rounds the waist (without it
// the neck meets the bell in a V). All three
// shrink with the neck and are 0 once it has drawn back, so at rest the field
// is exactly the notch box and the window: nothing lingers.
//
//   g.cx, g.notchW, g.notchH, g.notchBottom   the centre notch; g.notchH is
//                the seam's y
//   g.card {x, y, w, h}, g.r                  the finished window and corners
//
// Channels (SurfaceLifecycle, liquid): w = the EXTRUSION (lead: the sag, the
// neck and the bulb, the descent), d = the SPREAD (body: bulb → sheet →
// window), n = the NECK (trail: broad while the sheet spreads, thinning as it
// draws back into the notch from its lower end). Closing, the trail lags the
// body and would keep the neck drawn back until the body was gone, so the
// neck also follows the body: it reaches down again as soon as the window
// starts to go and is whole long before the lead begins to leave (at the
// Nexus's closeRelease, 0.2). Without channels, derived from p.
function notchExtrudeDerived(p) {
    return { w: span(p, 0.0, 0.55), d: smooth(span(p, 0.2, 0.9)), n: span(p, 0.3, 1.0) };
}
function notchExtrudeField(p, g) {
    p = clamp01(p);
    var ch = g.ch || notchExtrudeDerived(p);
    var L = clamp01(ch.w), B = Math.max(0, ch.d), Bc = Math.min(1, B), N = clamp01(ch.n);
    var y0 = g.notchH;
    var flat = Math.max(4, g.notchW - 2 * g.notchBottom);
    // The field's notch box: inside the notch's flat bottom, and wide enough
    // that the meniscus never reaches its corner (it would kink there).
    var nhw = 0.46 * flat;
    // Sizes follow the bar's own scale, not the notch's live width: a media
    // title widening the notch must not fatten the neck.
    var U = Math.min(flat, 6.8 * g.notchH);
    var cardCX = g.card.x + g.card.w / 2, CHW = g.card.w / 2, CHH = g.card.h / 2;
    var gap = Math.max(0, g.card.y - y0);

    // ── the extrusion (lead)
    // The gather is an EASE-OUT of the lead, so the notch moves on the first
    // frame the spring does ("fast first, fluid second"); a broad neck and
    // its bulb form and descend behind it.
    var form = 1 - Math.pow(1 - Math.min(1, L / 0.3), 2);
    var grow = smooth(span(L, 0.08, 0.8));
    var ext = smooth(span(L, 0.1, 1));
    var bulbR = 0.26 * U;
    var Rb = lerp(0.2 * U, bulbR, grow) * form;           // the bulb, grown out of the neck
    var sag = 0.06 * U;
    var bulbBottom = y0 + sag * form + (0.3 * gap + 2 * bulbR - sag) * ext;
    var cyB = bulbBottom - Rb;

    // ── the spread (body): out of the bulb, DEEPENING a little ahead of
    // widening (Andre, 2026-09-27: "let depth lead width slightly"), and on
    // the springs' own easing — a curve on top of a spring eases twice and
    // crushed the whole change into ~200 ms. Written as the finished value
    // less what is left, so at rest they ARE the window.
    var gH = Math.pow(Bc, 0.7), gW = Math.pow(Bc, 1.3), gT = Math.pow(Bc, 1.3);
    var b0 = 0.8 * Rb;                                    // the sheet, inside the bulb at first
    var hw = CHW - (CHW - b0) * (1 - gW) + (B > 1 ? softCap((CHW - b0) * (B - 1), 3) : 0);
    var hh = CHH - (CHH - b0) * (1 - gH) + (B > 1 ? softCap((CHH - b0) * (B - 1), 3) : 0);
    var top = g.card.y - (g.card.y - (cyB - b0)) * (1 - gT);
    // Closing, the notch recovers the material (Andre, 2026-09-27: "sides
    // draw inward, the remaining mass climbs"): the trail runs ahead of the
    // body only while it drains, and by that much the mass rises and its
    // sides draw in — a few dozen pixels at most, nothing opening, nothing
    // at rest.
    var lag = Math.max(0, N - Bc);
    top -= 0.25 * gap * lag;
    hw -= 0.25 * (hw - b0) * lag;
    var cy = top + hh, cx = cardCX - (cardCX - g.cx) * (1 - Bc);
    // Corners: organic while it moves, architectural when it settles
    // (Andre, 2026-09-27): fully round while it is a bulb, broad and soft
    // while it spreads, and the window's own radius only over the last fifth
    // of the spread — never a rectangle appearing all at once.
    var rK = lerp(1, 0.4, smooth(span(Bc, 0.15, 0.55)));
    var rBig = Math.min(hw, hh, rK * Math.min(hw, hh) + g.r);
    var r = Math.max(0, Math.min(g.r - (g.r - rBig) * (1 - smooth(span(Bc, 0.8, 1))), hw, hh));

    // ── the neck (trail) and the flare
    // Closing, the trail lags the body and would keep the neck drawn back
    // until the body was gone; so the neck also follows the body: the top
    // centre pinches up into it as soon as the window starts to go, and the
    // mass is drawn up it rather than shrinking in place.
    var Ne = Math.min(N, 0.25 + 0.75 * smooth(span(B, 0.5, 0.92)));
    // The release (Andre, 2026-09-27: "material finished forming,
    // connection releases — not a drop of goo snapping off"): the neck
    // narrows continuously to a hairline, its flare with it; it pinches just
    // under the notch, not half-way; the notch's tiny remainder is drawn up
    // at once, and the rest, on the window's side, sinks into the window.
    // No drop at either tip — each piece tapers to its end — and nothing left
    // dangling from the notch. Closing runs it backwards: a hairline rises
    // from the window to the notch and thickens.
    var thin = smooth(span(Ne, 0.45, 0.72));
    var ret = smooth(span(Ne, 0.55, 0.97));
    var rN0 = 0.2 * U;                                    // the neck, full: broad
    var rN = rN0 * form * (1 - 0.85 * thin);
    var a1 = smooth(span(ret, 0, 0.25));                  // narrowing to the pinch, the waist rising to the notch
    var a2 = smooth(span(ret, 0.25, 0.37));               // the notch's remainder drawn up
    // (linear: `ret` is already eased, and a second ease on a 200 px travel
    // made the hairline cross it in about a frame when a close re-forms it;
    // done by 0.75 of the retraction, so it does not stand on the window —
    // any sooner and a close's hairline crosses in a frame again)
    var a3 = span(ret, 0.25, 0.75);                       // the window's side sinking into it
    var kThin = lerp(1, 0.15, thin);
    var kN = 0.32 * U * form * kThin * (1 - a2);
    // The flare is the blend where the neck meets the sheet: wide, so the
    // outline opens out in one CONCAVE sweep from the neck to the sheet's
    // corners — the same material stretching, not a neck joining two masses
    // (the convex shoulders of a bottle). Capped by the sheet's width: past
    // it, the blend bulges the sheet's sides. It narrows with the neck.
    var kC = Math.min(1.1 * U * kThin * (1 - a3), 0.6 * Math.max(hw, 1)) * form;
    // The bell: while it is a bulb, the bulb's own circle; as the sheet
    // spreads, only the neck's widening end, just inside the sheet's top and
    // never wider than the sheet.
    var fitH = Math.max(0, (2 * hh - 0.4 * kC - 2) / 2.2);
    var s0 = smooth(span(Bc, 0, 0.35));
    var R2 = lerp(Math.min(Rb, fitH), Math.min(2.21 * rN + 0.001, 0.9 * hw), s0);
    var c2y = lerp(cyB, top + Math.min(hh, R2 + 0.15 * kC), s0);
    var ay = y0 - kN - 3;                                 // inside the notch, past its meniscus
    var R2r = lerp(R2, 0.85 * rN, Math.min(1, 2 * a1)) * (1 - a3);
    var yw = lerp(lerp(y0, c2y - R2, 0.3), y0 + 0.03 * U, a1);
    var rw = 0.85 * rN * (1 - a1);
    var kW = Math.min(0.2 * U, 0.9 * rw) * form;
    var upper = null, lower = null;
    if (form > 0.001 && rN > 0.05 && ret < 1) {
        var wx = lerp(g.cx, cx, 0.3), wy = Math.max(yw, ay + 0.5);
        if (a2 < 1)
            upper = { ax: g.cx, ay: ay, ra: 1.2 * rN * (1 - a2), bx: wx, by: lerp(wy, ay + 0.5, a2),
                      rb: Math.max(rw, 0.3 * (1 - a2)) };
        if (a3 < 1) {
            var yl = lerp(wy, c2y, a3);
            lower = { ax: wx, ay: yl, ra: Math.max(rw, 0.3 * (1 - a3)), bx: cx, by: Math.max(c2y, yl + 0.5), rb: R2r };
        }
    }
    if (!(form > 0)) { hw = 0; hh = 0; kN = 0; kC = 0; kW = 0; }

    // The content is revealed inside the sheet: inset from its corners by as
    // much as they are rounder than the window's own (whose corners the
    // content already keeps clear of), so exactly the window once it has
    // arrived.
    var ins = 0.3 * Math.max(0, r - g.r);
    var clipX0 = Math.max(cx - hw + ins, g.card.x), clipY0 = Math.max(cy - hh + ins, g.card.y);
    var clipX1 = Math.min(cx + hw - ins, g.card.x + g.card.w), clipY1 = Math.min(cy + hh - ins, g.card.y + g.card.h);
    // Nothing while only the sheet's rounded bottom reaches into the window's
    // place: a sliver there is all corner, and its middle is the content's.
    // (Early in the open, late in the close: the content is 0 either way.)
    if (cy + hh - r < g.card.y + r) clipY1 = clipY0;
    // Where the field can be inside: the seam down to the lowest part, across
    // the notch box, the sheet and the bell, with room for the meniscus and
    // the edge's antialiasing. What draws it (FluidDrop) covers only this.
    var lowR = lower ? lower.rb : 0, pad = 4 + 0.25 * Math.max(kN, kC, kW);
    var upLow = upper ? Math.max(upper.ay + upper.ra, upper.by + upper.rb) : 0;
    var bx0 = Math.min(g.cx - nhw, cx - hw, cx - lowR) - pad, bx1 = Math.max(g.cx + nhw, cx + hw, cx + lowR) + pad;
    var by1 = Math.max(y0 + 4, cy + hh + pad, lower ? lower.by + lowR + pad : 0, upLow + pad);
    return {
        notch: { x0: g.cx - nhw, x1: g.cx + nhw, y: y0, r: Math.min(10, nhw) },
        card: { cx: cx, cy: cy, hw: hw, hh: hh, r: r },
        upper: upper, lower: lower, kN: kN, kC: kC, kW: kW,
        bounds: { x: bx0, y: y0, w: bx1 - bx0, h: by1 - y0 },
        clip: { x: clipX0, y: clipY0, w: Math.max(0, clipX1 - clipX0), h: Math.max(0, clipY1 - clipY0) },
        params: { L: L, B: B, N: N, Ne: Ne, hw: hw, hh: hh, cx: cx, cy: cy, r: r, top: top,
                  rN: rN, R2: R2, thin: thin, ret: ret, form: form }
    };
}
// The field, exactly as shaders/fluiddrop.frag evaluates it (the tests
// rasterise it; the shader is checked against it).
function sdRoundBox(px, py, cx, cy, hw, hh, r) {
    var qx = Math.abs(px - cx) - hw + r, qy = Math.abs(py - cy) - hh + r;
    var ox = Math.max(qx, 0), oy = Math.max(qy, 0);
    return Math.sqrt(ox * ox + oy * oy) + Math.min(Math.max(qx, qy), 0) - r;
}
// A round cone: circle (a, ra), circle (b, rb) and their outer tangents
// (Inigo Quilez's sdRoundCone). One circle inside the other is that circle.
function sdRoundCone(px, py, s) {
    var bax = s.bx - s.ax, bay = s.by - s.ay;
    var l2 = bax * bax + bay * bay, rr = s.ra - s.rb, a2 = l2 - rr * rr;
    if (a2 <= 1e-6) {
        var da = Math.hypot(px - s.ax, py - s.ay) - s.ra, db = Math.hypot(px - s.bx, py - s.by) - s.rb;
        return Math.min(da, db);
    }
    var il2 = 1 / l2, pax = px - s.ax, pay = py - s.ay;
    var y = pax * bax + pay * bay, z = y - l2;
    var qx = pax * l2 - bax * y, qy = pay * l2 - bay * y;
    var x2 = qx * qx + qy * qy, y2 = y * y * l2, z2 = z * z * l2;
    var k = Math.sign(rr) * rr * rr * x2;
    if (Math.sign(z) * a2 * z2 > k) return Math.sqrt(x2 + z2) * il2 - s.rb;
    if (Math.sign(y) * a2 * y2 < k) return Math.sqrt(x2 + y2) * il2 - s.ra;
    return (Math.sqrt(x2 * a2 * il2) + y * rr) * il2 - s.ra;
}
function smin(a, b, k) {
    if (!(k > 0)) return Math.min(a, b);
    var h = Math.max(k - Math.abs(a - b), 0) / k;
    return Math.min(a, b) - h * h * k * 0.25;
}
var FIELD_FAR = 1e5;
function dropField(f, px, py) {
    var n = f.notch, c = f.card;
    var nhh = (n.y + 400) / 2;                      // from 400 px above the screen
    var dn = sdRoundBox(px, py, (n.x0 + n.x1) / 2, n.y - nhh, (n.x1 - n.x0) / 2, nhh, n.r);
    var dc = (c.hw > 0 && c.hh > 0) ? sdRoundBox(px, py, c.cx, c.cy, c.hw, c.hh, c.r) : FIELD_FAR;
    var du = f.upper ? sdRoundCone(px, py, f.upper) : FIELD_FAR;
    var dl = f.lower ? sdRoundCone(px, py, f.lower) : FIELD_FAR;
    return smin(smin(dn, du, f.kN), smin(dc, dl, f.kC), f.kW || 0);
}

if (typeof module !== "undefined" && module.exports)
    module.exports = {
        KAPPA: KAPPA,
        Path: Path,
        clamp01: clamp01, lerp: lerp, span: span, smooth: smooth, decel: decel, accel: accel,
        curve: curve, fastDecel: fastDecel, standard: standard,
        softCap: softCap, size: size, notchHole: notchHole,
        standardDecel: standardDecel, emphasizedDecel: emphasizedDecel,
        barNotch: barNotch, barSilhouette: barSilhouette, barHairline: barHairline,
        windowRounding: windowRounding,
        centerBloom: centerBloom,
        rightPourWidth: rightPourWidth, rightPour: rightPour,
        leftSpill: leftSpill, edgeSpillRight: edgeSpillRight,
        spillRidge: spillRidge, leftSpillWidth: leftSpillWidth, edgeSpillWidth: edgeSpillWidth,
        riseRidge: riseRidge, bottomRise: bottomRise, bottomRiseHeight: bottomRiseHeight,
        cornerRise: cornerRise, cornerRiseWidth: cornerRiseWidth, cornerRiseHeight: cornerRiseHeight,
        notchExtrudeField: notchExtrudeField, notchExtrudeDerived: notchExtrudeDerived, dropField: dropField, sdRoundBox: sdRoundBox, sdRoundCone: sdRoundCone, smin: smin
    };
