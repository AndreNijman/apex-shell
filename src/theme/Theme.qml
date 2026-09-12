pragma Singleton
import QtQuick
import "."

QtObject {
    // ── Bindings to Modular Singletons ────────────────────────────────────────
    // Note: property alias cannot point to other singletons, so we use direct bindings.
    
    // Colors
    property color background: Colors.background
    property color active:     Colors.active
    property color text:       Colors.text
    property color subtext:    Colors.subtext
    property color icon:       Colors.icon
    property color border:     Colors.border
    property color iconFont:   Colors.iconFont

    // Status and fixed-contrast tokens. Mirrored here because every call site in
    // the tree reads Theme.*, so exposing these on Colors alone would have left
    // the shell reading two different singletons for its colours.
    property color danger:    Colors.danger
    property color warning:   Colors.warning
    property color success:   Colors.success
    property color info:      Colors.info
    property color attention: Colors.attention

    property color fixedLight: Colors.fixedLight
    property color fixedDark:  Colors.fixedDark

    // True while the palette's surface is dark. Read it to choose a treatment,
    // never to choose a colour — a call site that branches on it is writing a
    // second palette next to this one.
    readonly property bool darkSurface: Colors.darkSurface

    // The readable foreground for a glyph or label drawn ON a status fill.
    function onStatus(fill) { return Colors.onStatus(fill) }

    property color dangerFill:      Colors.dangerFill
    property color dangerFillHover: Colors.dangerFillHover

    property color wsBackground: Colors.wsBackground
    property color wsActive:     Colors.wsActive
    property color wsOccupied:   Colors.wsOccupied
    property color wsEmpty:      Colors.wsEmpty
    property color wsOverlay:    Colors.wsOverlay
    property color wsUrgent:     Colors.wsUrgent

    // ── Scaling ───────────────────────────────────────────────────────────────
    // fs() scales a font size that was calibrated against 1080p. Call it instead
    // of writing a literal: `font.pixelSize: Theme.fs(12)`. px() is the same for
    // geometry written at a call site rather than defined as a token here.
    readonly property real scale: Metrics.scale

    function fs(v) { return Metrics.fs(v) }
    function px(v) { return Metrics.px(v) }

    // ── Per-output sizing (P1-040) ────────────────────────────────────────────
    // The scalers above are the REFERENCE output's, which is all the shell has
    // for the 2758 call sites across 116 files that read this singleton. A
    // surface that is built per output and sizes only itself does not have to
    // accept that: it builds its own ThemeSet at the factor its own screen
    // deserves.
    //
    //     readonly property ThemeSet theme: ThemeSet {
    //         scale: Theme.factorForScreen(root.screen)
    //     }
    //
    // and reads `theme.px(...)` for sizes while still reading `Theme.<colour>`
    // for colours, because a palette belongs to the shell rather than to a
    // monitor. The policy — the breakpoint table, and the manual override that
    // outranks it — lives in theme/OutputScale.qml and is the same policy that
    // produced `scale` above, so a per-output surface and the global set can
    // never be answering two different questions.
    function factorForScreen(screen) { return OutputScale.factorForScreen(screen) }
    function factorForHeight(h)      { return OutputScale.factorForHeight(h) }


    // Metrics
    property bool barEnabled: Metrics.barEnabled
    
    property int borderWidth:   Metrics.borderWidth
    property int cornerRadius:  Metrics.cornerRadius
    property int notchRadius:   Metrics.notchRadius
    property int notchHeight:   Metrics.notchHeight
    property int exclusionGap:  Metrics.exclusionGap
    property int spacing:       Metrics.spacing

    property int notchPadding:           Metrics.notchPadding
    property int notchHorizontalPadding: Metrics.notchHorizontalPadding
    property int notchVerticalPadding:   Metrics.notchVerticalPadding
    property int notchSideMargin:        Metrics.notchSideMargin

    property int lNotchMinWidth: Metrics.lNotchMinWidth
    property int lNotchMaxWidth: Metrics.lNotchMaxWidth
    property int cNotchMinWidth: Metrics.cNotchMinWidth
    property int cNotchMaxWidth: Metrics.cNotchMaxWidth
    property int rNotchMinWidth: Metrics.rNotchMinWidth
    property int rNotchMaxWidth: Metrics.rNotchMaxWidth

    property int dashboardWidth:  Metrics.dashboardWidth
    property int dashboardHeight: Metrics.dashboardHeight

    property int notificationsWidth: Metrics.notificationsWidth
    property int notificationToastWidth: Metrics.notificationToastWidth
    property int networkPopupWidth:  Metrics.networkPopupWidth

    property int popupMinWidth:   Metrics.popupMinWidth
    property int popupMaxWidth:   Metrics.popupMaxWidth
    property int popupMinHeight:   Metrics.popupMinHeight
    property int popupMaxHeight:  Metrics.popupMaxHeight
    property int popupPadding:     Metrics.popupPadding

    property int wsDotSize:     Metrics.wsDotSize
    property int wsActiveWidth: Metrics.wsActiveWidth
    property int wsSpacing:     Metrics.wsSpacing
    property int wsPadding:     Metrics.wsPadding
    property int wsRadius:      Metrics.wsRadius

    property int animDuration: Metrics.animDuration
}
