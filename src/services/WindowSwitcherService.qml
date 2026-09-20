pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../"
import "../components"

// ─────────────────────────────────────────────────────────────────────────────
//  WindowSwitcherService — the ALT+Tab switcher's state.
//
//  Andre: "build a full alt+tab switcher thing and it goes for all windows
//  including windows in other workspaces."
//
//  ── One protocol, not three IPCs ────────────────────────────────────────────
//
//  The window list is ToplevelManager, i.e. wlr-foreign-toplevel-management.
//  It is what the app dock already reads, it is compositor-agnostic, and it is
//  workspace-agnostic by construction: a compositor publishes every toplevel it
//  has over that protocol regardless of which workspace or output the window is
//  on. Hyprland's `hyprctl clients`, niri's `niri msg windows` and labwc's
//  nothing-at-all would have been three code paths for a list this one already
//  gives, and `activate()` on a handle is the protocol's own "switch to this",
//  which each compositor implements including the workspace change.
//
//  ── Why there is no keyboard grab ───────────────────────────────────────────
//
//  A real alt-tab is hold ALT, tap TAB, release ALT. The obvious way to see the
//  release is to put the overlay on a layer-shell surface with exclusive
//  keyboard focus. That is wrong HERE specifically: taking keyboard focus takes
//  it away from the window the switcher is about to activate, and "the window I
//  moved to instantly loses focus" is the defect this whole unit exists to
//  remove. It would also make the single-tap case — press and release faster
//  than the surface can map — unobservable, because the release would arrive
//  before there was anything focused to receive it.
//
//  So the COMPOSITOR reports the release, through a keybind, exactly the way it
//  reports the ALT+Tab that opened the switcher:
//
//      hl.bind("ALT + Alt_L", …, { release = true, transparent = true })
//
//  It lands here as `commit()`, as does ALT+Return — an ordinary press bind
//  that exists because nothing headless can press a real ALT and let go of it,
//  so a switcher with only a release commit could become one you can open and
//  not close. The overlay never asks for the keyboard either way, so a single
//  tap-and-release is a plain window swap with no visible switcher at all if
//  the user is quick enough — which is what an alt-tab should be.
//
//  ── Only the Hyprland session binds this ────────────────────────────────────
//
//  labwc's onRelease is documented as firing when a modifier is used WITHOUT
//  another key, and measured on 0.9.6 it fires zero times after an ALT+Tab. niri
//  has no release binding at all, and 26.04 ships its own recent-windows
//  switcher. Both sessions therefore keep the switcher they already have, which
//  in both cases is a real hold-and-release one. See docs/window-switcher.md in
//  apex-os. This service stays compositor-agnostic regardless — it reads a
//  protocol every wlroots-family compositor implements — so binding it in a
//  second session is a config change and nothing more.
//
//  ── The flag file ───────────────────────────────────────────────────────────
//
//  The release keybind fires on EVERY ALT release, all day. So the keybinds do
//  not call the shell; they call /usr/libexec/apex-switcher, which tests for
//  this flag first and exits without contacting anything when the switcher is
//  closed. Writing it is therefore not bookkeeping — it is the thing that keeps
//  a global key release cheap.
// ─────────────────────────────────────────────────────────────────────────────

