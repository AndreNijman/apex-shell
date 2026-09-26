#!/usr/bin/env node
// ─── spring-test.js ──────────────────────────────────────────────────────────
// src/theme/spring.js — the closed-form damped spring behind Spring.qml — held
// to the physics it claims. Run by CI's "The motion system" step.
const path = require("path");
const S = require(path.join(__dirname, "..", "src", "theme", "spring.js"));

let pass = 0, fail = 0;
function check(name, cond, detail) {
    if (cond) { pass++; console.log("  ok   " + name); }
    else { fail++; console.log("  FAIL " + name + (detail !== undefined ? "  [" + detail + "]" : "")); }
}
function run(response, z, from, target, dt, seconds) {
    let x = from, v = 0, peak = from, t = 0;
    const trace = [];
    while (t < seconds) {
        const r = S.step(x, v, target, response, z, dt); x = r[0]; v = r[1]; t += dt;
        peak = target >= from ? Math.max(peak, x) : Math.min(peak, x);
        trace.push(x);
    }
    return { x, v, peak, trace };
}

// It arrives, and stays.
for (const z of [0.7, 0.86, 1.0, 1.3]) {
    const r = run(0.5, z, 0, 1, 1 / 60, 3);
    check(`ζ=${z}: at rest on the target after 3 s`, S.atRest(r.x, r.v, 1, 0.0005), r.x.toFixed(6) + " v=" + r.v.toFixed(6));
}
// Overshoot matches theory: e^{-πζ/√(1-ζ²)}.
{
    const z = 0.86, r = run(0.5, z, 0, 1, 1 / 1000, 2);
    const theory = Math.exp(-Math.PI * z / Math.sqrt(1 - z * z));
    check("ζ=0.86 overshoots by the theoretical amount (~0.5 %)", Math.abs((r.peak - 1) - theory) < 2e-4,
          (100 * (r.peak - 1)).toFixed(3) + "% vs " + (100 * theory).toFixed(3) + "%");
}
check("critical damping never overshoots", run(0.5, 1.0, 0, 1, 1 / 1000, 2).peak <= 1 + 1e-9);
check("overdamped never overshoots", run(0.5, 1.4, 0, 1, 1 / 1000, 2).peak <= 1 + 1e-9);
// Frame-rate independence: sixty 1/60 s steps land where one 1 s step does.
for (const z of [0.86, 1.0, 1.3]) {
    let x = 0, v = 0;
    for (let i = 0; i < 60; i++) { const r = S.step(x, v, 1, 0.5, z, 1 / 60); x = r[0]; v = r[1]; }
    const one = S.step(0, 0, 1, 0.5, z, 1);
    check(`ζ=${z}: 60 steps of 1/60 s = one step of 1 s`, Math.abs(x - one[0]) < 1e-9 && Math.abs(v - one[1]) < 1e-9,
          x + " vs " + one[0]);
}
// Retargeting keeps velocity: turn around at 40 % and the first step back still
// moves forward (it bends, it does not snap).
{
    let x = 0, v = 0;
    while (x < 0.4) { const r = S.step(x, v, 1, 0.5, 0.86, 1 / 120); x = r[0]; v = r[1]; }
    const before = v;
    const r = S.step(x, v, 0, 0.5, 0.86, 1 / 120);
    check("a reversal keeps the velocity it had (the first step back still moves on)",
          before > 0 && r[0] > x, "v=" + before.toFixed(3) + " x " + x.toFixed(4) + "→" + r[0].toFixed(4));
}
// `response` is how quick: a longer response takes longer to settle.
{
    const a = S.settleTime(0.35, 1, 0, 1, 0.001), b = S.settleTime(0.55, 1, 0, 1, 0.001);
    check("a longer response settles later", b > a, a.toFixed(3) + " < " + b.toFixed(3));
}
// Continuity: no step jumps (the value moves at most velocity × dt + a margin).
{
    const r = run(0.5, 0.86, 0, 1, 1 / 60, 2);
    let worst = 0;
    for (let i = 1; i < r.trace.length; i++) worst = Math.max(worst, Math.abs(r.trace[i] - r.trace[i - 1]));
    check("no frame moves more than 12 % of the travel at 60 Hz (response 0.5)", worst < 0.12, (100 * worst).toFixed(2) + "%");
}

// (Qt's SpringAnimation was measured to be a fixed 16 ms integrator,
// v += k·(to − x) − c·v; x += 0.016·v, and an exact mapping onto it lived here
// with MotionSpring. Both are gone: at 16 ms a step it updated at ~62 Hz on a
// 144 Hz panel. SpringFollower steps this closed form per frame instead.)

console.log("\nspring: passed=" + pass + " failed=" + fail);
process.exit(fail === 0 ? 0 : 1);
