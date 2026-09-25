import QtQuick
import "../../theme/motion.js" as MotionTable

// ─────────────────────────────────────────────────────────────────────────────
// PasswordShapes — what a password field shows instead of bullet dots.
//
// Each character typed adds one small geometric shape — a circle, a rounded
// square, a pill or a diamond — that grows out of a dot into its form; each
// character deleted takes the last shape away, and the row closes up behind it.
// The lock screen (src/windows/Lockscreen.qml) and the login screen
// (apex-os files/desktop/apex-greet/GreetSurface.qml, which loads this very
// file from /usr/share/apex-shell) draw it over their password fields, so the
// two are one implementation, not two that drift.
//
// ── What it knows about the secret: its LENGTH, and nothing else ────────────
// `length` is the only input. There is deliberately no `text` property, no
// signal carrying a key, and nothing here reads the field it decorates: a
// shape's kind and tone are chosen by its POSITION alone (plus a per-screen
// shuffle that is fixed before anything is typed), so the row reveals exactly
// what a row of bullet dots always revealed — how many characters there are —
// and the field itself stays a masked TextInput with passwordMaskDelay 0, so no
// character is ever drawn, even for a frame. tests/check-password-shapes.sh
// holds both halves of that.
//
// ── Motion ───────────────────────────────────────────────────────────────────
// The login screen runs before any session, so the shell's Motion singleton
// does not exist there. This file therefore reads the motion TABLE directly
// (theme/motion.js — the same numbers Motion.qml applies) and takes the user's
// three motion settings as they are stored: `speed`, `motionScale` and
// `reduced`. Both screens hand over the RAW settings and this file resolves
// them with the table's own speedScale(), so the two cannot disagree: the lock
// screen reads them from SettingsService, the login screen from what the last
// user's session published (/var/lib/apex-greet/motion/<user>).
//
//   enter   spatial surfaceEnterSmall (190 ms Balanced): the slot opens on
//           fastDecel, the shape grows from a dot on emphasizedDecel and — in
//           the same beat — morphs from a circle into its form; pills and
//           diamonds turn the last 14° into place
//   exit    spatial surfaceExitSmall (135 ms): the reverse, quicker
//   fade    effect fadeIn / fadeOut — the one thing Reduce Motion keeps: under
//           it a shape is simply there at full size and fades in over the hover
//           beat, and leaves the same way
//   several at once (a paste, clearing after a failed attempt) stagger by a
//   notification-stack step, capped, so a cleared field reads as one gesture
// Nothing overshoots and nothing loops.
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
    property int size: 14            // the box one shape is drawn in
    property int gap: 7
    // Slots built. Past what fits, the row scrolls (the newest stays in view),
    // so every keystroke still adds a shape; only a password longer than this
    // stops adding them. At 32 a 40-character passphrase went silent for its
    // last eight keys.
    property int maxShapes: 64

    implicitHeight: root.size
    implicitWidth:  row.width
    clip: true

    /// No shape is on screen any more — not merely `length` 0, but every
    /// departure finished. A field's placeholder waits for this, so "Enter
    /// password" never draws over shapes that are still leaving.
    readonly property bool empty: root._alive === 0
    property int _alive: 0

    // ── Timing, from the table ──────────────────────────────────────────────
    readonly property int tEnter: MotionTable.spatial(MotionTable.BASE.surfaceEnterSmall,
                                                      root._scale, root.reduced)
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

    // ── Shape and tone, by position only ────────────────────────────────────
    // A fixed shuffle per screen, chosen at construction — before any key —
    // so the pattern differs between sessions but never depends on input.
    readonly property int _seed: Math.floor(Math.random() * 1000)
    // Twelve steps, each kind three times, no kind next to itself — including
    // across the wrap from the last step back to the first — so a long
    // password never shows two identical shapes side by side and has no short
    // visible period. Rotated by the seed per screen.
    readonly property var _pattern: ["circle", "square", "pill", "diamond",
                                     "square", "circle", "diamond", "pill",
                                     "circle", "diamond", "square", "pill"]
    function kindAt(i) { return root._pattern[(i + root._seed) % root._pattern.length] }
    // Tone has its OWN pattern over the same twelve steps. Deriving it from
    // the same index (`(i + seed) % 3`) tied it to the shape — 3 divides 12,
    // so every square was always the pale tone and every diamond the accent —
    // which is not variation, only a colour per kind. This one gives each kind
    // all three tones and never repeats a tone side by side, wrap included.
    readonly property var _tonePattern: [0, 1, 2, 0, 2, 1, 2, 0, 2, 1, 0, 1]
    function toneAt(i) { return root._tonePattern[(i + root._seed) % root._tonePattern.length] }

    function _mix(a, b, k) {
        return Qt.rgba(a.r + (b.r - a.r) * k, a.g + (b.g - a.g) * k,
                       a.b + (b.b - a.b) * k, 1)
    }
    // Close together on purpose: variety a glance registers, never a tone that
    // reads as disabled (the busy state already owns "dimmer").
    readonly property var _tones: [root.accent,
                                   _mix(root.accent, root.text, 0.30),
                                   _mix(root.accent, root.background, 0.12)]

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
            if (s) { s.shown = true; s.p = 1; s.f = 1 }
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

    Row {
        id: row
        // Centred in the field while it fits; once full, the newest shape
        // stays in view at the right end, the way a text field scrolls.
        x: row.width <= root.width ? Math.round((root.width - row.width) / 2)
                                   : root.width - row.width
        anchors.verticalCenter: parent.verticalCenter

        Repeater {
            id: slots
            model: root.maxShapes

            delegate: Item {
                id: slot
                required property int index

                readonly property string kind: root.kindAt(slot.index)
                readonly property color tone:  root._tones[root.toneAt(slot.index)]

                property bool shown: false
                readonly property bool alive: slot.p > 0 || slot.f > 0
                onAliveChanged: root._alive += slot.alive ? 1 : -1
                // Spatial progress 0..1 (animated linearly; each derived
                // property below puts it on its own curve) and effect fade.
                property real p: 0
                property real f: 0

                // Two channels. With spatial motion on, `p` carries everything,
                // opacity included, and `f` simply stays 1 until the shape has
                // actually gone — a separate fade would run ahead of the shrink
                // and the shape would vanish before it visibly left. Under
                // Reduce Motion `p` jumps and `f` is the whole transition.
                readonly property bool spatialOn: (slot.shown ? root.tEnter : root.tExit) > 0

                function go(on, delay) {
                    slot.shown = on
                    pSeq.stop(); fAnim.stop()
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
                    // gives the slot up — it leaves the way it arrived, rather
                    // than snapping to a tilted dot in a zero-width slot.
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

                // Box sizes per kind, balanced for optical mass: a pill is
                // wider and flatter, a diamond smaller because its diagonal is
                // what the eye measures.
                readonly property real bw: slot.kind === "pill"    ? root.size * 1.18
                                         : slot.kind === "diamond" ? root.size * 0.62
                                         : slot.kind === "square"  ? root.size * 0.74
                                         :                           root.size * 0.80
                readonly property real bh: slot.kind === "pill"    ? root.size * 0.62
                                         : slot.bw
                readonly property real cellW: (slot.kind === "pill" ? root.size * 1.18 : root.size) + root.gap

                // ── Derived from p (enter reads forward, exit backward) ────
                readonly property real wP:     MotionTable.ease(MotionTable.CURVES.fastDecel, slot.p)
                readonly property real growP:  MotionTable.ease(MotionTable.CURVES.emphasizedDecel,
                                                                Math.max(0, Math.min(1, (slot.p - 0.08) / 0.92)))
                readonly property real formP:  MotionTable.ease(MotionTable.CURVES.standard,
                                                                Math.max(0, Math.min(1, (slot.p - 0.18) / 0.82)))

                width:  Math.round(slot.cellW * slot.wP)
                height: root.size

                // Once the row is wider than the field, the oldest shapes slide
                // past the left edge; each fades over its own width as it goes
                // rather than being sliced by the clip into a sliver.
                readonly property real edge: {
                    var left = slot.x + row.x
                    return left >= 0 ? 1 : Math.max(0, 1 + 2 * left / Math.max(1, slot.cellW))
                }

                Rectangle {
                    id: shape
                    anchors.centerIn: parent
                    width:  slot.bw
                    height: slot.bh
                    // Every shape starts as a dot and settles into its form.
                    radius: {
                        var round = Math.min(width, height) / 2
                        var finalR = slot.kind === "square"  ? width * 0.26
                                   : slot.kind === "diamond" ? width * 0.20
                                   : round
                        return round + (finalR - round) * slot.formP
                    }
                    color: root.error && !slot.shown ? root.danger : slot.tone
                    Behavior on color { ColorAnimation { duration: root.tState } }

                    scale:   0.22 + 0.78 * slot.growP
                    opacity: slot.f * (root.reduced ? 1 : Math.min(1, slot.p * 2.2)) * slot.edge
                    // Pills and diamonds turn a little way into place (a diamond
                    // settles at 45°); circles and squares do not — on a circle
                    // it is invisible and on a square it read as a wobble.
                    rotation: (slot.kind === "diamond" ? 45 : 0)
                              - ((slot.kind === "pill" || slot.kind === "diamond") ? 14 : 0) * (1 - slot.formP)
                    antialiasing: true
                }
            }
        }
    }

    // Nothing in here is for a screen reader: the field it decorates is the
    // accessible object (role EditableText, passwordEdit), and a second
    // announcement of the same count would be noise.
    Accessible.ignored: true
}
