pragma Singleton
import QtQuick
import Quickshell
import "../"

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

    // ── 12 or 24 hours (2026-09-27) ─────────────────────────────────────────
    // SettingsService.clockFormat: "12", "24", or "system" — the locale the
    // session runs in (its short time format carries an AM/PM marker or not;
    // C.UTF-8, the L16's, is 24 h). Every clock the shell draws asks here, so
    // the bar, the lock screen, the dashboard and a notification's time agree.
    readonly property bool localeIs12h: /a|A/.test(Qt.locale().timeFormat(Locale.ShortFormat))
    readonly property bool use24h: SettingsService.clockFormat === "24" ? true
                                 : SettingsService.clockFormat === "12" ? false
                                 : !root.localeIs12h
    /// The time of day: "14:05" or "2:05 PM"; `seconds` adds them (read
    /// secondsDate, so hold a ServiceRef); `meridiem` false drops the AM/PM
    /// for a display that sets it apart (the lock screen's big clock).
    function clock(seconds, meridiem) {
        const d = seconds ? secondClock.date : minuteClock.date
        const rest = Qt.formatDateTime(d, seconds ? "mm:ss" : "mm")
        if (root.use24h) return Qt.formatDateTime(d, "HH") + ":" + rest
        // The hour by hand: Qt's `h` is 12-hour only while the same format
        // also carries AP, so a 12-hour time without its marker (the lock
        // screen draws it apart) came out as "15:08".
        const h = d.getHours() % 12 || 12
        return h + ":" + rest + (meridiem !== false ? " " + Qt.formatDateTime(d, "AP") : "")
    }
    /// "AM" / "PM" under a 12-hour clock, "" under a 24-hour one.
    readonly property string meridiem: root.use24h ? "" : Qt.formatDateTime(minuteClock.date, "AP")

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
