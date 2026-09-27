import QtQuick
import Quickshell
import Quickshell.Wayland
import "../"
import "../components"
import "../components/controls"
import "../shapes/fluid"
import "../shapes/fluid/geometry.js" as Geo

// ─────────────────────────────────────────────────────────────────────────────
// Nexus — the standalone settings window.
//
// Settings previously existed only as a tab inside the dashboard, which meant
// they shared the dashboard's lifetime and its dismissal rules: click anywhere
// outside and the settings vanished, and any compositor focus change closed
// them. That is correct behaviour for a popup and wrong for a window you edit
// configuration in.
//
// So this is a real window. It has keyboard focus, it survives clicks elsewhere,
// it closes on Escape or its own close button, and it is opened over IPC:
//
//     apex shell nexus            (or: nexus <page>)
//
// Its body — navigation, header and page stack — is SettingsHost, the one host
// of the PageRegistry pages since UI/UX Phase 19 removed the dashboard's Config
// tab (a second host of every page, with its own staged state).
//
// One instance per screen, following the dashboard's pattern; NexusState.
// screenName decides which one is live, so the window opens on the output the
// user is actually looking at instead of always the primary.
//
// ── NOTCH_EXTRUDE (2026-09-27, replacing the drip) ──────────────────────────
// It comes out of the centre notch (Andre: "make the nexus actually flow in
// / liquid in from the top notch, becoming the window it is now"). The first
// version DRIPPED — a drop fell on a thread and inflated into the window —
// and read as "notch → teardrop → balloon → Nexus": a string holding a
// balloon, a giant round blob, then a rectangle, and on the way out the
// window shrank into a blob with its controls still readable. So it
// EXTRUDES now: the notch's bottom sags on the first frame, a broad neck
// comes down with a bulb on it, the bulb deepens and then widens — a flask
// flaring all the way down from the neck, never the window at 60 % — and
// becomes the window, and the neck thins and draws back into the notch. The
// content arrives once the silhouette is established, the navigation and
// title a beat before the page. Closing is not that backwards: the content
// goes at once, the window's top centre pinches up into a broad neck, and
// the mass is drawn up it into the notch. Three springs (SurfaceLifecycle,
// liquid), as every surface: the extrusion leads, the spread follows it, the
// neck trails.
//
// It is drawn as a FIELD (shapes/fluid/FluidDrop, geometry.js
// notchExtrudeField): round primitives smooth-unioned per pixel, so every
// join is a meniscus and every tip is round. The card's rim and its shadow
// arrive once the neck has drawn back — a shadow under a shape that is still
// pouring would be the wrong shape. Under Reduce Motion the card is simply
// there and fades, as before. Its window's lifetime is the lifecycle's
// `mapped` — completion, not a timer.
// ─────────────────────────────────────────────────────────────────────────────

