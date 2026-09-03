pragma Singleton
import QtQuick
import "."

QtObject {
    id: root

    // ── Color loader — watches matugen output and updates live ────────────────
    // Use a unique ID to avoid namespace collision with the 'Colors' singleton
    property var _loader: ColorLoader { id: internalLoader }

    // ── Colors — bound to loader, update automatically when matugen runs ──────
    property color background: internalLoader.background
    property color active:     internalLoader.active
    property color text:       internalLoader.text
    property color subtext:    internalLoader.subtext
    property color icon:       internalLoader.icon
    property color border:     internalLoader.border
    property color iconFont:   internalLoader.iconFont

    // ── Status ────────────────────────────────────────────────────────────────
    // Deliberately NOT loaded from the palette, and that is the whole point.
    //
    // matugen gives us `error`, so `danger` COULD follow the wallpaper. The
    // other two have no Material You role at all — there is no guaranteed-amber
    // or guaranteed-green in an M3 scheme — so sourcing one of the three and
    // fixing the other two would make the status family internally incoherent:
    // a red that moves with the wallpaper next to a green that does not.
    //
    // A status colour also has a job that outranks harmony. "Disk 94% full" and
    // "battery at 4%" have to read as alarming on every wallpaper, including a
    // red one, where a harmonised error colour is at its least legible.
    //
    // The values are the ones already dominant in the tree, so nothing moves on
    // an existing install: `danger` was #f87171 at 12 of the 24 red call sites,
    // `warning` #f5c47a at 7 of 13, `success` #a6e3a1 at 2 of 3. The fixed
    // Workspace Visuals below are the established precedent for this in
    // this file — wsUrgent is a fixed status red already.
    property color danger:  "#f87171"
    property color warning: "#f5c47a"
    property color success: "#a6e3a1"

    // ── Fixed-contrast foregrounds ────────────────────────────────────────────
    // For a foreground sitting on something whose colour is NOT the themed
    // background: a knob on a filled slider track, a label on a status chip, a
    // glyph on a fixed dark overlay. Theme.text would follow the palette and
    // could land at the same lightness as the fill underneath it, so these two
    // stay put on purpose. Named for the constraint, not for a surface, so
    // nobody reads them as "the accent's foreground" and reuses them wrongly.
    property color fixedLight: "#ffffff"
    property color fixedDark:  "#1e1e2e"

    // ── Destructive filled control ────────────────────────────────────────────
    // The confirm button on a "this deletes things" dialog. A *fill*, so it is
    // much darker than `danger`, which is a foreground accent — they are not
    // interchangeable. Already identical in ConfirmDialog and KanbanBoard before
    // this became a token; a token is what stops them drifting apart.
    property color dangerFill:      "#993030"
    property color dangerFillHover: "#cc3a3a"

    // --- Workspace Visuals ---
    property color wsBackground: "#20000000"
    property color wsActive:     "#FFFFFF"
    property color wsOccupied:   "#80FFFFFF"
    property color wsEmpty:      "#30FFFFFF"
    property color wsOverlay:    "#CC1e1e2e"
    property color wsUrgent:     "#fa6b94"
}
