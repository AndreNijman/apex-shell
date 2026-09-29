import QtQuick
import Quickshell
import Quickshell.Wayland
import "../shapes/fluid"
import "../components"
import "../modules/Overview"
import "../services"
import "../shapes/fluid/geometry.js" as Geo
import "../modules/Overview/overview.js" as O
import "../"
import "../components/controls"

// ─────────────────────────────────────────────────────────────────────────────
// Overview — every workspace at once (SUPER+Tab).
//
// Andre, 2026-09-29: "make our own version of end4s super+tab workspace
// overview … same function BUT RIME style". It first grew the centre notch
// itself into a wide slab hanging from the bar (the Dashboard's CENTER_BLOOM);
// Andre: "i dont like it in the top notch, make it come off like the nexus,
// also make it smaller its too fat". So it now comes off the notch as the
// Nexus does — NOTCH_EXTRUDE (shapes/fluid/FluidDrop, geometry.js
// notchExtrudeField): the notch's bottom sags, a broad neck comes down with a
// bulb on it, the bulb becomes a card in the middle of the screen and the neck
// draws back into the notch, leaving the card on its own over a dimmed desk,
// its rim and shadow arriving once the neck has gone. Closing draws the mass
// back up into the notch. The same springs and beats as the Nexus (its
// lifecycle's tuning is copied below with the reasons it carries there).
//
// Smaller than the first cut: a cell is 0.13 of its monitor (end-4's 0.18
// filled the screen's width), the card at most two thirds of the screen wide,
// and the caption is a line inside the card rather than the notch's band.
//
// It is a popup, not the Nexus's window: a click outside the card closes it,
// as Escape and SUPER+Tab do. The rest of the window scaffolding is the
// Dashboard's: fullscreen on its output on the Overlay layer, the whole
// window its input region while open and none while it closes, exclusive
// keyboard focus taken 15 ms after the open and dropped at once on close,
// focus handed back to the content on the way out.
//
// The grid itself — cells, live windows, drag, the focused ring — is
// modules/Overview/OverviewGrid.qml, and its arithmetic overview.js.
// ─────────────────────────────────────────────────────────────────────────────
PanelWindow {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForScreen(root.screen) }   // P1-040: this output's sizes

    required property var anchorWindow
    readonly property string screenName: anchorWindow.screen ? anchorWindow.screen.name : ""
    readonly property bool open: Popups.overviewOpen && Popups.overviewScreen === screenName
    screen: anchorWindow.screen

    // ── Lifecycle: the Nexus's extrusion ────────────────────────────────────
    SurfaceLifecycle {
        name: "overview"
        id: life
        open:          root.open
        enterDuration: Motion.hero
        exitDuration:  Motion.morphEnter
        liquid:        true
        surface:       body
        openRelease:   0.2
        closeRelease:  0.2
        bodyIn:        0.98
        bodyDamping:   0.85
        trailScale:    0.38
        contentAt:     0.82
        contentOut:      Motion.fadeOut
        contentOutCurve: Motion.standardDecel
    }

    // Live — capturing windows, reacting to the pointer — from the moment the
    // open finishes until the window is gone (Dashboard's latch, same reason:
    // starting every capture under the extrusion is the hitch, and dropping
    // them at the close's start blanks the pictures mid-exit).
    property bool _settled: false
    Connections {
        target: life
        function onPhaseChanged() {
            if (life.phase === "Open") root._settled = true
            else if (life.phase === "Closed" || life.phase === "Opening") root._settled = false
        }
    }
    readonly property bool live: life.mapped && !LockState.locked
    // The pictures start as the card forms; before it has a shape there is
    // nothing to show them in.
    readonly property bool capturing: root.live && (root._settled || life.body > 0.6)

    // The window list costs a hyprctl per event while held: only while mapped.
    ServiceRef {
        service: CompositorService.windowsRef
        active:  root.live
    }

    color:   "transparent"
    visible: life.mapped

    anchors.top:    true
    anchors.left:   true
    anchors.right:  true
    anchors.bottom: true
    exclusionMode:  ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay

    property bool wantsFocus: false
    WlrLayershell.keyboardFocus: wantsFocus ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    mask: Region { item: root.open ? inputAll : null }
    Item { id: inputAll; anchors.fill: parent }

    Timer {
        id: focusGrabTimer
        interval: 15
        onTriggered: if (life.mapped && root.open) { root.wantsFocus = true; content.forceActiveFocus() }
    }
    onOpenChanged: {
        if (root.open) {
            focusGrabTimer.restart()
        } else {
            root.wantsFocus = false
            focusGrabTimer.stop()
            content.forceActiveFocus()
        }
    }
    Component.onCompleted: if (root.open) focusGrabTimer.restart()

    function close() { Popups.overviewOpen = false }

    // ── The desk behind: dimmed with the liquid, and a click on it closes ───
    Rectangle {
        anchors.fill: parent
        color: "black"
        opacity: 0.35 * life.progress * life.alpha
    }
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onClicked: root.close()
    }

    // ── Size ────────────────────────────────────────────────────────────────
    // A cell is its monitor at 0.13, shrunk until five fit two thirds of the
    // screen's width and two rows half its height. The card is the grid, its
    // padding and the caption line.
    readonly property int pad: theme.spaceM
    readonly property int gap: theme.spaceS
    readonly property int captionH: theme.px(28)
    readonly property var cell: {
        const sw = root.screen ? root.screen.width : 1920
        const sh = root.screen ? root.screen.height : 1080
        const maxW = Math.round(sw * 0.66) - 2 * root.pad
        const maxH = Math.round(sh * 0.5) - root.captionH - root.gap - 2 * root.pad
        return O.cellSize(sw, sh, maxW, maxH, root.gap, 0.13)
    }
    readonly property var gridSz: O.gridSize(root.cell, root.gap)
    readonly property real cardW: root.gridSz.w + 2 * root.pad
    readonly property real cardH: root.pad + root.captionH + root.gap + root.gridSz.h + root.pad
    readonly property real cardX: Math.round((root.width - root.cardW) / 2)
    readonly property real cardY: Math.round((root.height - root.cardH) / 2)

    readonly property var dropGeometry: ({
        cx:          root.width / 2,
        notchW:      root.anchorWindow ? root.anchorWindow.cWidth : theme.cNotchMinWidth,
        notchH:      theme.notchHeight,
        notchBottom: theme.notchBottom,
        card:        { x: root.cardX, y: root.cardY, w: root.cardW, h: root.cardH },
        r:           theme.radiusXL
    })
    // The rim and the shadow, in as the neck finishes drawing back and out as
    // the card begins to contract (Nexus.qml, `_rim`).
    readonly property real _rim: life.alpha * Geo.smooth(Geo.span(life.trail, 0.9, 1))
                                            * Geo.smooth(Geo.span(life.body, 0.6, 1))

    // ── What the workspace, window or drag in front of you is ───────────────
    readonly property int activeId: {
        const ws = CompositorService.workspaces
        let focused = -1
        for (let i = 0; i < ws.length; i++) {
            if (ws[i].output === root.screenName && ws[i].isActive && ws[i].id > 0) return ws[i].id
            if (ws[i].isFocused && ws[i].id > 0) focused = ws[i].id
        }
        return focused > 0 ? focused : 1
    }
    readonly property string wallpaper: WallpaperService.currentWall !== ""
        ? WallpaperService.currentWall : Quickshell.env("HOME") + "/.curr_wall_static.jpg"

    function _appName(w) {
        const e = w && w.appId ? DesktopEntries.heuristicLookup(w.appId) : null
        return e && e.name ? e.name : (w && w.appId ? w.appId : "Window")
    }
    function _count(ws) {
        const n = grid.windowsIn(ws).length
        return n === 0 ? "empty" : n === 1 ? "1 window" : n + " windows"
    }
    readonly property string caption: {
        if (grid.dragging) {
            const t = grid.dropIndex
            if (t >= 0 && grid.dragWin && grid.workspaceOf(t) !== grid.dragWin.workspaceId)
                return "Move " + root._appName(grid.dragWin) + " to workspace " + grid.workspaceOf(t)
            return "Drop on a workspace to move it there"
        }
        if (grid.hoverWin) {
            const t = grid.hoverWin.title
            const a = root._appName(grid.hoverWin)
            return t && t !== a ? a + " · " + t : a
        }
        const i = grid.keyboardSel ? grid.selIndex : grid.hoverIndex
        if (i >= 0) return "Workspace " + grid.workspaceOf(i) + " · " + root._count(grid.workspaceOf(i))
        return "Workspace " + root.activeId + " · " + root._count(root.activeId)
    }

    Item {
        id: content
        anchors.fill: parent
        focus: true
        // Keys go to the focused item and then up through its parents: Escape
        // and the grid's keys live on the outermost item that holds focus
        // (Dashboard.qml records the day that mattered).
        Keys.onPressed: function (event) {
            InputModality.key(event)
            const k = event.key
            if (k === Qt.Key_Escape) root.close()
            else if (k === Qt.Key_Left)  grid.moveSel("left")
            else if (k === Qt.Key_Right) grid.moveSel("right")
            else if (k === Qt.Key_Up)    grid.moveSel("up")
            else if (k === Qt.Key_Down)  grid.moveSel("down")
            else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space)
                grid.goTo(grid.selIndex >= 0 ? grid.selIndex : grid.activeIndex)
            else if (O.digitIndex(event.text) >= 0) grid.goTo(O.digitIndex(event.text))
            else return
            event.accepted = true
        }

        Elevation { target: card; level: "modal" }

        // The neck, the bulb and the card: one liquid body.
        FluidDrop {
            id: body
            anchors.fill: parent
            channels: ({ w: life.lead, d: life.body, n: life.trail })
            geometry: root.dropGeometry
            color:    Theme.background
            opacity:  life.alpha
        }

        // The card's rim (and the shadow's target), following the body's own
        // box so it never outlives the body it outlines.
        Rectangle {
            id: card
            readonly property var _box: body.result.card
            x: _box.cx - _box.hw; y: _box.cy - _box.hh
            width: 2 * _box.hw; height: 2 * _box.hh
            radius: _box.r
            color: "transparent"
            border.color: Theme.outlineSoft
            border.width: 1
            opacity: root._rim
        }

        // Content at its finished layout, revealed where the card already is.
        Item {
            id: reveal
            x: body.result.clip.x; y: body.result.clip.y
            width: body.result.clip.w; height: body.result.clip.h
            clip: true

            Item {
                x: root.cardX - reveal.x
                y: root.cardY - reveal.y
                width: root.cardW; height: root.cardH
                opacity: life.alpha * life.content
                transform: Translate { y: (1 - life.content) * Motion.travel(theme.px(8)) }

                // The card keeps its clicks from the desk behind it.
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.AllButtons
                }

                Text {
                    x: root.pad; width: parent.width - 2 * root.pad
                    y: root.pad; height: root.captionH
                    verticalAlignment: Text.AlignVCenter
                    horizontalAlignment: Text.AlignHCenter
                    text: root.caption
                    color: Theme.textPrimary
                    font.pixelSize: theme.typeBody
                    font.weight: Font.DemiBold
                    elide: Text.ElideMiddle
                }

                OverviewGrid {
                    id: grid
                    x: root.pad
                    y: root.pad + root.captionH + root.gap
                    theme: root.theme
                    screen: root.screen
                    screens: Quickshell.screens
                    live: root.capturing
                    cell: root.cell
                    gap: root.gap
                    activeId: root.activeId
                    windows: CompositorService.windows
                    previewSources: CompositorService.previewSources
                    wallpaper: root.wallpaper
                    onDone: root.close()
                }
            }
        }
    }
}
