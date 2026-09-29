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
// Overview — every workspace at once, out of the centre notch (SUPER+Tab).
//
// Andre, 2026-09-29: "make our own version of end4s super+tab workspace
// overview … same function BUT RIME style … make it come from the top notch
// like dashboard, but its not a tab in the top notch, it just uses the top
// notch as a surface when you press super+tab".
//
// So it is the Dashboard's surface and not the Dashboard: the same CENTER_BLOOM
// (geometry.js centerBloom) grows out of the bar's centre notch — at progress 0
// it IS that notch, so the bar does not move — to a body the size of the grid,
// and the notch's own band becomes the overview's caption line: what the
// pointer is on, where a dragged window would go. The content is laid out once
// at its finished size and revealed by the bloom's clip, arriving a beat after
// the body starts and leaving before it (SurfaceLifecycle.content).
//
// The window scaffolding is Dashboard.qml's, for the reasons written there:
// fullscreen on its output on the Overlay layer, the whole window its input
// region while open and none while it closes, a backdrop that closes on a click
// outside the body, exclusive keyboard focus taken 15 ms after the open and
// dropped at once on close, focus reset to the content on the way out (or the
// next open's Escape reaches nothing).
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

    // ── Lifecycle ───────────────────────────────────────────────────────────
    SurfaceLifecycle {
        name: "overview"
        id: life
        open: root.open
        enterDuration: Motion.morphEnter
        exitDuration:  Motion.morphExit
        liquid:  true
        surface: body
    }

    // Live — capturing windows, reacting to the pointer — from the moment the
    // open finishes until the window is gone (Dashboard's latch, same reason:
    // starting forty captures under the bloom is the hitch, and dropping them
    // at the close's start blanks the pictures mid-exit).
    property bool _settled: false
    Connections {
        target: life
        function onPhaseChanged() {
            if (life.phase === "Open") root._settled = true
            else if (life.phase === "Closed" || life.phase === "Opening") root._settled = false
        }
    }
    readonly property bool live: life.mapped && !LockState.locked
    // The pictures start with the body; before it has any size there is
    // nothing to show them in.
    readonly property bool capturing: root.live && (root._settled || life.progress > 0.2)

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

    // ── Backdrop — a click outside the body closes it ───────────────────────
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onClicked: root.close()
    }

    // ── Size ────────────────────────────────────────────────────────────────
    // The grid is the screen at 0.18 a cell (end-4's scale), shrunk until five
    // cells fit the screen with a margin either side and two rows fit 60 % of
    // its height. The body is the grid, its padding, and the notch's band.
    readonly property int pad: theme.spaceL
    readonly property int gap: theme.spaceS
    readonly property int band: theme.notchHeight
    readonly property var cell: {
        const sw = root.screen ? root.screen.width : 1920
        const sh = root.screen ? root.screen.height : 1080
        const maxW = sw - 2 * (theme.borderWidth + theme.spaceXXL) - 2 * root.pad
        const maxH = Math.round(sh * 0.6) - root.band - root.gap - root.pad
        return O.cellSize(sw, sh, maxW, maxH, root.gap, 0.18)
    }
    readonly property var gridSz: O.gridSize(root.cell, root.gap)
    readonly property int bodyW: root.gridSz.w + 2 * root.pad
    readonly property int bodyH: root.band + root.gap + root.gridSz.h + root.pad

    readonly property var bloomGeometry: ({
        cx:          root.width / 2,
        strip:       theme.borderWidth,
        notchW:      root.anchorWindow ? root.anchorWindow.cWidth : theme.cNotchMinWidth,
        notchH:      theme.notchHeight,
        shoulder:    theme.notchShoulder,
        notchBottom: theme.notchBottom,
        w:           root.bodyW,
        h:           root.bodyH,
        r:           theme.radiusXL,
        shoulderW1:  theme.px(28),
        shoulderH1:  theme.px(22)
    })

    // The notch's label is left showing through the body until the bloom has
    // grown enough to take over, then covered (Dashboard.qml's `_hole`).
    readonly property real _coverK: Geo.smooth(Geo.span(life.progress, 0.22, 0.6))
    readonly property var _hole: {
        const g = root.bloomGeometry, inset = theme.px(2)
        const L0 = Math.round(g.cx) - Math.round(g.notchW / 2)
        return { x: L0 + inset, y: g.strip, w: Math.round(g.notchW) - 2 * inset,
                 h: g.notchH - g.strip - inset, rb: Math.max(0, g.notchBottom - inset) }
    }

    FluidShape {
        id: body
        anchors.fill: parent
        family:   "centerBloom"
        progress: life.progress
        channels: ({ w: life.lead, d: life.body, n: life.trail, fw: life.leadFlow, fd: life.bodyFlow })
        hole:     (life.alpha >= 1 && root._coverK < 1)
                  ? Geo.notchHole(root._hole.x, root._hole.y, root._hole.w, root._hole.h, root._hole.rb) : ""
        geometry: root.bloomGeometry
        color:    Theme.background
        opacity:  life.alpha

        // The body keeps its clicks from the backdrop.
        MouseArea {
            x: body.result.bounds.x; y: body.result.bounds.y
            width: body.result.bounds.w; height: body.result.bounds.h
            acceptedButtons: Qt.AllButtons
            onClicked: {}
        }
    }

    Rectangle {
        visible: body.hole !== ""
        x: root._hole.x; y: root._hole.y
        width: root._hole.w; height: root._hole.h
        bottomLeftRadius: root._hole.rb; bottomRightRadius: root._hole.rb
        color: Theme.background
        opacity: root._coverK
    }

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

    // ── Content, at its finished layout, revealed by the bloom's clip ───────
    readonly property real finalLeft: Math.round(root.width / 2) - Math.round(root.bodyW / 2)

    Item {
        id: reveal
        x: body.result.clip.x; y: body.result.clip.y
        width: body.result.clip.w; height: body.result.clip.h
        clip: true

        Item {
            id: content
            focus: true
            // Keys go to the focused item and then up through its parents:
            // Escape and the grid's keys live on the outermost item that holds
            // focus (Dashboard.qml records the day that mattered).
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

            x: root.finalLeft - reveal.x
            y: 0 - reveal.y
            width: root.bodyW
            height: root.bodyH

            opacity: life.content
            transform: Translate { y: (1 - life.content) * Motion.travel(theme.px(10)) }

            // The caption, in the notch's band, where the notch's own label was.
            Text {
                x: root.pad; width: parent.width - 2 * root.pad
                y: theme.borderWidth
                height: root.band - theme.borderWidth
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
                y: root.band + root.gap
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