Singleton {
    id: root

    // ── State ────────────────────────────────────────────────────────────────

    /// Whether the switcher is on screen and taking next/prev.
    property bool open: false

    /// The handles being cycled, most-recently-used first. SNAPSHOT at open:
    /// see `_snapshot`.
    property var entries: []

    /// Index into `entries`. Always valid while open, because `open` is only
    /// ever set true with a non-empty list.
    property int index: 0

    readonly property var selected: (root.open && root.index >= 0
                                     && root.index < root.entries.length)
                                    ? root.entries[root.index] : null

    // ── Most-recently-used order ─────────────────────────────────────────────
    //
    // ToplevelManager publishes a list in creation order and has no notion of
    // recency, so the order that makes a single tap "go back to the last
    // window" has to be kept here. `_mru` holds handles, newest first.
    //
    // It is maintained from ToplevelManager.activeToplevel rather than from
    // anything the switcher does, so it is correct even when focus changed by
    // mouse, by SUPER+arrow, or by an application raising itself.
    property var _mru: []

    function _touch(handle) {
        if (!handle) return
        const next = [handle]
        for (const t of root._mru)
            if (t && t !== handle) next.push(t)
        root._mru = next
    }

    // Dropping dead handles here rather than filtering on read: a closed window
    // must not sit in the list holding a slot, and `entries` is built from this.
    function _forget(handle) {
        const next = []
        for (const t of root._mru)
            if (t && t !== handle) next.push(t)
        root._mru = next
    }

    property var _activeWatch: Connections {
        target: ToplevelManager
        function onActiveToplevelChanged() {
            // Deliberately NOT ignored while the switcher is open. The overlay
            // takes no keyboard focus and activates nothing until commit, so
            // anything that changes the active toplevel mid-switch is a real
            // focus change by something else, and the MRU should follow it.
            // `entries` is a snapshot taken at open, so the list the user is
            // looking at does not move underneath them either way.
            root._touch(ToplevelManager.activeToplevel)
        }
    }

    /// Every toplevel the compositor has, most-recently-used first, with any
    /// window that has appeared since the last focus change appended in the
    /// order the compositor lists it.
    ///
    /// Built fresh rather than kept incrementally because ToplevelManager gives
    /// no per-window created/closed signal here; reconciling against the live
    /// list at open time is both simpler and impossible to get out of step.
    function _snapshot() {
        const live = []
        const values = (ToplevelManager.toplevels && ToplevelManager.toplevels.values) || []
        for (const t of values) if (t) live.push(t)

        const out = []
        const seen = []
        for (const t of root._mru) {
            if (live.indexOf(t) === -1) continue     // closed since we saw it
            if (seen.indexOf(t) !== -1) continue
            seen.push(t); out.push(t)
        }
        for (const t of live) {
            if (seen.indexOf(t) !== -1) continue
            seen.push(t); out.push(t)
        }
        return out
    }

    // ── Labels ───────────────────────────────────────────────────────────────

    function labelFor(handle) {
        if (!handle) return ""
        const title = (handle.title || "").trim()
        if (title !== "") return title
        const appId = (handle.appId || "").trim()
        return appId !== "" ? appId : qsTr("Window")
    }

    function appIdFor(handle) {
        if (!handle) return ""
        const appId = (handle.appId || "").trim()
        return appId !== "" ? appId : (handle.title || "").trim()
    }

    // ── The four operations ──────────────────────────────────────────────────

    /// Step forward. Opens the switcher if it is closed.
    ///
    /// Opening already selects the SECOND entry, not the first: the first is
    /// the window you are looking at, so "tap once and release" has to land on
    /// the previous one or the shortcut does nothing. That is the single-tap
    /// case, and it is the one that has to behave like a plain window swap.
    function next()  { root._step(1) }

    /// Step backwards. ALT+SHIFT+Tab.
    function prev()  { root._step(-1) }

    function _step(delta) {
        if (!root.open) {
            const list = root._snapshot()
            // One window, or none, is not a switch. Silently doing nothing is
            // right: the alternative is a switcher showing a single tile that
            // the user then has to dismiss.
            if (list.length < 2) return
            root.entries = list
            root.index = 0
            root.open = true
            root._writeFlag(true)
        }
        const n = root.entries.length
        if (n === 0) { root.cancel(); return }
        root.index = ((root.index + delta) % n + n) % n
    }

    // ── Holding the compositor's window list while a switch is in progress ──
    //
    // CompositorService.windows is refcounted, and on Hyprland holding the ref
    // is what makes it exist at all (a `hyprctl clients` per refresh). The ref
    // is taken when the switcher opens and handed back when it closes, so a
    // machine nobody is switching on polls nothing.
    //
    // It is needed for `commit`, not for the list: see below.
    property var _windowsRef: ServiceRef {
        service: CompositorService.windowsRef
        active:  root.open
    }

    /// The compositor's own handle for a foreign-toplevel, matched on app id
    /// and title, or "" when there is no unambiguous match.
    ///
    /// Matching on two fields and REFUSING an ambiguous answer, rather than
    /// taking the first hit: two terminals with the same title are the normal
    /// case, and focusing the wrong one is worse than falling back.
    function _compositorHandle(handle) {
        if (!handle) return ""
        const title = (handle.title || "")
        const appId = (handle.appId || "")
        const list = CompositorService.windows || []
        let found = ""
        for (const w of list) {
            if (!w) continue
            if ((w.title || "") !== title) continue
            if ((w.appId || "").toLowerCase() !== appId.toLowerCase()) continue
            if (found !== "" && found !== w.handle) return ""   // ambiguous
            found = w.handle
        }
        return found
    }

    /// Activate the selected window and close. Bound to the ALT release, so it
    /// arrives on every ALT release the helper did not filter out — hence the
    /// early return rather than a warning.
    ///
    /// ── Two ways to focus, and why both ─────────────────────────────────────
    ///
    /// `Toplevel.activate()` is wlr-foreign-toplevel-management's own "switch
    /// to this window", and it is the right thing to call: it is what the
    /// protocol is for, it works across workspaces, and it needs no
    /// compositor-specific knowledge.
    ///
    /// It also did not take effect in ANY compositor that could be measured
    /// here: nested Hyprland 0.56.2 and headless labwc 0.9.6 both accepted the
    /// request and left the active window unchanged (2026-09-20). Whether that
    /// is an artefact of a compositor with no real seat devices or something
    /// that would happen on a desk cannot be settled without a desk — and
    /// "cannot be settled" is not a thing to ship a switcher on.
    ///
    /// So the compositor's OWN focus verb is asked first, through the facade
    /// that already implements it for all three backends. On Hyprland that is
    /// `hl.dsp.focus({ window = "address:…" })`, which is measured to move
    /// focus AND warp the pointer into the window — the second half being the
    /// whole point of this unit. On labwc the facade's implementation IS
    /// `activate()`, so the fallback below is the only path there and nothing
    /// is called twice.
    function commit() {
        if (!root.open) return
        const handle = root.selected
        const address = root._compositorHandle(handle)
        root._close()
        if (!handle) return

        // AFTER the overlay is down. It holds no keyboard focus, so the order
        // does not matter for focus — but it does for the pointer: the
        // compositor warps the cursor into the window it focuses, and a surface
        // still mapped over that point would take the enter event first.
        let done = false
        if (address !== "") done = CompositorService.focusWindow(address)
        if (!done && typeof handle.activate === "function") handle.activate()
        root._touch(handle)
    }

    /// Close and change nothing. ALT+ESCAPE, and ESCAPE inside the overlay.
    function cancel() {
        if (!root.open) return
        root._close()
    }

    function _close() {
        root.open = false
        root.entries = []
        root.index = 0
        root._writeFlag(false)
    }

    // ── The flag /usr/libexec/apex-switcher tests ────────────────────────────

    readonly property string flagDir: {
        const override = Quickshell.env("APEX_SWITCHER_RUNTIME_DIR") || ""
        if (override !== "") return override
        const rt = Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
        return rt + "/apex-shell"
    }
    readonly property string flagPath: root.flagDir + "/switcher-open"

    property var _flagProc: Process { command: []; running: false }

    function _writeFlag(want) {
        // `mkdir -p` every time rather than once at startup: XDG_RUNTIME_DIR is
        // cleaned by systemd while a session is still alive, and a switcher
        // that silently stopped committing because a directory went away is
        // the kind of fault nobody would ever connect to its cause.
        //
        // sh -c, and the path is not interpolated into it — it arrives as $0 —
        // so a runtime directory with a space or a quote in it cannot become
        // shell syntax.
        root._flagProc.running = false
        root._flagProc.command = want
            ? ["sh", "-c", 'mkdir -p "$(dirname "$0")" && : > "$0"', root.flagPath]
            : ["sh", "-c", 'rm -f "$0"', root.flagPath]
        root._flagProc.running = true
    }

    // A shell that exits with the switcher open would leave the flag behind,
    // which costs one wasted IPC on the next ALT release rather than anything
    // worse — but it is one line to not do that.
    Component.onDestruction: if (root.open) root._writeFlag(false)
}
