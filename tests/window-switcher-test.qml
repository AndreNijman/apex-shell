import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "src/services"
import "src/popups"

// The entry point run-window-switcher-test.sh stages into the repo root.
//
// It instantiates the SHIPPED WindowSwitcherService and the SHIPPED
// WindowSwitcher overlay — not copies — and adds one IpcHandler of its own so
// the runner can ask what the compositor and the switcher currently think.
//
// The switcher is driven the way a user drives it: real ALT and TAB key events
// from wtype into a headless labwc, whose rc.xml carries the same bindings the
// image ships. Nothing here calls next()/commit() directly; that would test the
// functions and skip the whole question, which is whether the KEYS reach them
// and whether the window that ends up focused stays focused.
ShellRoot {
    id: root

    // The shell's own IPC surface, reproduced rather than imported: IpcManager
    // is a singleton that brings the entire shell up with it.
    IpcHandler {
        target: "window-switcher"
        function next(): string   { WindowSwitcherService.next();   return root.state() }
        function prev(): string   { WindowSwitcherService.prev();   return root.state() }
        function commit(): string {
            const was = WindowSwitcherService.labelFor(WindowSwitcherService.selected)
            WindowSwitcherService.commit()
            return was === "" ? "closed" : "activated " + was
        }
        function cancel(): string { WindowSwitcherService.cancel(); return "closed" }
    }

    IpcHandler {
        target: "probe"

        /// The title of the toplevel the COMPOSITOR says is active. This is the
        /// acceptance: what the switcher believes is irrelevant if the
        /// compositor disagrees.
        function active(): string {
            const t = ToplevelManager.activeToplevel
            return t ? (t.title || t.appId || "?") : "<none>"
        }

        /// Every toplevel, in the order ToplevelManager lists them.
        function windows(): string {
            const out = []
            const values = (ToplevelManager.toplevels && ToplevelManager.toplevels.values) || []
            for (const t of values) if (t) out.push(t.title || t.appId || "?")
            return out.join(",")
        }

        /// The switcher's own state, so a failure says whether the keys never
        /// arrived or arrived and did the wrong thing.
        function state(): string { return root.state() }

        /// Whether the overlay's flag file is what the helper would find. The
        /// runner cannot see the shell's XDG_RUNTIME_DIR resolution, so it asks.
        function flag(): string { return WindowSwitcherService.flagPath }

        /// title:minimized for every toplevel, so the runner can prove a window
        /// it asked to hide really is hidden rather than assuming the request
        /// landed.
        function flags(): string {
            const out = []
            const values = (ToplevelManager.toplevels && ToplevelManager.toplevels.values) || []
            for (const t of values)
                if (t) out.push((t.title || t.appId || "?")
                                + (t.minimized ? ":minimized" : ":shown"))
            return out.join(" ")
        }

        /// Minimise the first toplevel that is not the active one, and say
        /// which. Over the protocol, not through a compositor keybind, because
        /// the state has to be read back over the same protocol to be believed.
        function minimize_first(): string {
            const values = (ToplevelManager.toplevels && ToplevelManager.toplevels.values) || []
            const active = ToplevelManager.activeToplevel
            for (const t of values) {
                if (!t || t === active || t.minimized) continue
                t.minimized = true
                return t.title || t.appId || "?"
            }
            return "<none>"
        }
    }

    function state(): string {
        if (!WindowSwitcherService.open) return "closed"
        return "open " + (WindowSwitcherService.index + 1)
            + "/" + WindowSwitcherService.entries.length
            + " " + WindowSwitcherService.labelFor(WindowSwitcherService.selected)
    }

    // The overlay itself, on every output, exactly as shell.qml creates it.
    Variants {
        model: Quickshell.screens
        delegate: Scope {
            required property var modelData
            WindowSwitcher { screen: modelData; screenName: modelData.name }
        }
    }

    Component.onCompleted: console.log("SWITCHER-TEST ready")
}
