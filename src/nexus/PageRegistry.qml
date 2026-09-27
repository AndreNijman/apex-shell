pragma Singleton
import QtQuick
import "../services/config_tab"
import "../services/config_tab/pages"

// ─────────────────────────────────────────────────────────────────────────────
// PageRegistry — the single definition of the shell's settings pages.
//
// Settings are presented in one place: Nexus, through SettingsHost (UI/UX
// Phase 19). There used to be two — the dashboard's Config tab as well — and
// before this registry the dashboard tab hardcoded its own tab list AND its own
// five Loaders, so adding a page meant editing two lists. A page is declared
// once — id, title, icon, and the Component that renders it — and the host and
// the suites (settings-staged, nav-geometry) all read it from here.
//
// `group` is the navigation's section (UI/UX Phase 19b): the pages are listed
// in group order, and NavPane draws a section label above the first page of
// each group. Sixteen pages in one flat column read as a pile; five groups — what
// it looks like, how you drive it, who may reach what, the devices paired to it,
// and the machine itself — read as a map.
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
            "group": "Look & feel",
            "title": "Appearance",
            "subtitle": "Palette, wallpaper, lock screen, shape",
            "icon": "󰏘",
            "needsScreen": false,
            "component": appearanceComp
        },
        {
            "id": "layout",
            "group": "Look & feel",
            "title": "Layout & Behavior",
            "subtitle": "Scaling, bar, motion, spacing, dimensions",
            "icon": "󰕰",
            "needsScreen": false,
            "component": layoutComp
        },
        {
            "id": "display",
            "group": "Look & feel",
            "title": "Display",
            "subtitle": "Resolution, refresh, scale, rotation, arrangement",
            "icon": "󰍹",
            "needsScreen": false,
            "component": displayComp
        },
        {
            "id": "input",
            "group": "Input",
            "title": "Input",
            "subtitle": "Touchpad, mouse, keyboard repeat",
            "icon": "󰟸",
            "needsScreen": false,
            "component": inputComp
        },
        {
            "id": "keybinds",
            "group": "Input",
            "title": "Keybinds",
            "subtitle": "Shortcuts for every popup",
            "icon": "󰌌",
            "needsScreen": false,
            "component": keybindsComp
        },
        {
            "id": "privacy",
            "group": "Privacy & agents",
            "title": "Privacy & Permissions",
            "subtitle": "Camera, microphone, capture, files, and who enforces each",
            "icon": "󰒃",
            // PermissionsService runs one `apex permissions list --json` per
            // sweep, and that command runs a `flatpak info` per installed
            // application. Getting this wrong means a burst of Flatpak
            // processes every 30 seconds until logout.
            "needsScreen": true,
            "component": privacyComp
        },
        {
            "id": "firewall",
            "group": "Privacy & agents",
            "title": "Firewall",
            "subtitle": "What is reachable from the network, and what you opened",
            "icon": "󰕥",
            // FirewallService runs three reads on a slow sweep while this page
            // is looked at, and nothing at all when it is not.
            "needsScreen": true,
            "component": firewallComp
        },
        {
            "id": "agents",
            "group": "Privacy & agents",
            "title": "Agents",
            "subtitle": "The sandbox new agent sessions start in",
            "icon": "󰚩",
            // AgentService forks `apex agent list` on a timer and is
            // refcounted on it. The page lists what is running so it can show
            // each session's own mode, so it holds a ref and has to be told
            // whether anyone is looking.
            "needsScreen": true,
            "component": agentsComp
        },
        {
            "id": "remote-pair",
            "group": "Devices",
            "title": "Pair a device",
            "subtitle": "Show a code for APEX Remote on your phone to scan",
            "icon": "",
            // Stronger than elsewhere: `apex remote pair` MINTS a one-time
            // token, so this page must not be built for somebody who never
            // opened it.
            "needsScreen": true,
            "component": remotePairComp
        },
        {
            "id": "remote-devices",
            "group": "Devices",
            "title": "Paired devices",
            "subtitle": "Every phone that can reach this machine, and how to revoke one",
            "icon": "",
            "needsScreen": true,
            "component": remoteDevicesComp
        },
        {
            "id": "data",
            "group": "System",
            "title": "Data & Storage",
            "subtitle": "Disks, memory, clipboard, notifications",
            "icon": "󰋊",
            "needsScreen": true,
            "component": dataComp
        },
        {
            "id": "lid",
            "group": "System",
            "title": "Closing the Lid",
            "subtitle": "What a shut lid does while work is running, and what it cost last time",
            "icon": "󰶐",
            // LidService runs `apex lid status --json` and `apex lid report
            // --json` one after the other on a sweep timer while this page is
            // looked at, and nothing at all when it is not. Getting this wrong
            // means two `apex` processes every 15 seconds until logout.
            "needsScreen": true,
            "component": lidComp
        },
        {
            "id": "gaming",
            "group": "System",
            "title": "Gaming",
            "subtitle": "Gaming Mode, what it needs, and the performance policy",
            "icon": "󰊴",
            // GamingService runs `apex gaming` and `apex mode status` when the
            // page is opened and when the user presses Refresh, and nothing on
            // a timer — `apex mode set --auto` is one-shot by design, so a
            // poller here would be the shell inventing a daemon the OS declined
            // to ship. Nothing to refcount, so nothing to tell about the screen.
            "needsScreen": false,
            "component": gamingComp
        },
        {
            "id": "recovery",
            "group": "System",
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
            "id": "blueprint",
            "group": "System",
            "title": "Blueprint",
            "subtitle": "What this machine should be, and what differs",
            "icon": "󰦑",
            "needsScreen": false,
            "component": blueprintComp
        },
        {
            "id": "misc",
            "group": "System",
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
    readonly property Component gamingComp: Component {
        GamingPage {}
    }
    readonly property Component recoveryComp: Component {
        RecoveryPage {}
    }
    readonly property Component privacyComp: Component {
        PrivacyPage {}
    }
    readonly property Component agentsComp: Component {
        AgentsPage {}
    }
    readonly property Component lidComp: Component {
        LidPage {}
    }
    readonly property Component firewallComp: Component {
        FirewallPage {}
    }
    readonly property Component remotePairComp: Component {
        RemotePairPage {}
    }
    readonly property Component remoteDevicesComp: Component {
        RemoteDevicesPage {}
    }
    readonly property Component keybindsComp: Component {
        KeybindsPage {}
    }
    readonly property Component miscComp: Component {
        MiscPage {}
    }
}
