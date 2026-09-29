import QtQuick
import Quickshell
import "../../"
import "../../components"
import "../../components/controls"
import "layouts.js" as Layouts

// ─── LayoutDisplayer ────────────────────────────────────────────────────────
// The window-layout button beside the Workspaces module: a picture of the
// focused workspace's tiling layout (LayoutGlyph), and a click opens the menu
// that names every layout and says what it does (LayoutMenu).
//
// It used to be `><` / `M` / `|n|` / `<n>` in a monospace font, and a left
// click jumped to the next layout, a right click to the previous one (Andre,
// 2026-09-29: "its so hard to understand what each option does, it has to be
// intuitive, the thing thats like 2 arrows pointg into each other"). Nothing
// said which layout was on or what a click would do, and one click could land
// on monocle, which hides every window but one. Blind cycling is gone: the
// wheel and right click did the same thing without the menu, so they went too.
//
// The reading lives in CompositorService's Hyprland backend, refreshed from the
// compositor's own event stream with a slow safety timer behind it. The choice
// is kept (SettingsService.windowLayout) and put back after a config reload or
// a login, which used to reset it to the config's own without a word.
// ────────────────────────────────────────────────────────────────────────────

Item {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes

    // Which output this indicator is on, so the ref below can be released when
    // this bar is unmapped.
    required property string screenName

    // ── The layout indicator ──────────────────────────────────────────────────
    // Named tiling layouts are a Hyprland concept — niri is scrollable tiling
    // with nothing to choose between, labwc floats — so the whole indicator
    // hides where the capability is absent. That is the same outcome the old
    // `isHyprland` check produced, arrived at from what the compositor can do
    // rather than from what it is called.
    readonly property bool available: CompositorService.can.tilingLayout

    visible:        available
    implicitWidth:  available ? button.implicitWidth : 0
    implicitHeight: button.implicitHeight

    // Keeping the layout current costs a poll, so the ref is held only while the
    // indicator is genuinely on screen.
    //
    // NOT `root.visible`. An Item inside a hidden Window still reports
    // visible == true — measured, and documented in ServiceRef's own header as
    // "exactly how the stats page kept six pollers running after the dashboard
    // was closed". TopBar is a PanelWindow unmapped by fullscreenCovers(), so
    // gating on `visible` held the ref for the entire session and the 4-second
    // poll ran behind every fullscreen game. The commit that introduced this
    // claimed the saving and did not deliver it.
    ServiceRef {
        service: CompositorService.layoutRef
        active:  root.available && !ShellState.fullscreenCovers(root.screenName)
    }

    // ── State ────────────────────────────────────────────────────────────────

    readonly property string currentLayout: CompositorService.layoutName
    readonly property int    windowCount:   CompositorService.layoutWindowCount

    // ── The button ───────────────────────────────────────────────────────────
    // The tray toggle's shape and states: a bar pill with the open state on the
    // OpenPill, the state layer on hover, and a 24 px target.
    RimePressable {
        id: button
        anchors.centerIn: parent

        readonly property bool open: menu.visible

        implicitWidth:  root.theme.px(30)
        implicitHeight: root.theme.px(24)
        radius: height / 2
        pressedScale: 0.96
        hitMargin: Math.max(0, (root.theme.hitBar - implicitHeight) / 2)
        Accessible.name: "Window layout: " + Layouts.name(root.currentLayout) + ". Choose a layout"
        onActivated: menu.toggle()

        Rectangle {
            anchors.fill: parent
            radius: button.radius
            color: button.open ? "transparent" : button.stateLayer()
            Behavior on color { MotionColor { role: "hover" } }
        }
        OpenPill {
            shown: button.open
            size: button.height
            width: button.width
        }

        LayoutGlyph {
            anchors.centerIn: parent
            width:  root.theme.px(18)
            height: root.theme.px(13)
            layout: root.currentLayout
            gap:    root.theme.px(1)
            tileRadius: root.theme.px(1)
            ink: button.open || button.pressed ? Theme.accentText
               : button.hovered ? Theme.textPrimary : Theme.iconDefault
            surface: button.open ? Theme.surfaceSelected : Theme.background
            Behavior on ink { MotionColor { role: "hover" } }
        }

        RimeFocusRing { target: button }

        BarTooltip {
            target: button
            text: {
                const n = Layouts.name(root.currentLayout)
                if (n === "") return "Window layout"
                // Monocle's other windows are the ones you cannot see: say how many.
                if (root.currentLayout === "monocle" && root.windowCount > 1)
                    return "Window layout: " + n + " (" + root.windowCount + " windows, Alt+Tab switches)"
                return "Window layout: " + n
            }
            shown: button.hovered && !button.pressed && !button.open
        }
    }

    LayoutMenu {
        id: menu
        target: button
        layouts: CompositorService.layouts
        current: root.currentLayout
        onChosen: (layout) => CompositorService.setLayout(layout)
    }
}
