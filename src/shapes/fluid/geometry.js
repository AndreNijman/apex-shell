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
    if (Math.abs(dx) < 1e-6 && Math.abs(dy) < 1e-6) return this;
    if (dirIn === "h")
        return this.cubic(this.x + dx * tau, this.y, x, y - dy * tau, x, y);
    return this.cubic(this.x, this.y + dy * tau, x - dx * tau, y, x, y);
};

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
function barHairline(g) {
    var w = g.w, b = g.strip, h = g.h, r = g.shoulder, i = 0.5;
    var side = Math.max(0, h - b - r);
    function rb(v, notchW) { return Math.max(i, Math.min(v, side, notchW / 2)); }
    var lW = Math.round(g.leftW), rW = Math.round(g.rightW);
    var cS = Math.round(w / 2) - Math.round(g.centerW / 2);
    var cE = cS + Math.round(g.centerW);
    var rS = w - rW;
    var rbL = rb(g.bottom, lW), rbC = rb(g.bottom, cE - cS), rbR = rb(g.rightBottomL, rW);

    var P = new Path();
    P.move(0, h - i);
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
        P.line(w, h - i);
    }
    return { path: P.toString(), segs: P.segs, params: { rS: rS, end: P.x } };
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
    var b = g.strip;
    var W  = g.notchW + (g.w - g.notchW) * fastDecel(p);
    var D  = g.notchH + (g.h - g.notchH) * standard(span(p, 0.18, 1.0));
    var es = standard(span(p, 0.15, 0.75));
    var sw = g.shoulder + (g.shoulderW1 - g.shoulder) * es;
    var sh = g.shoulder + (g.shoulderH1 - g.shoulder) * es;
    var tau = KAPPA + (0.65 - KAPPA) * es;
    var rb = g.notchBottom + (g.r - g.notchBottom) * es;
    // Degenerate guard: the corner and the shoulder must share the side.
    rb = Math.min(rb, Math.max(0, D - (b + sh)), W / 2);

    var xc = Math.round(g.cx);
    var L = xc - Math.round(W / 2), R = L + Math.round(W);
    var P = new Path();
    P.move(L - sw, 0);
    P.step(R + sw, 0);                        // across the top, inside the strip
    P.step(R + sw, b);
    P.cornerT(R, b + sh, "h", tau);           // right shoulder (concave)
    P.line(R, D - rb);
    P.corner(R - rb, D, "v");                 // bottom-right (convex)
    P.line(L + rb, D);
    P.corner(L, D - rb, "h");                 // bottom-left (convex)
    P.line(L, b + sh);
    P.cornerT(L - sw, b, "v", tau);           // left shoulder (concave)
    P.close();

    var inset = Math.min(8, W / 4);
    return {
        path: P.toString(), segs: P.segs,
        bounds: { x: L - sw, y: 0, w: (R - L) + 2 * sw, h: D },
        clip: { x: L + inset, y: b, w: Math.max(0, (R - L) - 2 * inset), h: Math.max(0, D - b) },
        params: { W: W, D: D, sw: sw, sh: sh, tau: tau, rb: rb, L: L, R: R },
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
    var W  = rightPourWidth(p, g.notchW, g.w);
    var Dr = g.h * standard(p);
    var lagMax = Math.max(6, Math.min(28, 0.045 * g.h));
    var Dl = Math.max(0, Dr - lagMax * Math.sin(Math.PI * p));
    var f  = Math.min(g.r, Dr / 2);                     // the melt into the strip

    var X0 = g.winW - W, X1 = g.winW;
    // The band reaches over the bar's own notch by its corner radius, so the
    // bar's rounded bottom-left corner is covered from below the moment the
    // body has depth; the bar needs no state for it. notchPadding >= that
    // radius, so the cover never reaches the status icons.
    var cover = g.winW - g.notchW + g.notchBottom;
    // Bottom-left: the notch's own corner at p = 0, the body's (bulging
    // 17 → 35 → 17) once it has depth; never more than its sides allow.
    var bodyR = g.r + 18 * Math.sin(Math.PI * p);
    var rbl = lerp(g.notchBottom, bodyR, smooth(span(p, 0, 0.12)));
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
function leftSpillWidth(p, g) {
    return Math.max(spillRidge(g), g.w * emphasizedDecel(span(clamp01(p), 0, 0.85)));
}
function edgeSpillWidth(p, g) {
    return Math.max(spillRidge(g), g.w * standardDecel(span(clamp01(p), 0, 0.85)));
}
function leftSpill(p, g) {
    p = clamp01(p);
    var fMin = Math.min(8, g.r);
    var eh = standardDecel(span(p, 0.25, 0.85));
    var hMin = Math.min(g.h, Math.max(2 * g.r + 24, 0.4 * g.h));
    var Wb = leftSpillWidth(p, g);
    var Hb = hMin + (g.h - hMin) * eh;
    var f  = fMin + (g.r - fMin) * eh;
    // The leading corner and the fillet share the top edge: while the body
    // is still narrower than both, the corner gives way — otherwise the edge
    // between them would run backwards into a cusp.
    var rb = Math.min(g.rm + (g.r - g.rm) * eh, Math.max(0, Wb - f), Hb / 2 - 0.01);
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
    var ot = 0.12 * g.h * (1 - standardDecel(span(p, 0, 0.55)));
    var ob = 0.46 * g.h * (1 - standard(span(p, 0.20, 1.0)));
    var settle = 1 - ob / (0.46 * g.h);
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

if (typeof module !== "undefined" && module.exports)
    module.exports = {
        KAPPA: KAPPA,
        Path: Path,
        clamp01: clamp01, lerp: lerp, span: span, smooth: smooth, decel: decel, accel: accel,
        curve: curve, fastDecel: fastDecel, standard: standard,
        standardDecel: standardDecel, emphasizedDecel: emphasizedDecel,
        barNotch: barNotch, barSilhouette: barSilhouette, barHairline: barHairline,
        centerBloom: centerBloom,
        rightPourWidth: rightPourWidth, rightPour: rightPour,
        leftSpill: leftSpill, edgeSpillRight: edgeSpillRight,
        spillRidge: spillRidge, leftSpillWidth: leftSpillWidth, edgeSpillWidth: edgeSpillWidth
    };
