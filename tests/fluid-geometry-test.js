#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
//  The fluid surface geometry (UI/UX roadmap v3 Phases 4–5, Fluid roadmap §3.5).
//
//      node tests/fluid-geometry-test.js
//
//  src/shapes/fluid/geometry.js builds every connected surface's silhouette
//  from named parameters. The roadmap's quality rules are properties of those
//  paths, so they are asserted here over a dense sweep of progress values and
//  at several output scales, not eyeballed:
//
//    * the surface keeps contact with its origin at every progress;
//    * joins are tangent-continuous (no kink at the neck or the shoulders);
//    * the outline never crosses itself;
//    * the body never collapses to nothing mid-morph, and grows monotonically;
//    * progress 0 IS the bar's notch, progress 1 IS the finished surface;
//    * the content clip always lies inside the body.
// ─────────────────────────────────────────────────────────────────────────────
"use strict";
const path = require("path");
const SRC = process.env.APEX_SHELL_SRC || path.join(__dirname, "..", "src");
const G = require(path.join(SRC, "shapes", "fluid", "geometry.js"));

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) passed++;
    else { failed++; console.log("  FAIL  " + name + (detail !== undefined ? "  [" + detail + "]" : "")); }
}
function section(s) { console.log("── " + s + " ──"); }

// ── geometry helpers ────────────────────────────────────────────────────────
function bez(p0, p1, p2, p3, t) {
    const u = 1 - t;
    return [u*u*u*p0[0] + 3*u*u*t*p1[0] + 3*u*t*t*p2[0] + t*t*t*p3[0],
            u*u*u*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2[1] + t*t*t*p3[1]];
}
function tangentStart(s) {
    const p = s.p;
    for (let i = 1; i < p.length; i++) {
        const dx = p[i][0] - p[0][0], dy = p[i][1] - p[0][1];
        if (Math.hypot(dx, dy) > 1e-6) return norm([dx, dy]);
    }
    return null;
}
function tangentEnd(s) {
    const p = s.p, n = p.length - 1;
    for (let i = n - 1; i >= 0; i--) {
        const dx = p[n][0] - p[i][0], dy = p[n][1] - p[i][1];
        if (Math.hypot(dx, dy) > 1e-6) return norm([dx, dy]);
    }
    return null;
}
function norm(v) { const l = Math.hypot(v[0], v[1]); return [v[0] / l, v[1] / l]; }
function polyline(segs, per) {
    const pts = [];
    for (const s of segs) {
        if (s.t === "L") { pts.push(s.p[0]); continue; }
        for (let i = 0; i < per; i++) pts.push(bez(s.p[0], s.p[1], s.p[2], s.p[3], i / per));
    }
    return pts;
}
function segsCross(a, b, c, d) {
    const o = (p, q, r) => (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0]);
    const d1 = o(c, d, a), d2 = o(c, d, b), d3 = o(a, b, c), d4 = o(a, b, d);
    return ((d1 > 1e-9 && d2 < -1e-9) || (d1 < -1e-9 && d2 > 1e-9))
        && ((d3 > 1e-9 && d4 < -1e-9) || (d3 < -1e-9 && d4 > 1e-9));
}
function selfIntersects(pts) {
    const n = pts.length;
    for (let i = 0; i < n; i++) {
        const a = pts[i], b = pts[(i + 1) % n];
        for (let j = i + 2; j < n; j++) {
            if (i === 0 && j === n - 1) continue;
            const c = pts[j], d = pts[(j + 1) % n];
            if (segsCross(a, b, c, d)) return [i, j];
        }
    }
    return null;
}
function area(pts) {
    let s = 0;
    for (let i = 0; i < pts.length; i++) {
        const a = pts[i], b = pts[(i + 1) % pts.length];
        s += a[0] * b[1] - b[0] * a[1];
    }
    return s / 2;
}
// Inside test by even-odd ray cast.
function inside(pts, x, y) {
    let c = false;
    for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
        const a = pts[i], b = pts[j];
        if (((a[1] > y) !== (b[1] > y)) && (x < (b[0] - a[0]) * (y - a[1]) / (b[1] - a[1]) + a[0])) c = !c;
    }
    return c;
}

// ── Phase 23: the parameters themselves ────────────────────────────────────
// Two of the roadmap's rejects are about the parameters a silhouette is built
// from rather than its outline at one instant:
//
//   SUDDEN RADIUS CHANGE — a parameter that JUMPS. Fast is not the fault: the
//   pour's fillet is min(r, depth / 2) and reaches its radius within 7 % of the
//   open because the body does; a spill's corner is clamped to a body a few
//   pixels wide. What is wrong is a discontinuity, and a discontinuity has a
//   signature fast motion does not: sample ten times finer and a continuous
//   parameter's largest step shrinks about tenfold, while a jump's does not
//   shrink at all. So a parameter jumps when its largest step at N = 2000 is
//   still over a quarter of its largest at N = 200 AND over 3 px — the pixel
//   floor, because edges and depths are rounded to whole pixels and a sum of
//   two rounded values steps up to ~2.6 px at ANY sampling density (measured:
//   bloom R, spill top/bottom/rb, edge Hb/rb). A snapped radius is several px.
//
//   OVERSHOOT — a parameter going past where it starts or ends. Every one stays
//   between its p = 0 and p = 1 values (a pixel of rounding either way — R is
//   L + W, both rounded),
//   except the ones named in EXEMPT with the reason, each documented where it
//   is computed in geometry.js.
const EXEMPT = {
    // "Bottom-left: the notch's own corner at p = 0, the body's (bulging
    // 17 → 35 → 17) once it has depth" — the pour's trailing corner is rounder
    // mid-pour by design (Fluid roadmap RIGHT_POUR); it is a shape, not a bounce.
    "pour.rbl": "the trailing corner's designed 17 → 35 → 17 bulge"
};
function paramAudit(name, fn, g) {
    const stepsAt = N => {
        const st = {}; let prev = null;
        for (let i = 0; i <= N; i++) {
            const pr = fn(i / N, g).params;
            for (const k in pr) {
                if (typeof pr[k] !== "number") continue;
                const s = st[k] || (st[k] = { step: 0, at: 0, min: Infinity, max: -Infinity });
                s.min = Math.min(s.min, pr[k]); s.max = Math.max(s.max, pr[k]);
                if (prev) { const d = Math.abs(pr[k] - prev[k]); if (d > s.step) { s.step = d; s.at = i / N; } }
            }
            prev = pr;
        }
        return st;
    };
    const coarse = stepsAt(200), fine = stepsAt(2000);
    const p0 = fn(0, g).params, p1 = fn(1, g).params;
    const jumps = [], overs = [];
    for (const k in fine) {
        const f = fine[k], c = coarse[k];
        if (f.step > 3 && f.step > c.step / 4)
            jumps.push(k + "@" + f.at.toFixed(4) + " (" + c.step.toFixed(2) + " → " + f.step.toFixed(2) + " px)");
        if (EXEMPT[name + "." + k]) continue;
        const lo = Math.min(p0[k], p1[k]) - 1, hi = Math.max(p0[k], p1[k]) + 1;
        if (f.min < lo || f.max > hi)
            overs.push(k + " " + f.min.toFixed(1) + ".." + f.max.toFixed(1) + " outside " + p0[k].toFixed(1) + "/" + p1[k].toFixed(1));
    }
    return { jumps: jumps, overs: overs };
}
function auditChecks(name, fn, g) {
    const a = paramAudit(name, fn, g);
    check(name + ": no parameter jumps (continuous under 10x finer sampling)", a.jumps.length === 0, a.jumps.slice(0, 4).join("; "));
    check(name + ": no parameter overshoots its endpoints", a.overs.length === 0, a.overs.slice(0, 4).join("; "));
}

