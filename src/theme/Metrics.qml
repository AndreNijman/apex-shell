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
// Nothing about what a call site reads changed — `Metrics.notchPadding` and
// `Theme.px(8)` answer exactly what they answered before — but the table is no
// longer trapped inside a singleton, so a second output can have its own set
// without a second copy of the arithmetic. That copy is the defect this item
// was opened for: tests/scaling-test.qml once re-implemented the breakpoint
// table and asserted its own copy, and every breakpoint assertion passed no
// matter what this file said.
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
// ── Multi-monitor ───────────────────────────────────────────────────────────
// This is still the GLOBAL factor, because Theme and every unmigrated call site
// in the tree reads it, and there are 2758 such reads across 116 files. What is
// supported here is CHOOSING which monitor sets it, via
// `SettingsService.scaleScreen` — on a mixed 4K + 1080p desk you pick the one
// you actually work on. Default is the tallest connected output.
//
// A surface that has been migrated to per-output sizing does NOT read this. It
// builds its own ThemeSet from its own screen:
//
//     readonly property ThemeSet theme: ThemeSet {
//         scale: OutputScale.factorForScreen(root.screen)
//     }
//
// src/windows/DisplayConfirm.qml and src/windows/ConfirmDialog.qml are the two
// that do, and tests/scaling-test.qml asserts they get different sizes on two
// outputs of different densities. The rest of the tree is the remaining work;
// the design and its costs are on ROADMAP/state/agents/p1-040.md.
//
// The other answer to a mixed-DPI desk is on the Display page: give each output
// a compositor scale that brings its LOGICAL size into the band this file was
// calibrated for, and one global factor is then correct for all of them.
// Measured: a 3840x2160 and a 1920x1080 output both at compositor scale 1 give a
// single factor of 1.5, which is 50% too large on the 1080p panel; with the 4K
// at compositor scale 2 both arrive as 1920x1080 and the factor is 1.0 for both.
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
