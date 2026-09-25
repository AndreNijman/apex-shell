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
}

console.log("\nfluid-geometry: passed=" + passed + " failed=" + failed);
process.exit(failed === 0 ? 0 : 1);