// ── The sweep every family must survive ────────────────────────────────────
// `contact(r, g)` returns false if the silhouette has let go of its origin.
function sweep(name, fn, g, contact, monotone) {
    const N = 200;
    let prev = null, maxArea = 0;
    const kinks = [], crosses = [], clipOut = [], lost = [], shrink = [], collapse = [];
    for (let i = 0; i <= N; i++) {
        const p = i / N;
        const r = fn(p, g);
        const segs = r.segs;
        for (let k = 1; k < segs.length; k++) {
            if (segs[k - 1].sharp || segs[k].sharp) continue;
            const a = tangentEnd(segs[k - 1]), b = tangentStart(segs[k]);
            if (!a || !b) continue;
            const dot = a[0] * b[0] + a[1] * b[1];
            if (dot < 0.9995) kinks.push(p.toFixed(3) + "@" + k + ":" + dot.toFixed(4));
        }
        const pts = polyline(segs, 24);
        if (selfIntersects(pts)) crosses.push(p.toFixed(3));
        const A = Math.abs(area(pts));
        if (A < maxArea * (1 - 1e-4)) collapse.push(p.toFixed(3));
        maxArea = Math.max(maxArea, A);
        if (!contact(r, g)) lost.push(p.toFixed(3));
        if (prev) for (const k of monotone)
            if (r.params[k] + 1e-6 < prev.params[k]) shrink.push(k + "@" + p.toFixed(3));
        prev = r;
        // The clip is a rectangle; the body's corners are round. Content
        // is inset from the clip, so what must hold is that the clip never
        // reaches past a corner by more than a quarter-circle's own bulge: a
        // point d in from both sides of a radius-r corner is inside exactly
        // when d >= r(1 - 1/sqrt 2) ~ 0.293 r.
        const c = r.clip;
        const rc = Math.max(r.params.rb || 0, r.params.rbl || 0, r.params.f || 0);
        const d = 0.3 * rc + 1.5;
        if (c.w > 2 * d + 2 && c.h > 2 * d + 2) {
            const probes = [[c.x + d, c.y + d], [c.x + c.w - d, c.y + d],
                            [c.x + d, c.y + c.h - d], [c.x + c.w - d, c.y + c.h - d]];
            for (const q of probes) if (!inside(pts, q[0], q[1])) { clipOut.push(p.toFixed(3)); break; }
        }
    }
    check(name + ": no kinks at any join", kinks.length === 0, kinks.slice(0, 4).join(" "));
    check(name + ": the outline never crosses itself", crosses.length === 0, crosses.slice(0, 6).join(","));
    check(name + ": no collapse mid-morph", collapse.length === 0, collapse.slice(0, 6).join(","));
    check(name + ": stays attached to its origin", lost.length === 0, lost.slice(0, 6).join(","));
    check(name + ": " + monotone.join("/") + " grow monotonically", shrink.length === 0, shrink.slice(0, 6).join(","));
    check(name + ": the content clip is inside the body", clipOut.length === 0, clipOut.slice(0, 6).join(","));
}
const near = (a, b, eps) => Math.abs(a - b) < (eps === undefined ? 1e-6 : eps);

