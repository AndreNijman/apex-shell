import Quickshell
import QtQuick
import "./src/theme"
import "./src/services"
import "./src"

// ─────────────────────────────────────────────────────────────────────────────
// Scaling tests. Run via tests/run-scaling-test.sh.
//
// The critical property is that scale is 1.0 on a 1080p/1200p panel: the whole
// token set was calibrated on one, so the refactor must be a NO-OP there. A
// scaling change that silently resizes the reference machine is a regression.
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

    // Replicates Metrics.autoScale so the breakpoints can be checked at every
    // height without physically owning the monitors.
    function bucket(h) {
        if (h < 900)
            return 0.85;
        if (h < 1250)
            return 1.00;
        if (h < 1600)
            return 1.20;
        if (h < 2000)
            return 1.35;
        return 1.50;
    }

    Timer {
        interval: 900
        running: true
        repeat: false
        onTriggered: {
            console.log("[reference] screen=" + (Metrics.referenceScreen ? Metrics.referenceScreen.name : "none") + " height=" + Metrics.referenceHeight + " scale=" + Metrics.scale);

            // ── Breakpoints ───────────────────────────────────────────────
            root.eq("768p  -> 0.85", root.bucket(768), 0.85);
            root.eq("900p  -> 1.00", root.bucket(900), 1.00);
            root.eq("1080p -> 1.00", root.bucket(1080), 1.00);
            root.eq("1200p -> 1.00 (calibrated baseline, must not grow)", root.bucket(1200), 1.00);
            root.eq("1440p -> 1.20", root.bucket(1440), 1.20);
            root.eq("1600p -> 1.35", root.bucket(1600), 1.35);
            root.eq("2160p -> 1.50", root.bucket(2160), 1.50);

            // Monotonic: a taller screen must never scale down.
            let mono = true;
            let prev = 0;
            for (const h of [720, 768, 900, 1080, 1200, 1440, 1600, 1800, 2160, 4320]) {
                const s = root.bucket(h);
                if (s < prev)
                    mono = false;
                prev = s;
            }
            root.check("scale is monotonic in height", mono);

            // ── Live values on this machine ───────────────────────────────
            root.check("a reference screen was resolved", Metrics.referenceScreen !== null);
            root.eq("live scale matches the bucket for this panel", Metrics.scale, root.bucket(Metrics.referenceHeight));

            // ── px()/fs() behaviour ──────────────────────────────────────
            root.check("px() returns whole pixels", Metrics.px(17) === Math.round(17 * Metrics.scale));
            root.check("fs() floors at 7px for legibility", Metrics.fs(1) >= 7);
            root.check("fs() scales a normal size", Metrics.fs(12) === Math.max(7, Math.round(12 * Metrics.scale)));
            root.check("Theme.fs mirrors Metrics.fs", Theme.fs(13) === Metrics.fs(13));
            root.check("Theme.px mirrors Metrics.px", Theme.px(13) === Metrics.px(13));

            // Geometry tokens must actually be scaled, not raw literals.
            root.eq("notchPadding is scaled", Metrics.notchPadding, Math.round(16 * Metrics.scale));
            root.eq("cNotchMinWidth is scaled", Metrics.cNotchMinWidth, Math.round(300 * Metrics.scale));

            // On the reference panel class the refactor must change nothing.
            if (Metrics.referenceHeight >= 1000 && Metrics.referenceHeight < 1250) {
                root.eq("baseline panel: scale is exactly 1.0", Metrics.scale, 1.0);
                root.eq("baseline panel: notchPadding unchanged at 16", Metrics.notchPadding, 16);
                root.eq("baseline panel: fs(12) unchanged at 12", Metrics.fs(12), 12);
            }

            // ── Manual override ──────────────────────────────────────────
            // SettingsService persists to the user's real settings.json, so the
            // originals are captured and put back before exiting. A test that
            // leaves the user's shell scaled to 1.5 is not a passing test.
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
