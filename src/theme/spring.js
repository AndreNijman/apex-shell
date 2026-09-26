// ─── spring.js ───────────────────────────────────────────────────────────────
// The closed-form damped spring behind components/Spring.qml (UI/UX roadmap v3,
// fluid motion — Andre: "real apple level animation"). Pure, so node drives it
// in tests/spring-test.js; no `.pragma library` because node reads it too.
//
// Parameterised like SwiftUI: `response` is the period of the undamped
// oscillation in seconds, `dampingFraction` ζ is 1 at critical damping.
//     ω0 = 2π / response,   k = ω0² (unit mass),   c = 2 ζ ω0
//
// step() advances (value, velocity) toward `target` by dt seconds EXACTLY — the
// analytic solution, not an integrator — so the motion does not depend on the
// frame rate: sixty 1/60 s steps land where one 1 s step does.
// ─────────────────────────────────────────────────────────────────────────────

function step(value, velocity, target, response, dampingFraction, dt) {
    var w0 = 2 * Math.PI / Math.max(0.02, response);
    var z = Math.max(0.05, dampingFraction);
    var d0 = value - target, v0 = velocity, d, v;
    if (z < 0.9999) {
        var wd = w0 * Math.sqrt(1 - z * z);
        var e = Math.exp(-z * w0 * dt);
        var c = Math.cos(wd * dt), s = Math.sin(wd * dt);
        var B = (v0 + z * w0 * d0) / wd;
        d = e * (d0 * c + B * s);
        v = e * (-z * w0 * (d0 * c + B * s) + wd * (-d0 * s + B * c));
    } else if (z <= 1.0001) {
        var e1 = Math.exp(-w0 * dt);
        var B1 = v0 + w0 * d0;
        d = (d0 + B1 * dt) * e1;
        v = (B1 - w0 * (d0 + B1 * dt)) * e1;
    } else {
        var r = w0 * Math.sqrt(z * z - 1);
        var r1 = -z * w0 + r, r2 = -z * w0 - r;
        var C2 = (v0 - r1 * d0) / (r2 - r1), C1 = d0 - C2;
        var x1 = Math.exp(r1 * dt), x2 = Math.exp(r2 * dt);
        d = C1 * x1 + C2 * x2;
        v = C1 * r1 * x1 + C2 * r2 * x2;
    }
    return [target + d, v];
}

// At rest on the target, to within `eps` of it and slower than eps × 10 / s.
function atRest(value, velocity, target, eps) {
    return Math.abs(value - target) < eps && Math.abs(velocity) < eps * 10;
}

// How long a spring takes to come to rest from `from` at rest (for mapping,
// logging and tests) — simulated at 1 ms.
function settleTime(response, dampingFraction, from, target, eps) {
    var x = from, v = 0, t = 0;
    while (t < 10 && !atRest(x, v, target, eps)) {
        var r = step(x, v, target, response, dampingFraction, 0.001);
        x = r[0]; v = r[1]; t += 0.001;
    }
    return t;
}

if (typeof module !== "undefined" && module.exports)
    module.exports = { step: step, atRest: atRest, settleTime: settleTime };