for (const scale of [0.85, 1.0, 1.5]) {
    const px = v => Math.round(v * scale);

    // ── CENTER_BLOOM ────────────────────────────────────────────────────────
    section("CENTER_BLOOM at scale " + scale);
    const cg = { cx: px(960), strip: px(6), notchW: px(300), notchH: px(40), shoulder: px(15),
                 notchBottom: px(14), w: px(900), h: px(560), r: px(24),
                 shoulderW1: px(28), shoulderH1: px(22) };
    auditChecks("bloom", G.centerBloom, cg);
    sweep("bloom", G.centerBloom, cg,
          (r, g) => r.bounds.y === 0 && Math.abs(r.bounds.x + r.bounds.w / 2 - Math.round(g.cx)) <= 1,
          ["W", "D", "sw", "sh", "rb"]);
    const b0 = G.centerBloom(0, cg).params, b1 = G.centerBloom(1, cg).params;
    check("bloom p=0 is the notch: width, depth", near(b0.W, cg.notchW) && near(b0.D, cg.notchH));
    check("bloom p=0 is the notch: circular shoulder, notch corner",
          near(b0.sw, cg.shoulder) && near(b0.sh, cg.shoulder) && near(b0.tau, G.KAPPA) && near(b0.rb, cg.notchBottom),
          [b0.sw, b0.sh, b0.tau, b0.rb].join(","));
    check("bloom p=1 is the surface", near(b1.W, cg.w) && near(b1.D, cg.h) && near(b1.rb, cg.r)
          && near(b1.sw, cg.shoulderW1) && near(b1.sh, cg.shoulderH1));
    const e = G.centerBloom(0.25, cg).params;
    const wf = (e.W - cg.notchW) / (cg.w - cg.notchW), hf = (e.D - cg.notchH) / (cg.h - cg.notchH);
    check("bloom at 25% has widened far more than it has deepened (a tray, then a body)",
          wf > 0.5 && hf < 0.2, wf.toFixed(2) + " vs " + hf.toFixed(2));
    check("bloom's shoulders end wider than tall", b1.sw > b1.sh);
    const odd = Object.assign({}, cg, { notchW: cg.notchW + 1 });
    const o = G.centerBloom(0.4, odd).params;
    check("bloom edges are whole pixels even for an odd width", Number.isInteger(o.L) && Number.isInteger(o.R));

    // ── RIGHT_POUR ──────────────────────────────────────────────────────────
    section("RIGHT_POUR at scale " + scale);
    const rg = { winW: px(495) + px(15), strip: px(6), seam: px(40), shoulder: px(15), notchBottom: px(14),
                 notchW: px(213), w: px(495), h: px(648), r: px(17) };
    auditChecks("pour", G.rightPour, rg);
    sweep("pour", G.rightPour, rg,
          (r, g) => r.bounds.y === 0 && near(r.bounds.x + r.bounds.w, g.winW),
          ["W", "Dr"]);
    const r0 = G.rightPour(0, rg).params, r1 = G.rightPour(1, rg).params;
    check("pour p=0 is the notch (its width, no depth)", near(r0.W, rg.notchW) && near(r0.Dr, 0));
    check("pour p=1 is the panel, bottom edge level", near(r1.W, rg.w) && near(r1.Dr, rg.h) && near(r1.Dl, rg.h));
    check("pour p=1 corner is back on radius L", near(r1.rbl, rg.r));
    const q = G.rightPour(0.25, rg).params;
    check("pour at 25% is a tall narrow stem (depth leads width)",
          q.Dr / rg.h > 0.45 && (q.W - rg.notchW) / (rg.w - rg.notchW) < 0.3,
          (q.Dr / rg.h).toFixed(2) + " deep, " + ((q.W - rg.notchW) / (rg.w - rg.notchW)).toFixed(2) + " wide");
    const m = G.rightPour(0.5, rg).params;
    check("pour mid-way: the bottom-left trails the right edge", m.Dl < m.Dr - 1, m.Dl.toFixed(1) + " < " + m.Dr.toFixed(1));
    let same = true;
    for (let i = 0; i <= 100; i++) {
        const p = i / 100, W = G.rightPour(p, rg).params.W;
        if (W !== G.rightPourWidth(p, rg.notchW, rg.w) || !Number.isInteger(W)) same = false;
    }
    check("pour's width is one integer function of p (its left edge is a whole pixel)", same);

    // ── The bar, and what the surfaces draw over it ────────────────────────
    section("BAR silhouette at scale " + scale);
    const bw = px(1920), bg = { w: bw, strip: px(6), h: px(40), shoulder: px(15), bottom: px(14),
                                leftW: px(200), centerW: px(300), rightW: rg.notchW, rightBottomL: px(14) };
    const bar = G.barSilhouette(bg), barPts = polyline(bar.segs, 32);
    const bk = [];
    for (let k = 1; k < bar.segs.length; k++) {
        if (bar.segs[k - 1].sharp || bar.segs[k].sharp) continue;
        const a = tangentEnd(bar.segs[k - 1]), b = tangentStart(bar.segs[k]);
        if (a && b && a[0] * b[0] + a[1] * b[1] < 0.9995) bk.push(k);
    }
    check("bar: no kinks at any join", bk.length === 0, bk.join(","));
    check("bar: the outline never crosses itself", !selfIntersects(barPts));
    const b0c = G.centerBloom(0, Object.assign({}, cg, { cx: bw / 2, notchW: bg.centerW })).params;
    check("bar: the centre notch's edges are the bloom's at progress 0",
          bar.params.cS === b0c.L && bar.params.cE === b0c.R,
          bar.params.cS + "," + bar.params.cE + " vs " + b0c.L + "," + b0c.R);
    const oddBar = G.barSilhouette(Object.assign({}, bg, { centerW: bg.centerW + 1 })).params;
    check("bar: whole-pixel centre edges for an odd width", Number.isInteger(oddBar.cS) && Number.isInteger(oddBar.cE));

    // The hairline: an open path, wholly inside the fill, joined without
    // kinks, stopping short of the right notch while a pane hangs from it.
    for (const attached of [false, true]) {
        const hl = G.barHairline(Object.assign({}, bg, { rightAttached: attached }));
        const pts = polyline(hl.segs, 32);
        const outside = pts.filter(q => !inside(barPts, q[0] + (q[0] <= 0.01 ? 0.3 : 0), q[1]));
        check(`bar hairline (${attached ? "attached" : "free"}): every point lies inside the bar's fill`,
              outside.length === 0, outside.slice(0, 3).map(q => q.map(v => v.toFixed(1)).join(",")).join(" "));
        const hk = [];
        for (let k = 1; k < hl.segs.length; k++) {
            const a = tangentEnd(hl.segs[k - 1]), b = tangentStart(hl.segs[k]);
            if (a && b && a[0] * b[0] + a[1] * b[1] < 0.9995) hk.push(k);
        }
        check(`bar hairline (${attached ? "attached" : "free"}): no kinks`, hk.length === 0, hk.join(","));
        check(`bar hairline (${attached ? "attached" : "free"}): ${attached ? "stops before the right notch" : "runs to the screen edge"}`,
              attached ? hl.params.end <= hl.params.rS - bg.shoulder + 1e-6 : Math.abs(hl.params.end - bw) < 1e-6,
              "ends at " + hl.params.end);
    }

    // The pour over the bar's right notch. Window x → screen x is + (bw - winW).
    const off = bw - rg.winW, rS = bar.params.rS, rbN = bar.params.rbR;
    const pourPts = p => polyline(G.rightPour(p, rg).segs, 32);
    const p0 = pourPts(0);
    let differ = [];
    for (let y = 0.41; y < bg.h; y += 1)
        for (let x = rS - bg.shoulder + 0.37; x < rS + rbN - 0.5; x += 1)
            if (inside(p0, x - off, y) !== inside(barPts, x, y)) differ.push(x.toFixed(0) + "," + y.toFixed(0));
    check("pour at p=0 is the bar's own notch where it draws (shoulder, side, corner)",
          differ.length === 0, differ.length + " px differ, e.g. " + differ.slice(0, 4).join(" "));
    let bites = [];
    for (let i = 5; i <= 100; i++) {
        const p = i / 100, pts = pourPts(p);
        for (let y = bg.h - rbN + 0.41; y < bg.h; y += 1)
            for (let x = rS + 0.37; x < rS + rbN; x += 1)
                if (!inside(pts, x - off, y)) { bites.push(p.toFixed(2)); y = bg.h; break; }
    }
    check("pour covers the bar's rounded corner once the body has depth (no wallpaper bite)",
          bites.length === 0, bites.slice(0, 6).join(","));
    const cov = G.rightPour(0.5, rg).params.cover + off;
    check("pour's cover stays left of the notch's padding (never over the status icons)",
          cov <= rS + px(16), cov + " vs " + (rS + px(16)));

    // ── LEFT_SPILL ──────────────────────────────────────────────────────────
    section("LEFT_SPILL at scale " + scale);
    const lg = { x0: px(6), cy: px(400), w: px(220), h: px(270), r: px(17), rm: px(12) };
    auditChecks("spill", G.leftSpill, lg);
    sweep("spill", G.leftSpill, lg,
          (r, g) => r.bounds.x === 0 && Math.abs((r.params.top + r.params.bottom) / 2 - g.cy) <= 1,
          ["Wb", "Hb", "f"]);
    const l1 = G.leftSpill(1, lg).params;
    check("spill p=1 is the menu", near(l1.Wb, lg.w) && Math.abs(l1.Hb - lg.h) <= 1 && near(l1.f, lg.r));
    const l = G.leftSpill(0.25, lg).params;
    check("spill at 25% has pushed out most of its width before it has unfolded",
          l.Wb / lg.w > 0.8 && (l.Hb - 0.4 * lg.h) / lg.h < 0.05, (l.Wb / lg.w).toFixed(2) + " wide");
    const fil = G.leftSpill(0.6, lg).segs.find(s => s.t === "C");
    check("spill's fillet leaves the strip's inner edge vertically (no kink at x0)",
          fil && near(fil.p[0][0], lg.x0) && near(fil.p[1][0], lg.x0), fil ? fil.p[0][0] + "," + fil.p[1][0] : "none");

    // ── EDGE_SPILL (right) ──────────────────────────────────────────────────
    section("EDGE_SPILL (right) at scale " + scale);
    const eg = { x1: px(174), edgeW: px(6), cy: px(400), w: px(174), h: px(340), r: px(17), rm: px(12) };
    auditChecks("edge", G.edgeSpillRight, eg);
    sweep("edge", G.edgeSpillRight, eg,
          (r, g) => near(r.bounds.x + r.bounds.w, g.x1 + g.edgeW),
          ["Wb", "Hb"]);
    const x1 = G.edgeSpillRight(1, eg).params;
    check("edge p=1 is the panel", near(x1.Wb, eg.w) && Math.abs(x1.Hb - eg.h) <= 1);
    const xm = G.edgeSpillRight(0.5, eg).params;
    const topSettled = Math.abs(xm.top - Math.round(eg.cy - eg.h / 2)) <= 1;
    const bottomSettled = Math.abs(xm.bottom - Math.round(eg.cy + eg.h / 2)) <= 1;
    check("edge mid-way: the top has settled and the bottom has not (it drips)",
          topSettled && !bottomSettled, xm.top + ".." + xm.bottom);
    const lm = G.leftSpill(0.5, lg).params;
    check("the two spills differ in character, not only in side",
          Math.abs((lm.top + lm.bottom) / 2 - lg.cy) <= 1 && Math.abs((xm.top + xm.bottom) / 2 - eg.cy) > 5);

    // ── BOTTOM_RISE ─────────────────────────────────────────────────────────
    section("BOTTOM_RISE at scale " + scale);
    const bg2 = { cx: px(960), y1: px(1074), edgeH: px(6), w: px(980), h: px(420), r: px(17), rm: px(12) };
    auditChecks("rise", G.bottomRise, bg2);
    sweep("rise", G.bottomRise, bg2,
          (r, g) => near(r.bounds.y + r.bounds.h, g.y1 + g.edgeH) && Math.abs(r.bounds.x + r.bounds.w / 2 - Math.round(g.cx)) <= 1,
          ["W", "H", "f"]);
    const u1 = G.bottomRise(1, bg2).params, u0 = G.bottomRise(0, bg2).params;
    check("rise p=1 is the picker", near(u1.W, bg2.w) && near(u1.H, bg2.h) && near(u1.rb, bg2.r) && near(u1.f, bg2.r));
    check("rise p=0 is a rounded ridge, not a slab", u0.H > 0 && u0.rb > 0 && u0.W < px(40));
    const u = G.bottomRise(0.25, bg2).params;
    check("rise at 25% has spread far more than it has risen (the strip swells, then the body rises)",
          (u.W - u0.W) / (bg2.w - u0.W) > 0.5 && (u.H - u0.H) / (bg2.h - u0.H) < 0.3,
          ((u.W - u0.W) / (bg2.w - u0.W)).toFixed(2) + " vs " + ((u.H - u0.H) / (bg2.h - u0.H)).toFixed(2));

    // ── CORNER_RISE ─────────────────────────────────────────────────────────
    section("CORNER_RISE at scale " + scale);
    const kg = { x1: px(440), y1: px(580), edgeW: px(6), edgeH: px(6), w: px(420), h: px(560), r: px(17), rm: px(12) };
    auditChecks("corner", G.cornerRise, kg);
    sweep("corner", G.cornerRise, kg,
          (r, g) => near(r.bounds.x + r.bounds.w, g.x1 + g.edgeW) && near(r.bounds.y + r.bounds.h, g.y1 + g.edgeH),
          ["W", "H", "f"]);
    const k1 = G.cornerRise(1, kg).params;
    check("corner p=1 is the sheet", near(k1.W, kg.w) && near(k1.H, kg.h) && near(k1.rb, kg.r));
    const k = G.cornerRise(0.25, kg).params;
    check("corner at 25% is a tall narrow column (it rises up the right strip, then pours left)",
          k.H / kg.h > 0.4 && k.W / kg.w < 0.35, (k.H / kg.h).toFixed(2) + " tall, " + (k.W / kg.w).toFixed(2) + " wide");
}

