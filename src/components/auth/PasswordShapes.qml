import QtQuick
import QtQuick.Shapes
import "../../theme/motion.js" as MotionTable
import "../../theme/spring.js" as Spring
import "../../shapes/materialpath.js" as MaterialPath

// ─────────────────────────────────────────────────────────────────────────────
// PasswordShapes — what a password field shows instead of bullet dots.
//
// Each character typed adds one Material 3 Expressive shape — a clover, an
// arrow, a pill, a soft burst, a diamond, a clamshell, a pentagon — that pops
// in on a spring, born in the accent and settling to the text colour; a caret
// rides after the last one. Each character deleted shrinks the last shape
// away and the row closes up behind it. After Google's own PIN entry and
// end-4's lock screen, which is modelled on it (Andre, 2026-09-27: "make lock
// pin typing animation like end4"). The shapes are Google's (AndroidX
// graphics-shapes, vendored under src/shapes/material, Apache-2.0), drawn as
// GPU paths (src/shapes/materialpath.js); the code here is Rime's own.
//
// The lock screen (src/windows/Lockscreen.qml) and the login screen (rime-os
// files/desktop/rime-greet/GreetSurface.qml, which loads this very file from
// /usr/share/rime-shell) draw it over their password fields, so the two are one
// implementation, not two that drift. Everything it imports is by relative
// path, so it loads outside the shell too.
//
// ── What it knows about the secret: its LENGTH, and nothing else ────────────
// `length` is the only input. There is deliberately no `text` property, no
// signal carrying a key, and nothing here reads the field it decorates: a
// shape's kind is chosen by its POSITION alone (plus a per-screen shuffle that
// is fixed before anything is typed), its colour by its age, and the caret by
// the count — so the row reveals exactly what a row of bullet dots always
// revealed, how many characters there are — and the field itself stays a
// masked TextInput with passwordMaskDelay 0, so no character is ever drawn,
// even for a frame. tests/check-password-shapes.sh holds both halves of that.
//
// ── Motion ───────────────────────────────────────────────────────────────────
// The login screen runs before any session, so the shell's Motion singleton
// does not exist there. This file therefore reads the motion TABLE directly
// (theme/motion.js — the same numbers Motion.qml applies) and takes the user's
// three motion settings as they are stored: `speed`, `motionScale` and
// `reduced`. Both screens hand over the RAW settings and this file resolves
// them with the table's own speedScale(), so the two cannot disagree.
//
//   enter   Material 3 Expressive "fast spatial": a spring (motion.js
//           EXPRESSIVE, damping 0.6 — about 9.5 % over) takes the shape from
//           nothing to its size, turning the last few degrees into place; the
//           slot opens on fastDecel under it, so the row makes room smoothly
//   colour  born in the accent, settling to the text colour over `settle` —
//           while typing, the last few shapes glow and fade in a trail
//   exit    spatial surfaceExitSmall: the shape shrinks away, quicker
//   fade    under Reduce Motion a shape is simply there at full size and fades
//           in over the hover beat, and leaves the same way
//   several at once (a paste, clearing after a failed attempt) stagger by a
//   notification-stack step, capped, so a cleared field reads as one gesture
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: root

    // ── Input: how many characters, never which ─────────────────────────────
    property int length: 0

    // ── Palette (the caller's own tokens) ───────────────────────────────────
    // No defaults, on purpose: both screens pass their whole palette (the lock
    // screen its Theme, the login screen its inlined greeter theme), and a
    // caller that forgot one gets a visibly wrong shape, not a plausible colour
    // from some other palette.
    property color accent
    property color text
    property color background
    property color danger

    // The last attempt was refused: the shapes that are leaving turn danger as
    // they go, which is the "no" the shake already says, in the row itself.
    property bool error: false
    // A check is in flight: the row steps back while it waits.
    property bool busy: false

    // ── Motion settings, raw (SettingsService's own three) ─────────────────
    property string speed: "balanced"
    property real motionScale: 1.0
    property bool reduced: false
    readonly property real _scale: MotionTable.speedScale(root.speed, root.motionScale)

    // ── Geometry ────────────────────────────────────────────────────────────
    property int size: 18            // the box one shape is drawn in
    property int gap: 3
    // Slots built. Past what fits, the row scrolls (the newest stays in view),
    // so every keystroke still adds a shape; only a password longer than this
    // stops adding them. At 32 a 40-character passphrase went silent for its
    // last eight keys.
    property int maxShapes: 64

    implicitHeight: root.size
    implicitWidth:  row.width + root._caretSpace
    clip: true

    /// No shape is on screen any more — not merely `length` 0, but every
    /// departure finished. A field's placeholder waits for this, so "Enter
    /// password" never draws over shapes that are still leaving.
    readonly property bool empty: root._alive === 0
    property int _alive: 0

    // ── Timing, from the table ──────────────────────────────────────────────
    readonly property var _pop: MotionTable.expressive("fastSpatial", root._scale, root.reduced)
    // The spring runs until it is within 0.2 % of its size (0.395 s Balanced).
    readonly property int tEnter: root._pop.response > 0
                                  ? Math.round(1000 * Spring.settleTime(root._pop.response, root._pop.damping, 0, 1, 0.002))
                                  : 0
    readonly property int tExit:  MotionTable.spatial(MotionTable.BASE.surfaceExitSmall,
                                                      root._scale, root.reduced)
    readonly property int tStep:  MotionTable.spatial(MotionTable.BASE.staggerStep,
                                                      root._scale, root.reduced)
    readonly property int tStaggerCap: MotionTable.spatial(MotionTable.BASE.staggerCap,
                                                           root._scale, root.reduced)
    readonly property int tFadeIn:  MotionTable.effect(root.reduced ? MotionTable.BASE.hover
                                                                    : MotionTable.BASE.fadeIn,
                                                       root._scale, root.reduced)
    readonly property int tFadeOut: MotionTable.effect(MotionTable.BASE.fadeOut,
                                                       root._scale, root.reduced)
    readonly property int tState: MotionTable.effect(MotionTable.BASE.state,
                                                     root._scale, root.reduced)
    readonly property int tSettle: MotionTable.effect(MotionTable.BASE.settle,
                                                      root._scale, root.reduced)

    // The spring's position at progress p of its run (from rest, to 1).
    function _popAt(p) {
        if (p >= 1) return 1
        if (p <= 0 || root.tEnter <= 0) return p <= 0 ? 0 : 1
        return Spring.step(0, 0, 1, root._pop.response, root._pop.damping, p * root.tEnter / 1000)[0]
    }

    // ── Shape, by position only ─────────────────────────────────────────────
    // A fixed shuffle per screen, chosen at construction — before any key —
    // so the pattern differs between sessions but never depends on input.
    readonly property int _seed: Math.floor(Math.random() * 1000)
    // Seven distinct shapes in turn (end-4's set, from the Material 3
    // Expressive library), rotated by the seed per screen: no shape ever sits
    // next to itself, across the wrap included.
    readonly property var _pattern: ["clover4Leaf", "arrow", "pill", "softBurst",
                                     "diamond", "clamShell", "pentagon"]
    function kindAt(i) { return root._pattern[(i + root._seed) % root._pattern.length] }

    // The length the row last saw, so a change of several characters at once
    // can be staggered from the right end.
    property int _prev: 0
    onLengthChanged: root._sync()
    // A field that already holds characters when this is built (the greeter
    // loads it asynchronously) shows them at once rather than replaying them.
    Component.onCompleted: {
        var n = Math.min(root.length, root.maxShapes)
        for (var i = 0; i < n; i++) {
            var s = slots.itemAt(i)
            if (s) s.settleNow()
        }
        root._prev = n
    }
    function _sync() {
        var from = root._prev, to = Math.min(root.length, root.maxShapes)
        root._prev = to
        if (to === from) return
        for (var i = 0; i < slots.count; i++) {
            var s = slots.itemAt(i)
            if (!s) continue
            var shown = i < to
            if (shown === s.shown) continue
            // Stagger: arrivals in reading order, departures from the end.
            var nth = shown ? (i - from) : (from - 1 - i)
            s.go(shown, Math.min(root.tStaggerCap, Math.max(0, nth) * root.tStep))
        }
    }

    opacity: root.busy ? 0.55 : 1
    Behavior on opacity { NumberAnimation { duration: root.tState } }

    // The caret rides after the last shape (end-4's row has one too); room for
    // it is always kept, so the row does not shift when it comes and goes.
    readonly property int _caretSpace: 2 + root.gap * 2

    Row {
        id: row
        // Centred in the field while it fits; once full, the newest shape
        // stays in view at the right end, the way a text field scrolls.
        x: row.width + root._caretSpace <= root.width
           ? Math.round((root.width - row.width - root._caretSpace) / 2)
           : root.width - row.width - root._caretSpace
        anchors.verticalCenter: parent.verticalCenter

        Repeater {
            id: slots
            model: root.maxShapes

            delegate: Item {
                id: slot
                required property int index

                readonly property string kind: root.kindAt(slot.index)

                property bool shown: false
                readonly property bool alive: slot.p > 0 || slot.f > 0
                onAliveChanged: root._alive += slot.alive ? 1 : -1
                // Spatial progress 0..1 (animated linearly; each derived
                // property below puts it on its own curve) and effect fade.
                property real p: 0
                property real f: 0

                // Born in the accent, settling to the text colour. Bound back
                // to the palette once settled, so a theme change reaches it.
                property color tint: root.text

                function settleNow() {
                    slot.shown = true; slot.p = 1; slot.f = 1
                    tintAnim.stop()
                    slot.tint = Qt.binding(function () { return root.text })
                }

                function go(on, delay) {
                    slot.shown = on
                    pSeq.stop(); fAnim.stop()
                    if (on) {
                        tintAnim.stop()
                        slot.tint = root.accent
                        tintAnim.to = root.text
                        tintAnim.duration = root.tSettle
                        tintWait.duration = delay
                        tintSeq.restart()
                    }
                    pPause.duration = delay
                    pMove.from = slot.p
                    pMove.to = on ? 1 : 0
                    var full = on ? root.tEnter : root.tExit
                    pMove.duration = Math.round(full * Math.max(0.35, Math.abs(pMove.to - slot.p)))
                    if (full > 0) {
                        pSeq.start()
                        if (on) slot.f = 1       // leaving: f drops when p lands (below)
                        return
                    }
                    // No spatial motion (Reduce Motion): the shape keeps its
                    // full form and its slot while it fades, and only then
                    // gives the slot up — it leaves the way it arrived.
                    if (on) slot.p = 1
                    fAnim.from = slot.f
                    fAnim.to = on ? 1 : 0
                    fAnim.duration = on ? root.tFadeIn : root.tFadeOut
                    if (fAnim.duration <= 0) { slot.f = fAnim.to; if (!on) slot.p = 0 }
                    else fAnim.start()
                }

                SequentialAnimation {
                    id: pSeq
                    PauseAnimation { id: pPause }
                    NumberAnimation { id: pMove; target: slot; property: "p" }
                    onFinished: if (!slot.shown && slot.p <= 0) slot.f = 0
                }
                NumberAnimation {
                    id: fAnim; target: slot; property: "f"
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: MotionTable.CURVES.effects
                    onFinished: if (!slot.shown && slot.f <= 0) slot.p = 0
                }
                SequentialAnimation {
                    id: tintSeq
                    PauseAnimation { id: tintWait }
                    ColorAnimation {
                        id: tintAnim; target: slot; property: "tint"
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: MotionTable.CURVES.effects
                    }
                    onFinished: if (slot.shown) slot.tint = Qt.binding(function () { return root.text })
                }

                readonly property real cellW: root.size + root.gap

                // ── Derived from p ─────────────────────────────────────────
                // The slot opens on fastDecel; the shape pops on the spring
                // arriving, and shrinks on an accelerating curve leaving.
                readonly property real wP:  MotionTable.ease(MotionTable.CURVES.fastDecel, slot.p)
                readonly property real pop: slot.shown ? root._popAt(slot.p)
                                                       : MotionTable.ease(MotionTable.CURVES.standardDecel, slot.p)

                width:  Math.round(slot.cellW * slot.wP)
                height: root.size

                // Once the row is wider than the field, the oldest shapes slide
                // past the left edge; each fades over its own width as it goes
                // rather than being sliced by the clip into a sliver.
                readonly property real edge: {
                    var left = slot.x + row.x
                    return left >= 0 ? 1 : Math.max(0, 1 + 2 * left / Math.max(1, slot.cellW))
                }

                // Built when first needed: 64 idle paths are not drawn or kept.
                Loader {
                    anchors.centerIn: parent
                    active: slot.shown || slot.alive
                    sourceComponent: Shape {
                        width:  root.size
                        height: root.size
                        preferredRendererType: Shape.CurveRenderer
                        scale:   Math.max(0, slot.pop)
                        // The last few degrees into place, carried past zero a
                        // little by the spring's overshoot.
                        rotation: slot.shown ? -18 * (1 - slot.pop) : 0
                        opacity: slot.f * (root.reduced ? 1 : Math.min(1, slot.p * 6)) * slot.edge
                        ShapePath {
                            strokeWidth: -1
                            fillColor: root.error && !slot.shown ? root.danger : slot.tint
                            PathSvg { path: MaterialPath.path(slot.kind, root.size) }
                        }
                    }
                }
            }
        }
    }

    // The caret: after the last shape, in the accent, while there are any.
    Rectangle {
        id: caret
        width: 2
        height: Math.round(root.size * 0.9)
        radius: 1
        x: row.x + row.width + root.gap
        anchors.verticalCenter: parent.verticalCenter
        color: root.accent
        opacity: root.length > 0 && !root.busy ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: root.tFadeIn } }
    }

    // Nothing in here is for a screen reader: the field it decorates is the
    // accessible object (role EditableText, passwordEdit), and a second
    // announcement of the same count would be noise.
    Accessible.ignored: true
}
