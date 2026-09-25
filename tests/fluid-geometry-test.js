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

// ── CENTER_BLOOM ────────────────────────────────────────────────────────────
function centreGeo(s) {
    const px = v => Math.round(v * s);
    return { cx: px(960), strip: px(6), notchW: px(300), notchH: px(40), shoulder: px(15),
             notchR: px(15), w: px(900), h: px(520), r: px(21), shoulder1: px(15) };
}
for (const scale of [0.85, 1.0, 1.5]) {
    section("CENTER_BLOOM at scale " + scale);
    const g = centreGeo(scale);
    const N = 200;
    let prevBounds = null, prevArea = -Infinity, monoW = true, monoH = true, monoA = true;
    let kinks = [], crosses = [], clipOut = [], contact = [];
    for (let i = 0; i <= N; i++) {
        const p = i / N;
        const r = G.centerBloom(p, g);
        // Joins: every consecutive pair of segments meets tangent-continuously,
        // EXCEPT at a segment the path marks `sharp` — the deliberate steps up
        // into the strip, which the bar covers. Marked by the builder, so the
        // exemption cannot drift onto a real join.
        const segs = r.segs;
        for (let k = 1; k < segs.length; k++) {
            if (segs[k - 1].sharp || segs[k].sharp) continue;
            const a = tangentEnd(segs[k - 1]), b = tangentStart(segs[k]);
            if (!a || !b) continue;
            const dot = a[0] * b[0] + a[1] * b[1];
            if (dot < 0.9995) kinks.push(p.toFixed(3) + "@" + k + ":" + dot.toFixed(4));
        }
        const pts = polyline(segs, 24);
        const x = selfIntersects(pts);
        if (x) crosses.push(p.toFixed(3));
        // No collapse: the painted area may never fall back by more than a
        // hair. Corners settling to a larger radius at the very end remove a
        // fraction of a square pixel (measured: 0.4 px² of 463 000) and that is
        // the settle, not a rebound; a real rebound is thousands.
        const A = Math.abs(area(pts));
        if (A < prevArea * (1 - 1e-4)) monoA = false;
        prevArea = Math.max(prevArea, A);
        if (prevBounds) {
            if (r.bounds.w + 1e-6 < prevBounds.w) monoW = false;
            if (r.bounds.h + 1e-6 < prevBounds.h) monoH = false;
        }
        prevBounds = r.bounds;
        // Contact: the top of the silhouette stays on the strip line, centred.
        if (Math.abs(r.bounds.y - (g.strip - 1)) > 1e-6
            || Math.abs(r.bounds.x + r.bounds.w / 2 - g.cx) > 0.51) contact.push(p.toFixed(3));
        // Clip inside body: sample the clip rectangle's corners, inset 1px.
        const c = r.clip;
        const probes = [[c.x + 1, c.y + 2], [c.x + c.w - 1, c.y + 2],
                        [c.x + 1, c.y + c.h - 1 - Math.min(c.h / 2, r.params.rc)],
                        [c.x + c.w - 1, c.y + c.h - 1 - Math.min(c.h / 2, r.params.rc)]];
        if (c.w > 2 && c.h > 4)
            for (const q of probes) if (!inside(pts, q[0], q[1])) { clipOut.push(p.toFixed(3)); break; }
    }
    check("no kinks at any join", kinks.length === 0, kinks.slice(0, 4).join(" "));
    check("the outline never crosses itself", crosses.length === 0, crosses.slice(0, 6).join(","));
    check("bounds width grows monotonically", monoW);
    check("bounds height grows monotonically", monoH);
    check("painted area grows monotonically (no collapse mid-morph)", monoA);
    check("stays attached to the strip, centred on the notch", contact.length === 0, contact.slice(0, 6).join(","));
    check("content clip always inside the body", clipOut.length === 0, clipOut.slice(0, 6).join(","));

    const r0 = G.centerBloom(0, g).params, r1 = G.centerBloom(1, g).params;
    check("p=0 is the notch: width", Math.abs(r0.wb - g.notchW) < 1e-6 && Math.abs(r0.wn - g.notchW) < 1e-6);
    check("p=0 is the notch: depth", Math.abs(r0.hb - g.notchH) < 1e-6);
    check("p=0 is the notch: shoulder and corner radius",
          Math.abs(r0.rs - g.shoulder) < 1e-6 && Math.abs(r0.rc - g.notchR) < 1e-6, r0.rs + "," + r0.rc);
    check("p=1 is the surface: width", Math.abs(r1.wb - g.w) < 1e-6 && Math.abs(r1.wn - g.w) < 1e-6);
    check("p=1 is the surface: depth", Math.abs(r1.hb - g.h) < 1e-6);
    check("p=1 is the surface: shoulder and corner radius",
          Math.abs(r1.rs - g.shoulder1) < 1e-6 && Math.abs(r1.rc - g.r) < 1e-6);
    check("p=1 has straight sides (no neck left)", r1.neckSpan === 0 || Math.abs(r1.wb - r1.wn) < 1e-6);

    // Character: width leads depth early (Fluid §4.3, 0–20 %).
    const e = G.centerBloom(0.2, g).params;
    const wFrac = (e.wb - g.notchW) / (g.w - g.notchW), hFrac = (e.hb - g.notchH) / (g.h - g.notchH);
    check("at 20% the body has widened more than it has deepened",
          wFrac > hFrac + 0.1, wFrac.toFixed(2) + " vs " + hFrac.toFixed(2));
    check("at 20% the neck is still tighter than the body", e.wn < e.wb - 1, e.wn.toFixed(1) + " vs " + e.wb.toFixed(1));
}

console.log("\nfluid-geometry: passed=" + passed + " failed=" + failed);
process.exit(failed === 0 ? 0 : 1);
