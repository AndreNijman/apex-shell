import QtQuick
import Quickshell
import "../../"
import "../../components"

// ─── LayoutDisplayer ────────────────────────────────────────────────────────
// Small icon button beside the Workspaces module.
// Shows the active tiling layout for the focused workspace.
//
// Layout → symbol map:
//   dwindle  →       (nf-md-view_quilt)
//   master   →       (nf-md-view_split_vertical)
//   monocle  → 󰊓     (nf-md-fullscreen)
//   scroller → 󰔧     (nf-md-scroll_horizontal)
//
// Update triggers (event-driven, no forever-loop):
// The reading itself lives in CompositorService's Hyprland backend, refreshed
// from the compositor's own event stream with a slow safety timer behind it.
// This file is the button.
// ────────────────────────────────────────────────────────────────────────────

Item {
    id: root

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
    implicitWidth:  available ? 26 : 0
    implicitHeight: 26

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
    readonly property string numWindows:
        CompositorService.layoutWindowCount > 0
            ? String(CompositorService.layoutWindowCount) : "  "
    readonly property var availableLayouts: CompositorService.layouts

    // ── Symbol map ───────────────────────────────────────────────────────────

    function layoutSymbol(name) {
        switch (name.toLowerCase()) {
            case "dwindle":  return "><"   // nf-md-view_quilt
            case "master":   return "M"   // nf-md-view_split_vertical
            case "monocle":  return "|"+root.numWindows+"|"  // nf-md-fullscreen
            case "scrolling": return "<"+root.numWindows+">"  // nf-md-scroll_horizontal (hyprscroller)
            default:         return "Unknown"  // nf-md-view_dashboard (unknown fallback)
        }
    }

    // ── Layout Changer ───────────────────────────────────────────────────────

    function cycleLayout(step) {
        const list = root.availableLayouts
        if (list.length === 0) return

        let idx = list.indexOf(root.currentLayout)
        if (idx === -1) idx = 0 // Fallback if unknown

        // Handles negative steps for right-click.
        idx = (idx + step + list.length) % list.length
        CompositorService.setLayout(list[idx])
    }

    // ── Visual ───────────────────────────────────────────────────────────────

    Rectangle {
        id: bg
        anchors.fill: parent
        radius: 6
        color: mouseArea.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : "transparent"

        Behavior on color {
            ColorAnimation { duration: 120 }
        }

        MouseArea {
            id: mouseArea
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            
            onClicked: (mouse) => {
                if (mouse.button === Qt.LeftButton) {
                    cycleLayout(1)  // Forward
                } else if (mouse.button === Qt.RightButton) {
                    cycleLayout(-1) // Backward
                }
            }
        }

        Text {
            id: icon
            anchors.centerIn: parent
            text: root.currentLayout !== "" ? layoutSymbol(root.currentLayout) : "…"
            font.family: "JetBrainsMono Nerd Font"
            font.pixelSize: Theme.fs(14)
            color: Theme.text

            // Brief scale-pop on symbol change
            Behavior on text {
                SequentialAnimation {
                    NumberAnimation {
                        target: icon; property: "scale"
                        to: 0.6; duration: 80
                        easing.type: Easing.InQuad
                    }
                    NumberAnimation {
                        target: icon; property: "scale"
                        to: 1.0; duration: 120
                        easing.type: Easing.OutBack
                    }
                }
            }
        }
    }
}
