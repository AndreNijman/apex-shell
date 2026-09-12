pragma Singleton
import QtQuick
import QtQml
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

    // ── The registry: one ThemeSet per factor, for the whole shell ────────────
    //
    // A ThemeSet is a pure function of its `scale`, and there are exactly five
    // factors the breakpoint table can answer, so a shell with a hundred
    // migrated files needs FIVE token sets, not one per component instance.
    // Without this, `readonly property ThemeSet theme: ThemeSet { ... }` in
    // every file would build a fresh set — and its ~40 bindings onto
    // SettingsService — for every workspace dot and every list delegate.
    //
    // The model is Scaling.factors(), derived from the same BREAKPOINTS array
    // scaleForHeight() reads. A hand-written list here would be a second copy
    // of the table, which is the defect this whole item was opened for.
    readonly property Instantiator _sets: Instantiator {
        model: Scaling.factors()
        delegate: ThemeSet {
            required property var modelData
            scale: modelData
        }
    }

    // Manual mode is not in the table — the user can type any factor in the
    // clamped range — so it gets one set of its own rather than a set rebuilt
    // on every tick of a slider drag.
    readonly property ThemeSet _manualSet: ThemeSet {
        scale: SettingsService.scaleManual
    }

    /// The shared token set for an output of this LOGICAL height.
    ///
    /// Identity matters and is asserted: two surfaces on the same output get
    /// the SAME object, and two outputs in different buckets get different
    /// ones. A lookup that quietly returned a fresh set each time would still
    /// produce correct numbers, so nothing else would notice.
    function setForHeight(h) {
        if (SettingsService.scaleMode === "manual")
            return policy._manualSet
        const f = Scaling.scaleForHeight(h)
        const all = Scaling.factors()
        const i = all.indexOf(f)
        // Not a float-tolerance comparison: factors() returns the very doubles
        // scaleForHeight() returns, both out of BREAKPOINTS. A miss therefore
        // means the table grew an entry factors() did not report, which is a
        // bug rather than a rounding question — say so, and hand back the
        // smallest set rather than null so the shell keeps drawing.
        if (i < 0) {
            console.warn("OutputScale: scaling.js factors() does not list "
                         + f + "; the breakpoint table and factors() disagree")
            return policy._sets.objectAt(0)
        }
        return policy._sets.objectAt(i)
    }

    /// The shared token set for a ShellScreen. A window knows its own `screen`
    /// at construction; an Item that does not know its window uses the QtQuick
    /// `Screen` attached property and passes `Screen.height` to setForHeight.
    function setForScreen(screen) {
        return policy.setForHeight(screen ? screen.height : 1080)
    }
}
