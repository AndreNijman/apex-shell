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

    // ── Why every surface builds its OWN set, and does not share one ─────────
    //
    // A ThemeSet is a pure function of its `scale` and the breakpoint table
    // answers five factors, so five shared objects would serve the whole shell
    // and every migrated file would cost one binding instead of thirty-four.
    // That registry was built, on this branch, and MEASURED — and it does not
    // work:
    //
    //   a ThemeSet handed out by this singleton and stored in another file's
    //   `readonly property ThemeSet theme` evaluates to undefined at the call
    //   site in some contexts. tests/settings-pages-test.qml builds its pages
    //   in an Item with no window, and there it produced 1641
    //   "Unable to assign [undefined] to int" warnings — no TypeError, no
    //   ReferenceError, the object alive and its fs() returning a number when
    //   called directly. Bisected: the ONLY thing that changed it was where the
    //   object is constructed. Inline, zero warnings, matching an untouched
    //   worktree exactly. Shared from here — whether built by an Instantiator
    //   or by createObject — 1641, with or without the ThemeSet type
    //   annotation.
    //
    // So the shared registry is not here, and this file hands out a FACTOR
    // rather than an object. The cost is one ThemeSet per component instance,
    // which is the price of a size that is actually defined everywhere it is
    // read; a cheaper set that is undefined during construction is not cheaper.
}