// ── Liquid channels: the shapes along real spring trajectories ─────────────
// Since 2026-09-26 the surfaces drive the families with CHANNELS (g.ch) from
// SurfaceLifecycle's three springs rather than one progress. This replays the
// lifecycle's sequencing with spring.js — lead first, body once the lead is at
// openRelease; on the way out the body first, the lead once the body is at
// closeRelease; the trail a critical follower — through an open, a close and
// both reversals, at 120 Hz, and holds every frame to what the sweep above
// holds a single progress to, plus: the swell past the finished shape stays
// inside its caps, the secondary motion is 0 at rest, and at rest the shape IS
// the notch (closed) or the finished surface (open), exactly.
const S = require(path.join(__dirname, "..", "src", "theme", "spring.js"));
function liquidRun(script, P, rate) {
    // P: { enter, exit (s), leadIn, bodyIn, leadOut, bodyOut, trail, leadZ, bodyZ, openRel, closeRel }
    const ch = { lead: { x: 0, v: 0, t: 0 }, body: { x: 0, v: 0, t: 0 }, trail: { x: 0, v: 0 } };
    let open = false, frames = [], t = 0;
    const dt = 1 / (rate || 120);
    const R = () => open ? { l: P.enter * P.leadIn, b: P.enter * P.bodyIn, tr: P.enter * P.trail, lz: P.leadZ, bz: P.bodyZ }
                         : { l: P.exit * P.leadOut, b: P.exit * P.bodyOut, tr: P.exit * P.trail, lz: 1, bz: 1 };
    const set = o => {
        open = o;
        if (open) { ch.lead.t = 1; if (ch.lead.x >= P.openRel) ch.body.t = 1; }
        else { ch.body.t = 0; if (ch.body.x <= P.closeRel) ch.lead.t = 0; }
    };
    for (const [at, o] of script) {
        while (t < at - 1e-9) {
            const r = R();
            let q = S.step(ch.lead.x, ch.lead.v, ch.lead.t, r.l, r.lz, dt); ch.lead.x = q[0]; ch.lead.v = q[1];
            q = S.step(ch.body.x, ch.body.v, ch.body.t, r.b, r.bz, dt); ch.body.x = q[0]; ch.body.v = q[1];
            q = S.step(ch.trail.x, ch.trail.v, ch.body.x, r.tr, 1, dt); ch.trail.x = q[0]; ch.trail.v = q[1];
            if (open && ch.body.t < 1 && ch.lead.x >= P.openRel) ch.body.t = 1;
            if (!open && ch.lead.t > 0 && ch.body.x <= P.closeRel) ch.lead.t = 0;
            frames.push({ t: t, lead: ch.lead.x, body: ch.body.x, trail: ch.trail.x,
                          leadFlow: ch.lead.v * r.l / 2.3, bodyFlow: ch.body.v * r.b / 2.3 });
            t += dt;
        }
        if (o !== null) set(o);
    }
    return frames;
}
// SurfaceLifecycle's defaults, at the Balanced morph tokens (motion.js).
const MJ = require(path.join(__dirname, "..", "src", "theme", "motion.js"));
const LP = { enter: MJ.BASE.morphEnter / 1000, exit: MJ.BASE.morphExit / 1000,
             leadIn: 0.72, bodyIn: 0.92, leadOut: 0.70, bodyOut: 0.80, trail: 0.80,
             leadZ: 0.84, bodyZ: 0.80, openRel: 0.12, closeRel: 0.35 };
