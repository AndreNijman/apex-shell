pragma Singleton
import QtQuick
import Quickshell

// ─────────────────────────────────────────────────────────────────────────────
// Time — the shell's single wall clock.
//
// Four independent 1 Hz `Timer`s used to tick forever in parallel: the bar clock
// (modules/Right/Clock.qml), the dashboard clock card (services/home/ClockCard),
// the lock screen (windows/Lockscreen.qml), and the quick-control panel. Each
// woke the process once a second on its own schedule, so the shell never got a
// full second of idle even with nothing on screen, and the four could disagree
// by up to a second on which minute it was.
//
// Quickshell's SystemClock is the right primitive: it aligns its wakeup to the
// wall-clock boundary (so a minute-precision clock wakes 60x less often than a
// 1 Hz Timer, and lands exactly ON the minute rather than drifting), and it is
// one shared source of truth.
//
// ── Two precisions, deliberately ────────────────────────────────────────────
// Most consumers only render "hh:mm" and have no business waking the process
// every second. `date` is minute-precision and always live — one wakeup per
// minute for the whole shell. `secondsDate` is second-precision and refcounted:
// it only ticks while something is genuinely displaying seconds (the bar clock
// in its hh:mm:ss mode, a running timer or stopwatch).
//
//   ServiceRef { service: Time; active: root.showingSeconds }
// ─────────────────────────────────────────────────────────────────────────────

Singleton {
    id: root

    // Demand for second-precision ticks. See ServiceRef.
    property int refCount: 0

    readonly property bool secondsEnabled: root.refCount > 0

    // Minute-precision wall clock. Always running.
    readonly property date date: minuteClock.date
    readonly property int hours: minuteClock.hours
    readonly property int minutes: minuteClock.minutes

    // Second-precision wall clock. Ticks only while referenced; when idle its
    // `date` simply stops advancing, so never read it without holding a ref.
    readonly property date secondsDate: secondClock.date
    readonly property int seconds: secondClock.seconds

    function format(fmt) {
        return Qt.formatDateTime(minuteClock.date, fmt)
    }

    function formatSeconds(fmt) {
        return Qt.formatDateTime(secondClock.date, fmt)
    }

    readonly property SystemClock minuteClock: SystemClock {
        precision: SystemClock.Minutes
    }

    readonly property SystemClock secondClock: SystemClock {
        precision: SystemClock.Seconds
        enabled: root.secondsEnabled
    }
}
