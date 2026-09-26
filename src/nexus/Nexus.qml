import QtQuick
import Quickshell
import Quickshell.Wayland
import QtQuick.Shapes
import "../"
import "../components"
import "../components/controls"
import "../shapes/fluid"

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
// and stay attached the way the Dashboard does. It DRIPS (geometry.js
// notchDrop): a drop swells out of the centre notch and falls on a liquid neck,
// inflates at the window's place into the card, and the neck thins, pinches
// and pulls back — half into the notch, half into the card, which settles
// flat. Closing plays it backwards: the card drains into a drop and is drawn
// up into the notch. Three springs (SurfaceLifecycle, liquid): the drip leads,
// the inflation follows it, the thread trails. The card's rim and its shadow
// arrive once the neck has let go — a shadow under a shape that is still
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
        // A morph, the same class as the Dashboard's bloom.
        enterDuration: Motion.morphEnter
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
    // The rim and the shadow: once the neck has let go, gone the moment a
    // close begins (on a short fade, not a cut).
    readonly property bool _settled: life.open && !life.closing && life.trail >= 0.9

    Item {
        id: content
        anchors.fill: parent
        focus: true

        Keys.onEscapePressed: NexusState.close()

        // Depth (UI/UX Phase 18b): the modal level. The scrim says the sheet is
        // modal; nothing said it was in front — on the light scheme the sheet sat
        // 3.6:1 over the scrimmed desk with only its hairline for an edge.
        Elevation { target: card; level: "modal" }

        // The drop, the neck and the card: one liquid body.
        FluidShape {
            id: body
            anchors.fill: parent
            family:   "notchDrop"
            progress: life.progress
            channels: ({ w: life.lead, d: life.body, n: life.trail })
            geometry: root.dropGeometry
            fillRule: ShapePath.WindingFill
            color:    Theme.background
            opacity:  life.alpha
        }

        // The finished card's rim (and the shadow's target), over the body.
        Rectangle {
            id: card
            x: root.cardX; y: root.cardY
            width: root.cardW; height: root.cardH
            radius: theme.radiusXL
            color: "transparent"
            border.color: Theme.outlineSoft   // the surface rim, as a role (UI/UX Phase 18b)
            border.width: 1
            opacity: root._settled ? life.alpha : 0
            Behavior on opacity { MotionFade { role: "state" } }
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
