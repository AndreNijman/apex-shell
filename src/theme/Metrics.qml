pragma Singleton
import QtQuick
import Quickshell
import "."
import "../services"
import "scaling.js" as Scaling

// ─────────────────────────────────────────────────────────────────────────────
// Metrics — the geometry tokens for the REFERENCE output.
//
// Every size in here used to be an absolute pixel literal calibrated against a
// 1080p panel, which is why the shell looked correct on exactly one class of
// monitor and wrong on every other. APEX-OS deliberately runs outputs at
// Hyprland scale 1.0 (an `auto` scale that cannot resolve to an integer buffer
// size errors the monitor rule out entirely, which is a worse failure than a
// small UI), so compensating for pixel density is the shell's job, not the
// compositor's.
//
// ── What this file is now ───────────────────────────────────────────────────
// The token table itself moved to theme/ThemeSet.qml, and this singleton is one
// INSTANCE of it: the instance whose factor comes from the reference output.
// The table is not trapped inside a singleton any more, so every output has its
// own set without a second copy of the arithmetic. That copy is the defect this
// item was opened for: tests/scaling-test.qml once re-implemented the
// breakpoint table and asserted its own copy, and every breakpoint assertion
// passed no matter what this file said.
//
// theme/OutputScale.qml answers what factor an output deserves; every surface
// builds its own instance at that factor. This one is built at the REFERENCE
// output's, which is a policy question rather than a density bucket.
//
// ── The scale factor ────────────────────────────────────────────────────────
// `scale` multiplies every geometry token and, through fs(), every font size.
// It is deliberately SUBLINEAR in resolution: a 4K panel is usually also
// physically larger, so a literal 2x would be enormous. Fixed breakpoints are
// used rather than a continuous height/1080 ratio because a continuous factor
// produces awkward fractional pixel values and shifts the whole UI on any mode
// change; breakpoints are predictable and reproducible. The table is in
// theme/scaling.js and the manual-override policy is in theme/OutputScale.qml —
// this file chooses the OUTPUT, not the arithmetic.
//
// `physicalDotsPerInch` would be the principled input, but EDID physical size is
// missing or wrong on a great many panels, and a bad DPI reading would size the
// shell absurdly with no obvious cause. Height is boring and always right.
//
// ── Who still reads this, after the migration ───────────────────────────────
// Almost nothing, and that is the point. Every surface in the shell resolves
// its OWN output's set:
//
//     readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForScreen(root.screen) }     // a window
//     readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // an Item
//
// and reads `theme.px(...)` where it used to read `Theme.px(...)`. 1042 reads
// across 99 files moved; tests/check-scale-tokens.sh's closure rule is what
// keeps them moved.
//
// This singleton remains for three things, all of them deliberate:
//
//   • `Theme.<colour>` and `Theme.animDuration` still come through here,
//     because neither is a function of an output. A palette belongs to the
//     shell; two monitors with different accent colours would be a bug.
//   • the REFERENCE output — which output's size the user considers the
//     canonical one, via `SettingsService.scaleScreen`, defaulting to the
//     tallest. Nothing lays out at it any more, but the Display page and the
//     suites ask what it is.
//   • `services/plugins/PluginService.qml`, the one file the closure rule
//     exempts: its `theme` is a versioned snapshot handed to plugin code, one
//     object for every plugin instance.
//
// The Display page's recommended scales are still worth applying, for the
// reason that was always the other half of the story: the shell is the only
// thing on the desk that magnifies itself, and every other application is drawn
// at the compositor's scale for the output it is on.
// ─────────────────────────────────────────────────────────────────────────────
ThemeSet {
    id: root

    // ── Scale ────────────────────────────────────────────────────────────────
    readonly property int baselineHeight: 1080

    // The output whose size drives the scale. Honours the user's choice by name
    // when it is connected, else the tallest screen, else null.
    readonly property var referenceScreen: {
        const screens = Quickshell.screens
        if (!screens || screens.length === 0)
            return null

        const wanted = SettingsService.scaleScreen
        if (wanted && wanted !== "") {
            for (const s of screens)
                if (s.name === wanted)
                    return s
        }

        let best = screens[0]
        for (const s of screens)
            if (s.height > best.height)
                best = s
        return best
    }

    readonly property int referenceHeight: referenceScreen ? referenceScreen.height : baselineHeight

    // Sublinear breakpoints, and they live in theme/scaling.js rather than here.
    // 1200 sits in the baseline bucket deliberately: a 1920x1200 panel is 11%
    // taller than 1080p, not a density class of its own, and the shell was
    // calibrated on exactly such a panel. Putting it in the 1440p bucket would
    // enlarge the UI on the reference machine — a regression dressed up as a
    // feature.
    //
    // The table moved out because it was unreachable from anything but a running
    // quickshell, so tests/scaling-test.qml kept its own copy of it and asserted
    // the copy. Every breakpoint assertion in that suite passed whatever this
    // file said.
    readonly property real autoScale: Scaling.scaleForHeight(root.referenceHeight)

    /// The breakpoint table, callable. The suite drives THIS, at heights this
    /// machine does not have, rather than a second copy of the arithmetic.
    function scaleForHeight(h) { return Scaling.scaleForHeight(h) }

    /// What this output would deserve on its own, ignoring every other screen.
    /// The Display page needs it to say which outputs disagree; a surface that
    /// wants to LAY OUT at it asks OutputScale, which also honours the manual
    /// override this function deliberately ignores.
    function scaleForScreen(screen) {
        return screen ? Scaling.scaleForHeight(screen.height) : 1.0
    }

    // The reference output's factor, through the same policy every per-output
    // surface uses. Manual mode wins here exactly as it wins there.
    scale: OutputScale.factorForHeight(root.referenceHeight)
}
