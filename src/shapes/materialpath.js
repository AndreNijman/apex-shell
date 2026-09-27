.pragma library
.import "material/material-shapes.js" as MaterialShapes

// ─────────────────────────────────────────────────────────────────────────────
// materialpath.js — a Material 3 Expressive shape as an SVG path.
//
// The shapes themselves are Google's (AndroidX graphics-shapes, via the
// vendored port in ./material, Apache-2.0): rounded polygons normalised to the
// unit square. This turns one into the path string a QtQuick.Shapes PathSvg
// draws, at a given pixel size, so it is rendered on the GPU (CurveRenderer)
// and scaled by a transform rather than repainted on a Canvas every frame.
//
//   path(kind, size)  "M … C … Z" in a size × size box
//   has(kind)         whether `kind` is one of the shapes below
//
// Kinds are the upstream names with a lower-case first letter.
// ─────────────────────────────────────────────────────────────────────────────

var _getters = {
    circle:        MaterialShapes.getCircle,
    square:        MaterialShapes.getSquare,
    slanted:       MaterialShapes.getSlanted,
    arch:          MaterialShapes.getArch,
    fan:           MaterialShapes.getFan,
    arrow:         MaterialShapes.getArrow,
    semiCircle:    MaterialShapes.getSemiCircle,
    oval:          MaterialShapes.getOval,
    pill:          MaterialShapes.getPill,
    triangle:      MaterialShapes.getTriangle,
    diamond:       MaterialShapes.getDiamond,
    clamShell:     MaterialShapes.getClamShell,
    pentagon:      MaterialShapes.getPentagon,
    gem:           MaterialShapes.getGem,
    sunny:         MaterialShapes.getSunny,
    verySunny:     MaterialShapes.getVerySunny,
    cookie4Sided:  MaterialShapes.getCookie4Sided,
    cookie6Sided:  MaterialShapes.getCookie6Sided,
    cookie7Sided:  MaterialShapes.getCookie7Sided,
    cookie9Sided:  MaterialShapes.getCookie9Sided,
    cookie12Sided: MaterialShapes.getCookie12Sided,
    ghostish:      MaterialShapes.getGhostish,
    clover4Leaf:   MaterialShapes.getClover4Leaf,
    clover8Leaf:   MaterialShapes.getClover8Leaf,
    burst:         MaterialShapes.getBurst,
    softBurst:     MaterialShapes.getSoftBurst,
    boom:          MaterialShapes.getBoom,
    softBoom:      MaterialShapes.getSoftBoom,
    flower:        MaterialShapes.getFlower,
    puffy:         MaterialShapes.getPuffy,
    puffyDiamond:  MaterialShapes.getPuffyDiamond,
    pixelCircle:   MaterialShapes.getPixelCircle,
    pixelTriangle: MaterialShapes.getPixelTriangle,
    bun:           MaterialShapes.getBun,
    heart:         MaterialShapes.getHeart
};

function has(kind) {
    return _getters.hasOwnProperty(kind);
}

var _cache = {};

function path(kind, size) {
    var key = kind + "@" + size;
    if (_cache.hasOwnProperty(key)) return _cache[key];
    var get = _getters.hasOwnProperty(kind) ? _getters[kind] : _getters.circle;
    var cubics = get().cubics;
    if (!cubics || cubics.length === 0) return "";
    function n(v) { return (Math.round(v * size * 100) / 100).toString(); }
    var c0 = cubics[0];
    var out = ["M", n(c0.anchor0X), n(c0.anchor0Y)];
    for (var i = 0; i < cubics.length; i++) {
        var c = cubics[i];
        out.push("C", n(c.control0X), n(c.control0Y), n(c.control1X), n(c.control1Y),
                 n(c.anchor1X), n(c.anchor1Y));
    }
    out.push("Z");
    return (_cache[key] = out.join(" "));
}
