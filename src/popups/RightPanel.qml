import QtQuick
import Quickshell
import Quickshell.Wayland
import "../shapes/fluid"
import "../components"
import "../services/"
import "../"

// ─────────────────────────────────────────────────────────────────────────────
// RightPanel — what pours out of the right notch (UI/UX roadmap v3 Phase 9,
// RIGHT_POUR): the network panel, the notification centre, audio and the
// toast, as panes of ONE surface.
//
// They used to be three windows, each with a sizer tweening its own width and
// height on InOutCubic while the bar tweened the notch on another, so the
// notch and the body it was meant to be joined to drifted apart; switching
// from Network to the centre closed one body while another opened under the
// same notch. Now there is one body and one clock:
//
//   * The clock is TopBar.rightLife. The bar owns it because the bar always
//     exists and this window is built lazily.
//   * The bar's notch does not move. This window draws everything that does —
//     the band the notch widens into, its shoulder out of the strip, a cover
//     over the notch's own bottom-left corner, and the body — so no moving
//     edge is shared between two layer surfaces, whose frames the compositor
//     presents independently. At progress 0 the band is exactly the bar's
//     notch, so the window maps and unmaps without a visible change.
//   * The body is geometry.js's rightPour: anchored right, depth first while a
//     short stem holds to the notch, then a leftward pour whose bottom-left
//     corner trails and bulges before it settles; its bottom-right melts into
//     the screen's right strip.
//   * Content is laid out at its finished place and revealed by the body's
//     clip. It arrives a beat after the body starts and leaves before it.
//   * Changing pane while the panel is up keeps the body open: the width and
//     depth retarget over a page beat and the panes cross-fade.
//
// The window is sized once for the largest pane; its input region is the body
// while open and nothing while it closes, so a closing panel never eats the
// click that follows it.
// ─────────────────────────────────────────────────────────────────────────────
PanelWindow {
    id: root

    // This screen's TopBar. It owns the clock this body runs on.
    required property var anchorWindow
    screen: root.anchorWindow.screen
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForScreen(root.screen) }   // P1-040: this output's sizes

    readonly property SurfaceLifecycle life: root.anchorWindow.rightLife
    readonly property string pane: root.anchorWindow.rightPane

    // The bar's clock waits for this window to exist (see TopBar.rightHostReady).
    Component.onCompleted: root.anchorWindow.rightHostReady = true

    // The toast asks for the surface through the bar, per screen.
    Binding {
        target:   root.anchorWindow
        property: "rightToastShowing"
        value:    toast.showing
    }

    // LazyPopup calls this right after the build: the notification that caused
    // it was announced before the toast pane existed.
    function applyOpenState() { toast.applyOpenState() }

    // Audio's page and tab pill go back to their start once the panel is gone,
    // not on a timer's guess at when that is.
    Connections {
        target: root.life
        function onClosed() { audio.reset() }
    }

    // y = 0 is the screen top: the band is drawn over the bar's strip, and
    // the seam (the notch's bottom edge) is at y = notchHeight.
    anchors.top:   true
    anchors.right: true

    exclusionMode: ExclusionMode.Ignore
    color:         "transparent"

    WlrLayershell.layer:         WlrLayer.Overlay
    // Only the network pane has anything to type into.
    WlrLayershell.keyboardFocus: (root.life.open && root.pane === "network")
                                 ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    visible: root.life.mapped

    // ── Finished sizes per pane ─────────────────────────────────────────────
    readonly property int networkDepth:       theme.px(648)
    readonly property int audioDepth:         theme.px(320)
    readonly property int notificationsDepth: Math.min(theme.px(700), notifications.bodyHeight)
    readonly property int paneDepth: root.pane === "network"       ? root.networkDepth
                                   : root.pane === "notifications" ? root.notificationsDepth
                                   : root.pane === "audio"         ? root.audioDepth
                                   : root.pane === "toast"         ? toast.bodyHeight
                                   : 0

    // D1. Retargets over a page beat while the body is up (a pane switch, a
    // notification arriving in the open centre); from closed it is simply the
    // pane's.
    property real targetD: root.paneDepth
    Behavior on targetD {
        enabled: root.life.progress > 0
        MotionMove { role: "page"; curve: Motion.standard }
    }

    // The window: wide enough for the widest pane plus the band's shoulder,
    // deep enough for the bar, the deepest pane and the fillet into the strip.
    implicitWidth:  Math.max(theme.networkPopupWidth, theme.notificationsWidth,
                             theme.notificationToastWidth, theme.rNotchMaxWidth)
                    + theme.notchRadius + theme.notchShoulder
    implicitHeight: theme.notchHeight + Math.max(root.networkDepth, theme.px(700)) + theme.radiusL

    // ── Body ────────────────────────────────────────────────────────────────
    // Under Reduce Motion a close holds the finished shape and fades it. The
    // band above the seam is dropped instead of faded: fading it showed the
    // bar's solid notch inside a translucent band for the length of the fade.
    // So while such a close runs, everything above the seam is clipped away
    // and the notch is the bar's own again from the first frame; only the
    // body below fades.
    Item {
        id: bodyClip
        readonly property bool bandGone: !root.life.open && root.life.exitDuration <= 0
        y: bodyClip.bandGone ? theme.notchHeight : 0
        width: root.width
        height: root.height - bodyClip.y
        clip: bodyClip.bandGone

        FluidShape {
            id: body
            y: -bodyClip.y
            width: root.width
            height: root.height
            family:   "rightPour"
            progress: root.life.progress
            color:    Theme.background
            opacity:  root.life.alpha
            geometry: ({
                winW:        root.width,
                strip:       theme.borderWidth,
                seam:        theme.notchHeight,
                shoulder:    theme.notchShoulder,
                notchBottom: theme.notchBottom,
                notchW:      root.anchorWindow.rNaturalWidth,
                w:           root.anchorWindow.rightTargetW,
                h:           root.targetD,
                r:           theme.radiusL
            })
        }
    }

    mask: Region { item: root.life.open ? hit : null }
    Item {
        id: hit
        x: body.result.bounds.x; y: body.result.bounds.y
        width: body.result.bounds.w; height: body.result.bounds.h
    }

    // ── Content, at its finished layout, revealed by the body's clip ────────
    component PaneSlot: Item {
        id: slot
        property string key
        readonly property bool current: root.pane === slot.key
        visible: slot.opacity > 0
        opacity: 0

        // Cross-fade on a switch while the panel is up; from closed, the pane
        // is simply the one on screen and the surface's content channel
        // carries it in.
        // The incoming pane waits for the outgoing one's fade, so the two are
        // never both at half strength over each other: out 70, then in 130 —
        // the page beat the body's own retarget runs on.
        onCurrentChanged: {
            fade.stop()
            if (root.life.progress <= 0) { slot.opacity = slot.current ? 1 : 0; return }
            fadeWait.duration = slot.current ? Motion.fadeOut : 0
            fadeMove.to = slot.current ? 1 : 0
            fadeMove.duration = slot.current ? Motion.fadeIn : Motion.fadeOut
            fade.start()
        }
        Component.onCompleted: slot.opacity = slot.current ? 1 : 0
        SequentialAnimation {
            id: fade
            PauseAnimation { id: fadeWait }
            NumberAnimation {
                id: fadeMove
                target: slot; property: "opacity"
                easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.effects
            }
        }
    }

    Item {
        id: reveal
        x: body.result.clip.x; y: body.result.clip.y
        width: body.result.clip.w; height: body.result.clip.h
        clip: true

        Item {
            id: content
            // Window coordinates, whatever the clip is doing.
            x: -reveal.x; y: -reveal.y
            width: root.width; height: root.height

            opacity: root.life.content
            transform: Translate { y: (1 - root.life.content) * Motion.travel(theme.px(10)) }

            PaneSlot {
                key: "network"
                readonly property int bodyW: theme.networkPopupWidth + theme.notchRadius
                x: root.width - bodyW + theme.popupPadding
                y: theme.notchHeight + theme.popupPadding
                width:  bodyW - theme.popupPadding * 2
                height: root.networkDepth - theme.popupPadding * 2

                // Built on the first visit and kept, like the window it was.
                Loader {
                    anchors.fill: parent
                    active: parent.current || item !== null
                    sourceComponent: Component { NetworkPane { theme: root.theme; focus: true } }
                }
            }

            PaneSlot {
                key: "notifications"
                readonly property int bodyW: theme.notificationsWidth + theme.notchRadius
                x: root.width - bodyW + theme.popupPadding
                y: theme.notchHeight + theme.popupPadding
                width:  bodyW - theme.popupPadding * 2
                height: root.notificationsDepth - theme.popupPadding

                NotificationsPane {
                    id: notifications
                    theme: root.theme
                    width: parent.width
                }
            }

            PaneSlot {
                key: "audio"
                // Audio's own width, not the pane on screen's: switching away,
                // the fading audio content must not jump to the next pane's.
                readonly property int bodyW: theme.px(Popups.audioPage === "mixer" ? 300 : 200) + theme.notchRadius
                x: root.width - bodyW + theme.px(10)
                y: theme.notchHeight + theme.px(12)
                width:  bodyW - theme.px(10) - theme.borderWidth - theme.px(6)
                height: root.audioDepth - theme.px(24)

                AudioControl {
                    id: audio
                    anchors.fill: parent
                }
            }

            PaneSlot {
                key: "toast"
                x: root.width - toast.width
                y: theme.notchHeight
                width:  toast.width
                height: toast.bodyHeight

                NotificationToast {
                    id: toast
                    theme: root.theme
                    blocked:     Popups.networkOpen || Popups.notificationsOpen
                    surfaceIdle: !root.life.mapped || root.pane !== "toast"
                }
            }
        }
    }
}