const SCRIPTS = {
    "open, then close":        [[0, true], [1.6, false], [3.2, null]],
    "reversed mid-open":       [[0, true], [0.12, false], [1.6, null]],
    "reversed mid-close":      [[0, true], [1.6, false], [1.72, true], [3.2, null]]
};
// Which channel drives which dimension, per family (as the surfaces wire it).
const WIRING = {
    bloom: f => ({ w: f.lead, d: f.body, n: f.trail, fw: f.leadFlow, fd: f.bodyFlow }),
    pour:  f => ({ d: f.lead, w: f.body, n: f.trail, fd: f.leadFlow, fw: f.bodyFlow }),
    spill: f => ({ w: f.lead, d: f.body, n: f.trail, fw: f.leadFlow, fd: f.bodyFlow }),
    edge:  f => ({ w: f.lead, d: f.body, n: f.trail, fw: f.leadFlow, fd: f.bodyFlow }),
    rise:  f => ({ w: f.lead, d: f.body, n: f.trail, fw: f.leadFlow, fd: f.bodyFlow }),
    corner: f => ({ d: f.lead, w: f.body, n: f.trail, fd: f.leadFlow, fw: f.bodyFlow })
};
function liquidSweep(name, fn, g, contact, caps) {
    for (const sname of Object.keys(SCRIPTS)) {
        const frames = liquidRun(SCRIPTS[sname], LP);
        const kinks = [], crosses = [], clipOut = [], lost = [], over = [], jumps = [];
        let peakSwell = {}, prev = null;
        const fin = fn(1, g).params;
        for (const f of frames) {
            const r = fn(0, Object.assign({}, g, { ch: WIRING[name](f) }));
            for (let k = 1; k < r.segs.length; k++) {
                if (r.segs[k - 1].sharp || r.segs[k].sharp) continue;
                const a = tangentEnd(r.segs[k - 1]), b = tangentStart(r.segs[k]);
                if (a && b && a[0] * b[0] + a[1] * b[1] < 0.9995) kinks.push(f.t.toFixed(3) + "@" + k);
            }
            const pts = polyline(r.segs, 24);
            if (selfIntersects(pts)) crosses.push(f.t.toFixed(3));
            if (!contact(r, g)) lost.push(f.t.toFixed(3));
            for (const k in caps) {
                const sw = r.params[k] - fin[k];
                peakSwell[k] = Math.max(peakSwell[k] || 0, sw);
                if (sw > caps[k] + 1) over.push(k + "+" + sw.toFixed(1) + "@" + f.t.toFixed(3));
            }
            if (prev) for (const k in r.params) {
                if (typeof r.params[k] !== "number") continue;
                // 120 Hz: a critically damped spring peaks at 2.3/response of
                // its travel a second — under 8 % a frame for every response
                // here. A step over 10 % of the parameter's travel (and 12 px)
                // is a jump, not speed.
                const range = Math.abs(fin[k] - fn(0, g).params[k]);
                if (Math.abs(r.params[k] - prev.params[k]) > Math.max(12, 0.1 * range)) jumps.push(k + "@" + f.t.toFixed(3));
            }
            prev = r;
            const c = r.clip;
            const rc = Math.max(r.params.rb || 0, r.params.rbl || 0, r.params.f || 0);
            const d = 0.3 * rc + 1.5;
            if (c.w > 2 * d + 2 && c.h > 2 * d + 2) {
                const probes = [[c.x + d, c.y + d], [c.x + c.w - d, c.y + d],
                                [c.x + d, c.y + c.h - d], [c.x + c.w - d, c.y + c.h - d],
                                [c.x + c.w / 2, c.y + c.h - 1]];
                for (const q of probes) if (!inside(pts, q[0], q[1])) { clipOut.push(f.t.toFixed(3)); break; }
            }
        }
        const tag = name + " (" + sname + ")";
        check(tag + ": no kinks", kinks.length === 0, kinks.slice(0, 4).join(" "));
        check(tag + ": the outline never crosses itself", crosses.length === 0, crosses.slice(0, 6).join(","));
        check(tag + ": stays attached to its origin", lost.length === 0, lost.slice(0, 6).join(","));
        check(tag + ": the content clip is inside the body", clipOut.length === 0, clipOut.slice(0, 6).join(","));
        check(tag + ": the swell past the finished shape stays inside its caps", over.length === 0, over.slice(0, 4).join(" "));
        check(tag + ": no parameter jumps between frames", jumps.length === 0, jumps.slice(0, 4).join(" "));
        if (sname === "open, then close")
            check(tag + ": the open swells (it is a spring, not a tween), by a few px",
                  Object.keys(caps).some(k => peakSwell[k] > 0.5),
                  JSON.stringify(peakSwell));
    }
    // At rest the channels draw exactly the finished surface and the notch.
    const at1 = fn(0, Object.assign({}, g, { ch: { w: 1, d: 1, n: 1, fw: 0, fd: 0 } }));
    const at0 = fn(0, Object.assign({}, g, { ch: { w: 0, d: 0, n: 0, fw: 0, fd: 0 } }));
    check(name + ": channels at rest on 1 draw the finished surface exactly", at1.path === fn(1, g).path);
    check(name + ": channels at rest on 0 draw the notch exactly", at0.path === fn(0, g).path);
}
{
    const px = v => v;
    section("LIQUID channels (spring trajectories)");
    const cg = { cx: 960, strip: 6, notchW: 300, notchH: 40, shoulder: 15, notchBottom: 14,
                 w: 900, h: 560, r: 24, shoulderW1: 28, shoulderH1: 22 };
    liquidSweep("bloom", G.centerBloom, cg,
                (r, g) => r.bounds.y === 0 && Math.abs(r.bounds.x + r.bounds.w / 2 - Math.round(g.cx)) <= 1,
                { W: 4, D: 6, bow: 8 });
    const rg = { winW: 495 + 15, strip: 6, seam: 40, shoulder: 15, notchBottom: 14,
                 notchW: 213, w: 495, h: 648, r: 17 };
    liquidSweep("pour", G.rightPour, rg,
                (r, g) => r.bounds.y === 0 && near(r.bounds.x + r.bounds.w, g.winW),
                { W: 5, Dr: 6 });
    const lg = { x0: 6, cy: 400, w: 220, h: 270, r: 17, rm: 12 };
    liquidSweep("spill", G.leftSpill, lg,
                (r, g) => r.bounds.x === 0 && Math.abs((r.params.top + r.params.bottom) / 2 - g.cy) <= 1,
                { Wb: 4, Hb: 4 });
    const eg = { x1: 174, edgeW: 6, cy: 400, w: 174, h: 340, r: 17, rm: 12 };
    liquidSweep("edge", G.edgeSpillRight, eg,
                (r, g) => near(r.bounds.x + r.bounds.w, g.x1 + g.edgeW),
                { Wb: 4 });
    liquidSweep("rise", G.bottomRise, { cx: 960, y1: 1074, edgeH: 6, w: 980, h: 420, r: 17, rm: 12 },
                (r, g) => near(r.bounds.y + r.bounds.h, g.y1 + g.edgeH) && Math.abs(r.bounds.x + r.bounds.w / 2 - Math.round(g.cx)) <= 1,
                { W: 4, H: 4, bow: 8 });
    liquidSweep("corner", G.cornerRise, { x1: 440, y1: 580, edgeW: 6, edgeH: 6, w: 420, h: 560, r: 17, rm: 12 },
                (r, g) => near(r.bounds.x + r.bounds.w, g.x1 + g.edgeW) && near(r.bounds.y + r.bounds.h, g.y1 + g.edgeH),
                { W: 4, H: 4 });
    // The bow is secondary motion: 0 at rest, and it bends the other way on
    // the way back up.
    const frames = liquidRun(SCRIPTS["open, then close"], LP);
    let down = 0, up = 0;
    for (const f of frames) {
        const bw = G.centerBloom(0, Object.assign({}, cg, { ch: WIRING.bloom(f) })).params.bow;
        down = Math.max(down, bw); up = Math.min(up, bw);
    }
    check("bloom: the bottom edge bows down as it drops and up as it rises", down > 2 && up < -1,
          down.toFixed(1) + " / " + up.toFixed(1));
}

