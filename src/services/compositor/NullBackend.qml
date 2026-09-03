import QtQuick

// ─── NullBackend ──────────────────────────────────────────────────────────────
// The backend for "running under something APEX has no adapter for" — sway,
// river, KDE Wayland, GNOME, a nested session, anything.
//
// It is also the schema. Every other backend in this directory answers exactly
// these properties and functions; this file is what a reviewer reads to see the
// shape, and what the CI invariant compares the others against.
//
// The important behaviour is that everything is false and every action is a
// no-op. The old default was to assume Hyprland when detection failed, and that
// is how a shell on sway ended up polling `hyprctl -j activeworkspace` every
// four seconds forever and appending include lines to a Hyprland config that
// was not there. Unknown means off.
// ──────────────────────────────────────────────────────────────────────────────

QtObject {
    readonly property bool ready: true

    // Declared so the facade's Connections has something to bind to. Never
    // emitted: with no adapter there is no focus to follow.
    signal focusMoved()

    readonly property var capabilities: ({
        workspaces:           false,
        workspaceSwitch:      false,
        specialWorkspace:     false,
        windows:              false,
        windowGeometry:       false,
        outputGeometry:       false,
        windowFocus:          false,
        windowMove:           false,
        windowClose:          false,
        overview:             false,
        accentBorder:         false,
        gaps:                 false,
        keyboardInterception: false
    })

    // Demand, pushed in by CompositorService. Nothing here costs anything, so
    // both are ignored — they exist so the Binding always has a target.
    property bool windowsWanted: false
    property bool titleWanted:   false

    readonly property var    workspaces:         []
    readonly property var    windows:            []
    readonly property string focusedTitle:       "Desktop"
    readonly property string focusedAppName:     "Desktop"
    readonly property string focusedOutput:      ""
    readonly property int    focusedWorkspaceId: -1

    readonly property string windowBoxScript: ""
    readonly property string outputBoxScript: ""

    // CompositorService gates every one of these on a capability, so none of
    // them can be reached. They exist so that a stray direct call on the backend
    // is a no-op rather than a TypeError.
    function focusWorkspace(ref)               {}
    function toggleSpecialWorkspace(name)      {}
    function focusWindow(handle)               {}
    function closeWindow(handle)               {}
    function moveWindowToWorkspace(handle, ws) {}
    function toggleOverview()                  {}
    function setAccentBorder(hex)              {}
    function setGaps(inner, outer)             {}
    function readGaps(callback)                { callback(false, null) }
    function setKeyboardInterception(on)       {}
}
