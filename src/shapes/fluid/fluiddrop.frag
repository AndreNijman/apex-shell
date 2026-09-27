#version 440
// ─────────────────────────────────────────────────────────────────────────────
// fluiddrop.frag — the Nexus's extrusion, per pixel (FluidDrop.qml).
//
// The signed-distance field of geometry.js notchExtrudeField, evaluated
// exactly as geometry.js dropField does: the notch box and the neck
// smooth-unioned (the meniscus under the notch), the sheet and the bell
// smooth-unioned (where the bell meets the sheet), and the two joined by a
// third smooth union at the waist, so the neck flares into the bell instead
// of meeting it in a V. tests/run-fluid-drop-test.sh renders this shader and
// holds it to the JavaScript field.
//
// Nothing is drawn above the seam: that is the bar's notch, and the box above
// it only shapes the meniscus below it. Coverage is the field in device
// pixels, so the edge is one device pixel of antialiasing at any scale.
//
// Built with:  qsb --glsl "100 es,120,150" --hlsl 50 --msl 12 \
//                  -o fluiddrop.frag.qsb fluiddrop.frag
// (tests/check-shaders.sh rebuilds it and fails if the committed .qsb differs.)
// ─────────────────────────────────────────────────────────────────────────────

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 fieldOrigin;   // the item's top-left, in the field's coordinates
    vec2 fieldSize;     // the item's size
    float pixelRatio;   // device pixels per field unit
    vec4 notchBox;      // x0, x1, seam y, corner radius
    vec4 bodyBox;       // centre x, centre y, half-width, half-height
    vec4 blends;        // body corner radius, kN, kC, kW (the waist)
    vec4 upperA;        // ax, ay, ra, present (1) or not (0)
    vec4 upperB;        // bx, by, rb, unused
    vec4 lowerA;
    vec4 lowerB;
    vec4 fillColor;     // premultiplied
};

const float FAR = 100000.0;

float sdRoundBox(vec2 p, vec2 c, vec2 h, float r)
{
    vec2 q = abs(p - c) - h + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// A round cone: circle (a, r1), circle (b, r2) and their outer tangents
// (Inigo Quilez's sdRoundCone). One circle inside the other is that circle.
float sdRoundCone(vec2 p, vec2 a, vec2 b, float r1, float r2)
{
    vec2 ba = b - a;
    float l2 = dot(ba, ba);
    float rr = r1 - r2;
    float a2 = l2 - rr * rr;
    if (a2 <= 1e-6)
        return min(length(p - a) - r1, length(p - b) - r2);
    float il2 = 1.0 / l2;
    vec2 pa = p - a;
    float y = dot(pa, ba);
    float z = y - l2;
    vec2 q = pa * l2 - ba * y;
    float x2 = dot(q, q);
    float y2 = y * y * l2;
    float z2 = z * z * l2;
    float k = sign(rr) * rr * rr * x2;
    if (sign(z) * a2 * z2 > k) return sqrt(x2 + z2) * il2 - r2;
    if (sign(y) * a2 * y2 < k) return sqrt(x2 + y2) * il2 - r1;
    return (sqrt(x2 * a2 * il2) + y * rr) * il2 - r1;
}

float smin(float a, float b, float k)
{
    if (k <= 0.0) return min(a, b);
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

void main()
{
    vec2 p = fieldOrigin + qt_TexCoord0 * fieldSize;
    if (p.y < notchBox.z) {
        fragColor = vec4(0.0);
        return;
    }
    float nhh = (notchBox.z + 400.0) * 0.5;       // from 400 px above the screen
    float dn = sdRoundBox(p, vec2((notchBox.x + notchBox.y) * 0.5, notchBox.z - nhh),
                          vec2((notchBox.y - notchBox.x) * 0.5, nhh), notchBox.w);
    float dc = (bodyBox.z > 0.0 && bodyBox.w > 0.0)
               ? sdRoundBox(p, bodyBox.xy, bodyBox.zw, blends.x) : FAR;
    float du = upperA.w > 0.5 ? sdRoundCone(p, upperA.xy, upperB.xy, upperA.z, upperB.z) : FAR;
    float dl = lowerA.w > 0.5 ? sdRoundCone(p, lowerA.xy, lowerB.xy, lowerA.z, lowerB.z) : FAR;
    float d = smin(smin(dn, du, blends.y), smin(dc, dl, blends.z), blends.w);
    float a = clamp(0.5 - d * pixelRatio, 0.0, 1.0);
    fragColor = fillColor * (a * qt_Opacity);
}