PanelWindow {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForScreen(root.screen) }   // P1-040: this output's sizes


    required property string screenName
    // The bar on this output: the drop comes out of its centre notch, whose
    // width is live (a media title can widen it).
    property var topBar: null

    readonly property bool live: NexusState.open
                                 && NexusState.effectiveScreen === root.screenName

    // A Nexus can be BORN live. shell.qml builds one per entry in
    // Quickshell.screens, so an output arriving or leaving — which is what a
    // display apply does — destroys and rebuilds the whole set while the
    // settings window is open. A handler on `live` never fires for those,
    // because `live` was already true when they were constructed; the
    // lifecycle observes `open` from construction, so a Nexus born live opens
    // itself (tests/surface-lifecycle-test.qml, test_born_open_opens_itself).
    SurfaceLifecycle {
        name: "nexus"
        id: life
        open:          root.live
        // The hero beat: the one signature transition. Andre (2026-09-27):
        // the first extrusion "flashed by" in ~250 ms; the notch still moves
        // on the first frame and the gather is out by ~90 ms, but the body
        // forms over ~70-330 ms, the width settles by ~430, and the neck
        // draws back while the content arrives, settled by ~520.
        enterDuration: Motion.hero
        // Longer than a morph's exit, still shorter than the entrance: at
        // morphExit the sheet contracted from under its fading content (70 %
        // wide with the content still at 38 %, simulated), which is the
        // "window scaled down with its controls still readable" this replaced.
        exitDuration:  Motion.morphEnter
        liquid:        true
        surface:       body
        // The spread starts as the neck comes out with its bulb; on the way
        // out the mass is drawn up once the window has gone into it (the neck
        // is whole long before: geometry.js notchExtrudeField).
        openRelease:   0.2
        closeRelease:  0.2
        // The body a little slower and calmer than a morph's (response 0.63 s,
        // under the hero beat; a whisper of overshoot, capped at 3 px). It
        // starts a touch early and forms over ~11 % more time than it did, so
        // the width opens progressively instead of a skinny shape suddenly
        // going wide (Andre, 2026-09-27) — the first response is unchanged.
        bodyIn:        0.98
        bodyDamping:   0.85
        // The neck follows the spread closely: thinning as the window forms,
        // gone by ~520 ms, not dangling the finished window for longer.
        trailScale:    0.38
        // Nothing to read until the silhouette is established.
        contentAt:     0.82
        // Content leaves ahead of its surface, at once, and on a soft start
        // that still drops most of the way early: the settings are gone
        // before the window is noticeably a bulb (Andre: "by the time the
        // body becomes noticeably bulb-shaped, the detailed settings UI
        // should already be essentially gone"). Under Reduce Motion the alpha
        // takes the same beat, so the short fade stays.
        contentOut:      Motion.fadeOut
        contentOutCurve: Motion.standardDecel
    }

    // The window stays mapped for the duration of the close animation.
    readonly property bool windowVisible: life.mapped

    color: "transparent"
    visible: root.windowVisible

    anchors.top: true
    anchors.left: true
    anchors.right: true
    anchors.bottom: true

    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay

    // The whole window takes input while it is live (the backdrop swallows
    // clicks rather than dismissing), and none while it closes: a fullscreen
    // Overlay surface fading out used to eat the clicks that followed it.
    mask: Region { item: root.live ? content : null }

    // Exclusive focus, unlike the popups: there are text fields in here (the
    // lock-background path, the keybind capture) and they must receive keys.
    WlrLayershell.keyboardFocus: root.windowVisible && root.live
                                     ? WlrKeyboardFocus.Exclusive
                                     : WlrKeyboardFocus.None

    // Dim the desktop behind. Deliberately NOT a click-to-dismiss surface:
    // mis-clicking beside a slider should not throw away the settings window.
    // Escape and the close button are the ways out, and both are discoverable.
    Rectangle {
        anchors.fill: parent
        color: "black"
        // With the liquid, both ways: the desk dims as the window forms and
        // undims as it is drawn back into the notch. On the content's beat it
        // undimmed 140 ms into a close with the mass still being drawn up for
        // another 300. Under Reduce Motion the progress jumps and alpha
        // carries the change, so it is a fade of its own.
        opacity: 0.35 * life.progress * life.alpha
    }

    // ── The window's finished place, and what the extrusion connects to ─────
    readonly property real cardW: Math.min(root.width - theme.px(80), theme.px(920))
    readonly property real cardH: Math.min(root.height - theme.px(80), theme.px(620))
    readonly property real cardX: Math.round((root.width - root.cardW) / 2)
    readonly property real cardY: Math.round((root.height - root.cardH) / 2)
    readonly property var dropGeometry: ({
        cx:          root.width / 2,
        notchW:      root.topBar ? root.topBar.cWidth : theme.cNotchMinWidth,
        notchH:      theme.notchHeight,
        notchBottom: theme.notchBottom,
        card:        { x: root.cardX, y: root.cardY, w: root.cardW, h: root.cardH },
        r:           theme.radiusXL
    })
    // The rim and the shadow: in as the neck finishes drawing back (it is
    // fully back at trail 0.9), out as the window begins to contract —
    // both read off the springs, so the fade is continuous through a reversal
    // and never outlives the body it outlines.
    readonly property real _rim: life.alpha * Geo.smooth(Geo.span(life.trail, 0.9, 1))
                                            * Geo.smooth(Geo.span(life.body, 0.6, 1))

    Item {
        id: content
        anchors.fill: parent
        focus: true

        Keys.onEscapePressed: NexusState.close()
        Keys.onPressed: function (event) { InputModality.key(event); event.accepted = false }

        // Depth (UI/UX Phase 18b): the modal level. The scrim says the sheet is
        // modal; nothing said it was in front — on the light scheme the sheet sat
        // 3.6:1 over the scrimmed desk with only its hairline for an edge.
        Elevation { target: card; level: "modal" }

        // The neck, the bell and the sheet: one liquid body.
        FluidDrop {
            id: body
            anchors.fill: parent
            channels: ({ w: life.lead, d: life.body, n: life.trail })
            geometry: root.dropGeometry
            color:    Theme.background
            opacity:  life.alpha
        }

        // The card's rim (and the shadow's target), over the body. It follows
        // the body's own box rather than the finished window's, and leaves as
        // the body drains: held at the finished place on a 220 ms fade, it
        // stayed on screen as a ghost outline while the body had already
        // drained away beneath it (captured, 2026-09-27).
        Rectangle {
            id: card
            readonly property var _box: body.result.card
            x: _box.cx - _box.hw; y: _box.cy - _box.hh
            width: 2 * _box.hw; height: 2 * _box.hh
            radius: _box.r
            color: "transparent"
            border.color: Theme.outlineSoft   // the surface rim, as a role (UI/UX Phase 18b)
            border.width: 1
            opacity: root._rim
        }

        // Content at its finished layout, revealed where the sheet already
        // covers the finished window.
        Item {
            id: reveal
            x: body.result.clip.x; y: body.result.clip.y
            width: body.result.clip.w; height: body.result.clip.h
            clip: true

            Item {
                x: root.cardX - reveal.x
                y: root.cardY - reveal.y
                width: root.cardW; height: root.cardH
                opacity: life.alpha
                transform: Translate { y: (1 - life.content) * Motion.travel(theme.px(8)) }

                // Swallow clicks so they do not reach the backdrop.
                MouseArea {
                    anchors.fill: parent
                }

                SettingsHost {
                    anchors.fill: parent
                    theme: root.theme
                    page: NexusState.page
                    // Navigation and title first, the page a beat after.
                    reveal: life.content
                    live: root.windowVisible && root.live
                    onPageSelected: function (id) { NexusState.page = id }
                    onCloseRequested: NexusState.close()
                }
            }
        }
    }
}
