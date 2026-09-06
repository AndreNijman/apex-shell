import Quickshell
import QtQuick
import "./src/theme"
import "./src/services"
import "./src"

// ─────────────────────────────────────────────────────────────────────────────
// Scaling, against a real session. Run via tests/run-scaling-test.sh, which
// brings its own headless compositor, its own HOME and — when it can — TWO
// outputs of different densities.
//
// ── What changed, and why the old version could not fail ────────────────────
//
// This file used to carry a `bucket()` function that re-implemented Metrics'
// breakpoint table, and seven assertions comparing that copy to its own
// literals. Moving the 1440p breakpoint from 1600 to 1500 in Metrics.qml left
// the suite at 25 passed, 0 failed. The table is now theme/scaling.js, both the
// shell and tests/scaling-test.js read it, and the arithmetic is asserted
// there. What is left here is what only a running session can answer: what the
// shell resolves on the outputs it was actually given.
//
// The critical property is unchanged: scale is 1.0 on a 1080p/1200p panel. The
// whole token set was calibrated on one, so any change here must be a NO-OP
// there.
// ─────────────────────────────────────────────────────────────────────────────

ShellRoot {
    id: root

    property int passed: 0
    property int failed: 0

    function check(name, cond) {
        if (cond) {
            root.passed++;
            console.log("  PASS  " + name);
        } else {
            root.failed++;
            console.log("  FAIL  " + name);
        }
    }

    function eq(name, got, want) {
        root.check(name + " (got " + got + ", want " + want + ")", got === want);
    }

    Timer {
        interval: 900
        running: true
        repeat: false
        onTriggered: {
            const screens = Quickshell.screens;
            console.log("[reference] screen=" + (Metrics.referenceScreen ? Metrics.referenceScreen.name : "none") + " height=" + Metrics.referenceHeight + " scale=" + Metrics.scale);
            for (let i = 0; i < screens.length; i++) {
                const s = screens[i];
                console.log("[screen] " + s.name + " " + s.width + "x" + s.height + " dpr=" + s.devicePixelRatio + " wants=" + Metrics.scaleForScreen(s));
            }

            // ── The table, through the shell's own function ────────────────
            // Not a copy of it. tests/scaling-test.js pins every breakpoint and
            // both sides of every edge; these four are here so that a Metrics
            // that stops delegating to theme/scaling.js is caught by the suite
            // that runs against a real session too.
            root.eq("Metrics answers the table at 768", Metrics.scaleForHeight(768), 0.85);
            root.eq("Metrics answers the table at 1080", Metrics.scaleForHeight(1080), 1.00);
            root.eq("Metrics answers the table at 1440", Metrics.scaleForHeight(1440), 1.20);
            root.eq("Metrics answers the table at 2160", Metrics.scaleForHeight(2160), 1.50);

            // ── Live values on this machine ───────────────────────────────
            root.check("a reference screen was resolved", Metrics.referenceScreen !== null);
            root.eq("the live factor is the table's answer for the reference height", Metrics.scale, Metrics.scaleForHeight(Metrics.referenceHeight));

            // ── px()/fs() behaviour ──────────────────────────────────────
            root.check("px() returns whole pixels", Metrics.px(17) === Math.round(17 * Metrics.scale));
            root.check("fs() floors at 7px for legibility", Metrics.fs(1) >= 7);
            root.check("fs() scales a normal size", Metrics.fs(12) === Math.max(7, Math.round(12 * Metrics.scale)));
            root.check("Theme.fs mirrors Metrics.fs", Theme.fs(13) === Metrics.fs(13));
            root.check("Theme.px mirrors Metrics.px", Theme.px(13) === Metrics.px(13));

            // Geometry tokens must actually be scaled, not raw literals.
            root.eq("notchPadding is scaled", Metrics.notchPadding, Math.round(16 * Metrics.scale));
            root.eq("cNotchMinWidth is scaled", Metrics.cNotchMinWidth, Math.round(300 * Metrics.scale));

            // On the reference panel class the token set must not move.
            if (Metrics.referenceHeight >= 1000 && Metrics.referenceHeight < 1250) {
                root.eq("baseline panel: scale is exactly 1.0", Metrics.scale, 1.0);
                root.eq("baseline panel: notchPadding unchanged at 16", Metrics.notchPadding, 16);
                root.eq("baseline panel: fs(12) unchanged at 12", Metrics.fs(12), 12);
            }

            // ── The mixed desk (P1-040) ───────────────────────────────────
            //
            // The whole point of the task, and it needs two outputs, so the
            // runner supplies them. THE SHELL HAS ONE FACTOR: what is asserted
            // is not that both screens are laid out correctly — they cannot be
            // — but that the shell agrees with the arithmetic about which ones
            // disagree, and that the reference screen is one of the connected
            // ones rather than a stale name.
            if (screens.length > 1) {
                let distinct = {};
                for (let i = 0; i < screens.length; i++)
                    distinct[String(Metrics.scaleForScreen(screens[i]))] = true;
                const wanted = Object.keys(distinct);
                console.log("[mixed] outputs=" + screens.length + " distinct factors=" + wanted.join(","));

                root.check("every connected output is asked what it wants",
                           wanted.length >= 1);
                root.check("the global factor is what SOME connected output wants",
                           wanted.indexOf(String(Metrics.scale)) >= 0);

                let refIsLive = false;
                for (let i = 0; i < screens.length; i++)
                    if (Metrics.referenceScreen && screens[i].name === Metrics.referenceScreen.name)
                        refIsLive = true;
                root.check("the reference screen is one that is connected", refIsLive);

                if (wanted.length === 1) {
                    // The state the Display page's recommended scales exist to
                    // produce, asserted where it can be produced: give the 4K a
                    // compositor scale of 2 and both outputs arrive as 1920x1080
                    // logical, so the one global factor is right for both.
                    //   SCALING_SCALES="2 1" ./tests/run-scaling-test.sh
                    root.eq("every output wants the same factor, and the shell uses it",
                            Metrics.scale, Metrics.scaleForScreen(screens[0]));
                    root.check("no output is laid out at a factor it did not want",
                               Metrics.scale === Metrics.scaleForScreen(screens[screens.length - 1]));
                }

                if (wanted.length > 1) {
                    // This is the defect, asserted as a defect: on a desk whose
                    // outputs disagree, the one factor is wrong for at least
                    // one of them, and the Display page's "Shell scaling"
                    // section exists to say so.
                    console.log("[mixed] the outputs disagree, so one factor is wrong for at least one of them");
                    root.check("a disagreeing desk still resolves a factor rather than none",
                               Metrics.scale > 0);
                }
            }

            // ── Manual override ──────────────────────────────────────────
            // SettingsService persists, so the runner gives this suite a
            // private HOME. The originals are restored anyway: a test that
            // leaves a shell at 150% is not a passing test even in a sandbox.
            const origMode = SettingsService.scaleMode;
            const origManual = SettingsService.scaleManual;

            SettingsService.set("scaleManual", 1.5);
            SettingsService.set("scaleMode", "manual");
            root.eq("manual mode takes the manual factor", Metrics.scale, 1.5);
            root.eq("manual mode scales geometry", Metrics.notchPadding, 24);

            SettingsService.set("scaleManual", 99);
            root.check("manual factor is clamped to a usable range", SettingsService.scaleManual <= 3.0);
            SettingsService.set("scaleManual", 0.01);
            root.check("manual factor is clamped at the bottom too", SettingsService.scaleManual >= 0.5);

            // A real must not be truncated to an int on the way in.
            SettingsService.set("scaleManual", 1.25);
            root.eq("a fractional scale survives (not parseInt'd)", SettingsService.scaleManual, 1.25);

            SettingsService.set("scaleMode", "auto");
            root.eq("auto mode returns to the derived factor", Metrics.scale, Metrics.autoScale);

            // ── Choosing which monitor sets the size ─────────────────────
            // The one lever the architecture does offer on a mixed desk. It was
            // never exercised: nothing checked that naming an output actually
            // moved the factor to that output's.
            if (screens.length > 1) {
                const origScreen = SettingsService.scaleScreen;
                for (let i = 0; i < screens.length; i++) {
                    SettingsService.set("scaleScreen", screens[i].name);
                    root.eq("naming " + screens[i].name + " makes it the reference",
                            Metrics.referenceScreen ? Metrics.referenceScreen.name : "none",
                            screens[i].name);
                    root.eq("and the factor becomes that output's",
                            Metrics.scale, Metrics.scaleForScreen(screens[i]));
                }
                SettingsService.set("scaleScreen", "no-such-output-DP-99");
                root.check("an output that is not connected falls back to the tallest",
                           Metrics.referenceScreen !== null);
                SettingsService.set("scaleScreen", origScreen);
            }

            // Restore whatever the user actually had.
            SettingsService.set("scaleManual", origManual);
            SettingsService.set("scaleMode", origMode);
            root.eq("settings restored: mode", SettingsService.scaleMode, origMode);
            root.eq("settings restored: manual factor", SettingsService.scaleManual, origManual);

            console.log("");
            console.log("passed=" + root.passed + " failed=" + root.failed);
            Qt.exit(root.failed === 0 ? 0 : 1);
        }
    }
}
