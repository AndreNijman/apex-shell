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
// Written by:  IpcManager "lockscreen" handler (lock only), PowerMenu.
// Read by:     windows/Lockscreen.qml (WlSessionLock.locked binding).
// ─────────────────────────────────────────────────────────────

QtObject {
    id: root

    // True while the session is locked. Default false so the shell never
    // comes up locked on startup.
    property bool locked: false
}
