pragma Singleton
import QtQuick
import "../services"
import "scaling.js" as Scaling

// ─────────────────────────────────────────────────────────────────────────────
// OutputScale — what magnification an output deserves, in one place.
//
// Two things decide it and they are not both arithmetic:
//
//   the breakpoint table   theme/scaling.js, keyed on LOGICAL height
//   the user's override    SettingsService.scaleMode === "manual"
//
// A manual factor is an explicit instruction and it applies to the whole desk:
// a user who has typed 125% has said what they want the shell to look like, not
// what they want each monitor to negotiate. Automatic mode is where an output
// gets to answer for itself.
//
// This exists as a singleton rather than a function on Metrics because Metrics
// is now one INSTANCE of ThemeSet — the reference output's — and a per-output
// surface must be able to ask the question without going through the instance
// that already answered it for a different output.
// ─────────────────────────────────────────────────────────────────────────────
QtObject {
    id: policy

    /// The factor for an output of this LOGICAL height — what Wayland reports
    /// after the compositor's own output scale, which is the input the
    /// breakpoint table is written against.
    function factorForHeight(h) {
        if (SettingsService.scaleMode === "manual")
            return SettingsService.scaleManual
        return Scaling.scaleForHeight(h)
    }

    /// The factor for a ShellScreen. A window knows its own `screen` from the
    /// moment it is constructed — measured on quickshell 0.3.1: with two
    /// headless outputs of different densities, `screen.height` on each
    /// PanelWindow is that output's height at t=0, before the surface is ever
    /// mapped. That is why a per-output surface resolves from here and not from
    /// the QtQuick `Screen` attached property, which reports the primary output
    /// until the item is actually on its own (measured: corrected 1ms after
    /// construction, still well before first paint at 39-84ms, but a needless
    /// re-evaluation when the window already holds the answer).
    ///
    /// The attached property remains the right tool for an item that does NOT
    /// know its window — see ROADMAP/state/agents/p1-040.md.
    function factorForScreen(screen) {
        return policy.factorForHeight(screen ? screen.height : 1080)
    }
}
