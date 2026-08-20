pragma Singleton
import QtQuick
import Quickshell
import "../services"

// ─────────────────────────────────────────────────────────────────────────────
// Metrics — geometry & timing tokens, scaled to the display.
//
// Every size in here used to be an absolute pixel literal calibrated against a
// 1080p panel, which is why the shell looked correct on exactly one class of
// monitor and wrong on every other. APEX-OS deliberately runs outputs at
// Hyprland scale 1.0 (an `auto` scale that cannot resolve to an integer buffer
// size errors the monitor rule out entirely, which is a worse failure than a
// small UI), so compensating for pixel density is the shell's job, not the
// compositor's.
//
// ── The scale factor ────────────────────────────────────────────────────────
// `scale` multiplies every geometry token and, through Theme.fs(), every font
// size. It is deliberately SUBLINEAR in resolution: a 4K panel is usually also
// physically larger, so a literal 2x would be enormous. Fixed breakpoints are
// used rather than a continuous height/1080 ratio because a continuous factor
// produces awkward fractional pixel values and shifts the whole UI on any mode
// change; breakpoints are predictable and reproducible.
//
// `physicalDotsPerInch` would be the principled input, but EDID physical size is
// missing or wrong on a great many panels, and a bad DPI reading would size the
// shell absurdly with no obvious cause. Height is boring and always right.
//
// ── Multi-monitor ───────────────────────────────────────────────────────────
// This is a GLOBAL factor. Theme and Metrics are QML singletons read directly by
// ~100 files, so one process-wide value is what the architecture can express;
// genuinely per-monitor tokens would need the scale resolved per item (an
// attached property, as upstream does in C++) or threaded through every
// component. What is supported is CHOOSING which monitor sets the scale, via
// `SettingsService.scaleScreen` — on a mixed 4K + 1080p desk you pick the one
// you actually work on. Default is the tallest connected output.
//
// User settings are expressed in 1080p-baseline units and scaled from there, so
// a settings.json stays correct when moved between machines.
// ─────────────────────────────────────────────────────────────────────────────
QtObject {
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

    // Sublinear breakpoints. Below 1080p the UI shrinks a little so a 1366x768
    // laptop does not lose half its vertical space to the bar.
    // 1200 sits in the baseline bucket deliberately: a 1920x1200 panel is 11%
    // taller than 1080p, not a density class of its own, and the shell was
    // calibrated on exactly such a panel. Putting it in the 1440p bucket would
    // enlarge the UI on the reference machine — a regression dressed up as a
    // feature.
    readonly property real autoScale: {
        const h = root.referenceHeight
        if (h < 900)  return 0.85   // 1366x768 and friends
        if (h < 1250) return 1.00   // 1080p and 1200p — the calibrated baseline
        if (h < 1600) return 1.20   // 1440p
        if (h < 2000) return 1.35   // 1600p / 1800p
        return 1.50                 // 2160p and up
    }

    readonly property real scale: SettingsService.scaleMode === "manual"
                                     ? SettingsService.scaleManual
                                     : root.autoScale

    // Round to whole pixels: fractional geometry on a layer-shell surface gives
    // blurry borders and off-by-one masks.
    function px(v) {
        return Math.round(v * root.scale)
    }

    // Fonts get a floor — below about 7px text stops being legible at any DPI.
    function fs(v) {
        return Math.max(7, Math.round(v * root.scale))
    }

    // --Bar Toggle-- (Config → Layout & Behavior)
    property bool barEnabled: SettingsService.barEnabled

    // -- Bar Sizes -- (Config → Appearance; stored in 1080p-baseline units)
    property int borderWidth:   px(SettingsService.borderWidth)
    property int cornerRadius:  px(SettingsService.cornerRadius)
    property int notchRadius:   px(SettingsService.notchRadius)
    property int notchHeight:   px(SettingsService.notchHeight)
    property int exclusionGap:  px(SettingsService.exclusionGap)
    property int spacing:       px(SettingsService.spacing)

    // -- Notch Content Padding --
    // Space added around the content inside each notch
    property int notchPadding:           px(16)   // horizontal padding each side
    property int notchHorizontalPadding: px(20)
    property int notchVerticalPadding:   px(10)
    property int notchSideMargin:        px(10)

    // -- Notch Width Constraints --
    // Each notch sizes itself to its content, clamped between min and max.
    property int lNotchMinWidth: px(180)
    property int lNotchMaxWidth: px(360)

    property int cNotchMinWidth: px(300)
    property int cNotchMaxWidth: px(360)

    property int rNotchMinWidth: px(180)
    property int rNotchMaxWidth: px(360)

    // -- Dashboard Dimensions -- (Config → Layout & Behavior)
    // Target size the center notch expands to when the dashboard is open.
    property int dashboardWidth:  px(SettingsService.dashboardWidth)
    property int dashboardHeight: px(SettingsService.dashboardHeight)

    // -- Notifications Popup Width -- (Config → Layout & Behavior)
    property int notificationsWidth: px(SettingsService.notificationsWidth)
    property int notificationToastWidth: notificationsWidth / 1.2
    property int networkPopupWidth:  px(480)

    // -- Popup Size Constraints --
    property int popupMinWidth:   px(160)
    property int popupMaxWidth:   px(420)
    property int popupMinHeight:  px(80)
    property int popupMaxHeight:  px(520)
    property int popupPadding:    px(16)

    // -- Workspace Dot Sizes --
    property int wsDotSize:     px(10)
    property int wsActiveWidth: px(24)
    property int wsSpacing:     px(6)
    property int wsPadding:     px(8)
    property int wsRadius:      px(16)

    // -- Animations -- (Config → Layout & Behavior; 0 when Reduce Motion is on)
    property int animDuration: SettingsService.effectiveAnim
}
