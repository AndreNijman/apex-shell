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
// ── NOTCH_DROP (2026-09-27, replacing QUIET_SHEET) ──────────────────────────
// Andre: "make the nexus actually flow in / liquid in from the top notch,
// becoming the window it is now, instead of just appearing." It floats in the
// middle of the screen, not under the bar, so it cannot bloom out of the notch
// and stay attached the way the Dashboard does. It DRIPS: a drop gathers at
// the centre notch and hangs, lets go and falls on a thread, the window swells
// out of it at its place, and the thread pinches — each tail drawing back into
// its own side, the upper into the notch, the lower into the window. Closing
// plays it backwards: the tails reach out and join, the window drains into a
// drop, and the drop is drawn up into the notch. Three springs
// (SurfaceLifecycle, liquid): the fall leads, the inflation follows it, the
// thread trails.
//
// It is drawn as a FIELD (shapes/fluid/FluidDrop, geometry.js
// notchDropField): round primitives smooth-unioned per pixel, so every join is
// a meniscus and every tip is round. The first version joined curves by hand;
// Andre found it ugly — a pipe with a lollipop, and tails that swelled after
// the pinch. Its duration is the hero beat: a drip needs time to read as one.
// The card's rim and its shadow arrive once the thread has let go — a shadow
// under a shape that is still pouring would be the wrong shape. Under Reduce
// Motion the card is simply there and fades, as before. Its window's lifetime
// is the lifecycle's `mapped` — completion, not a timer.
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
        // The hero beat: a drop has to gather, fall and swell, and at the
        // morph beat the fall was over in 150 ms — too quick to read as one.
        enterDuration: Motion.hero
        exitDuration:  Motion.morphExit
        liquid:        true
        surface:       body
        // The inflation starts as the drop nears the window's place; on the
        // way out the drop is drawn back up once the card has drained into it.
        openRelease:   0.55
        closeRelease:  0.25
        // The sheet leaves on the scrim's beat. On the content beat (70 ms) it
        // was gone while the scrim still dimmed an empty desk for another
        // 65 ms (design review 2). Under Reduce Motion that beat is 0 and the
        // alpha takes it too, so the short fade stays.
        contentOut:    Motion.reduced ? Motion.fadeOut : Motion.surfaceExitSmall
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
        // With the progress (a fade of its own under Reduce Motion, when the
        // progress jumps and alpha carries the change). Closing, with the
        // sheet's own channel: on the progress (standardAccel, slow to start)
        // the dim outlived the sheet — at 187 ms of a slowed close, 69 % of the
        // scrim was left over 15 % of the sheet (design review 2, measured).
        opacity: 0.35 * (life.closing ? life.content : life.progress) * life.alpha
    }

    // ── The window's finished place, and what the drop connects to ──────────
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
    // The rim and the shadow: in as the thread's tails finish drawing back
    // (they are fully back at trail 0.9), out as the window begins to drain —
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

        // The drop, the thread and the card: one liquid body.
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

        // Content at its finished layout, revealed where the drop already
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
                opacity: life.content * life.alpha
                transform: Translate { y: (1 - life.content) * Motion.travel(theme.px(8)) }

                // Swallow clicks so they do not reach the backdrop.
                MouseArea {
                    anchors.fill: parent
                }

                SettingsHost {
                    anchors.fill: parent
                    theme: root.theme
                    page: NexusState.page
                    live: root.windowVisible && root.live
                    onPageSelected: function (id) { NexusState.page = id }
                    onCloseRequested: NexusState.close()
                }
            }
        }
    }
}
