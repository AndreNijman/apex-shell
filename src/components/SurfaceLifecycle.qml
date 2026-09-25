import QtQuick
import "../"

// ─────────────────────────────────────────────────────────────────────────────
// SurfaceLifecycle — Closed → Opening → Open → Closing, driven by progress.
//
// Every transient surface used to keep its window mapped through its own close
// animation with a timer: `interval: Theme.animDuration + 20`. That made a
// window's lifetime a GUESS about how long its slowest animation takes, and
// every surface carried its own copy of the guess. Reopening inside the close
// needed a guard on the timer; a new animation longer than the guess would be
// cut off by an unmap; and nothing could tell a surface "you are 40% open".
//
// This object is the one clock a surface — and the bar notch it grows out of —
// runs on:
//
//   progress   0..1, SPATIAL. Shape geometry is a pure function of it. It
//              animates from wherever it is, so reversing half-way through an
//              open or a close continues from the current shape with no jump.
//              Under Reduce Motion it jumps (its durations are spatial tokens):
//              to 1 on open, and to 0 on close only once `alpha` has faded —
//              the surface leaves as its finished shape, not as whatever its
//              progress-0 geometry is (for a pour, nothing at all).
//   content    0..1, the content inside the surface. It arrives a beat after
//              the body starts moving and leaves ahead of it, on effect tokens,
//              so it survives Reduce Motion as a short fade.
//   alpha      0..1, EFFECT. The surface's own opacity for the case where there
//              is no spatial motion to show it arriving: 1 while spatial motion
//              is on, a short fade under Reduce Motion.
//   mapped     the window must exist. True from the moment `open` goes true
//              until every value above has actually reached 0 — completion, not
//              a timer — so the unmap can never cut an animation short and can
//              never come late.
//   phase      Closed | Opening | Open | Closing, for code that needs to know.
//
// Usage:
//     SurfaceLifecycle { id: life; open: Popups.networkOpen }
//     PanelWindow { visible: life.mapped; … }
//
// It observes `open` from construction, so a popup that a LazyPopup builds BY
// its flag flipping true starts opening on its own; it needs no applyOpenState.
// ─────────────────────────────────────────────────────────────────────────────
QtObject {
    id: life

    // ── Input ────────────────────────────────────────────────────────────────
    property bool open: false

    // ── Timing (Motion roles; override per surface family) ───────────────────
    property int enterDuration: Motion.morphEnter
    property int exitDuration:  Motion.morphExit
    // Linear on the way in: a connected surface's shape puts each of its
    // parameters on its own curve (geometry.js), so progress itself must not
    // be eased as well. On the way out the whole parameter set is played back
    // on fastDecel — a fast start and a soft landing — which is what makes the
    // exit shorter and different in character without a second shape.
    property var enterCurve:    Motion.linear
    property var exitCurve:     Motion.fastDecel

    // Content choreography: how long after the body starts the content begins,
    // and how long its fades take. The delay is choreography and vanishes with
    // Reduce Motion (there is no body motion to wait for); so does most of the
    // fade, down to the hover beat, which is all a change needs to be seen.
    property int contentDelay:   Motion.contentDelay
    property int contentIn:      Motion.reduced ? Motion.hover : Motion.fadeIn
    property int contentOut:     Motion.fadeOut

    // A reversal takes the share of the full duration that is left to travel,
    // with a floor, so a surface reopened at 90% closed still reads as an
    // opening rather than a flicker.
    property real minFraction: 0.35

    // ── Output ───────────────────────────────────────────────────────────────
    property real progress: 0
    property real content:  0
    property real alpha:    0

    readonly property bool mapped: life.open || life._settling
                                   || life.progress > 0 || life.content > 0 || life.alpha > 0

    readonly property string phase: {
        if (!life.mapped) return "Closed"
        if (life.open) return (life.progress >= 1 && !life._pAnim.running) ? "Open" : "Opening"
        return "Closing"
    }

    // True from a close starting until it has finished (or been reversed).
    // For a binding that must react to the direction: reading `open` from a
    // binding that also reads `alpha` is a binding loop — evaluating `open`
    // there runs _drive(), which writes `alpha` (measured on the spills'
    // opacity). This reads a plain flag that _drive() sets, with no effects.
    readonly property bool closing: life._settling

    signal opened()
    signal closed()

    // ── Internals ────────────────────────────────────────────────────────────
    // True between a close starting and every animation finishing. `mapped`
    // cannot be derived from the values alone: a close begins from progress 1
    // and there is one frame before the animation moves it.
    property bool _settling: false
    property bool _announced: false

    property NumberAnimation _pAnim: NumberAnimation {
        target: life; property: "progress"
        easing.type: Easing.BezierSpline
        onFinished: life._check()
    }
    property SequentialAnimation _cAnim: SequentialAnimation {
        PauseAnimation   { id: cDelay }   // duration set before every start
        NumberAnimation  {
            id: cMove
            target: life; property: "content"
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Motion.effects
        }
        onFinished: life._check()
    }
    property NumberAnimation _aAnim: NumberAnimation {
        target: life; property: "alpha"
        easing.type: Easing.BezierSpline
        easing.bezierCurve: Motion.effects
        onFinished: life._check()
    }

    function _dur(full, from, to) {
        var dist = Math.abs(to - from)
        if (full <= 0 || dist <= 0) return 0
        return Math.round(full * Math.max(life.minFraction, dist))
    }

    function _run(anim, from, to, ms) {
        anim.stop()
        if (ms <= 0 || from === to) {
            anim.target[anim.property] = to
            return false
        }
        anim.from = from
        anim.to = to
        anim.duration = ms
        anim.start()
        return true
    }

    function _drive() {
        var to = life.open ? 1 : 0
        // A close and a reopen in the same tick — `closeAll()` followed by the
        // next surface's flag, with one lifecycle shared by both — must be a
        // no-op, not a close that is still "settling" underneath an open one.
        life._settling = !life.open
        life._announced = false
        var spatial = (life.open ? life.enterDuration : life.exitDuration) > 0

        // Body. With no spatial motion a close HOLDS the shape: it fades out
        // whole and drops to 0 in _check once alpha has gone (brief B.10:
        // "exits opacity … then unmap").
        life._pAnim.easing.bezierCurve = life.open ? life.enterCurve : life.exitCurve
        if (spatial || life.open)
            life._run(life._pAnim, life.progress, to,
                      life._dur(life.open ? life.enterDuration : life.exitDuration, life.progress, to))
        else
            life._pAnim.stop()

        // Surface opacity. While spatial motion is on, the body is opaque for
        // its whole life — it arrives and leaves by changing shape, and closed()
        // drops alpha only once it has finished. With no spatial motion (Reduce
        // Motion) the shape is simply there, and a short fade is how it arrives.
        if (spatial) {
            life._aAnim.stop()
            life.alpha = 1
        } else {
            life._run(life._aAnim, life.alpha, to,
                      life._dur(life.open ? life.contentIn : life.contentOut, life.alpha, to))
        }

        // Content: delayed on the way in (only from fully closed), immediate
        // and quicker on the way out.
        life._cAnim.stop()
        var cFrom = life.content
        if (cFrom === to) {
            life.content = to
        } else {
            cDelay.duration = (life.open && cFrom === 0) ? life.contentDelay : 0
            cMove.from = cFrom
            cMove.to = to
            cMove.duration = life._dur(life.open ? life.contentIn : life.contentOut, cFrom, to)
            if (cMove.duration <= 0 && cDelay.duration <= 0) life.content = to
            else life._cAnim.start()
        }
        life._check()
    }

    function _check() {
        var busy = life._pAnim.running || life._cAnim.running || life._aAnim.running
        if (busy) return
        if (life.open) {
            if (life.progress >= 1 && !life._announced) {
                life._announced = true
                life.opened()
            }
            return
        }
        // Closing and nothing left moving: make sure every value is at rest
        // (a zero-duration run sets it directly), then release the window.
        if (life._settling) {
            // A shape held through a Reduce Motion fade goes once it is unseen.
            if (life.progress > 0 && life.alpha <= 0 && life.exitDuration <= 0)
                life.progress = 0
            if (life.progress <= 0 && life.content <= 0) {
                life.alpha = 0
                life._settling = false
                life.closed()
            }
        }
    }

    onOpenChanged: life._drive()
    Component.onCompleted: if (life.open) life._drive()
}
