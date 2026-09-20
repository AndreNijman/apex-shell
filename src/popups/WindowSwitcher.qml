import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import "../"
import "../services"
import "../theme"

// ─────────────────────────────────────────────────────────────────────────────
//  WindowSwitcher — the ALT+Tab overlay.
//
//  One per output; only the one on the output with focus draws anything, so two
//  monitors do not show two switchers.
//
//  ── It takes no keyboard focus, deliberately ────────────────────────────────
//
//  WlrKeyboardFocus.None, and an empty input `mask` except while it is open.
//  Taking keyboard focus would take it off the window the switcher is about to
//  activate, which is the defect the whole change exists to remove; the ALT
//  release arrives as a compositor keybind instead (see WindowSwitcherService).
//
//  The consequence worth stating: ESCAPE is not handled here. It is
//  ALT+ESCAPE, a compositor binding, for the same reason.
//
//  ── Why the tiles are icons and titles, not thumbnails ──────────────────────
//
//  wlr-foreign-toplevel-management carries no pixels. A thumbnail would need
//  per-compositor screencopy of every window on every ALT press, which is a
//  frame capture of windows on workspaces that are not even composited. labwc
//  and niri draw real thumbnails because they are the compositor and already
//  have the buffers; a shell on the outside does not.
// ─────────────────────────────────────────────────────────────────────────────

PanelWindow {
    id: root

    required property string screenName

    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForScreen(root.screen) }

    // Only on the output the user is looking at. Falls back to showing it on
    // the first screen when nothing claims focus, rather than on none.
    readonly property bool mine: {
        const focused = CompositorService.focusedOutput
        if (focused !== "") return focused === root.screenName
        return Quickshell.screens.length > 0
            && Quickshell.screens[0].name === root.screenName
    }

    visible: WindowSwitcherService.open && root.mine

    color: "transparent"
    anchors { top: true; left: true; right: true; bottom: true }
    exclusionMode: ExclusionMode.Ignore

    WlrLayershell.layer:         WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Click-through everywhere except the card itself, so the desktop under it
    // keeps working — including the pointer's focus-follows-mouse, which must
    // not be interrupted by a surface the user cannot even click.
    mask: Region { item: card }

    // ── Scrim ────────────────────────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.45)
        opacity: root.visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: root.theme.animDuration } }
    }

    // ── The card ─────────────────────────────────────────────────────────────
    Rectangle {
        id: card
        anchors.centerIn: parent
        width:  Math.min(parent.width - root.theme.px(80), content.implicitWidth + root.theme.px(48))
        height: content.implicitHeight + root.theme.px(36)
        radius: root.theme.cornerRadius
        color: Theme.background
        border.width: root.theme.borderWidth
        border.color: Theme.border

        ColumnLayout {
            id: content
            anchors.centerIn: parent
            spacing: root.theme.px(14)

            // The tiles. A Flow rather than a Row: eleven windows on a 1366px
            // laptop is a card wider than the screen otherwise, and clipping
            // the selected tile off the edge is the one thing a switcher may
            // never do.
            Flow {
                Layout.maximumWidth: root.width - root.theme.px(128)
                Layout.alignment: Qt.AlignHCenter
                spacing: root.theme.px(10)

                Repeater {
                    model: WindowSwitcherService.entries

                    delegate: Rectangle {
                        id: tile
                        required property var modelData
                        required property int index

                        readonly property bool current: index === WindowSwitcherService.index

                        width:  root.theme.px(92)
                        height: root.theme.px(92)
                        radius: root.theme.px(12)
                        color: tile.current
                            ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.18)
                            : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.06)
                        border.width: tile.current ? root.theme.px(2) : 0
                        border.color: Theme.active
                        Behavior on color { ColorAnimation { duration: 120 } }

                        readonly property var entry:
                            DesktopEntries.byId(WindowSwitcherService.appIdFor(tile.modelData))

                        Column {
                            anchors.centerIn: parent
                            spacing: root.theme.px(6)

                            Image {
                                id: icon
                                anchors.horizontalCenter: parent.horizontalCenter
                                width:  root.theme.px(40)
                                height: root.theme.px(40)
                                sourceSize.width:  root.theme.px(40)
                                sourceSize.height: root.theme.px(40)
                                fillMode: Image.PreserveAspectFit
                                smooth: true
                                source: (tile.entry && tile.entry.icon)
                                    ? "image://icon/" + tile.entry.icon : ""
                            }

                            // Same fallback glyph the dock uses, so a window
                            // whose app-id matches no desktop entry still has a
                            // tile you can aim at rather than an empty square.
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                visible: icon.status !== Image.Ready
                                text: "󰣆"
                                color: tile.current ? Theme.active : Theme.icon
                                font.pixelSize: root.theme.fs(30)
                            }
                        }

                        // Clicking a tile is a commit. The card is the only
                        // part of this surface that takes input at all.
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                WindowSwitcherService.index = tile.index
                                WindowSwitcherService.commit()
                            }
                        }
                    }
                }
            }

            // The selected window's title, full width, under the row. The tiles
            // are 92px and a title is not, so putting it on the tile would mean
            // eliding every one of them to nothing.
            Text {
                Layout.alignment: Qt.AlignHCenter
                Layout.maximumWidth: root.width - root.theme.px(128)
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideMiddle
                text: WindowSwitcherService.labelFor(WindowSwitcherService.selected)
                color: Theme.text
                font.pixelSize: root.theme.fs(14)
            }
        }
    }
}
