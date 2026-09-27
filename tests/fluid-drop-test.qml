import QtQuick
import QtTest
import "shapes/fluid"
import "shapes/fluid/geometry.js" as Geo

// ─────────────────────────────────────────────────────────────────────────────
// FluidDrop — the Nexus's extrusion shader, held to the field it claims to draw.
//
// The extrusion is computed twice: geometry.js notchExtrudeField/dropField (what
// tests/fluid-geometry-test.js checks for continuity, bounds and rest states)
// and shapes/fluid/fluiddrop.frag (what the screen shows). Nothing else ties
// them together, so this renders the REAL shader, white on black, at the
// states the extrusion passes through and compares every sampled pixel with the
// coverage the JavaScript field predicts: clearly inside must be lit, clearly
// outside must be dark, the edge within one pixel of antialiasing.
//
// It must run where shaders do: tests/run-fluid-drop-test.sh starts it on a
// private headless compositor (the offscreen platform is the software scene
// graph, where ShaderEffect draws nothing and FluidDrop falls back to plain
// rectangles).
// A shader that did not load would draw nothing and the Nexus would open as a
// scrim and floating text — so "it rendered" is asserted, not assumed.
// ─────────────────────────────────────────────────────────────────────────────
TestCase {
    id: tc
    name: "FluidDrop"
    when: windowShown
    width: 1000; height: 720

    readonly property var g: ({ cx: 500, notchW: 300, notchH: 40, notchBottom: 14,
                                card: { x: 200, y: 230, w: 600, h: 420 }, r: 28 })

    // Pixels are read back through grabToImage and a Canvas: TestCase's own
    // grabImage returns a blank white window on a Wayland platform (measured
    // on the headless labwc), which would make every check here meaningless.
    Canvas {
        id: reader
        width: tc.width; height: tc.height
        renderTarget: Canvas.Image
        renderStrategy: Canvas.Immediate
    }

    Rectangle {
        id: stage
        width: 1000; height: 720
        color: "black"
        FluidDrop {
            id: drop
            anchors.fill: parent
            color: "white"
            geometry: tc.g
            channels: ({ w: 0, d: 0, n: 0 })
        }
    }

    // The states the extrusion passes through (lead, body, trail) — among
    // them the bell over the spreading sheet, where all three blends (the
    // notch's meniscus, the bell's, the waist's) are at work at once.
    readonly property var states: [
        { name: "the notch sagging",                  ch: { w: 0.1,  d: 0,    n: 0 } },
        { name: "a bulb on its neck",                 ch: { w: 0.5,  d: 0,    n: 0 } },
        { name: "the sheet spreading under the bell", ch: { w: 0.9,  d: 0.35, n: 0.1 } },
        { name: "the window forming, neck thinning",  ch: { w: 1,    d: 0.7,  n: 0.35 } },
        { name: "the neck drawing back",              ch: { w: 1,    d: 0.95, n: 0.7 } },
        { name: "closing: the neck on the mass",      ch: { w: 1,    d: 0.2,  n: 0.45 } },
        { name: "at rest, open",                      ch: { w: 1,    d: 1,    n: 1 } }
    ]

    function renderAt(ch) {
        drop.channels = ch
        wait(50)          // a frame or two for the uniforms to reach the GPU
        let res = null
        verify(stage.grabToImage(function (r) { res = r }), "the scene graph took the grab")
        tryVerify(function () { return res !== null }, 3000, "the grab arrived")
        reader.loadImage(res.url)
        tryVerify(function () { return reader.isImageLoaded(res.url) && reader.available }, 3000, "read back")
        const ctx = reader.getContext("2d")
        ctx.clearRect(0, 0, tc.width, tc.height)
        ctx.drawImage(res.url, 0, 0)
        const data = ctx.getImageData(0, 0, tc.width, tc.height).data
        reader.unloadImage(res.url)
        const w = tc.width
        return { red: function (x, y) { return data[(y * w + x) * 4] } }
    }

    function test_0_the_shader_runs() {
        verify(GraphicsInfo.api !== GraphicsInfo.Software,
               "a hardware scene graph (the software one cannot run shaders): api " + GraphicsInfo.api)
        compare(drop.shader.status, ShaderEffect.Compiled, "the shader loaded: " + drop.shader.log)
        verify(drop.shaded, "FluidDrop draws with the shader, not the fallback")
    }

    function test_1_parity_with_the_field() {
        // One field unit per pixel: the private output is at scale 1, and
        // the read-back canvas is in the same units.
        compare(Screen.devicePixelRatio, 1, "the headless output is at scale 1")
        const dpr = 1
        for (let s = 0; s < tc.states.length; s++) {
            const st = tc.states[s]
            const img = renderAt(st.ch)
            const f = Geo.notchExtrudeField(0, Object.assign({}, tc.g, { ch: st.ch }))
            let inside = 0, outside = 0, wrongIn = [], wrongOut = [], wrongEdge = []
            for (let y = 1.5; y < tc.height; y += 3) {
                for (let x = 1.5; x < tc.width; x += 3) {
                    const got = img.red(Math.floor(x), Math.floor(y)) / 255
                    const d = y < tc.g.notchH ? 1e5 : Geo.dropField(f, x, y)
                    if (d <= -1) {
                        inside++
                        if (got < 0.9) wrongIn.push(x + "," + y + " got " + got.toFixed(2))
                    } else if (d >= 1) {
                        outside++
                        if (got > 0.1) wrongOut.push(x + "," + y + " got " + got.toFixed(2))
                    } else {
                        const want = Math.min(1, Math.max(0, 0.5 - d * dpr))
                        if (Math.abs(got - want) > 0.3) wrongEdge.push(x + "," + y + " got " + got.toFixed(2) + " want " + want.toFixed(2))
                    }
                }
            }
            verify(inside > 20, st.name + ": the field has an inside to compare (" + inside + ")")
            verify(outside > 1000, st.name + ": and an outside (" + outside + ")")
            compare(wrongIn.length, 0, st.name + ": clearly inside the field is lit: " + wrongIn.slice(0, 4).join("; "))
            compare(wrongOut.length, 0, st.name + ": clearly outside the field is dark: " + wrongOut.slice(0, 4).join("; "))
            compare(wrongEdge.length, 0, st.name + ": the edge is the field's, within antialiasing: " + wrongEdge.slice(0, 4).join("; "))
        }
    }

    function test_2_nothing_above_the_seam() {
        // The notch box reaches far above the seam; above it is the bar's notch.
        const img = renderAt({ w: 0.6, d: 0, n: 0 })
        const f = Geo.notchExtrudeField(0, Object.assign({}, tc.g, { ch: { w: 0.6, d: 0, n: 0 } }))
        verify(Geo.dropField(f, tc.g.cx, tc.g.notchH - 10) < -5, "the field IS inside above the seam (so this can fail)")
        let lit = 0
        for (let x = 300; x < 700; x += 2)
            for (let y = 0; y < tc.g.notchH - 1; y += 2)
                if (img.red(x, y) > 10) lit++
        compare(lit, 0, "no pixel above the seam")
    }

    function test_3_closed_draws_nothing() {
        const img = renderAt({ w: 0, d: 0, n: 0 })
        let lit = 0
        for (let y = 0; y < tc.height; y += 4)
            for (let x = 0; x < tc.width; x += 4)
                if (img.red(x, y) > 10) lit++
        compare(lit, 0, "closed, the extrusion draws nothing at all")
    }
}
