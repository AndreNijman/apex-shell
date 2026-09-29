import QtQuick
import Quickshell
import Quickshell.Wayland
import "../../"

// ─── OverviewWindowTile ─────────────────────────────────────────────────────
// One window in the workspace overview: its live picture where it sits on its
// workspace, with its application's icon over it.
//
// The picture is a ScreencopyView of the window's own buffer (Hyprland exports
// any window's, on-screen or not — measured with a window on a workspace that
// was not showing). It captures only while the overview is up: `live` and the
// source both drop to nothing on close, so ten workspaces of windows are not
// being copied behind the desktop. `constraintSize` asks for the tile's size,
// not the window's.
//
// Until the first frame arrives (and wherever there is no source) the tile is
// the surface colour with the icon, so a window never shows as a hole.
// ────────────────────────────────────────────────────────────────────────────

Item {
    id: root

    required property var win          // a CompositorService.windows record
    property var source: null          // CompositorService.previewSources[win.handle]
    property bool live: false          // capture only while the overview is up
    property var theme: null           // the overview's ThemeSet

    property bool hovered: false
    property bool pressed: false
    property bool lifted:  false       // being dragged: the tile left here is a ghost

    readonly property var entry: root.win && root.win.appId
        ? DesktopEntries.heuristicLookup(root.win.appId) : null
    readonly property string iconName: root.entry && root.entry.icon ? root.entry.icon : ""

    readonly property int _r: root.theme ? root.theme.radiusXS : 4

    opacity: root.lifted ? 0.35 : 1
    Behavior on opacity { MotionFade { role: "state" } }

    Rectangle {
        id: base
        anchors.fill: parent
        radius: root._r
        color: Theme.surfaceHigh
    }

    ScreencopyView {
        id: shot
        anchors.fill: parent
        captureSource: root.live ? root.source : null
        live: root.live
        constraintSize: Qt.size(Math.max(1, Math.ceil(root.width)), Math.max(1, Math.ceil(root.height)))
        visible: hasContent
    }

    // The state layer over the picture, and the rim: a hairline at rest, the
    // accent while the pointer is on it.
    Rectangle {
        anchors.fill: parent
        radius: root._r
        color: root.pressed ? Qt.rgba(Theme.textPrimary.r, Theme.textPrimary.g, Theme.textPrimary.b, 0.14)
             : root.hovered ? Qt.rgba(Theme.textPrimary.r, Theme.textPrimary.g, Theme.textPrimary.b, 0.08)
             : "transparent"
        border.width: root.hovered ? 2 : 1
        border.color: root.hovered ? Theme.active : Theme.hairline
        Behavior on color { MotionColor { role: "hover" } }
    }

    // The application, centred, a third of the tile's shorter side, on a disc
    // in the surface colour so it reads over any picture.
    readonly property real _icon: Math.max(12, Math.min(root.theme ? root.theme.px(44) : 44,
                                                        Math.min(root.width, root.height) * 0.34))
    Rectangle {
        visible: root.width > root._icon * 1.2 && root.height > root._icon * 1.2
        anchors.centerIn: parent
        width: root._icon * 1.3; height: width; radius: width / 2
        color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.72)

        Image {
            id: icon
            anchors.centerIn: parent
            width: root._icon; height: width
            sourceSize.width: width * 2; sourceSize.height: height * 2
            source: root.iconName !== "" ? "image://icon/" + root.iconName : ""
            asynchronous: true
            smooth: true
        }
        // No icon: the application's initial.
        Text {
            visible: icon.status !== Image.Ready
            anchors.centerIn: parent
            text: root.win && root.win.appId ? root.win.appId.charAt(0).toUpperCase() : "?"
            color: Theme.textPrimary
            font.pixelSize: Math.max(8, root._icon * 0.6)
            font.weight: Font.DemiBold
        }
    }
}
