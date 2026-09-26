import QtQuick
import "../"

// ─────────────────────────────────────────────────────────────────────────────
// SurfaceLifecycle — Closed → Opening → Open → Closing, driven by springs.
//
// Every transient surface used to keep its window mapped through its own close
// animation with a timer: `interval: Theme.animDuration + 20`. That made a
// window's lifetime a GUESS about how long its slowest animation takes, and
// every surface carried its own copy of the guess. This object is the one clock
// a surface — and the bar notch it grows out of — runs on.
//
// ── Why springs (2026-09-26) ────────────────────────────────────────────────
// Andre: "everything goes way too quick and doesn't feel liquid and fluid, i
// want real apple level animation." The body used to run 240 ms on a fixed
// curve. A curve has one shape whatever came before it: reversed half-way it
// restarted from rest and the shape stopped dead. The body is now a damped
// spring (Spring.qml). A reversal carries the velocity it had into the new
// direction, so the shape bends back; and it lands on a long soft tail.
//
// ── Outputs ─────────────────────────────────────────────────────────────────
//   progress   0..1, SPATIAL: the body channel, clamped. Geometry that is a
//              function of one value reads it. Under Reduce Motion it jumps
//              (its durations are spatial tokens): to 1 on open, and to 0 on
//              close only once `alpha` has faded — the surface leaves as its
//              finished shape, not as its progress-0 geometry.
//   lead, body, trail
//              the three LIQUID channels (only distinct with `liquid: true`;
//              otherwise all three are the body). Raw spring values: with a
//              damping below 1 they pass 1 by a hair before settling, and the
//              geometry soft-caps that into a visible swell of a few pixels.
//                lead   moves first on the way in (a bloom's width, a pour's
//                       depth) and leaves LAST — it is the part touching the bar.
//                body   follows once the lead has crossed `openRelease`; on the
//                       way out it leaves first, and the lead follows once the
//                       body is below `closeRelease`.
//                trail  a critically damped follower of the body: radii,
//                       shoulders, fillets. It lags a few frames and settles
//                       last, which is what reads as liquid rather than rubber.
//   velocity, leadVelocity, bodyFlow, leadFlow
//              the body's and the lead's speed: in 1/s, and as FLOW, relative
//              to a nominal open's peak (about 1 at the fastest, 0 at rest) —
//              for secondary motion proportional to speed (a bowing edge).
//   content    0..1, the content inside the surface. It arrives once the body
//              has substance (`contentAt`) and leaves ahead of it, on effect
//              tokens, so it survives Reduce Motion as a short fade.
//   alpha      0..1, EFFECT. The surface's own opacity for the case where there
//              is no spatial motion to show it arriving: 1 while spatial motion
//              is on, a short fade under Reduce Motion.
//   mapped     the window must exist. True from the moment `open` goes true
//              until every value above has actually reached 0 — completion, not
//              a timer — so the unmap can never cut an animation short.
//   phase      Closed | Opening | Open | Closing. "Open" is PERCEPTUAL: the lead
//              and the body have both crossed 98 %. A spring's last fraction of
//              a pixel takes as long again as the rest, and pages that start
//              their services on Open must not wait for it. A close releases
//              the window at a visual zero (0.4 %, sub-pixel) the same way.
//
// ── The first frame ─────────────────────────────────────────────────────────
// Mapping a window takes a while — Quickshell builds a new backing window on
// every map, and the compositor needs a commit — 50 to 150 ms on the L16. A
// clock that started when `open` flipped had the body a third grown before its
// first frame reached the screen: the notch did not grow, a big shape simply
// appeared (Andre, 2026-09-26: "the middle notch fades away and a big rectangle
// appears"). Give the lifecycle `surface` — any item in the surface's window —
// and the springs hold at 0, where the body IS the notch, until that window
// has swapped a frame since it mapped. Every open starts from the notch.
//
// Usage:
//     SurfaceLifecycle { id: life; open: Popups.networkOpen; surface: body }
//     PanelWindow { visible: life.mapped; … }
//
// It observes `open` from construction, so a popup that a LazyPopup builds BY
// its flag flipping true starts opening on its own; it needs no applyOpenState.
// ─────────────────────────────────────────────────────────────────────────────
QtObject {
    id: life

    // ── Input ────────────────────────────────────────────────────────────────
    property bool open: false
    // Names the surface in the frame-pacing log (Motion.pacingLog, Phase 22).
    property string name: ""
    // An item in the surface's window: the springs wait for its first frame.
    property Item surface: null

    // ── Timing (Motion roles; override per surface family) ───────────────────
    // The body spring's response, in ms: about when the change looks finished.
    // 0 is "no spatial motion" (Reduce Motion, or motion off) and snaps.
    property int enterDuration: Motion.morphEnter
    property int exitDuration:  Motion.morphExit
    // Damping fractions. 1 lands without overshoot. `progress` is clamped, so
    // a non-liquid surface keeps 1 (an overshoot would read as a flat spot).
    property real enterDamping: 1.0
    property real exitDamping:  1.0

    // ── Liquid channels (opt-in) ─────────────────────────────────────────────
    // Responses are fractions of enterDuration / exitDuration, so the speed
    // setting and Reduce Motion (0) reach them with no extra wiring.
    property bool liquid: false
    property real leadIn:    0.72     // × enterDuration
    property real bodyIn:    0.92
    property real leadOut:   0.70     // × exitDuration
    property real bodyOut:   0.80
    property real trailScale: 0.80    // × whichever duration applies
    property real leadDamping: 0.84   // opening; closing is always critical
    property real bodyDamping: 0.80
    property real openRelease:  0.12  // the body starts once the lead is here
    property real closeRelease: 0.35  // the lead leaves once the body is here

    // Content choreography. With spatial motion and a delay, the content starts
    // once the body is `contentAt` open — it arrives when there is something
    // to arrive in, however long the window took to show. `contentDelay` 0
    // means "with the body" (menus, dialogs). Under Reduce Motion there is no
    // body motion to wait for and most of the fade goes too.
    property int contentDelay:   Motion.contentDelay
    property real contentAt:     0.30
    property int contentIn:      Motion.reduced ? Motion.hover : Motion.fadeIn
    property int contentOut:     Motion.fadeOut

    // A content or alpha fade reversed part-way takes the share of its full
    // duration that is left to travel, with a floor. (The body needs no such
    // rule: the springs' velocity is the continuity.)
    property real minFraction: 0.35

    // ── Output ───────────────────────────────────────────────────────────────
    readonly property real progress: Math.max(0, Math.min(1, life._body.value))
    readonly property real body:  life._body.value
    readonly property real lead:  life.liquid ? life._lead.value  : life._body.value
    readonly property real trail: life.liquid ? life._trail.value : life._body.value
    readonly property real velocity:     life._body.velocity
    readonly property real leadVelocity: life.liquid ? life._lead.velocity : life._body.velocity
    // FLOW: speed relative to the peak of a nominal open — a critically damped
    // spring from rest peaks at 2π/(e·response) ≈ 2.3/response — so about 1 at
    // the fastest and exactly 0 at rest. geometry.js bends edges by it.
    readonly property real bodyFlow: life._body.response > 0
                                     ? life._body.velocity * life._body.response / 2.3 : 0
    readonly property real leadFlow: !life.liquid ? life.bodyFlow
                                     : life._lead.response > 0
                                       ? life._lead.velocity * life._lead.response / 2.3 : 0
    property real content:  0
    property real alpha:    0

    readonly property bool mapped: life.open || life._settling
                                   || life.progress > 0 || life.content > 0 || life.alpha > 0
                                   || (life.liquid && (life._lead.value > 0 || life._trail.value > 0))

    readonly property string phase: {
        if (!life.mapped) return "Closed"
        if (life.open) return life._arrived ? "Open" : "Opening"
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
    // and there is one frame before the springs move it.
    property bool _settling: false
    property bool _announced: false
    // Open: perceptually there (see `phase`). Set by _onStep, never by a timer.
    property bool _arrived: false
    // The content fade is waiting for the body to reach `contentAt`.
    property bool _contentPending: false

    // ── Springs ──────────────────────────────────────────────────────────────
    property Spring _body: Spring {
        epsilon: 0.0005
        onValueChanged: life._onStep()
        onSettled: { life._onStep(); life._check() }
    }
    property Spring _lead: Spring {
        epsilon: 0.0005
        onValueChanged: if (life.liquid) life._onStep()
        onSettled: if (life.liquid) { life._onStep(); life._check() }
    }
    // A follower: its target is wherever the body is right now.
    property Spring _trail: Spring {
        epsilon: 0.0005
        target: life.liquid ? life._body.value : 0
        dampingFraction: 1.0
        onValueChanged: if (life.liquid) life._onStep()
        onSettled: if (life.liquid) { life._onStep(); life._check() }
    }
    function _anyRunning() {
        return life._body.running || (life.liquid && (life._lead.running || life._trail.running))
    }
    function _snapAll(to) {
        life._body.target = to; life._body.snap()
        life._lead.target = to; life._lead.snap()
        life._trail.snap()      // its target follows the body's value
    }

    // ── The first frame ──────────────────────────────────────────────────────
    readonly property var _win: life.surface ? life.surface.Window.window : null
    property bool _presented: false
    // A new backing window (Quickshell builds one per map) has shown nothing.
    on_WinChanged: life._presented = false
    onMappedChanged: {
        if (!life.mapped) life._presented = false
        // For tests/visual/stress-matrix.sh: every map and unmap, by name.
        if (Motion.pacingLog)
            console.info("APEX pacing: " + (life.name || "surface") + " mapped=" + life.mapped)
    }
    property Connections _firstFrame: Connections {
        target: (life.surface && !life._presented) ? life._win : null
        ignoreUnknownSignals: true
        function onFrameSwapped() {
            if (Motion.pacingLog && life.open)
                console.info("APEX pacing: " + (life.name || "surface") + " first-frame ms="
                             + (Date.now() - life._openedAt))
            life._presented = true
        }
    }
    property real _openedAt: 0
    readonly property bool _ready: !life.surface || life._presented
    on_ReadyChanged: if (life._ready && life.open) life._drive()
    // Never hold longer than this for a window that does not report frames.
    property Timer _presentGuard: Timer {
        interval: 250
        onTriggered: if (life.open && !life._presented) life._presented = true
    }

    // Perceptual thresholds, checked on every step.
    readonly property real _nearOpen:   0.98
    readonly property real _nearClosed: 0.004
    readonly property real _still:      0.35
    function _atOpen() {
        return life._body.value >= life._nearOpen
               && (!life.liquid || life._lead.value >= life._nearOpen)
    }
    function _atClosed() {
        function low(sp) { return sp.value <= life._nearClosed && Math.abs(sp.velocity) < life._still }
        return low(life._body) && (!life.liquid || (low(life._lead) && low(life._trail)))
    }

    function _onStep() {
        var spatial = (life.open ? life.enterDuration : life.exitDuration) > 0
        if (life.liquid && spatial && life._ready) {
            // Sequencing, evaluated both ways so a reversal resumes it.
            if (life.open && life._body.target < 1 && life._lead.value >= life.openRelease)
                life._body.target = 1
            if (!life.open && life._lead.target > 0 && life._body.value <= life.closeRelease)
                life._lead.target = 0
        }
        if (life.open) {
            if (life._contentPending && life._ready && life.progress >= life.contentAt) life._startContent()
            if (!life._arrived && life._atOpen()) {
                life._arrived = true
                life._check()
            }
        } else if (life._settling && life._anyRunning() && life._atClosed()) {
            life._snapAll(0)
            life._check()
        }
    }

    // ── Frame pacing (UI/UX Phase 22) ─────────────────────────────────────────
    // Frames DELIVERED during an open or a close, not what each cost to render:
    // a FrameAnimation ticks once per frame the animation driver advances, so
    // its count against the wall-clock duration is the miss count, and the
    // longest gap between ticks is the worst hitch. Logged when the phase ends:
    //     APEX pacing: <name> <Opening|Closing> ms=<n> frames=<n> worst=<ms>
    //                  at=<where the worst gap ended, 0..1 of the phase> first=<ms>
    // `first` is the wait for the first frame after the phase began: a surface
    // that builds its content or starts a process as it opens pays it there.
    // Only while Motion.pacingLog: with it off, this never runs.
    property FrameAnimation _pace: FrameAnimation {
        running: Motion.pacingLog && (life.phase === "Opening" || life.phase === "Closing")
        property real t0: 0
        property real last: 0
        property int n: 0
        property real worst: 0
        property real worstT: 0
        property real first: -1
        property string ph: ""
        onRunningChanged: {
            if (running) {
                t0 = Date.now(); last = t0; n = 0; worst = 0; worstT = t0; first = -1; ph = life.phase
            } else if (n > 0) {
                const span = Math.max(1, last - t0)
                console.info("APEX pacing: " + (life.name || "surface") + " " + ph
                             + " ms=" + Math.round(last - t0) + " frames=" + n
                             + " worst=" + Math.round(worst)
                             + " at=" + ((worstT - t0) / span).toFixed(2)
                             + " first=" + Math.round(first))
            }
        }
        onTriggered: {
            const now = Date.now()
            if (first < 0) first = now - t0
            if (now - last > worst) { worst = now - last; worstT = now }
            last = now
            n++
        }
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

    // The content fade toward the current direction, from wherever it is.
    function _startContent() {
        life._contentPending = false
        life._cAnim.stop()
        var to = life.open ? 1 : 0
        var cFrom = life.content
        if (cFrom === to) { life.content = to; return }
        cDelay.duration = 0
        cMove.from = cFrom
        cMove.to = to
        cMove.duration = life._dur(life.open ? life.contentIn : life.contentOut, cFrom, to)
        if (cMove.duration <= 0) life.content = to
        else life._cAnim.start()
    }

    function _retarget() {
        var L = life._lead, B = life._body
        if (life.open) {
            if (life.liquid) {
                L.target = 1
                if (L.value >= life.openRelease) B.target = 1
            } else {
                B.target = 1
            }
        } else {
            B.target = 0
            if (life.liquid && B.value <= life.closeRelease) L.target = 0
        }
    }

    function _drive() {
        var to = life.open ? 1 : 0
        // A close and a reopen in the same tick — `closeAll()` followed by the
        // next surface's flag, with one lifecycle shared by both — must be a
        // no-op, not a close that is still "settling" underneath an open one.
        life._settling = !life.open
        life._announced = false
        var spatial = (life.open ? life.enterDuration : life.exitDuration) > 0

        // Spring parameters for this direction, applied at the retarget: the
        // closed form carries position and velocity across, so it is continuous.
        var dur = (life.open ? life.enterDuration : life.exitDuration) / 1000
        var B = life._body, L = life._lead
        if (life.open) {
            B.response = dur * (life.liquid ? life.bodyIn : 1)
            B.dampingFraction = life.liquid ? life.bodyDamping : life.enterDamping
            L.response = dur * life.leadIn
            L.dampingFraction = life.leadDamping
        } else {
            B.response = dur * (life.liquid ? life.bodyOut : 1)
            B.dampingFraction = life.exitDamping
            L.response = dur * life.leadOut
            L.dampingFraction = life.exitDamping
        }
        life._trail.response = dur * life.trailScale

        // Body. With no spatial motion a close HOLDS the shape: it fades out
        // whole and drops to 0 in _check once alpha has gone (brief B.10:
        // "exits opacity … then unmap"). With it, the springs are retargeted
        // from wherever they are, at whatever speed they have — once the
        // window has a frame on screen.
        if (!spatial) {
            if (life.open) life._snapAll(1)
        } else if (life.open && !life._ready) {
            life._presentGuard.restart()
        } else {
            life._retarget()
        }
        // Perceptually there already (a close and a reopen in one tick): Open
        // stays Open. Otherwise arrival is _onStep's to decide.
        life._arrived = life.open && life._atOpen()

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

        // Content: on the way in it waits for the window's first frame and, if
        // the surface asked for a delay, for the body to have substance; on the
        // way out it leaves at once, quicker.
        life._cAnim.stop()
        life._contentPending = false
        if (life.open && life.content < 1
                && (!life._ready || (spatial && life.contentDelay > 0 && life.progress < life.contentAt)))
            life._contentPending = true
        else
            life._startContent()
        life._check()
    }

    function _check() {
        // An open is done when the body has ARRIVED (perceptually) and the
        // effects have finished; the springs may still be settling their last
        // fraction of a pixel. A close waits for every spring to stop.
        var busy = life._cAnim.running || life._aAnim.running || life._contentPending
                   || (!life.open && life._anyRunning())
        if (busy) return
        if (life.open) {
            if (life._arrived && !life._announced) {
                life._announced = true
                life.opened()
            }
            return
        }
        // Closing and nothing left moving: make sure every value is at rest,
        // then release the window.
        if (life._settling) {
            // A shape held through a Reduce Motion fade goes once it is unseen.
            if (life.progress > 0 && life.alpha <= 0 && life.exitDuration <= 0)
                life._snapAll(0)
            if (life.progress <= 0 && life.content <= 0
                    && (!life.liquid || (life._lead.value <= 0 && life._trail.value <= 0))) {
                life.alpha = 0
                life._settling = false
                life.closed()
            }
        }
    }

    onOpenChanged: {
        if (life.open) life._openedAt = Date.now()
        life._drive()
    }
    Component.onCompleted: if (life.open) { life._openedAt = Date.now(); life._drive() }
}