// ── NOTCH_EXTRUDE (the Nexus): an extrusion, not a drip ─────────────────────
// geometry.js notchExtrudeField, drawn per pixel by shapes/fluid/fluiddrop.frag
// (tests/run-fluid-drop-test.sh holds the shader to this same field). The drip
// it replaced (2026-09-27) read as "notch → teardrop → balloon → Nexus": a
// drop let go of the notch, a thread held a giant round blob, and the close
// shrank the window into a blob. So what is held here is the extrusion's
// character, not only its bounds:
//
//   * the notch moves on the lifecycle's first frame ("fast first");
//   * attached: until the neck starts to draw back, nothing below the seam is
//     ever cut off from the notch — no detached drop, at any frame;
//   * in order: a sag, a bulb on a neck, the sheet spreading on a whole neck,
//     then the neck drawing back into the notch from its lower end;
//   * no blob: once the sheet is wider than the notch's footprint it is
//     clearly wider than tall, and its corners never make it a stadium;
//   * closing: the neck is whole again before the mass is drawn up, and stays
//     whole until the mass is in the notch; the window contracts toward its
//     top rather than falling;
//   * exact rest states, bounds that hold everything the shader draws, the
//     content clip inside the window and the body, no parameter jumps, and NO
//     POP in the neck through the open, the close and every reversal.
{
    section("NOTCH_EXTRUDE field (Nexus)");
    const W = 1920;
    const dg = { cx: 960, notchW: 300, notchH: 40, notchBottom: 14,
                 card: { x: 500, y: 230, w: 920, h: 620 }, r: 28 };
    const at = (w, d, n, g) => G.notchExtrudeField(0, Object.assign({}, g || dg, { ch: { w: w, d: d, n: n } }));
    // As Nexus.qml wires its lifecycle: the hero open (the body at 0.98 of
    // it, damping 0.85), the morphEnter close, the spread once the extrusion
    // is at 0.2, the mass drawn up once the window is at 0.2, the neck
    // trailing at 0.38.
    const DP = Object.assign({}, LP, { enter: MJ.BASE.hero / 1000, exit: MJ.BASE.morphEnter / 1000,
                                       bodyIn: 0.98, bodyZ: 0.85, trail: 0.38, openRel: 0.2, closeRel: 0.2 });
    const RUNS = Object.assign({}, SCRIPTS, {
        "reversed at a quarter of the open":        [[0, true], [0.07, false], [1.2, null]],
        "reversed half-way through the open":       [[0, true], [0.16, false], [1.2, null]],
        "reversed at three quarters of the open":   [[0, true], [0.26, false], [1.2, null]],
        "reversed a quarter into the close":        [[0, true], [1.6, false], [1.65, true], [3.2, null]],
        "reversed three quarters into the close":   [[0, true], [1.6, false], [1.8, true], [3.2, null]]
    });
    const finite = o => JSON.stringify(o, (k, v) => (typeof v === "number" && !isFinite(v)) ? "BAD" : v).indexOf("BAD") < 0;
    // Along the axis, from just under the seam to just inside the sheet's
    // top: is everything there joined (every sample inside)?
    const whole = (f, g) => {
        g = g || dg;
        const top = f.card.hw > 0 ? f.card.cy - f.card.hh : g.notchH;
        for (let y = g.notchH + 1; y < top + 2; y += 1) if (G.dropField(f, g.cx, y) >= 0) return false;
        return true;
    };
    // The lowest point on the axis that is inside, below the seam.
    const reach = (f, g) => {
        g = g || dg;
        let low = g.notchH;
        for (let y = g.notchH + 0.25; y < 1080; y += 0.25) if (G.dropField(f, g.cx, y) < 0) low = y;
        return low - g.notchH;
    };
    function fieldChecks(tag, f, g) {
        g = g || dg;
        const bad = [];
        if (!finite(f)) bad.push("non-finite");
        const b = f.bounds;
        // Nothing outside the bounds (a ring 1 px outside, below the seam).
        for (let x = b.x - 1; x <= b.x + b.w + 1; x += 4) {
            if (G.dropField(f, x, b.y + b.h + 1) < 0.5) { bad.push("inside below the bounds at x=" + x.toFixed(0)); break; }
        }
        for (let y = g.notchH + 0.5; y <= b.y + b.h + 1; y += 4) {
            if (G.dropField(f, b.x - 1, y) < 0.5 || G.dropField(f, b.x + b.w + 1, y) < 0.5) { bad.push("inside beside the bounds at y=" + y.toFixed(0)); break; }
        }
        const c = f.clip, cd = g.card;
        if (c.w > 8 && c.h > 8) {
            if (c.x < cd.x - 0.5 || c.y < cd.y - 0.5 || c.x + c.w > cd.x + cd.w + 0.5 || c.y + c.h > cd.y + cd.h + 0.5)
                bad.push("clip outside the finished window");
            // The edges' middles, and the corners as far in as the finished
            // window's own corner (the content keeps clear of that already).
            const e = 0.3 * g.r + 1;
            const probes = [[c.x + c.w / 2, c.y + 2], [c.x + c.w / 2, c.y + c.h - 2], [c.x + 2, c.y + c.h / 2], [c.x + c.w - 2, c.y + c.h / 2],
                            [c.x + e, c.y + e], [c.x + c.w - e, c.y + e], [c.x + e, c.y + c.h - e], [c.x + c.w - e, c.y + c.h - e]];
            if (probes.some(q => G.dropField(f, q[0], q[1]) >= 0)) bad.push("clip outside the body");
        }
        // Attached: until the neck starts to draw back, nothing is cut off.
        if (f.params.form > 0.99 && f.params.ret === 0 && !whole(f, g)) bad.push("cut off from the notch");
        // No blob: once it is a sheet (wider than the notch), its corners are
        // not those of a stadium, and nothing of it is wider than the window
        // is. The bulb before that may be round: it is modest.
        const p = f.params;
        if (p.hw > 200 && p.r > 0.8 * Math.min(p.hw, p.hh)) bad.push("a stadium (r " + p.r.toFixed(0) + ")");
        if (f.lower && f.lower.rb > p.hw + 0.5 && p.hw > 100) bad.push("the bell wider than the sheet");
        return bad.map(x => tag + ": " + x);
    }
    let bad = [];
    for (let i = 0; i <= 400; i++) {
        const pp = i / 400;
        bad = bad.concat(fieldChecks("p=" + pp.toFixed(4), G.notchExtrudeField(pp, dg)));
    }
    check("field along progress: finite, inside its bounds, attached, no blob, clip inside",
          bad.length === 0, bad.slice(0, 4).join("; "));
    // At rest.
    const z = at(0, 0, 0);
    let under = true;
    for (let x = 0; x <= W; x += 4) for (let y = dg.notchH + 0.5; y < 1080; y += 8) if (G.dropField(z, x, y) < 0.5) under = false;
    check("field at rest on 0: nothing below the seam (the notch is the bar's own)", under);
    check("field at rest on 0: no sheet, no neck, no blends",
          z.card.hw === 0 && z.card.hh === 0 && z.upper === null && z.lower === null && z.kN === 0 && z.kC === 0 && z.kW === 0);
    const o = at(1, 1, 1);
    let exact = o.upper === null && o.lower === null && o.kW === 0;
    for (let x = 400; x <= 1520 && exact; x += 7) for (let y = 0; y < 1000; y += 7) {
        const n = o.notch, nhh = (n.y + 400) / 2;
        const want = Math.min(G.sdRoundBox(x, y, (n.x0 + n.x1) / 2, n.y - nhh, (n.x1 - n.x0) / 2, nhh, n.r),
                              G.sdRoundBox(x, y, 960, 540, 460, 310, 28));
        if (G.dropField(o, x, y) !== want) { exact = false; break; }
    }
    check("field at rest on 1: exactly the window (and the notch box above the seam), no neck", exact);
    check("field at rest on 1: the content clip is exactly the window",
          o.clip.x === 500 && o.clip.y === 230 && o.clip.w === 920 && o.clip.h === 620, JSON.stringify(o.clip));
    check("the field's notch box stays inside the notch's flat bottom",
          o.notch.x1 - o.notch.x0 < dg.notchW - 2 * dg.notchBottom, (o.notch.x1 - o.notch.x0).toFixed(1));
    // Fast first: one 60 Hz frame into the open, the notch has moved.
    const f60 = liquidRun([[0, true], [1 / 60 + 1e-6, null]], DP, 60);
    const first = f60[f60.length - 1];
    const r1 = reach(at(first.lead, first.body, first.trail));
    check("fast first: the notch sags on the lifecycle's first frame", r1 >= 1, r1.toFixed(2) + " px at lead " + first.lead.toFixed(3));
    // In order, through a real open.
    const frames = liquidRun(SCRIPTS["open, then close"], DP);
    let phase = 0, order = [];
    frames.forEach(fr => {
        if (fr.t > 1.6) return;
        const f = at(fr.lead, fr.body, fr.trail), p = f.params;
        if (phase === 0 && p.B === 0 && reach(f) > 2 && reach(f) < 40 && whole(f)) { phase = 1; order.push("a sag"); }
        if (phase === 1 && p.hw > p.rN && p.hw < 120 && whole(f)) { phase = 2; order.push("a bulb on a neck"); }
        if (phase === 2 && p.B > 0.5 && p.hw > 300 && whole(f)) { phase = 3; order.push("the sheet spreading on a whole neck"); }
        if (phase === 3 && p.ret > 0.1 && p.ret < 0.9 && !whole(f) && G.dropField(f, dg.cx, dg.notchH + 2) < 0) { phase = 4; order.push("the neck drawing back into the notch"); }
    });
    check("it is an extrusion: a sag, a bulb on a neck, the sheet spreading on it, the neck drawn back",
          phase === 4, order.join(" → "));
    // Depth leads width, and the sheet is never the window at 60 % (Andre,
    // 2026-09-27: "let depth lead width slightly; avoid the intermediate body
    // looking like the final rectangle at 60% scale"): through the open, the
    // sheet's height is at least as far along as its width, and while it is
    // between a third and three quarters of the window's width it is clearly
    // taller for its width than the window is.
    const CW = dg.card.w / 2, CH = dg.card.h / 2, aspect = CW / CH;
    let lag = [], scaled = [];
    frames.forEach(fr => {
        if (fr.t > 1.6) return;
        const p = at(fr.lead, fr.body, fr.trail).params;
        if (p.B <= 0.02 || p.B >= 0.98) return;
        if (p.hh / CH + 0.005 < p.hw / CW) lag.push(fr.t.toFixed(3));
        if (p.hw > CW / 3 && p.hw < 0.75 * CW && p.hw / p.hh > aspect / 1.15) scaled.push(fr.t.toFixed(3) + " (" + (p.hw / p.hh).toFixed(2) + ")");
    });
    check("depth leads width through the open", lag.length === 0, lag.slice(0, 4).join(", "));
    // The flare is the same material stretching, not a neck joining two
    // masses (Andre, 2026-09-27: "a narrow neck, then shoulders that flare
    // hard into the body … slightly too literal"). What made the second mass
    // was a DOME: the bell's circle riding above the sheet's top, whose
    // convex shoulders the neck then had to join. So once the sheet spreads,
    // the bell stays inside it and the flare is the blend alone (while the
    // neck is attached: drawing back, its tip rises past the sheet's top
    // into the notch). And the
    // corners stay organic — at least 0.45 of the sheet's half-size — until
    // the last fifth of the spread ("organic while moving, architectural when
    // settled"); before, they were halfway to the window's own by 0.76.
    let domes = [], early = [];
    frames.forEach(fr => {
        if (fr.t > 1.6) return;
        const f = at(fr.lead, fr.body, fr.trail), p = f.params;
        if (p.B > 0.02 && p.B < 0.8 && p.hw > 150 && p.r < 0.45 * Math.min(p.hw, p.hh)) early.push(fr.t.toFixed(3) + " (r " + p.r.toFixed(0) + ")");
        if (p.B >= 0.35 && p.ret === 0 && f.lower && f.lower.by - f.lower.rb < p.top - 0.5) domes.push(fr.t.toFixed(3));
    });
    check("the flare is the blend, not a dome over the sheet (no second mass for the neck to join)",
          domes.length === 0, domes.slice(0, 4).join(", "));
    check("the corners stay organic until the last fifth of the spread", early.length === 0, early.slice(0, 4).join(", "));
    check("the sheet is never the window scaled down", scaled.length === 0, scaled.slice(0, 4).join(", "));
    // Closing: the neck is whole before the mass is drawn up (the lead is
    // released at closeRelease) and stays whole until the mass is in the
    // notch; the window contracts toward its top.
    let released = false, lost = [], reconnected = false, fell = [];
    frames.forEach(fr => {
        if (fr.t <= 1.6) return;
        const f = at(fr.lead, fr.body, fr.trail), p = f.params;
        if (fr.body <= DP.closeRel) released = true;
        if (p.hw > 0 && p.top > dg.card.y + 0.5 && fr.body > DP.closeRel) fell.push(fr.t.toFixed(3));
        if (!released) { if (whole(f)) reconnected = true; return; }
        if (p.form > 0.99 && p.top > dg.notchH + 3 && !whole(f)) lost.push(fr.t.toFixed(3));
    });
    check("closing: the neck reaches the window before the mass is drawn up", reconnected);
    check("closing: the mass is drawn up on its neck, never cut loose", released && lost.length === 0, lost.slice(0, 4).join(", "));
    check("closing: the window contracts toward its top, never falls", fell.length === 0, fell.slice(0, 4).join(", "));
    // And the notch recovers it: the mass only climbs. Through the close
    // the body's centre never moves down, and the closing lift puts it
    // higher than the same channels would without it (the trail ahead of
    // the body is what lifts it; opening, the trail is behind and there is
    // no lift at all).
    let sank = [], prevCy = null, lifted = 0, openLift = 0;
    frames.forEach(fr => {
        const f = at(fr.lead, fr.body, fr.trail), p = f.params;
        const noLift = at(fr.lead, fr.body, Math.min(fr.trail, fr.body)).params;
        // (the frame AT 1.6 is the close's first: liquidRun steps, then flips)
        if (fr.t < 1.6 - 1e-6) { openLift = Math.max(openLift, Math.abs(p.cy - noLift.cy)); prevCy = null; return; }
        if (p.hw <= 0 || p.form < 0.99) return;
        if (prevCy !== null && p.cy > prevCy + 0.01) sank.push(fr.t.toFixed(3));
        prevCy = p.cy;
        lifted = Math.max(lifted, noLift.cy - p.cy);
    });
    check("closing: the mass only climbs, and higher than it would without the lift",
          sank.length === 0 && lifted > 10, "sank at " + sank.slice(0, 3).join(", ") + "; lift " + lifted.toFixed(1) + " px");
    // (the open's own settle — a whisper of undershoot after its overshoot —
    // can put the trail a hundred-thousandth ahead: thousandths of a pixel)
    check("opening: no lift (under a hundredth of a pixel)", openLift < 0.01, openLift.toFixed(4));
    // A jump, as the parameter audit above defines one: fast is not the
    // fault — the neck thins "rapidly" by design — a discontinuity is, and it
    // has a signature speed does not: at 1200 Hz a continuous parameter's
    // largest step is about a tenth of its largest at 120 Hz; a jump's is not.
    const KEYS = ["hw", "hh", "top", "cx", "r", "rN", "R2"];
    const steps = (script, rate) => {
        const st = {}; let prev = null;
        liquidRun(script, DP, rate).forEach(fr => {
            const p = at(fr.lead, fr.body, fr.trail).params;
            if (prev) for (const k of KEYS) {
                const d = Math.abs(p[k] - prev[k]);
                if (!st[k] || d > st[k].d) st[k] = { d: d, t: fr.t };
            }
            prev = p;
        });
        return st;
    };
    for (const sname of Object.keys(RUNS)) {
        let fb = [];
        liquidRun(RUNS[sname], DP).forEach(fr => {
            fb = fb.concat(fieldChecks(sname + " t=" + fr.t.toFixed(3), at(fr.lead, fr.body, fr.trail)));
        });
        check("field (" + sname + "): every frame finite, inside its bounds, attached, no blob, clipped inside",
              fb.length === 0, fb.slice(0, 3).join("; "));
        const coarse = steps(RUNS[sname], 120), fine = steps(RUNS[sname], 1200), jumps = [];
        for (const k of KEYS)
            if (fine[k].d > 3 && fine[k].d > coarse[k].d / 4)
                jumps.push(k + "@" + fine[k].t.toFixed(4) + " (" + coarse[k].d.toFixed(2) + " → " + fine[k].d.toFixed(2) + " px)");
        check("field (" + sname + "): no parameter jumps (continuous under 10x finer sampling)", jumps.length === 0, jumps.slice(0, 4).join("; "));
    }
    // A wider notch (a media title) does not fatten the neck, and a smaller
    // screen (the card nearer the notch) keeps every rule.
    const wide = Object.assign({}, dg, { notchW: 460 });
    const wn = at(1, 0.2, 0.1, wide).params.rN, nn = at(1, 0.2, 0.1).params.rN;
    check("a wider notch does not fatten the neck", Math.abs(wn - nn) < 0.5, nn.toFixed(1) + " / " + wn.toFixed(1));
    const small = { cx: 683, notchW: 300, notchH: 40, notchBottom: 14, card: { x: 223, y: 104, w: 920, h: 560 }, r: 24 };
    let sb = [];
    for (const sname of ["open, then close", "reversed mid-open", "reversed mid-close"])
        liquidRun(SCRIPTS[sname], DP).forEach(fr => { sb = sb.concat(fieldChecks("small " + sname + " t=" + fr.t.toFixed(3), at(fr.lead, fr.body, fr.trail, small), small)); });
    check("a small screen (the window near the notch): every frame keeps every rule", sb.length === 0, sb.slice(0, 3).join("; "));
    // NO POP. Along the axis, between the seam and the sheet (clear of the
    // sheet's own meniscus), the field's value is minus the neck's local
    // half-width: it measures the neck, and only the neck. Stepped at 1 kHz
    // and at 10 kHz through an open, a close and a reversal each way, a
    // continuous neck changes about tenfold less per step at the finer rate;
    // a jump — a neck that vanishes, or is born thicker than it was — does
    // not shrink at all.
    const worst = (fn, rate) => {
        let w = 0;
        for (const sname of ["open, then close", "reversed mid-open", "reversed mid-close"]) {
            let prev = null;
            liquidRun(SCRIPTS[sname], DP, rate).forEach(fr => {
                const f = fn(Object.assign({}, dg, { ch: { w: fr.lead, d: fr.body, n: fr.trail } }));
                const top = f.card.hw > 0 ? f.card.cy - f.card.hh : 1e9;
                const cur = { top: top, d: [] };
                // Clamped just outside the edge: what is far from the surface
                // is not seen, and moves as fast as the sheet does.
                for (let y = dg.notchH + 1; y < 400; y += 0.5) cur.d.push(Math.min(2, G.dropField(f, dg.cx, y)));
                if (prev) {
                    // Clear of the sheet's own blend — but never more than
                    // 0.4 of the neck: the flare's blend is wide now, and
                    // skipping all of it left nothing to measure while the
                    // neck was thick (the self-test below stopped catching
                    // a neck that vanishes).
                    const t0 = Math.min(top, prev.top);
                    const lim = t0 - Math.min(f.kC, 0.4 * Math.max(0, t0 - dg.notchH)) - 4;
                    for (let i = 0; dg.notchH + 1 + i * 0.5 < lim && i < cur.d.length; i++)
                        w = Math.max(w, Math.abs(cur.d[i] - prev.d[i]));
                }
                prev = cur;
            });
        }
        return w;
    };
    const real = g => G.notchExtrudeField(0, g);
    const w1k = worst(real, 1000), w10k = worst(real, 10000);
    check("no pop: the neck changes continuously, opening, closing and reversing",
          w10k < w1k / 4, w1k.toFixed(2) + " → " + w10k.toFixed(2) + " px per step");
    // Can it fail? A neck that is simply dropped a third of the way into
    // drawing back, instead of drawn back.
    const popping = g => {
        const f = G.notchExtrudeField(0, g);
        if (f.params.ret > 0.33) return Object.assign({}, f, { upper: null, lower: null, kW: 0 });
        return f;
    };
    const m1k = worst(popping, 1000), m10k = worst(popping, 10000);
    check("self-test: a neck that vanishes instead of drawing back is caught as a pop",
          !(m10k < m1k / 4), m1k.toFixed(2) + " → " + m10k.toFixed(2) + " px per step");
}

