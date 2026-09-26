import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../shapes"
import "../shapes/fluid"
import "../components"
import "../modules/Center/"
import '../services/'
import "../shapes/fluid/geometry.js" as Geo
import "../"

// ─────────────────────────────────────────────────────────────────────────────
// Dashboard — the centre notch, grown into the shell's workspace.
//
// PanelWindow, fullscreen on its output, Overlay layer: TextInputs inside the
// pages need WlrKeyboardFocus.Exclusive, and a PopupWindow cannot have it.
//
// ── How it opens (UI/UX roadmap v3 Phase 8, CENTER_BLOOM) ───────────────────
// The body is ONE silhouette drawn from the screen top, over the bar's own
// centre notch: geometry.js's centerBloom at the lifecycle's progress. At
// progress 0 it IS that notch — same width (a live binding to the bar's
// cWidth), same shoulder and corner tokens — so the bar does not animate for
// the Dashboard at all, and the window unmaps at 0 where the two coincide.
// Width leads, depth follows from 18 %, the shoulders open into a wider join,
// the corners land on radius XL. Nothing overshoots.
//
// The content does NOT squeeze through the morph. It is laid out once, at the
// finished page width, in its finished place, and the bloom's clip reveals it;
// it arrives a beat after the body starts (SurfaceLifecycle.content) and
// leaves ahead of it. That is what fixes the two defects the baseline showed:
// the first open laid every page out in a 300 px column, and the tab bar
// re-measured itself at every intermediate width and popped its labels.
//
// The window's lifetime is the lifecycle's `mapped` — the close's completion,
// not `animDuration + 20`.
// ─────────────────────────────────────────────────────────────────────────────
PanelWindow {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForScreen(root.screen) }   // P1-040: this output's sizes


    // The bar this Dashboard grows out of (shell.qml's per-screen TopBar).
    required property var anchorWindow
    readonly property string screenName: anchorWindow.screen ? anchorWindow.screen.name : ""
    readonly property bool open: Popups.dashboardOpen && Popups.dashboardScreen === screenName
    screen: anchorWindow.screen

    property string page: Popups.dashboardPage

    // ── Page direction ──────────────────────────────────────────────────────
    // Pages travel in the direction of the tab order. The pages bind to
    // `shownPage`, not `page`, and it is set only after `pageDir` is: two
    // bindings on the same change have no order, and a page reading a stale
    // direction would arrive from the wrong side.
    property int    pageDir: 1
    property int    _pageIdx: 0
    property string shownPage: ""
    function _indexOf(key) {
        var t = DashboardLayout.tabs
        for (var i = 0; i < t.length; i++) if (t[i].key === key) return i
        return 0
    }
    onPageChanged: {
        var i = root._indexOf(root.page)
        root.pageDir = i >= root._pageIdx ? 1 : -1
        root._pageIdx = i
        root.shownPage = root.page
    }

    // ── Lifecycle ───────────────────────────────────────────────────────────
    SurfaceLifecycle {
        name: "dashboard"
        id: life
        open: root.open
        enterDuration: Motion.morphEnter
        exitDuration:  Motion.morphExit
        // The bloom is liquid: width leads, depth follows and swells a few
        // pixels past its mark before it settles, the shoulders and corners
        // trail — and nothing moves until this window's first frame is on
        // screen, so it grows out of the notch rather than appearing.
        liquid:  true
        surface: body
        onClosed: tabBar.reset()
        // The launcher page is the one worth building ahead: once the first
        // open has finished, build it in the background (LazyPage.prewarm).
        onOpened: root._warmLauncher = true
    }
    property bool _warmLauncher: false

    // "A user can actually see this window right now." Pages hand this down to
    // their ServiceRefs; it is the difference between a poller that stops when
    // the dashboard closes and one that runs until logout. Item-level `visible`
    // is NOT a substitute: an Item inside an unmapped window still reports
    // visible === true.
    // Live from the moment the open FINISHES (UI/UX Phase 22 — its services
    // fork and its lists rebuild, and doing that under the bloom was the
    // hitch), and still live through the close: dropping at the close's start
    // reset the launcher's query and blanked live content mid-exit. So a latch,
    // not the phase: set on Open, cleared once the window is gone or a new open
    // begins.
    property bool _settled: false
    Connections {
        target: life
        function onPhaseChanged() {
            if (life.phase === "Open") root._settled = true
            else if (life.phase === "Closed" || life.phase === "Opening") root._settled = false
        }
    }
    readonly property bool pageLive: root._settled && life.mapped && !LockState.locked

    // ── Per-page content width ────────────────────────────────────────────────
    // The rule lives in DashboardLayout, not here: this is a PanelWindow, and a
    // geometry test cannot build one without a compositor and a screen.
    //
    // A binding rather than the assignment this used to make on page change and
    // on open. The width now depends on the scale factor and on how wide this
    // output is, and neither of those is a page change: a monitor swapped out
    // under an open dashboard, or a scale changed from the Config tab that is
    // itself inside the dashboard, both used to leave the old width in place.
    // `when` keeps the dashboards on the other screens out of it.
    Binding {
        target:   Popups
        property: "dashboardPageWidth"
        value:    DashboardLayout.widthFor(root.theme, root.page, root.width)
        when:     root.open
        // Keep the last width when the close starts. Qt 6's default restores the
        // value from before the Binding took over — 900 — the moment `open` goes
        // false: closing the launcher (560) re-flowed its content to the Home
        // width while the body was still the lens, and the body swelled 24 px a
        // side as it retracted (Fable's slow-motion review, UI/UX Phase 23).
        restoreMode: Binding.RestoreNone
    }

    // The finished width the bloom is heading for. A page change while open
    // (Home 900 → Apps 560) retargets it over a page beat; progress stays 1.
    readonly property real targetW: _targetW.value
    SpringFollower { id: _targetW; role: "page"; target: Popups.dashboardPageWidth }

    color:   "transparent"
    visible: life.mapped

    anchors.top:   true
    anchors.left:  true
    anchors.right: true
    anchors.bottom: true

    exclusionMode: ExclusionMode.Ignore

    WlrLayershell.layer:         WlrLayer.Overlay

    property bool wantsFocus: false
    WlrLayershell.keyboardFocus: wantsFocus ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    // A closing Dashboard must not keep eating the clicks that follow it: while
    // it collapses, its input region is empty and the desktop is reachable.
    mask: Region { item: root.open ? inputAll : null }
    Item { id: inputAll; anchors.fill: parent }

    Timer {
        id: focusGrabTimer
        interval: 15
        onTriggered: if (life.mapped && root.open) root.wantsFocus = true
    }

    onOpenChanged: {
        if (root.open) {
            focusGrabTimer.restart() // Delay the grab slightly
        } else {
            root.wantsFocus = false // Release instantly
            focusGrabTimer.stop()
            // The window only hides on close, so its focused item survived to
            // the next open: Tab then started from wherever the last visit left
            // it (a tile, say) instead of the tab bar. Reset here, on the way
            // out, so the next open starts at the top with nothing contending —
            // on open it could race the launcher taking its field.
            content.forceActiveFocus()
        }
    }
    Component.onCompleted: {
        root._pageIdx = root._indexOf(root.page)
        root.shownPage = root.page
        if (root.open) focusGrabTimer.restart()
    }

    // ── Backdrop — closes popup when clicking outside the body ──────────────
    MouseArea {
        anchors.fill: parent
        onClicked:    Popups.dashboardOpen = false
    }

    // ── Geometry ────────────────────────────────────────────────────────────
    // What the bloom connects to, and where it ends. `notchW` is LIVE: a media
    // title widening the notch while the Dashboard is up is what the body must
    // shrink back into.
    readonly property var bloomGeometry: ({
        cx:          root.width / 2,
        strip:       theme.borderWidth,
        notchW:      root.anchorWindow ? root.anchorWindow.cWidth : theme.cNotchMinWidth,
        notchH:      theme.notchHeight,
        shoulder:    theme.notchShoulder,
        notchBottom: theme.notchBottom,
        w:           root.targetW,
        h:           theme.notchHeight + theme.dashboardHeight,
        r:           theme.radiusXL,
        shoulderW1:  theme.px(28),
        shoulderH1:  theme.px(22)
    })

    // The notch's content window, left open in the body until the bloom has
    // grown enough to take over: the bar's own label (CenterContent) fades out
    // underneath it on the dashboard's flag, and is SEEN fading, instead of
    // being covered by the body's first frame. Covered back in (`cover`) as
    // the body grows; on the way out the reverse — the label is back by the
    // time the bloom has shrunk into the notch. Same fill both sides of the
    // hole's edge, so the edge itself is never seen.
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

        // Swallow clicks on the body so they do not reach the backdrop.
        MouseArea {
            x: body.result.bounds.x; y: body.result.bounds.y
            width: body.result.bounds.w; height: body.result.bounds.h
            onClicked: {}
        }
    }

    Rectangle {
        id: holeCover
        visible: body.hole !== ""
        x: root._hole.x; y: root._hole.y
        width: root._hole.w; height: root._hole.h
        bottomLeftRadius: root._hole.rb; bottomRightRadius: root._hole.rb
        color: Theme.background
        opacity: root._coverK
    }

    // ── Content, at its finished layout, revealed by the bloom's clip ───────
    readonly property int inset: DashboardLayout.contentInset(root.theme)
    // The finished body, in window coordinates.
    readonly property real finalLeft: Math.round(root.width / 2) - Math.round(Popups.dashboardPageWidth / 2)

    Item {
        id: reveal
        x: body.result.clip.x; y: body.result.clip.y
        width: body.result.clip.w; height: body.result.clip.h
        clip: true

        Item {
            id: content
            // Placed in WINDOW coordinates, whatever the clip is doing.
            x: root.finalLeft + root.inset - reveal.x
            y: theme.borderWidth + root.inset - reveal.y
            width:  Popups.dashboardPageWidth - 2 * root.inset
            height: theme.notchHeight + theme.dashboardHeight - theme.borderWidth - 2 * root.inset

            // Carried by the surface: it arrives a beat after the body starts,
            // rising a little into place, and leaves first.
            opacity: life.content
            transform: Translate { y: (1 - life.content) * Motion.travel(theme.px(10)) }

            Column {
                anchors.fill: parent
                spacing: 0

                // ── Tab bar ───────────────────────────────────────────────────
                TabSwitcher {
                    id: tabBar
                    orientation: "horizontal"
                    width:       parent.width
                    currentPage: root.page
                    model:       DashboardLayout.tabs
                    onPageChanged: function(key) { Popups.dashboardPage = key }
                }

                // ── Page area ─────────────────────────────────────────────────
                Item {
                    id: pageArea
                    focus: true

                    width:  parent.width
                    height: parent.height - tabBar.height

                    // Each page is built on first visit rather than at shell
                    // startup, and told whether it is genuinely in front of a
                    // user so its services can stop when it is not. See
                    // components/LazyPage.qml and components/ServiceRef.qml.
                    LazyPage {
                        anchors.fill: parent
                        shown: root.shownPage === "home"
                        direction: root.pageDir
                        sourceComponent: Component {
                            DashHome {
                                anchors.fill: parent
                                onScreen: root.pageLive && root.page === "home"
                            }
                        }
                    }

                    LazyPage {
                        anchors.fill: parent
                        shown: root.shownPage === "stats"
                        direction: root.pageDir
                        sourceComponent: Component {
                            DashStats {
                                anchors.fill: parent
                                onScreen: root.pageLive && root.page === "stats"
                            }
                        }
                    }

                    LazyPage {
                        anchors.fill: parent
                        shown: root.shownPage === "agents"
                        direction: root.pageDir
                        sourceComponent: Component {
                            AgentCenter {
                                anchors.fill: parent
                                onScreen: root.pageLive && root.page === "agents"
                            }
                        }
                    }

                    LazyPage {
                        anchors.fill: parent
                        shown: root.shownPage === "kanban"
                        direction: root.pageDir
                        sourceComponent: Component {
                            KanbanBoard { anchors.fill: parent }
                        }
                    }

                    LazyPage {
                        anchors.fill: parent
                        shown: root.shownPage === "launcher"
                        direction: root.pageDir
                        // Its field is the anchor (LENS_REVEAL): the page is
                        // there at once and reveals its own results.
                        anchored: true
                        prewarm: root._warmLauncher
                        sourceComponent: Component {
                            // The launcher is the one page that took no
                            // `onScreen` before §15, because it consumed no
                            // refcounted service. It does now — the search
                            // stack and the compositor's window list are both
                            // held only while somebody is looking at it.
                            AppLauncher {
                                anchors.fill: parent
                                onScreen: root.pageLive && root.page === "launcher"
                            }
                        }
                    }

                    Keys.onEscapePressed: Popups.dashboardOpen = false
                }
            }
        }
    }
}
