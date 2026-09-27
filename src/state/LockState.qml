pragma Singleton
import QtQuick

// ─────────────────────────────────────────────────────────────
// LockState — global session-lock flag.
//
// The single source of truth for whether the native lock screen is up.
//   • Set true  → WlSessionLock in windows/Lockscreen.qml engages the
//                 compositor session-lock and shows the lock surface.
//   • Set false → ONLY set by a successful PAM authentication inside
//                 Lockscreen.qml. Never flip this to false from IPC or any
//                 other path — that would be a trivial lock bypass.
//
// Written by:  IpcManager "lockscreen" handler (lock only), PowerMenu — both
//              through lock(), which may take up to 120 ms to engage while
//              windows/LockCapture.qml takes the arrival's first frame.
// Read by:     windows/Lockscreen.qml (WlSessionLock.locked binding).
// ─────────────────────────────────────────────────────────────

QtObject {
    id: root

    // True while the session is locked. Default false so the shell never
    // comes up locked on startup.
    property bool locked: false

    // ── The unlock, as motion (2026-09-26) ──────────────────────────────────
    // Presentation only; neither of these unlocks anything. Both are set by
    // Lockscreen.qml's PAM-success path, which is still the one writer of
    // `locked = false` — it now releases the lock a beat later, once the lock
    // UI has played its exit (see Lockscreen.release()).
    //   unlocking  auth passed; the lock UI is leaving (the clock lifts, the
    //              field fades, the wallpaper sharpens back into the desktop's)
    //   curtain    the desktop wallpaper, mapped over everything BEHIND the
    //              lock so that, when the lock lets go, the desktop does not
    //              pop in: windows and bar fade in from under it
    //              (windows/UnlockCurtain.qml). Raised as the lock engages —
    //              not at the unlock — so it has long had its first frame by
    //              the time it is needed; it drops itself once it has faded.
    property bool unlocking: false
    property bool curtain: false
    onLockedChanged: if (root.locked) { root.unlocking = false; root.curtain = true }

    // The curtain may only cover the desktop once the compositor has actually
    // engaged the lock (Lockscreen mirrors ext-session-lock's `secure` here):
    // a lock that failed to engage must leave the desktop visible and usable,
    // not hidden behind a wallpaper. Armed once per lock and kept through the
    // release, so the fade does not depend on the order `locked` and `secure`
    // come down in.
    property bool lockSecure: false
    property bool curtainArmed: false
    onLockSecureChanged: {
        if (root.lockSecure && root.curtain) root.curtainArmed = true
        // The compositor ended a lock it had engaged (ext-session-lock lets it)
        // while the shell still believes it locked: the curtain must not stay
        // over a live desktop with nothing to take it down.
        if (!root.lockSecure && root.locked && !root.unlocking) root.curtain = false
    }
    onCurtainChanged: if (!root.curtain) root.curtainArmed = false

    // ── The ONE way to ask for a lock ───────────────────────────────────────
    // Every lock request (IPC — hypridle's lock_cmd, before_sleep and idle —
    // and the power menu) comes through here, not by writing `locked`. A
    // correct password now releases the lock a beat later (the exit plays
    // first), and during that beat `locked` is still true: a bare
    // `locked = true` changed nothing and was LOST, and the release timer then
    // unlocked anyway — so a lid closed within ~240 ms of Enter would suspend
    // and resume UNLOCKED (found by review, 2026-09-26). Cancelling the
    // release is what makes a lock asked for in that window hold.
    //
    // It no longer engages in the same instant (2026-09-27): the lock screen's
    // first frame is the desktop as it was, which then recedes into the lock
    // (Andre: "make the transition to lock screen actually cleaner and sleek
    // not just fading"), and that picture has to be taken BEFORE the lock
    // engages — once it has, the compositor shows nothing but the lock. So a
    // fresh lock asks windows/LockCapture.qml for it and engages when it is
    // ready, or when _captureCap runs out (120 ms; a capture takes 16-31 ms on
    // the L16), whichever is first. Nothing waits on the capture beyond that:
    // with no capture the lock arrives the way it did before.
    //
    // At once, with no capture: a lock asked for while locked — the release
    // window included, which is what makes it hold — or while a capture is
    // already running (a second request is never made to wait), or when there
    // is nothing to capture with (LockCapture absent, no grim, Reduce Motion).
    function lock() {
        root.unlocking = false
        if (root.locked || root.capturing || !root.captureEnabled) { root._engage(); return }
        root.capturing = true
        root.captures = ({})
        root.captureSeq += 1
        root._captureCap.restart()
        root.captureRequested(root.captureSeq)
    }

    // ── The desktop as it was, for the arrival ──────────────────────────────
    // Presentation only, like `unlocking` and `curtain`: none of this can hold
    // the session unlocked past _captureCap, and none of it unlocks anything.
    //   captureEnabled  LockCapture exists and can take the picture
    //   capturing       a lock is waiting (at most _captureCap) for it
    //   captures        screen name → image URL, for THIS lock only; published
    //                   by captured(), read once by each lock surface as it
    //                   arrives, emptied by the next lock
    property bool captureEnabled: false
    property bool capturing: false
    property var captures: ({})
    property int captureSeq: 0
    signal captureRequested(int seq)

    // LockCapture: every output's picture for request `seq` is ready (or has
    // failed; a screen missing from `shots` arrives without one). Ignored once
    // the lock has engaged without them: a late picture never appears mid-way.
    function captured(seq, shots) {
        if (seq !== root.captureSeq || !root.capturing) return
        root.captures = shots
        root._engage()
    }

    function _engage() {
        root.capturing = false
        root._captureCap.stop()
        root.locked = true
    }
    property Timer _captureCap: Timer {
        interval: 120
        repeat: false
        onTriggered: root._engage()
    }
}
