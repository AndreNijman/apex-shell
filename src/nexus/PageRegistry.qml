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
// therefore be told whether they are genuinely on screen (see ServiceRef). Data
// & Storage and Misc do; getting it wrong on a new page means a poller that
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
            "id": "blueprint",
            "title": "Blueprint",
            "subtitle": "What this machine should be, and what differs",
            "icon": "󰦑",
            "needsScreen": false,
            "component": blueprintComp
        },
        {
            "id": "recovery",
            "title": "Recovery",
            "subtitle": "Health, rollback, repair, ways back in",
            "icon": "󰑙",
            // RecoveryService runs `apex recover status --json` and
            // `apex doctor --json` on a sweep timer while this page is looked
            // at, and nothing at all when it is not. Getting this wrong means
            // two `apex` processes every 20 seconds until logout.
            "needsScreen": true,
            "component": recoveryComp
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
            // SystemStats lives in the About area and shells out to collect
            // distro/kernel/uptime/packages, so this page has to be told
            // whether anyone is looking.
            "needsScreen": true,
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
    readonly property Component blueprintComp: Component {
        BlueprintPage {}
    }
    readonly property Component recoveryComp: Component {
        RecoveryPage {}
    }
    readonly property Component keybindsComp: Component {
        KeybindsPage {}
    }
    readonly property Component miscComp: Component {
        MiscPage {}
    }
}
