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
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForScreen(root.screen) }   // P1-040: this output's sizes


    anchors { top: true; bottom: true; left: true; right: true }

    exclusionMode: ExclusionMode.Ignore
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    // Exclusive while it is open, and nothing once it is gone, so it never keeps
    // focus from whatever the user was typing into. It was OnDemand, which a
    // compositor may grant only on a click — measured on labwc: Escape and the
    // arrows reached nothing and the menu stayed open (UI/UX Phase 21).
    WlrLayershell.keyboardFocus: Popups.contextMenuOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    // The window maps with the flag, so the catcher below can learn where the
    // pointer is; the menu's own entrance starts once it has been placed.
    readonly property bool windowVisible: Popups.contextMenuOpen || life.mapped
    visible: windowVisible

    // ── PIVOT_POP (UI/UX roadmap v3 Phase 14, brief B.8) ────────────────────
    // In: a fade on the state beat and a scale 0.97 → 1 on emphasizedDecel,
    // from the corner nearest the pointer. Out: the fade only, on the hover
    // beat — no scale-down, which under the click reads as a missed click.
    SurfaceLifecycle {
        id: life
        open:          Popups.contextMenuOpen && root.placed
        enterDuration: Motion.selection
        exitDuration:  Motion.hover
        enterCurve:    Motion.emphasizedDecel
        contentDelay:  0
        contentIn:     Motion.state
        contentOut:    Motion.hover
    }
    // The corner the menu grows from: the one nearest the pointer, which flips
    // when the placement had to be clamped at the right or bottom edge.
    property int origin: Item.TopLeft

    // Where the menu is drawn. Negative means "not placed yet".
    property real menuX: -1
    property real menuY: -1
    readonly property bool placed: menuX >= 0 && menuY >= 0

    function applyOpenState() {
        root.menuX = -1
        root.menuY = -1
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
        const right  = px > root.menuX + w / 2
        const bottom = py > root.menuY + h / 2
        root.origin = bottom ? (right ? Item.BottomRight : Item.BottomLeft)
                             : (right ? Item.TopRight    : Item.TopLeft)
    }

    Connections {
        target: Popups
        function onContextMenuOpenChanged() {
            if (Popups.contextMenuOpen)
                root.applyOpenState()
        }
    }

    // Opened without a pointer (a keybind): centre it.
    Timer {
        id: fallbackTimer
        interval: 120
        onTriggered: if (!root.placed) {
            root.placeAt((root.width - menuCard.implicitWidth) / 2,
                         (root.height - menuCard.implicitHeight) / 2)
            root.origin = Item.Center
        }
    }

    // Input only while the menu is wanted: through its exit fade the window is
    // still mapped, and without this the catcher below swallowed the click
    // that followed the menu.
    mask: Region { item: Popups.contextMenuOpen ? catcher : null }

    // Full-screen catcher: reports where the pointer is, and dismisses on a
    // click anywhere outside the card.
    MouseArea {
        id: catcher
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
        opacity: life.content * life.alpha
        scale: life.closing ? 1 : 0.97 + 0.03 * life.progress
        transformOrigin: root.origin

        Rectangle {
            anchors.fill: parent
            radius: theme.cornerRadius
            color: Theme.background
            // A hairline, not the strip's width: this used theme.borderWidth,
            // a 6 px frame round a floating menu (design review 2).
            border.width: 1
            border.color: Theme.outlineSoft
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
                    required property int index
                    width: itemColumn.width
                    sourceComponent: modelData.separator ? separatorItem : menuItem
                    onLoaded: if (!modelData.separator) {
                        item.label = modelData.label
                        item.action = modelData.action
                        item.idx = index
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

    // ── Keyboard (UI/UX roadmap v3 Phase 21) ────────────────────────────────
    // The menu pattern: nothing is highlighted when it opens (it opens under
    // the pointer), Down or Up takes the first or last item, the arrows walk
    // the items and skip the separators, Home and End jump, Return, Enter or
    // Space choose. The pointer and the keyboard move the SAME highlight, so
    // there is never one item lit by each.
    property int current: -1
    onWindowVisibleChanged: if (root.windowVisible) root.current = -1
    function _step(d) {
        const n = root.entries.length
        let i = root.current
        for (let k = 0; k < n; k++) {
            i = i < 0 ? (d > 0 ? 0 : n - 1) : (i + d + n) % n
            if (!root.entries[i].separator) { root.current = i; return }
        }
    }
    function _edge(first) {
        root.current = -1
        root._step(first ? 1 : -1)
    }

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
                height: 1
                color: Theme.outlineSoft
            }
        }
    }

    Component {
        id: menuItem
        Rectangle {
            property string label: ""
            property string action: ""
            property int idx: -1

            height: 32
            // The state layer, not a full accent flood (brief §E list row) —
            // on the one highlight the pointer and the arrows share.
            color: root.current === idx ? Theme.surfaceHover(Theme.background) : "transparent"
            Accessible.role: Accessible.MenuItem
            Accessible.name: label
            Accessible.onPressAction: root.run(action)
            Behavior on color { MotionColor {} }
            radius: theme.cornerRadius > 6 ? 6 : theme.cornerRadius

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
                color: Theme.textPrimary
                // No explicit family: inherit the shell's, like every other
                // popup. Theme.fs() scales a size calibrated at 1080p, which is
                // the house convention — a literal pixelSize would be wrong on
                // a scaled output.
                font.pixelSize: theme.fs(13)
                elide: Text.ElideRight
            }

            HoverHandler {
                id: hover
                onHoveredChanged: if (hovered) root.current = parent.idx
            }
            TapHandler {
                acceptedButtons: Qt.LeftButton
                onTapped: root.run(parent.action)
            }
        }
    }

    // Escape closes, and the arrows and Return drive the menu — the reason this
    // window takes keyboard focus.
    Item {
        anchors.fill: parent
        focus: root.windowVisible
        Accessible.role: Accessible.PopupMenu
        Keys.onEscapePressed: root.close()
        Keys.onPressed: function(event) {
            if      (event.key === Qt.Key_Down) root._step(1)
            else if (event.key === Qt.Key_Up)   root._step(-1)
            else if (event.key === Qt.Key_Home) root._edge(true)
            else if (event.key === Qt.Key_End)  root._edge(false)
            else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                      || event.key === Qt.Key_Space) && root.current >= 0)
                root.run(root.entries[root.current].action)
            else return
            event.accepted = true
        }
    }
}
