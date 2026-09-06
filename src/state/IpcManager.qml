pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../"
import "../nexus"

// ─────────────────────────────────────────────────────────────
// IpcManager — centralized entry point for all external IPC signals.
//
// Moving handlers here ensures that on multi-monitor setups (where 
// TopBar/PopupLayer are duplicated) only ONE handler reacts to a signal.
// ─────────────────────────────────────────────────────────────

QtObject {
    id: root

    // ── Dashboard Toggles ────────────────────────────────────

    // Which output the user is looking at, so a dashboard toggled by a keybind
    // opens on the monitor with focus rather than on all of them.
    //
    // The per-compositor answers moved into CompositorService: Hyprland has a
    // focused monitor, niri reports the output on the focused workspace, and
    // labwc reports the screens of the active toplevel. labwc got an answer out
    // of that move — it used to fall through to "the first screen", which is the
    // wrong monitor half the time on a two-monitor desk.
    function focusedScreenName() {
        const name = CompositorService.focusedOutput
        if (name !== "") return name

        // Nothing focused, or a compositor APEX has no adapter for.
        return Quickshell.screens.length > 0 ? Quickshell.screens[0].name : ""
    }

    function toggleDashboard(page) {
        if (Popups.anyOpen && !Popups.dashboardOpen) {
            Popups.closeAll()
            Popups.dashboardScreen = focusedScreenName()
            Popups.dashboardPage = page
            Popups.dashboardOpen = true
        } else if (Popups.dashboardOpen && Popups.dashboardPage !== page) {
            Popups.dashboardPage = page
        } else {
            var next = !Popups.dashboardOpen
            Popups.closeAll()
            if (next) {
                Popups.dashboardScreen = focusedScreenName()
                Popups.dashboardPage = page
            }
            Popups.dashboardOpen = next
        }
    }

    property var dashboardHome: IpcHandler {
        target: "dashboard-home"
        function toggle() { root.toggleDashboard("home") }
    }

    property var dashboardStats: IpcHandler {
        target: "dashboard-stats"
        function toggle() { root.toggleDashboard("stats") }
    }

    property var dashboardAgents: IpcHandler {
        target: "dashboard-agents"
        function toggle() { root.toggleDashboard("agents") }
    }

    property var dashboardKanban: IpcHandler {
        target: "dashboard-kanban"
        function toggle() { root.toggleDashboard("kanban") }
    }

    property var dashboardLauncher: IpcHandler {
        target: "dashboard-launcher"
        function toggle() { root.toggleDashboard("launcher") }
    }

    property var dashboardConfig: IpcHandler {
        target: "dashboard-config"
        function toggle() { root.toggleDashboard("config") }
    }

    // ── Nexus (standalone settings window) ───────────────────
    // Deliberately not routed through Popups: Nexus is a window you leave open
    // while you work, and Popups.closeAll() is wired to click-outside and to
    // compositor focus changes, which would close it constantly.
    //
    // `page` is optional on every function so a bare `nexus toggle` works as a
    // single keybind, while `nexus open keybinds` jumps straight to a page.
    property var nexus: IpcHandler {
        target: "nexus"

        function open(page: string): string {
            if (page !== "" && !PageRegistry.has(page))
                return "unknown page: " + page + " (try: " + root.nexusPageIds() + ")"
            NexusState.openAt(page, root.focusedScreenName())
            return "nexus open at " + NexusState.page
        }

        function close(): string {
            NexusState.close()
            return "nexus closed"
        }

        function toggle(page: string): string {
            if (page !== "" && !PageRegistry.has(page))
                return "unknown page: " + page + " (try: " + root.nexusPageIds() + ")"
            NexusState.toggle(page, root.focusedScreenName())
            return NexusState.open ? "nexus open at " + NexusState.page : "nexus closed"
        }

        // So `apex shell nexus --list` and tab-completion have a source of
        // truth that cannot drift from the registry.
        function pages(): string {
            return root.nexusPageIds()
        }
    }

    function nexusPageIds() {
        const ids = []
        for (const p of PageRegistry.pages)
            ids.push(p.id)
        return ids.join(" ")
    }

    // ── Display transactions ─────────────────────────────────
    // The one settings domain that can take away the pointer you would use to
    // fix it. The dialog is now built on every output so it survives the apply
    // that raised it, but "every output" is still every output the compositor
    // has left — and if that set is empty or unreadable, the only remaining way
    // to answer is from a TTY:
    //
    //     apex shell display status
    //     apex shell display revert
    //
    // Deliberately not a second implementation of the transaction: every verb
    // is the same call the dialog's buttons make.
    property var display: IpcHandler {
        target: "display"

        /// name field value — stage one change, exactly as the page does.
        function set(name: string, field: string, value: string): string {
            if (name === "" || field === "")
                return "usage: display set <output> <field> <value>"
            let v = value
            if (value === "true")  v = true
            else if (value === "false") v = false
            else if (value !== "" && !isNaN(Number(value)) && field !== "transform")
                v = Number(value)
            DisplayService.stage(name, field, v)
            return DisplayService.dirty ? "staged " + name + " " + field + "=" + value
                                        : "no output called " + name
        }

        function apply(): string {
            if (DisplayService.pending)
                return "a display change is already waiting to be confirmed"
            if (!DisplayService.dirty)
                return "nothing staged"
            DisplayService.apply()
            return "applying"
        }

        function keep(): string {
            if (!DisplayService.pending) return "nothing to keep"
            DisplayService.confirm()
            return "kept"
        }

        function revert(): string {
            DisplayService.revertApplied()
            return "reverted"
        }

        /// Everything a person on a TTY needs before deciding, in one line.
        function status(): string {
            const bits = []
            bits.push(DisplayService.pending
                ? "waiting " + DisplayService.confirmSeconds + "s"
                : "idle")
            bits.push(DisplayService.dirty ? "staged" : "clean")
            if (DisplayService.confirmScreen !== "")
                bits.push("dialog on " + DisplayService.confirmScreen)
            if (DisplayService.lastError !== "")
                bits.push("error: " + DisplayService.lastError)
            if (DisplayService.lastNotice !== "")
                bits.push("note: " + DisplayService.lastNotice)
            return bits.join(" | ")
        }

        function refresh(): string {
            DisplayService.refresh()
            return "re-reading the outputs"
        }
    }

    // ── Agents & Workspaces help (§43) ───────────────────────
    // The guide's own "Keys and commands" section prints these lines, so a user
    // who dismissed the first-run card has a documented way to get it back and
    // a keybind target for the guide itself.
    //
    // `toggle` takes nothing and `open` takes a section, because quickshell
    // requires every declared argument at the call site: `ipc call agent-help
    // open` with no argument is refused, not defaulted. One verb per arity is
    // the only shape that gives a keybind a bare command AND gives the guide a
    // way to jump to a page.
    //
    // Both pull the Agents tab up with them. A guide floating over the Home
    // page would explain a list the user cannot see.
    property var agentHelp: IpcHandler {
        target: "agent-help"

        function toggle(): string {
            if (AgentHelp.panelOpen) {
                AgentHelp.close()
                return "agent help closed"
            }
            return root.openAgentHelp(AgentHelp.section)
        }

        function open(section: string): string {
            return root.openAgentHelp(section)
        }

        function close(): string {
            AgentHelp.close()
            return "agent help closed"
        }

        // Permanent, and the one call the first-run card's button makes.
        function dismiss(): string {
            AgentHelp.dismissOnboarding()
            return "first-run card dismissed"
        }

        function reset(): string {
            AgentHelp.resetOnboarding()
            return "first-run card restored"
        }

        function state(): string {
            return (AgentHelp.panelOpen ? "guide open at " + AgentHelp.section : "guide closed")
                 + ", first-run card "
                 + (AgentHelp.showOnboarding ? "shown" : "dismissed")
        }

        function sections(): string {
            return root.agentHelpSections()
        }
    }

    function openAgentHelp(section) {
        const id = (section === undefined || section === null) ? "" : String(section)
        if (id !== "" && !agentHelpHas(id))
            return "unknown section: " + id + " (try: " + agentHelpSections() + ")"
        if (!Popups.dashboardOpen || Popups.dashboardPage !== "agents")
            toggleDashboard("agents")
        AgentHelp.open(id)
        return "agent help open at " + AgentHelp.section
    }

    // Asked of the content singleton rather than listed here, so the ids the
    // IPC accepts cannot drift from the sections the guide draws.
    function agentHelpSections() {
        const ids = []
        for (const s of AgentHelpContent.sections)
            ids.push(s.id)
        return ids.join(" ")
    }

    function agentHelpHas(id) {
        for (const s of AgentHelpContent.sections)
            if (s.id === id) return true
        return false
    }

    // ── Audio Toggles ────────────────────────────────────────

    property var audioOut: IpcHandler {
        target: "audioOut-toggle"
        function toggle() {
            if(Popups.anyOpen && !Popups.audioOpen) {
                Popups.closeAll()
                Popups.audioPage = "output"
                Popups.audioOpen = true
            } else if (Popups.audioOpen && Popups.audioPage != "output") {
                Popups.audioPage = "output"
            } else {
                var next = !Popups.audioOpen
                Popups.closeAll()
                Popups.audioOpen = next
                if (next) Popups.audioPage = "output"
            }
        }
    }

    property var audioMix: IpcHandler {
        target: "audioMix-toggle"
        function toggle() {
            if(Popups.anyOpen && !Popups.audioOpen) {
                Popups.closeAll()
                Popups.audioPage = "mixer"
                Popups.audioOpen = true
            } else if (Popups.audioOpen && Popups.audioPage != "mixer") {
                Popups.audioPage = "mixer"
            } else {
                var next = !Popups.audioOpen
                Popups.closeAll()
                Popups.audioOpen = next
                if (next) Popups.audioPage = "mixer"
            }
        }
    }

    property var audioIn: IpcHandler {
        target: "audioIn-toggle"
        function toggle() {
            if(Popups.anyOpen && !Popups.audioOpen) {
                Popups.closeAll()
                Popups.audioPage = "input"
                Popups.audioOpen = true
            } else if (Popups.audioOpen && Popups.audioPage != "input") {
                Popups.audioPage = "input"
            } else {
                var next = !Popups.audioOpen
                Popups.closeAll()
                Popups.audioOpen = next
                if (next) Popups.audioPage = "input"
            }
        }
    }

    // ── Network Toggles ──────────────────────────────────────

    property var wifiToggle: IpcHandler {
        target: "wifi-toggle"
        function toggle() {
            if(Popups.anyOpen && !Popups.networkOpen) {
                Popups.closeAll()
                Popups.networkPage = "wifi"
                Popups.networkOpen = true
            } else if (Popups.networkOpen && Popups.networkPage != "wifi") {
                Popups.networkPage = "wifi"
            } else {
                var next = !Popups.networkOpen
                Popups.closeAll()
                Popups.networkOpen = next
                if (next) Popups.networkPage = "wifi"
            }
        }
    }

    property var btToggle: IpcHandler {
        target: "bluetooth-toggle"
        function toggle() {
            if(Popups.anyOpen && !Popups.networkOpen) {
                Popups.closeAll()
                Popups.networkPage = "bluetooth"
                Popups.networkOpen = true
            } else if (Popups.networkOpen && Popups.networkPage != "bluetooth") {
                Popups.networkPage = "bluetooth"
            } else {
                var next = !Popups.networkOpen
                Popups.closeAll()
                Popups.networkOpen = next
                if (next) Popups.networkPage = "bluetooth"
            }
        }
    }

    property var vpnToggle: IpcHandler {
        target: "vpn-toggle"
        function toggle() {
            if(Popups.anyOpen && !Popups.networkOpen) {
                Popups.closeAll()
                Popups.networkPage = "vpn"
                Popups.networkOpen = true
            } else if (Popups.networkOpen && Popups.networkPage != "vpn") {
                Popups.networkPage = "vpn"
            } else {
                var next = !Popups.networkOpen
                Popups.closeAll()
                Popups.networkOpen = next
                if (next) Popups.networkPage = "vpn"
            }
        }
    }

    property var hotspotToggle: IpcHandler {
        target: "hotspot-toggle"
        function toggle() {
            if(Popups.anyOpen && !Popups.networkOpen) {
                Popups.closeAll()
                Popups.networkPage = "hotspot"
                Popups.networkOpen = true
            } else if (Popups.networkOpen && Popups.networkPage != "hotspot") {
                Popups.networkPage = "hotspot"
            } else {
                var next = !Popups.networkOpen
                Popups.closeAll()
                Popups.networkOpen = next
                if (next) Popups.networkPage = "hotspot"
            }
        }
    }

    // ── Misc Toggles ─────────────────────────────────────────

    property var notification: IpcHandler {
        target: "notification-toggle"
        function toggle() {
            var next = !Popups.notificationsOpen
            Popups.closeAll()
            Popups.notificationsOpen = next
        }
    }

    // Desktop right-click menu. `open` rather than `toggle` for the mousebind
    // path: a second right-click should reposition the menu at the new cursor
    // position, not dismiss it, which is what every desktop does.
    property var contextMenu: IpcHandler {
        target: "context-menu"
        function open() {
            if (Popups.contextMenuOpen) {
                // Force the popup to re-read the pointer position.
                Popups.contextMenuOpen = false
                reopen.restart()
            } else {
                Popups.closeAll()
                Popups.contextMenuOpen = true
            }
        }
        function toggle() {
            var next = !Popups.contextMenuOpen
            Popups.closeAll()
            Popups.contextMenuOpen = next
        }
        function close() { Popups.contextMenuOpen = false }
    }

    property var reopen: Timer {
        interval: 1
        onTriggered: { Popups.closeAll(); Popups.contextMenuOpen = true }
    }

    property var clipboard: IpcHandler {
        target: "clipboard-toggle"
        function toggle() {
            var next = !Popups.clipboardOpen
            Popups.closeAll()
            Popups.clipboardOpen = next
        }
    }

    property var wallpaper: IpcHandler {
        target: "wallpaper-toggle"
        function toggle() {
            var next = !Popups.wallpaperOpen
            Popups.closeAll()
            Popups.wallpaperOpen = next
        }
    }

    property var archMenu: IpcHandler {
        target: "PowerMenu-toggle"
        function toggle() {
            var next = !Popups.archMenuOpen
            Popups.closeAll()
            Popups.archMenuOpen = next
        }
    }

    property var screenRec: IpcHandler {
        target: "screenrec-on"
        function toggle() {
            if (ScreenRecService.recording) {
                 ScreenRecService.stopRecording()
             } else if (ShellState.screenRecord) {
                 ScreenRecService.cancelSetup()
             } else {
                 Popups.closeAll()
                 ShellState.screenRecord = true
             }
        }
    }

    property var focusMode: IpcHandler {
        target: "focus-toggle"
        function toggle() {
            root.focusToggleRequested()
        }
    }

    // Exposed independently so caffeine's actual inhibitor can be tested and
    // automated without opening the dashboard.
    property var caffeine: IpcHandler {
        target: "caffeine"
        function toggle(): bool {
            ShellState.caffeine = !ShellState.caffeine
            return ShellState.caffeine
        }
        function state(): bool {
            return ShellState.caffeine
        }
    }

    signal focusToggleRequested()

    // ── Session Lock ─────────────────────────────────────────
    // External entry point for the native lock screen (windows/Lockscreen.qml).
    // Invoked by scripts/PowerControl.sh, hypridle's lock_cmd, and
    // `loginctl lock-session` → all via:
    //   qs ipc -c "$HOME/.local/src/apex-shell" call lockscreen lock
    //
    // SECURITY: unlock() is intentionally a no-op. Unlocking over IPC would be
    // a trivial lock bypass — the ONLY path back to unlocked is a successful
    // PAM authentication inside the lock surface.
    property var lockscreen: IpcHandler {
        target: "lockscreen"

        function lock() {
            LockState.locked = true
        }

        function unlock() {
            // Deliberately does nothing. See note above.
        }
    }
}
