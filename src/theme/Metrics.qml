pragma Singleton
import QtQuick
import "../services"

// Metrics — geometry & timing tokens.
//
// The user-tunable subset is bound to SettingsService (persisted to
// settings.json and edited from Config → Appearance / Layout & Behavior), so
// changing a value there reflows the live shell. The rest stay constant.
QtObject {
    // --Bar Toggle-- (Config → Layout & Behavior)
    property bool barEnabled: SettingsService.barEnabled

    // -- Bar Sizes -- (Config → Appearance)
    property int borderWidth:   SettingsService.borderWidth
    property int cornerRadius:  SettingsService.cornerRadius
    property int notchRadius:   SettingsService.notchRadius
    property int notchHeight:   SettingsService.notchHeight
    property int exclusionGap:  SettingsService.exclusionGap
    property int spacing:       SettingsService.spacing

    // -- Notch Content Padding --
    // Space added around the content inside each notch
    property int notchPadding:           16   // horizontal padding each side
    property int notchHorizontalPadding: 20
    property int notchVerticalPadding:   10
    property int notchSideMargin:        10

    // -- Notch Width Constraints --
    // Each notch sizes itself to its content, clamped between min and max.
    property int lNotchMinWidth: 180
    property int lNotchMaxWidth: 360

    property int cNotchMinWidth: 300
    property int cNotchMaxWidth: 360

    property int rNotchMinWidth: 180
    property int rNotchMaxWidth: 360

    // -- Dashboard Dimensions -- (Config → Layout & Behavior)
    // Target size the center notch expands to when the dashboard is open.
    property int dashboardWidth:  SettingsService.dashboardWidth
    property int dashboardHeight: SettingsService.dashboardHeight

    // -- Notifications Popup Width -- (Config → Layout & Behavior)
    property int notificationsWidth: SettingsService.notificationsWidth
    property int notificationToastWidth: notificationsWidth / 1.2
    property int networkPopupWidth:  480

    // -- Popup Size Constraints --
    property int popupMinWidth:   160
    property int popupMaxWidth:   420
    property int popupMinHeight:   80
    property int popupMaxHeight:  520
    property int popupPadding:     16

    // -- Workspace Dot Sizes --
    property int wsDotSize:     10
    property int wsActiveWidth: 24
    property int wsSpacing:     6
    property int wsPadding:     8
    property int wsRadius:      16

    // -- Animations -- (Config → Layout & Behavior; 0 when Reduce Motion is on)
    property int animDuration: SettingsService.effectiveAnim
}
