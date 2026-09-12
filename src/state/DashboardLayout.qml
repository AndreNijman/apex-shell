pragma Singleton
import QtQuick
import "../"

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

    // ── Everything below takes the caller's token set ────────────────────────
    // This singleton does layout arithmetic for a window, and since P1-040 the
    // window's sizes are its OWN output's. A singleton has no output, so the
    // factor cannot be read here: `Theme.px(8)` would answer for the reference
    // monitor and the dashboard would be inset by the wrong number of pixels on
    // every other one — invisible on a single-monitor desk, which is every desk
    // this gets developed on.
    //
    // So the three scaled values became functions of a ThemeSet. The caller
    // already has one: popups/Dashboard.qml is a PanelWindow and resolves its
    // own screen's set; tests hand in whichever set they are driving.
    //
    // The tab list above is NOT a function of anything — six tabs are six tabs
    // on any monitor.

    // Padding between the sizer's edge and the page inside it, on all four
    // sides. The tab bar's usable width is what is left.
    function contentInset(theme) { return theme.px(8) }

    // ── Room between the two notches ─────────────────────────────────────────
    // The dashboard is the centre notch, grown. windows/TopBar.qml anchors the
    // other two to the screen edges and caps each at Theme.[lr]NotchMaxWidth,
    // padded by one notch radius; a centre notch wider than what is left over
    // is drawn straight through them.
    //
    // Reserved at the CAP rather than at the width the notches happen to be
    // right now. Their width is content-driven — a long window title, a fuller
    // tray — so a dashboard sized against today's left notch collides the first
    // time something in it gets longer, and it would collide by animating into
    // the collision, which is worse than being narrow.
    function sideReserve(theme) {
        return Math.max(theme.lNotchMaxWidth, theme.rNotchMaxWidth)
               + theme.notchRadius + theme.spacing
    }

    function roomOn(theme, screenWidth) {
        return Math.max(0, screenWidth - 2 * root.sideReserve(theme))
    }

    // The width the dashboard opens to on an output `screenWidth` wide.
    //
    // Two things it did not used to do. It scales: the base width is a 1080p
    // measurement and everything drawn inside it is multiplied by the output's
    // so a container that stayed at 900 was a container the content grew out
    // of. And it yields: on an output too narrow to hold the wanted width
    // between the notches, the width that fits wins.
    // Six icon-only tabs and some air. Below this there is no dashboard, only a
    // sliver, so this is where yielding stops.
    function minWidth(theme) { return theme.px(280) }

    function widthFor(theme, page, screenWidth) {
        var want = theme.px(root.baseWidthFor(page))
        if (!screenWidth || screenWidth <= 0)
            return want
        // On an output with no room for both, the dashboard wins: overlapping a
        // notch is a cosmetic defect on a bar, and a dashboard narrower than its
        // own tab bar is not a dashboard. Reachable only by forcing a scale
        // factor an output cannot carry — 150% on a 1280x720 panel leaves
        // 853x480 of usable space — and it must degrade rather than collapse.
        return Math.max(Math.min(want, root.roomOn(theme, screenWidth)),
                        Math.min(want, root.minWidth(theme)))
    }

    // What the tab bar across the top of that page gets.
    function barWidthFor(theme, page, screenWidth) {
        return Math.max(0, root.widthFor(theme, page, screenWidth)
                          - 2 * root.contentInset(theme))
    }
}
