pragma Singleton
import QtQuick
import "../services/config_tab"
import "../services/config_tab/pages"

// ─────────────────────────────────────────────────────────────────────────────
// PageRegistry — the single definition of the shell's settings pages.
//
// There are two places settings are presented: the dashboard's Config tab, and
// the standalone Nexus window. Before this, the dashboard tab hardcoded its own
// tab list AND its own five Loaders, so adding a page meant editing two lists in
// the same file and any new surface would have needed a third copy.
//
// Now both read from here. A page is declared once — id, title, icon, and the
// Component that renders it — and appears everywhere.
//
// `needsScreen` marks pages that consume refcounted telemetry services and must
// therefore be told whether they are genuinely on screen (see ServiceRef). Only
// Data & Storage does today; getting it wrong on a new page means a poller that
// never stops, so it is declared rather than inferred.
// ─────────────────────────────────────────────────────────────────────────────

QtObject {
    id: root

    readonly property var pages: [
        {
            "id": "appearance",
            "title": "Appearance",
            "subtitle": "Palette, wallpaper, lock screen, shape",
            "icon": "󰏘",
            "needsScreen": false,
            "component": appearanceComp
        },
        {
            "id": "layout",
            "title": "Layout & Behavior",
            "subtitle": "Scaling, bar, motion, spacing, dimensions",
            "icon": "󰕰",
            "needsScreen": false,
            "component": layoutComp
        },
        {
            "id": "data",
            "title": "Data & Storage",
            "subtitle": "Disks, memory, clipboard, notifications",
            "icon": "󰋊",
            "needsScreen": true,
            "component": dataComp
        },
        {
            "id": "input",
            "title": "Input",
            "subtitle": "Touchpad, mouse, keyboard repeat",
            "icon": "󰟸",
            "needsScreen": false,
            "component": inputComp
        },
        {
            "id": "display",
            "title": "Display",
            "subtitle": "Resolution, refresh, scale, rotation, arrangement",
            "icon": "󰍹",
            "needsScreen": false,
            "component": displayComp
        },
        {
            "id": "keybinds",
            "title": "Keybinds",
            "subtitle": "Shortcuts for every popup",
            "icon": "󰌌",
            "needsScreen": false,
            "component": keybindsComp
        },
        {
            "id": "misc",
            "title": "Misc",
            "subtitle": "Compositor, updates, about",
            "icon": "󰒓",
            "needsScreen": false,
            "component": miscComp
        }
    ]

    function pageFor(id) {
        for (const p of root.pages)
            if (p.id === id)
                return p
        return null
    }

    function has(id) {
        return root.pageFor(id) !== null
    }

    readonly property string firstId: root.pages.length > 0 ? root.pages[0].id : ""

    // The components live here rather than inline in the list so the list stays
    // readable and each page is named once.
    readonly property Component appearanceComp: Component {
        AppearancePage {}
    }
    readonly property Component layoutComp: Component {
        LayoutPage {}
    }
    readonly property Component dataComp: Component {
        DataPage {}
    }
    readonly property Component inputComp: Component {
        InputPage {}
    }
    readonly property Component displayComp: Component {
        DisplayPage {}
    }
    readonly property Component keybindsComp: Component {
        KeybindsPage {}
    }
    readonly property Component miscComp: Component {
        MiscPage {}
    }
}
