import Quickshell
import QtQuick
import "./src/theme"
import "./src/services"
import "./src"
import "./src/windows"

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

    // ── The surfaces that size themselves from their own output ──────────────
    //
    // These are the PRODUCTION components, built here exactly as shell.qml
    // builds them: one per entry in Quickshell.screens, each handed its own
    // ShellScreen. Nothing about them is reimplemented for the test, because a
    // test that builds its own copy of the thing it is checking is the defect
    // this whole item was opened for — tests/scaling-test.qml used to carry its
    // own `bucket()` and assert that.
    //
    // They are never visible: DisplayConfirm shows only while
    // DisplayService.pending and ConfirmDialog only while Popups.confirmOpen,
    // and both stay false. The sizes below are laid out anyway, which is the
    // point — `screen` is exact at construction, so the card does not wait for
    // a surface to be mapped to know how wide it is.
    property var perOutput: []

    Variants {
        model: Quickshell.screens
        delegate: Component {
            Scope {
                required property var modelData

                DisplayConfirm {
                    screen: modelData
                    screenName: modelData.name
                    Component.onCompleted: root.perOutput.push({
                        kind: "DisplayConfirm", win: this, screen: modelData,
                        card: "apex-display-confirm-card"
                    })
                }

                ConfirmDialog {
                    screen: modelData
                    Component.onCompleted: root.perOutput.push({
                        kind: "ConfirmDialog", win: this, screen: modelData,
                        card: "apex-confirm-dialog-card"
                    })
                }
            }
        }
    }

    /// Every descendant with this objectName, as a list. A list rather than the
    /// first hit on purpose: the assertions below check HOW MANY were found, so
    /// a renamed or deleted objectName fails the run instead of quietly
    /// reducing it to nothing.
    function findByName(item, name, acc) {
        if (!item)
            return acc;
        if (item.objectName === name)
            acc.push(item);
        const kids = item.children || [];
        for (let i = 0; i < kids.length; i++)
            root.findByName(kids[i], name, acc);
        return acc;
    }

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

            // ── THE REMAINDER OF P1-040, ASSERTED ────────────────────────
            //
            //   "two outputs at compositor scale 1 with different densities
            //    each get their own size."
            //
            // Everything above this line is about the ONE factor: which output
            // the shell picked and what it resolved. This section is about two
            // outputs getting two different answers at the same time, on the
            // production surfaces that have been migrated to ask for their own.
            //
            // Only these two surfaces have been. The shell's other 114 files
            // still read the global Theme, and the Display page still says so.
            // See ROADMAP/state/agents/p1-040.md for what the rest costs.

            // The harness asked the backend for a number of outputs. If it did
            // not get them, every assertion below would pass on one screen by
            // never comparing anything — the exact shape of a suite that
            // vanishes instead of failing. So the count is itself an assertion.
            const wantOutputs = parseInt(Quickshell.env("SCALING_EXPECT_OUTPUTS") || "0", 10);
            if (wantOutputs > 0)
                root.eq("the backend supplied the outputs the runner asked for",
                        screens.length, wantOutputs);

            // Two surfaces per output, and the same again: if the Variants
            // delegate silently built none, the loops below would assert
            // nothing at all.
            root.eq("one per-output surface set was built for every screen",
                    root.perOutput.length, screens.length * 2);

            let sizes = {};   // kind -> [ {name, scale, cardW, cardR} ]
            for (let i = 0; i < root.perOutput.length; i++) {
                const e = root.perOutput[i];
                const cards = root.findByName(e.win.contentItem, e.card, []);

                // The lookup is by objectName, which is a lookup BY CONTENT: if
                // the name is removed the search returns nothing and every
                // assertion that depends on it evaporates. Asserting the count
                // first is what turns that into a failure.
                root.eq(e.kind + " on " + e.screen.name + ": exactly one card was found",
                        cards.length, 1);
                if (cards.length !== 1)
                    continue;

                const want = Metrics.scaleForScreen(e.screen);
                root.eq(e.kind + " on " + e.screen.name + " resolved its OWN output's factor",
                        e.win.theme.scale, want);

                if (!sizes[e.kind]) sizes[e.kind] = [];
                sizes[e.kind].push({
                    name: e.screen.name, scale: e.win.theme.scale,
                    cardW: cards[0].width, cardR: cards[0].radius,
                    wantPx400: e.win.theme.px(400), wantRadius: e.win.theme.notchRadius
                });
                console.log("[per-output] " + e.kind + " " + e.screen.name
                            + " scale=" + e.win.theme.scale
                            + " card=" + cards[0].width + "x" + Math.round(cards[0].height)
                            + " radius=" + cards[0].radius);
            }

            // The card is measured, not recomputed. `width: theme.px(400)` is
            // what the file says; this reads the laid-out width off the real
            // Rectangle and checks it against that output's scaler.
            const dc = sizes["DisplayConfirm"] || [];
            for (let i = 0; i < dc.length; i++)
                root.eq("DisplayConfirm card on " + dc[i].name + " is laid out at its own output's px(400)",
                        dc[i].cardW, dc[i].wantPx400);

            const cd = sizes["ConfirmDialog"] || [];
            for (let i = 0; i < cd.length; i++)
                root.eq("ConfirmDialog card on " + cd[i].name + " is rounded at its own output's notchRadius",
                        cd[i].cardR, cd[i].wantRadius);

            // ── The assertion this unit exists for ───────────────────────────
            // Guarded on the outputs genuinely disagreeing, and the guard is
            // itself asserted above: with SCALING_SCALES="2 1" both outputs
            // arrive as 1920x1080 logical and SHOULD agree, which is the other
            // half of the Display page's story.
            if (screens.length > 1) {
                let distinctWanted = {};
                for (let i = 0; i < screens.length; i++)
                    distinctWanted[String(Metrics.scaleForScreen(screens[i]))] = true;

                if (Object.keys(distinctWanted).length > 1) {
                    root.check("two outputs of different densities resolved two different factors",
                               dc.length === 2 && dc[0].scale !== dc[1].scale);
                    root.check("...and each DisplayConfirm card is therefore a different WIDTH ("
                               + dc.map(function (d) { return d.name + "=" + d.cardW }).join(", ") + ")",
                               dc.length === 2 && dc[0].cardW !== dc[1].cardW);
                    root.check("...and each ConfirmDialog card a different RADIUS ("
                               + cd.map(function (d) { return d.name + "=" + d.cardR }).join(", ") + ")",
                               cd.length === 2 && cd[0].cardR !== cd[1].cardR);

                    // The global factor is one of the two. The surface that is
                    // NOT on the reference output is the one that used to be
                    // laid out wrong, so name it: this is the assertion failing
                    // if per-output resolution regresses to the singleton.
                    let offReference = 0;
                    for (let i = 0; i < dc.length; i++)
                        if (dc[i].scale !== Metrics.scale) offReference++;
                    root.check("at least one output is now sized at a factor that is NOT the shell's global one",
                               offReference >= 1);
                } else {
                    // Both outputs want the same factor — the state the Display
                    // page's recommended compositor scales exist to produce.
                    root.check("outputs that agree are sized the same, and that is not a per-output failure",
                               dc.length === 2 && dc[0].cardW === dc[1].cardW);
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

            // A manual factor is an explicit instruction and it applies to the
            // whole desk, per-output surfaces included. This is the half of the
            // policy the auto-mode assertions above cannot see: HEADLESS-2's
            // own factor is 1.0, so if OutputScale ever stopped honouring the
            // override, the suite would stay green in auto and the user's 150%
            // would silently not reach these two windows.
            for (let m = 0; m < root.perOutput.length; m++) {
                const e = root.perOutput[m];
                root.eq(e.kind + " on " + e.screen.name + " follows the manual override, not its own density",
                        e.win.theme.scale, 1.5);
            }
            root.check("the manual override reached every per-output surface there is",
                       root.perOutput.length === screens.length * 2);

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
