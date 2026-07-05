import QtQuick
import "../../../"
import "../../../components/config"

// Config → Layout & Behavior
//   • Bar & frame visibility
//   • Motion — reduce-motion + animation speed
//   • Spacing — element gap / screen-edge exclusion
//   • Dashboard & popup dimensions
// Every control writes through SettingsService.set(key, value) → persisted +
// reflowed live via Metrics.
CfgScroll {
    id: root

    // ── Bar & Frame ───────────────────────────────────────────────────────────
    CfgSection {
        title: "Bar & Frame"
        first: true

        CfgRow {
            label:       "Top bar"
            description: "Show the top status bar"
            CfgSwitch {
                checked:   SettingsService.barEnabled
                onToggled: function(v) { SettingsService.set("barEnabled", v) }
            }
        }
    }

    // ── Motion ────────────────────────────────────────────────────────────────
    CfgSection {
        title: "Motion"

        CfgRow {
            label:       "Reduce motion"
            description: "Turn off animations across the shell"
            CfgSwitch {
                checked:   SettingsService.reduceMotion
                onToggled: function(v) { SettingsService.set("reduceMotion", v) }
            }
        }
        CfgRow {
            label:       "Animation speed"
            description: "Base duration for transitions"
            CfgSlider {
                from: 0; to: 1200; step: 20; suffix: "ms"
                value:   SettingsService.animDuration
                onMoved: function(v) { SettingsService.set("animDuration", v) }
            }
        }
    }

    // ── Spacing ───────────────────────────────────────────────────────────────
    CfgSection {
        title: "Spacing"

        CfgRow {
            label: "Element gap"
            CfgSlider {
                from: 0; to: 40; step: 1; suffix: "px"
                value:   SettingsService.spacing
                onMoved: function(v) { SettingsService.set("spacing", v) }
            }
        }
        CfgRow {
            label:       "Screen edge gap"
            description: "Reserved space at the screen edges"
            CfgSlider {
                from: 0; to: 80; step: 1; suffix: "px"
                value:   SettingsService.exclusionGap
                onMoved: function(v) { SettingsService.set("exclusionGap", v) }
            }
        }
    }

    // ── Dashboard & Popups ────────────────────────────────────────────────────
    CfgSection {
        title: "Dashboard & Popups"

        CfgRow {
            label: "Dashboard height"
            CfgSlider {
                from: 360; to: 900; step: 10; suffix: "px"
                value:   SettingsService.dashboardHeight
                onMoved: function(v) { SettingsService.set("dashboardHeight", v) }
            }
        }
        CfgRow {
            label: "Notifications width"
            CfgSlider {
                from: 280; to: 640; step: 10; suffix: "px"
                value:   SettingsService.notificationsWidth
                onMoved: function(v) { SettingsService.set("notificationsWidth", v) }
            }
        }
    }

    // ── Reset ─────────────────────────────────────────────────────────────────
    CfgSection {
        title: "Reset"

        Item {
            width:  parent.width
            height: 32
            CfgButton {
                x:     10
                label: "Reset layout to defaults"
                icon:  "↺"
                onClicked: {
                    SettingsService.set("barEnabled",         false)
                    SettingsService.set("reduceMotion",       false)
                    SettingsService.set("animDuration",       320)
                    SettingsService.set("spacing",            10)
                    SettingsService.set("exclusionGap",       34)
                    SettingsService.set("dashboardHeight",    520)
                    SettingsService.set("notificationsWidth", 400)
                }
            }
        }
    }

    Item { width: parent.width; height: 10 }
}