// ── Phase 23: can the parameter audit fail? ─────────────────────────────────
// A family with a radius that snaps at p = 0.5, and one whose width swells 40 px
// past its end, must both be caught — or the two checks above assert nothing.
section("parameter audit self-test");
{
    const cg = { cx: 960, strip: 6, notchW: 300, notchH: 40, shoulder: 15, notchBottom: 14,
                 w: 900, h: 560, r: 24, shoulderW1: 28, shoulderH1: 22 };
    const snapping = (p, g) => { const r = G.centerBloom(p, g); r.params = Object.assign({}, r.params, { rb: p < 0.5 ? g.notchBottom : g.r }); return r; };
    const swelling = (p, g) => { const r = G.centerBloom(p, g); r.params = Object.assign({}, r.params, { W: r.params.W + 40 * Math.sin(Math.PI * p) }); return r; };
    const snap = paramAudit("mutant", snapping, cg), swell = paramAudit("mutant", swelling, cg);
    check("self-test: a radius that snaps mid-morph is caught as a jump", snap.jumps.some(j => j.startsWith("rb@")), snap.jumps.join("; "));
    check("self-test: a width that swells past its end is caught as an overshoot", swell.overs.some(o => o.startsWith("W ")), swell.overs.join("; "));
    const clean = paramAudit("bloom", G.centerBloom, cg);
    check("self-test: the real bloom passes the same audit", clean.jumps.length === 0 && clean.overs.length === 0);
}

