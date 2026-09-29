import QtQuick
import QtQuick.Effects
import Quickshell
import "../../"
import "../../services"
import "overview.js" as O

// ─── OverviewGrid ───────────────────────────────────────────────────────────
// The workspace overview's content: ten workspaces (two rows of five), each a
// scaled picture of its monitor — the wallpaper, its number, its windows live
// where they sit — and the accent ring on the focused one.
//
// What it does, after end-4's overview (Andre, 2026-09-29: "make it basically
// the same thing and same function"):
//   click a window ............ focus it (its workspace comes with it), close
//   middle-click a window ..... close that window
//   drag a window to a cell ... move it there, without following it
//   click a cell's empty part . go to that workspace, close
//   arrows / Return / 1–0 ..... the keyboard's selection (Overview.qml routes keys)
// The overview surface owns open/close; this owns only what is inside it.
// ────────────────────────────────────────────────────────────────────────────

Item {
    id: grid

    property var theme: null
    // The output this overview is on (a Quickshell screen), and every output —
    // a window is drawn relative to its OWN monitor.
    property var screen: null
    property var screens: []
    property bool live: false          // the overview is up: capture, react
    property var cell: ({ w: 1, h: 1 })
    property int gap: 8
    property int activeId: 1
    property var windows: []
    property var previewSources: ({})
    property string wallpaper: ""

    signal done()                      // an action that ends the overview

    readonly property int group: O.groupOf(grid.activeId)
    readonly property int activeIndex: O.indexOf(grid.group, grid.activeId)
    readonly property var stackedWindows: O.stacked(grid.windows, grid.group)
    readonly property var _geo: {
        const out = []
        for (let i = 0; i < grid.screens.length; i++) {
            const s = grid.screens[i]
            if (s) out.push({ name: s.name, x: s.x, y: s.y, width: s.width, height: s.height })
        }
        return out
    }
    readonly property var _home: grid.screen
        ? { name: grid.screen.name, x: grid.screen.x, y: grid.screen.y,
            width: grid.screen.width, height: grid.screen.height } : null

    readonly property var size: O.gridSize(grid.cell, grid.gap)
    implicitWidth: grid.size.w
    implicitHeight: grid.size.h

    readonly property int cellRadius: grid.theme ? grid.theme.radiusM : 12

    // ── Selection, hover, drag ────────────────────────────────────────────────
    property int selIndex: -1          // the keyboard's cell (-1: none yet)
    property bool keyboardSel: false   // the ring shows only once a key moved it
    property int hoverIndex: -1
    property var hoverWin: null

    property var dragWin: null
    property bool dragging: false
    property point dragPos: Qt.point(0, 0)     // ghost top-left, grid coordinates
    property size dragSize: Qt.size(0, 0)
    property int dropIndex: -1

    // The current record of every window, by handle. The cells' models are
    // HANDLES (strings compare by value), so ScriptModel keeps a tile — and its
    // live capture — through every refresh of the list, which is a fresh parse
    // of `hyprctl clients` on each compositor event; a model of the records
    // themselves rebuilt every tile each time, restarting its capture, and
    // would have destroyed a tile in the middle of its own drag.
    readonly property var byHandle: {
        const out = {}
        for (let i = 0; i < grid.stackedWindows.length; i++) out[grid.stackedWindows[i].handle] = grid.stackedWindows[i]
        return out
    }
    function handlesIn(ws) {
        const out = []
        for (let i = 0; i < grid.stackedWindows.length; i++)
            if (grid.stackedWindows[i].workspaceId === ws) out.push(grid.stackedWindows[i].handle)
        return out
    }

    function workspaceOf(index) { return O.workspaceAt(grid.group, index) }
    function windowsIn(ws) {
        const out = []
        for (let i = 0; i < grid.stackedWindows.length; i++)
            if (grid.stackedWindows[i].workspaceId === ws) out.push(grid.stackedWindows[i])
        return out
    }

    function goTo(index) {
        if (index < 0) return
        CompositorService.focusWorkspace(grid.workspaceOf(index))
        grid.done()
    }
    function focusWin(w) {
        if (!w) return
        CompositorService.focusWindow(w.handle)
        grid.done()
    }
    function closeWin(w) { if (w) CompositorService.closeWindow(w.handle) }

    // The first arrow already moves, from the focused workspace: Right from 7
    // is 8 (it took a press to light 7 first, so Right, Right, Return went to 8).
    function moveSel(key) {
        const from = grid.selIndex >= 0 ? grid.selIndex : Math.max(0, grid.activeIndex)
        grid.selIndex = O.step(from, key)
        grid.keyboardSel = true
    }
    // Window records are rebuilt on every compositor event (the list is a
    // fresh parse of `hyprctl clients`), so a window is the same window by its
    // handle, never by object identity: the dragged tile did not fade because
    // the list had been refreshed under the drag.
    function same(a, b) { return !!a && !!b && a.handle === b.handle }
    function reset() {
        grid.selIndex = -1; grid.keyboardSel = false
        grid.hoverIndex = -1; grid.hoverWin = null
        grid.dragWin = null; grid.dragging = false; grid.dropIndex = -1
    }
    onLiveChanged: if (!grid.live) grid.reset()

    // ── Cells ─────────────────────────────────────────────────────────────────
    Repeater {
        id: cells
        model: O.PER_GROUP

        delegate: Item {
            id: cellItem
            required property int index
            readonly property int ws: grid.workspaceOf(cellItem.index)
            readonly property var o: O.cellOrigin(cellItem.index, grid.cell, grid.gap)
            readonly property var handles: grid.handlesIn(cellItem.ws)
            readonly property bool dropTarget: grid.dragging && grid.dropIndex === cellItem.index
                                               && grid.dragWin && grid.dragWin.workspaceId !== cellItem.ws
            readonly property bool pointed: grid.hoverIndex === cellItem.index && !grid.dragging
            readonly property bool selected: grid.keyboardSel && grid.selIndex === cellItem.index

            x: cellItem.o.x; y: cellItem.o.y
            width: grid.cell.w; height: grid.cell.h

            // The wallpaper, rounded, dimmed toward the surface so the windows
            // read over it; the surface colour alone when it does not load.
            Rectangle {
                id: mask
                anchors.fill: parent
                radius: grid.cellRadius
                visible: false
                layer.enabled: true
            }
            Rectangle {
                anchors.fill: parent
                radius: grid.cellRadius
                color: Theme.surfaceRaised
            }
            Item {
                anchors.fill: parent
                layer.enabled: true
                layer.effect: MultiEffect {
                    maskEnabled:      true
                    maskSource:       mask
                    maskThresholdMin: 0.5
                    maskSpreadAtMin:  1.0
                }
                Image {
                    id: wall
                    anchors.fill: parent
                    source: grid.wallpaper !== "" ? "file://" + grid.wallpaper : ""
                    sourceSize.width: grid.cell.w; sourceSize.height: grid.cell.h
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: true
                    visible: status === Image.Ready
                    opacity: 0.45
                }
            }


            // An empty part of the cell: go there.
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: grid.hoverIndex = cellItem.index
                onExited: if (grid.hoverIndex === cellItem.index) grid.hoverIndex = -1
                onClicked: grid.goTo(cellItem.index)
            }

            // Its windows, where they sit on their monitor, clipped to it.
            Item {
                anchors.fill: parent
                clip: true

                Repeater {
                    model: ScriptModel { values: cellItem.handles }
                    delegate: OverviewWindowTile {
                        id: tile
                        required property string modelData      // the window's handle
                        required property int index             // back to front
                        readonly property var rec: grid.byHandle[tile.modelData] || null
                        readonly property var mon: tile.rec ? O.monitorFor(tile.rec, grid._geo, grid._home) : null
                        readonly property var r: tile.mon ? O.windowRect(tile.rec, tile.mon, grid.cell)
                                                          : ({ x: 0, y: 0, w: 1, h: 1 })
                        z: tile.index
                        win: tile.rec
                        theme: grid.theme
                        source: grid.previewSources[tile.modelData] || null
                        live: grid.live
                        x: Math.round(tile.r.x); y: Math.round(tile.r.y)
                        width: Math.round(tile.r.w); height: Math.round(tile.r.h)
                        hovered: grid.same(grid.hoverWin, tile.rec) && !grid.dragging
                        pressed: tileArea.pressed && !grid.dragging
                        lifted: grid.dragging && grid.same(grid.dragWin, tile.rec)

                        MouseArea {
                            id: tileArea
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                            cursorShape: grid.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                            property point _start: Qt.point(0, 0)
                            property point _grab: Qt.point(0, 0)
                            // Set once this press became a drag: a drag that
                            // ends back on its own tile still emits `clicked`
                            // after `released`, and must not focus the window.
                            property bool _dragged: false

                            onEntered: { grid.hoverWin = tile.rec; grid.hoverIndex = cellItem.index }
                            onExited: if (grid.same(grid.hoverWin, tile.rec)) grid.hoverWin = null
                            onPressed: function (mouse) {
                                if (mouse.button !== Qt.LeftButton) return
                                _start = mapToItem(grid, mouse.x, mouse.y)
                                _grab = Qt.point(mouse.x, mouse.y)
                                _dragged = false
                            }
                            onPositionChanged: function (mouse) {
                                if (!pressed || !(mouse.buttons & Qt.LeftButton)) return
                                const p = mapToItem(grid, mouse.x, mouse.y)
                                const slop = grid.theme ? grid.theme.px(6) : 6
                                if (!grid.dragging && Math.hypot(p.x - _start.x, p.y - _start.y) > slop) {
                                    grid.dragWin = tile.rec
                                    grid.dragSize = Qt.size(tile.width, tile.height)
                                    grid.dragging = true
                                    _dragged = true
                                }
                                if (grid.dragging) {
                                    grid.dragPos = Qt.point(p.x - _grab.x, p.y - _grab.y)
                                    grid.dropIndex = O.cellAt(p.x, p.y, grid.cell, grid.gap)
                                }
                            }
                            onReleased: function (mouse) {
                                if (mouse.button !== Qt.LeftButton || !grid.dragging) return
                                const target = grid.dropIndex
                                const w = grid.dragWin
                                grid.dragging = false; grid.dragWin = null; grid.dropIndex = -1
                                if (w && target >= 0 && grid.workspaceOf(target) !== w.workspaceId)
                                    CompositorService.moveWindowToWorkspace(w.handle, grid.workspaceOf(target))
                            }
                            onCanceled: { grid.dragging = false; grid.dragWin = null; grid.dropIndex = -1 }
                            onClicked: function (mouse) {
                                if (mouse.button === Qt.MiddleButton) grid.closeWin(tile.rec)
                                else if (!_dragged) grid.focusWin(tile.rec)
                            }
                        }
                    }
                }
            }

            // The rim: where a dragged window would land, the keyboard's cell,
            // the pointer's.
            Rectangle {
                anchors.fill: parent
                radius: grid.cellRadius
                color: cellItem.dropTarget ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.14) : "transparent"
                border.width: cellItem.dropTarget || cellItem.selected ? 2 : 1
                border.color: cellItem.dropTarget ? Theme.active
                            : cellItem.selected ? Theme.textPrimary
                            : cellItem.pointed ? Theme.outlineStrong : Theme.hairline
                Behavior on color { MotionColor { role: "hover" } }
                Behavior on border.color { MotionColor { role: "hover" } }
            }

            // The workspace's number, as the bar's workspace pill draws it: a
            // filled pill for the focused one, the surface for the rest. In the
            // corner, over the windows, so a bright wallpaper or a full-screen
            // window never hides which workspace this is (a large faint number
            // behind the windows did, on the first capture).
            Rectangle {
                id: chip
                readonly property bool current: cellItem.ws === grid.activeId
                x: grid.theme ? grid.theme.spaceXS : 4
                y: x
                height: grid.theme ? grid.theme.px(20) : 20
                width: Math.max(height, num.implicitWidth + (grid.theme ? grid.theme.px(12) : 12))
                radius: height / 2
                color: chip.current ? Theme.wsActive
                     : Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.82)
                Text {
                    id: num
                    anchors.centerIn: parent
                    text: String(cellItem.ws)
                    color: chip.current ? Theme.background : Theme.textPrimary
                    font.pixelSize: grid.theme ? grid.theme.typeBodySmall : 12
                    font.weight: Font.DemiBold
                    font.features: { "tnum": 1 }
                }
            }
        }
    }

    // ── The focused workspace: an accent ring that springs to it ─────────────
    readonly property var _activeO: O.cellOrigin(Math.max(0, grid.activeIndex), grid.cell, grid.gap)
    SpringFollower { id: ringX; role: "selection"; live: grid.live; target: grid._activeO.x }
    SpringFollower { id: ringY; role: "selection"; live: grid.live; target: grid._activeO.y }
    Rectangle {
        visible: grid.activeIndex >= 0
        readonly property int out: grid.theme ? grid.theme.px(3) : 3
        x: ringX.value - out; y: ringY.value - out
        width: grid.cell.w + 2 * out; height: grid.cell.h + 2 * out
        radius: grid.cellRadius + out
        color: "transparent"
        border.width: grid.theme ? Math.max(2, grid.theme.px(2)) : 2
        border.color: Theme.active
    }

    // ── The window being dragged, over everything ────────────────────────────
    OverviewWindowTile {
        visible: grid.dragging && grid.dragWin !== null
        win: grid.dragWin
        theme: grid.theme
        source: grid.dragWin ? (grid.previewSources[grid.dragWin.handle] || null) : null
        live: grid.live && grid.dragging
        x: grid.dragPos.x; y: grid.dragPos.y
        width: grid.dragSize.width; height: grid.dragSize.height
        hovered: true
        z: 10
    }
}
