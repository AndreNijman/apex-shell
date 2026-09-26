import QtQuick
import "../"

// ─────────────────────────────────────────────────────────────────────────────
// DialogLifecycle — SurfaceLifecycle with the modal timings (UI/UX roadmap v3
// Phase 6, finishing it): the confirm dialog, the display confirmation, the
// update popup and the window switcher.
//
// They were the surfaces left on the old model, each its own way: the confirm
// dialog and the display confirmation mapped and unmapped on their flag, with
// no motion at all; the update popup unmapped on a 20 ms timer; the switcher's
// scrim had a fade-out that never showed, because the window it lived in was
// unmapped the instant the switcher closed. The lifecycle keeps the window
// until the exit has actually finished (`mapped`), on completion, not a guess.
//
// The Nexus sheet's timings, because these are the same kind of thing: a card
// over a scrim that barely moves (no shape morph — they grow out of nothing):
// in on the page duration with emphasized deceleration, out on the small-
// surface exit with standard acceleration, the content on the scrim's beat.
// Under Reduce Motion the spatial parts jump and the fade stays.
//
// A surface built on it:
//     DialogLifecycle { id: life; open: <flag> }
//     visible: life.mapped
//     scrim:  opacity: <alpha> * (life.closing ? life.content : life.progress) * life.alpha
//     card:   opacity: life.content * life.alpha
//             scale:   life.closing ? 0.99 + 0.01 * life.progress : 0.97 + 0.03 * life.progress
// and it holds the keyboard on `life.open`, not `visible`: a dialog that is
// leaving must not keep the keys through its exit.
// ─────────────────────────────────────────────────────────────────────────────
SurfaceLifecycle {
    enterDuration: Motion.page
    exitDuration:  Motion.surfaceExitSmall
    enterCurve:    Motion.emphasizedDecel
    exitCurve:     Motion.standardAccel
    contentDelay:  0
    contentOut:    Motion.reduced ? Motion.fadeOut : Motion.surfaceExitSmall

    // The card's scale for this progress: a 3 % settle in, 1 % out.
    function cardScale() {
        return closing ? 0.99 + 0.01 * progress : 0.97 + 0.03 * progress
    }
    // A scrim's opacity multiplier: it follows the body in and the content out.
    function scrimK() {
        return (closing ? content : progress) * alpha
    }
}