// ── Phase 23: the input mask follows the body ──────────────────────────────
// A mask computed apart from the silhouette drifts from it mid-animation: a
// click lands on nothing where the body is drawn, or the body's neighbour is
// blocked where it is not. Every fluid popup masks by an item bound to the SAME
// geometry result it draws (body.result.bounds), so the two cannot disagree at
// any progress. Asserted on the source, and self-tested on a hand-sized copy.
section("input masks follow the body");
{
    const fs = require("fs");
    // Since 2026-09-27 a popup holding the keyboard masks its whole window
    // while it does (`root.grabbing ? outside : <body>` — see
    // tests/check-exclusive-focus.sh); the body's own item is the one that
    // is not the catcher, and it is what must follow the silhouette.
    const maskFollowsBody = src => {
        const m = src.match(/mask:\s*Region\s*\{\s*item:\s*([^}]*)\}/);
        if (!m) return false;
        const declared = new Set([...src.matchAll(/\bid:\s*(\w+)/g)].map(x => x[1]));
        const ids = (m[1].match(/\b[A-Za-z_]\w*\b/g) || []).filter(x => declared.has(x) && x !== "outside" && x !== "root");
        if (ids.length !== 1) return false;
        const id = ids[0];
        const at = src.indexOf("id: " + id);
        if (at < 0) return false;
        const block = src.slice(at, at + 600);
        return ["x", "y", "width", "height"].every(k =>
            new RegExp("\\b" + k + ":\\s*[^;\\n]*body\\.result\\.bounds\\.").test(block));
    };
    for (const f of ["popups/RightPanel.qml", "popups/ArchMenu.qml", "popups/QuickControl.qml"]) {
        const src = fs.readFileSync(path.join(SRC, f), "utf8");
        check(f + ": its input mask is the body's own bounds", maskFollowsBody(src));
    }
    const rp = fs.readFileSync(path.join(SRC, "popups/RightPanel.qml"), "utf8");
    const handSized = rp.replace(/width: body\.result\.bounds\.w/, "width: 400");
    check("self-test: a mask sized by hand is caught", handSized !== rp && !maskFollowsBody(handSized));
}

console.log("\nfluid-geometry: passed=" + passed + " failed=" + failed);
process.exit(failed === 0 ? 0 : 1);
