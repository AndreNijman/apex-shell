import QtQuick
import "../"

// ─────────────────────────────────────────────────────────────────────────────
// LazyPage — a page that is not built until it is first looked at.
//
// The dashboard used to instantiate every page eagerly, per screen: the home
// cards, the full stats grid, the Kanban board, the launcher, and the whole
// config tree with all of its sub-pages, all constructed at shell startup
// whether or not the dashboard was ever opened. On a two-monitor machine that
// was two of everything.
//
// ── Why it keeps the instance once built ────────────────────────────────────
// `active` latches on first reveal and never goes back to false. Unloading on
// hide would also be valid and would return the memory, but it throws away page
// state that users notice: Kanban scroll offset, which config sub-page you were
// on, a half-typed card title. The expensive part of a page is not its existence
// but its *pollers*, and those are handled properly by ServiceRef gating on
// actual on-screen state — so a built-but-hidden page costs essentially nothing.
//
// Pair the two: LazyPage for construction cost, ServiceRef for running cost.
//
// ── Changing page (UI/UX roadmap v3 Phase 7) ─────────────────────────────────
// A page that becomes current arrives from the side it comes from and a page
// that stops being current leaves toward the other — `direction` is +1 when
// the new page is further along the owner's order and -1 when it is before —
// travelling only Motion.pageTravel px while it cross-fades, over the page
// token. A switch in the middle of another continues from where the page is,
// never from its start. Under Reduce Motion the travel is 0 and the
// cross-fade is all that is left. The page that has just been built by its
// first reveal simply appears: there is nothing for it to have come from.
//
// An `anchored` page (the launcher) does not travel at all: it is there, whole,
// the moment it is chosen — its search field is the anchor and must take
// typing from the first frame — and it leaves by fading where it stands. Such a
// page reveals its own content (AppLauncher's results).
// ─────────────────────────────────────────────────────────────────────────────

Loader {
    id: root

    // Whether this page is the selected one right now.
    required property bool shown

    // +1 = the page being arrived at lies later in the owner's order. Set by
    // the owner at the moment it changes page, before `shown` flips.
    property int direction: 1

    // Present at once, no travel; see the header.
    property bool anchored: false

    // Build ahead of the first visit, in the background: an asynchronous load
    // that does not block the thread, so the visit that would have paid for
    // the build (the launcher's was ~300 ms at capture scale) finds the page
    // ready. A page chosen before the background build has finished is built
    // at once, as it always was.
    property bool prewarm: false

    property bool _everShown: false
    property bool _leaving: false
    property real _offset: 0

    active: root._everShown || root.prewarm
    asynchronous: root.prewarm && !root._everShown
    visible: root.shown || root._leaving
    transform: Translate { x: root._offset }

    onShownChanged: {
        if (root.shown) {
            var fresh = !root._everShown
            root._everShown = true
            exitAnim.stop()
            root._leaving = false
            if (fresh || root.anchored) { root._offset = 0; root.opacity = 1; return }
            // From wherever an interrupted exit left it, or from the side.
            enterMove.from = enterAnim.running || root.opacity < 1
                             ? root._offset : root.direction * Motion.pageTravel
            enterFade.from = root.opacity < 1 ? root.opacity : 0
            enterAnim.restart()
        } else if (root._everShown) {
            enterAnim.stop()
            root._leaving = true
            exitMove.to = root.anchored ? root._offset : -root.direction * Motion.pageTravel
            exitAnim.restart()
        }
    }

    Component.onCompleted: if (root.shown)
        root._everShown = true

    ParallelAnimation {
        id: enterAnim
        NumberAnimation {
            id: enterMove
            target: root; property: "_offset"; to: 0
            duration: Motion.page
            easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.standardDecel
        }
        NumberAnimation {
            id: enterFade
            target: root; property: "opacity"; to: 1
            duration: Motion.fadeIn
            easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.effects
        }
    }
    ParallelAnimation {
        id: exitAnim
        NumberAnimation {
            id: exitMove
            target: root; property: "_offset"
            duration: Motion.page
            easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.standardAccel
        }
        NumberAnimation {
            target: root; property: "opacity"; to: 0
            duration: Motion.fadeOut
            easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.effects
        }
        onFinished: {
            root._leaving = false
            root._offset = 0
        }
    }
}
