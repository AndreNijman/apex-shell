import QtQuick
import "../services"

// ─────────────────────────────────────────────────────────────────────────────
// ThemeSet — the shell's geometry tokens, as a function of ONE scale factor.
//
// This is the token table that used to live inside theme/Metrics.qml. It moved
// out for the same reason the breakpoint table moved to theme/scaling.js: a
// value that can only exist once cannot be computed for a second output, and a
// second copy of it is the defect P1-040 was opened for.
//
// Metrics is one INSTANCE of this component — the one built at the reference
// output's factor, which is what Theme's colours and the handful of
// non-per-output readers still go through.
//
// Every surface builds its own instance, at the factor theme/OutputScale gives
// its output. A registry of five shared sets — one per factor the table can
// answer — was tried and removed; OutputScale.qml carries the measurement.
//
// A surface takes the set for the output it is drawn on:
//
//     readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForScreen(root.screen) }     // a window
//     readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // an Item
//
// and reads `theme.px(...)` where it used to read `Theme.px(...)`. There is one
// table and every set is an instance of it, so a token changed here changes for
// all of them.
//
// COLOURS ARE NOT IN HERE, deliberately. A palette is a property of the shell,
// not of an output: two monitors showing different accent colours would be a
// bug. A migrated file therefore reads its SIZES from `theme.` and its COLOURS
// from `Theme.`, and the split is visible at every call site rather than hidden.
//
// User settings are expressed in 1080p-baseline units and scaled from there, so
// a settings.json stays correct when moved between machines.
// ─────────────────────────────────────────────────────────────────────────────
QtObject {
    id: set

    /// The magnification this set is built at. 1.0 is the calibrated baseline.
    /// Set it from OutputScale rather than computing a factor here — the policy
    /// that decides between the breakpoint table and the user's manual override
    /// lives in exactly one place.
    property real scale: 1.0

    // Round to whole pixels: fractional geometry on a layer-shell surface gives
    // blurry borders and off-by-one masks.
    function px(v) {
        return Math.round(v * set.scale)
    }

    // Fonts get a floor — below about 7px text stops being legible at any DPI.
    function fs(v) {
        return Math.max(7, Math.round(v * set.scale))
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

    // -- Radius roles (UI/UX roadmap Phase 2) --
    // Derived from the two radius settings rather than written as numbers, so a
    // settings.json that changed cornerRadius or notchRadius moves every role
    // with it. XS and S are fixed: a checkbox corner is not a setting.
    property int radiusXS:   px(4)
    property int radiusS:    px(8)
    property int radiusM:    Math.round(cornerRadius * 0.7)
    property int radiusL:    cornerRadius
    property int radiusXL:   Math.round(cornerRadius * 1.4)
    property int radiusFull: 9999

    // -- The notch's two radii --
    // The shoulder is the JOIN (strip → notch, concave) and the bottom corner
    // is the OBJECT (convex). They were one number; they are two tokens now,
    // read by the bar and by every surface that grows out of a notch, so a
    // surface at progress 0 is the bar's own notch to the pixel. The bottom is
    // capped so the notch's side keeps a straight run between the two curves.
    property int notchShoulder: notchRadius
    property int notchBottom:   Math.max(0, Math.min(notchRadius + px(2),
                                     Math.floor((notchHeight - borderWidth - px(6)) / 2)))

    // -- Spacing scale --
    property int spaceXS:  px(4)
    property int spaceS:   px(8)
    property int spaceM:   px(12)
    property int spaceL:   px(16)
    property int spaceXL:  px(24)
    property int spaceXXL: px(32)

    // ── Control heights (UI/UX roadmap v3 Phase 2, brief §C.3) ──────────────
    // Visual size and hit size are separate (ApexPressable): a 20 px glyph in
    // the bar still has a 24 px target, a control anywhere else 32.
    property int controlCompact:     px(28)   // bar pills, chips
    property int controlStandard:    px(32)   // buttons, inputs, row actions
    property int controlComfortable: px(36)   // Nexus controls, toggle rows
    property int controlProminent:   px(40)   // primary action, search field, tab bar
    property int rowHeight:          px(40)   // a single-line list row
    property int rowHeightTwoLine:   px(52)
    property int tileHeight:         px(72)   // quick-setting tile
    property int hitMin:             px(32)   // the smallest target outside the bar
    property int hitBar:             px(24)   // … and inside it

    // ── Type roles (brief §C.4) ─────────────────────────────────────────────
    // Sizes per output; family and weight are global (Theme.fontUi, …). Every
    // number is drawn with tabular figures (`font.features: { "tnum": 1 }`).
    property int typeCaption:     fs(11)   // 500 · metadata, timestamps
    property int typeSection:     fs(11)   // 600 uppercase +0.6 · "CONNECTED"
    property int typeBodySmall:   fs(12)   // 400 · compact rows, menu items
    property int typeBody:        fs(13)   // 400 · the default
    property int typeBodyStrong:  fs(13)   // 600 · values, row titles, labels
    property int typeHeading:     fs(15)   // 600 · popup and card titles
    property int typePageTitle:   fs(18)   // 600 · Nexus page title
    property int typeDisplay:     fs(28)   // 600 · rare hero text
    property int typeMono:        fs(12)   // 400 mono · technical values, paths
    property int typeDisplayMono: fs(56)   // 500 mono · the dashboard clock
    property int typeIcon:        fs(15)   // the bar's glyphs, in a 20 px box

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
    // Not a size, and deliberately not scaled: a bigger monitor does not want
    // slower transitions.
    property int animDuration: SettingsService.effectiveAnim
}
