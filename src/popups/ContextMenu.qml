import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../components"
import "../services"
import "../"

// ─────────────────────────────────────────────────────────────────────────────
// ContextMenu — the desktop right-click menu.
//
// Replaces the compositor's own root menu. On labwc that menu is Openbox-derived
// and looks it, which was the loudest remaining "this is a fallback" signal in
// the Floating session; the compositor menus on Hyprland and niri are absent
// entirely. One QML surface serves all three, so the menu is the same object
// everywhere rather than three things that drift.
//
// `menu.xml` stays on disk as the emergency path for when the shell is not
// running — see the compositor configs for how it is reached.
//
// ── Positioning ─────────────────────────────────────────────────────────────
// A layer-shell surface cannot ask where the pointer is. What it can do is
// notice where the pointer already was: mapping a surface under the cursor makes
// the compositor send wl_pointer.enter with surface-local coordinates, which
// arrives here as the first hover event. The menu stays hidden until that lands,
// so it never flashes at the wrong place and then jumps.
//
// If no pointer event arrives at all (the menu was opened from a keybind, not a
// click) `fallbackTimer` places it centre-screen, which is the right answer for
// a keyboard-invoked menu anyway.
// ─────────────────────────────────────────────────────────────────────────────

PanelWindow {
    id: root

    anchors { top: true; bottom: true; left: true; right: true }

    exclusionMode: ExclusionMode.Ignore
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    // OnDemand, not Exclusive: the menu takes the keyboard while it is up so
    // Escape closes it, but it must not steal focus from whatever the user was
    // typing into once it is gone.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    property bool windowVisible: false
    visible: windowVisible

    // Where the menu is drawn. Negative means "not placed yet".
    property real menuX: -1
    property real menuY: -1
    readonly property bool placed: menuX >= 0 && menuY >= 0

    function applyOpenState() {
        closeTimer.stop()
        root.menuX = -1
        root.menuY = -1
        root.windowVisible = true
        fallbackTimer.restart()
    }

    function close() {
        Popups.contextMenuOpen = false
    }

    // Clamp so the menu never opens partly off-screen — at the right or bottom
    // edge it flips back over the cursor rather than being cut off.
    function placeAt(px, py) {
        fallbackTimer.stop()
        var w = menuCard.implicitWidth
        var h = menuCard.implicitHeight
        var maxX = Math.max(0, root.width - w - 8)
        var maxY = Math.max(0, root.height - h - 8)
        root.menuX = Math.min(Math.max(8, px), maxX)
        root.menuY = Math.min(Math.max(8, py), maxY)
    }

    Connections {
        target: Popups
        function onContextMenuOpenChanged() {
            if (Popups.contextMenuOpen)
                root.applyOpenState()
            else
                closeTimer.restart()
        }
    }

    Timer {
        id: closeTimer
        interval: Theme.animDuration + 20
        onTriggered: if (!Popups.contextMenuOpen) root.windowVisible = false
    }

    // Opened without a pointer (a keybind): centre it.
    Timer {
        id: fallbackTimer
        interval: 120
        onTriggered: if (!root.placed)
            root.placeAt((root.width - menuCard.implicitWidth) / 2,
                         (root.height - menuCard.implicitHeight) / 2)
    }

    // Full-screen catcher: reports where the pointer is, and dismisses on a
    // click anywhere outside the card.
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

        onPositionChanged: mouse => { if (!root.placed) root.placeAt(mouse.x, mouse.y) }
        onEntered: if (!root.placed) root.placeAt(mouseX, mouseY)
        onPressed: root.close()
    }

    Item {
        id: menuCard
        x: root.menuX
        y: root.menuY
        implicitWidth: 232
        implicitHeight: itemColumn.implicitHeight + 12

        visible: root.placed
        opacity: Popups.contextMenuOpen && root.placed ? 1 : 0
        scale: Popups.contextMenuOpen && root.placed ? 1 : 0.96
        transformOrigin: Item.TopLeft

        Behavior on opacity { NumberAnimation { duration: Theme.animDuration * 0.5; easing.type: Easing.OutCubic } }
        Behavior on scale   { NumberAnimation { duration: Theme.animDuration * 0.5; easing.type: Easing.OutCubic } }

        Rectangle {
            anchors.fill: parent
            radius: Theme.cornerRadius
            color: Theme.background
            border.width: Theme.borderWidth
            border.color: Theme.border
        }

        // Swallow clicks on the card itself, so choosing an item does not also
        // trigger the dismiss handler underneath.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onPressed: mouse => mouse.accepted = true
        }

        Column {
            id: itemColumn
            anchors { fill: parent; topMargin: 6; bottomMargin: 6 }

            Repeater {
                model: root.entries

                delegate: Loader {
                    required property var modelData
                    width: itemColumn.width
                    sourceComponent: modelData.separator ? separatorItem : menuItem
                    onLoaded: if (!modelData.separator) {
                        item.label = modelData.label
                        item.action = modelData.action
                    }
                }
            }
        }
    }

    // ── entries ─────────────────────────────────────────────────────────────
    // Deliberately short, and deliberately the same set the labwc root menu
    // offered: this replaces that menu, it does not become a second launcher.
    // APEX Shell already owns app launching, settings and power.
    readonly property var entries: [
        { label: "Terminal",             action: "terminal",   separator: false },
        { label: "App launcher",         action: "launcher",   separator: false },
        { label: "Wallpaper…",           action: "wallpaper",  separator: false },
        { label: "Settings",             action: "settings",   separator: false },
        { separator: true },
        { label: "Restart APEX Shell",   action: "restart",    separator: false },
        { label: "Reload compositor",    action: "reload",     separator: false },
        { separator: true },
        { label: "Lock",                 action: "lock",       separator: false },
        { label: "Log out",              action: "logout",     separator: false }
    ]

    function run(action) {
        root.close()
        switch (action) {
        case "terminal":  proc.exec(["sh", "-c", "${TERMINAL:-alacritty}"]); break
        case "launcher":  proc.exec(["apex", "shell", "launcher"]); break
        case "wallpaper": proc.exec(["apex", "shell", "wallpaper"]); break
        case "settings":  proc.exec(["apex", "shell", "settings"]); break
        case "restart":   proc.exec(["/usr/libexec/apex-shell-autostart"]); break
        // Compositor-neutral: each session's reload verb differs, so ask the
        // helper rather than teaching this menu about three compositors.
        case "reload":    proc.exec(["/usr/libexec/apex-compositor-reload"]); break
        case "lock":      proc.exec(["apex", "shell", "lock"]); break
        case "logout":    proc.exec(["/usr/libexec/apex-session-logout"]); break
        }
    }

    Process { id: proc }

    Component {
        id: separatorItem
        Item {
            height: 9
            Rectangle {
                anchors.centerIn: parent
                width: parent.width - 20
                height: Math.max(1, Theme.borderWidth)
                color: Theme.border
                opacity: 0.7
            }
        }
    }

    Component {
        id: menuItem
        Rectangle {
            property string label: ""
            property string action: ""

            height: 32
            color: hover.hovered ? Theme.active : "transparent"
            radius: Theme.cornerRadius > 6 ? 6 : Theme.cornerRadius

            // Inset so the hover highlight does not touch the card's border.
            anchors.leftMargin: 6
            anchors.rightMargin: 6

            Text {
                anchors {
                    left: parent.left; leftMargin: 14
                    right: parent.right; rightMargin: 14
                    verticalCenter: parent.verticalCenter
                }
                text: parent.label
                color: hover.hovered ? Theme.background : Theme.text
                // No explicit family: inherit the shell's, like every other
                // popup. Theme.fs() scales a size calibrated at 1080p, which is
                // the house convention — a literal pixelSize would be wrong on
                // a scaled output.
                font.pixelSize: Theme.fs(13)
                elide: Text.ElideRight
            }

            HoverHandler { id: hover }
            TapHandler {
                acceptedButtons: Qt.LeftButton
                onTapped: root.run(parent.action)
            }
        }
    }

    // Escape closes, which is the reason this window takes keyboard focus.
    Item {
        anchors.fill: parent
        focus: root.windowVisible
        Keys.onEscapePressed: root.close()
    }
}
