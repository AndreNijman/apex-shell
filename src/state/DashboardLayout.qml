pragma Singleton
import QtQuick

// ─────────────────────────────────────────────────────────────────────────────
// DashboardLayout — the dashboard's tab list and its content width, in one
// place that is not a window.
//
// Both were literals inside popups/Dashboard.qml, which is a PanelWindow. A
// window cannot be instantiated by a geometry test without a compositor, a
// layer shell and a screen, so neither the six tabs nor the width rule could be
// measured without standing up the entire shell. They are the two inputs every
// piece of the tab bar's arithmetic depends on, so they live here and the window
// reads them.
//
// This is not a settings surface. SettingsService owns what the user may
// change; this owns what the layout is, given those settings.
// ─────────────────────────────────────────────────────────────────────────────
QtObject {
    id: root

    // ── The tabs ─────────────────────────────────────────────────────────────
    // Order is the order they are drawn in, and the first is where the dashboard
    // returns when it closes.
    readonly property var tabs: [
        { key: "home",     icon: "󰋜", label: "Home"   },
        { key: "stats",    icon: "󰻠", label: "System" },
        { key: "agents",   icon: "󰚩", label: "Agents" },
        { key: "kanban",   icon: "󰄬", label: "Tasks"  },
        { key: "launcher", icon: "󱓞", label: "Apps"   },
        { key: "config",   icon: "󰒓", label: "Config" }
    ]

    // ── Per-page content width ───────────────────────────────────────────────
    // The launcher is narrower on purpose: it is a search field over a list, and
    // a 900-wide result row reads as a mistake. "agents" is absent and takes the
    // fallback, which is the same 900.
    readonly property var baseWidths: ({
        "home":     900,
        "stats":    900,
        "kanban":   900,
        "launcher": 560,
        "config":   900
    })
    readonly property int fallbackBaseWidth: 900

    function baseWidthFor(page) {
        var w = root.baseWidths[page]
        return (w !== undefined) ? w : root.fallbackBaseWidth
    }

    // Padding between the sizer's edge and the page inside it, on all four
    // sides. The tab bar's usable width is what is left.
    readonly property int contentInset: 8

    // The width the dashboard opens to on an output `screenWidth` wide.
    //
    // It currently answers the same number for every output and every scale
    // factor, which is the defect P0-017 names: the fonts inside are multiplied
    // by Theme.scale and the box holding them is not, so the content grows into
    // a container that never moves. Moved here first, unchanged, so the geometry
    // suite can measure the rule that exists before it is replaced.
    function widthFor(page, screenWidth) {
        return root.baseWidthFor(page)
    }

    // What the tab bar across the top of that page actually gets.
    function barWidthFor(page, screenWidth) {
        return root.widthFor(page, screenWidth) - 2 * root.contentInset
    }
}
