import Quickshell
import Quickshell.Wayland
import QtQuick
import "../components"
import "../modules/Center/"
import "../modules/Right/"
import "../modules/Left/"
import "../"
import "../shapes/"

PanelWindow {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForScreen(root.screen) }   // P1-040: this output's sizes


    property string screenName: screen ? screen.name : ""

    color: "transparent"

    // Preserve the original full-surface input behavior outside labwc. On
    // labwc, match the painted shape: the full-width border strip plus each
    // notch and its concave shoulder. This frees the transparent gaps without
    // making visible bar pixels click through to application titlebars.
    mask: Region {
        Region {
            x: 0; y: 0
            width: root.width
            height: Compositor.isLabwc ? theme.borderWidth : root.implicitHeight
        }
        Region {
            x: 0; y: 0
            width: Compositor.isLabwc && !ShellState.focusMode
                ? root.lWidth + theme.notchRadius : 0
            height: root.implicitHeight
        }
        Region {
            x: Math.round((root.width - root.cWidth) / 2) - theme.notchRadius
            y: 0
            width: Compositor.isLabwc && !ShellState.focusMode
                ? root.cWidth + theme.notchRadius * 2 : 0
            height: root.implicitHeight
        }
        Region {
            x: root.width - root.rWidth - theme.notchRadius; y: 0
            width: Compositor.isLabwc && !ShellState.focusMode
                ? root.rWidth + theme.notchRadius : 0
            height: root.implicitHeight
        }
    }

    // Unmap the whole bar while a fullscreen window owns this output. This is a
    // layer-shell surface on layer `top`, so the compositor draws it OVER a
    // fullscreen game and pays to composite it on every frame. `visible: false`
    // really does unmap the surface (verified against `hyprctl layers`), so the
    // compositor has nothing to draw instead of something invisible to draw.
    visible: !ShellState.fullscreenCovers(root.screenName)

    anchors {
        top:   true
        left:  true
        right: true
    }

    // ── Caffeine — Wayland idle-inhibit while ShellState.caffeine is on ───────
    // One inhibitor per bar window, which is always mapped.
    //
    // This is the SECONDARY mechanism, and on Hyprland it does nothing at all.
    // Measured on Hyprland 0.56.2 against hypridle 0.1.8, one arm per fresh
    // nested compositor: an inhibitor on this layer surface leaves idle firing
    // exactly as if it were absent, while the identical inhibitor on a plain
    // toplevel suppresses it. Hyprland ignores idle inhibitors on layer-shell
    // surfaces, and a bar is a layer-shell surface. On labwc 0.9.6 the same
    // inhibitor on the same kind of surface DOES suppress idle.
    //
    // So this is kept, not deleted, and not gated on a capability:
    //   • it works on labwc, and on anything else whose compositor honours the
    //     protocol for layer surfaces;
    //   • it is the ONLY route that works for an idle daemon which never asks
    //     logind — swayidle being the obvious one — and the shell does not know
    //     which daemon a session runs;
    //   • where it is inert it costs one protocol object and nothing else.
    //
    // What actually makes Caffeine work today is the logind `idle` block
    // inhibitor in ShellState, which is compositor-independent and held
    // unconditionally. The two together are why the tile cannot be dead; see
    // ShellState.caffeineInhibitor for the full measurement.
    //
    // `enabled` is Caffeine and nothing else — deliberately no compositor name
    // and no capability, so no session can end up holding neither mechanism.
    IdleInhibitor {
        window:  root
        enabled: ShellState.caffeine
    }

    // ── Height shrinks to a border strip in focus mode ───────────────────────
    // Safe to animate on PanelWindow (anchored, no position jank).
    // PopupWindow is the one that must never have animated implicitHeight.
    implicitHeight: ShellState.focusMode ? theme.borderWidth : theme.notchHeight
    // Focus mode collapses the bar to its strip over the page beat (brief §D.7).
    Behavior on implicitHeight { MotionMove { role: "page"; curve: Motion.standard } }

    // labwc adds real server-side titlebars. Reserve the complete bar height so
    // their iconify/maximize/close buttons start below the right notch instead
    // of sharing its last few rows. Hyprland keeps its existing spacing.
    exclusiveZone: ShellState.focusMode ? 0
        : (Compositor.isLabwc
            ? Math.max(theme.notchHeight, theme.exclusionGap)
            : theme.exclusionGap)
    Behavior on exclusiveZone {
        enabled: !Compositor.isLabwc
        MotionMove { role: "page"; curve: Motion.standard }
    }

    // The left notch grows with its content like the centre one; it used to
    // snap while the other two animated (brief §F.10).
    property int lWidth: Math.max(
        theme.lNotchMinWidth,
        Math.min(theme.lNotchMaxWidth,
                 leftContent.implicitWidth + theme.notchPadding * 2)
    )
    Behavior on lWidth { MotionMove { role: "page"; curve: Motion.standard } }

    // The centre notch's own width — its content's, clamped. It no longer
    // widens to the Dashboard's page width while the Dashboard is open: the
    // Dashboard draws its whole silhouette over the notch (CENTER_BLOOM) and
    // starts from, and shrinks back into, exactly this width, read live. A
    // notch tweening underneath a body that already covers it was motion
    // nobody could see, and a second clock on the same edge.
    property int cWidth: Math.max(
            theme.cNotchMinWidth,
            Math.min(theme.cNotchMaxWidth,
                     centerContent.implicitWidth + theme.notchPadding * 2)
          )
    Behavior on cWidth { MotionMove { role: "page"; curve: Motion.standard } }

    // ── The right notch, and the clock of what pours out of it ──────────────
    // (UI/UX roadmap v3 Phase 9, RIGHT_POUR)
    // Network, the notification centre and the toast are panes of ONE surface
    // under this notch (popups/RightPanel.qml). Its lifecycle lives HERE, in the
    // bar, because the bar is the one party always present — the panel is built
    // lazily and cannot be referenced from here, but it can read this.
    //
    // The notch itself does not move. The panel draws the part that does — the
    // band the notch widens into, its shoulder, a cover over this notch's own
    // bottom-left corner — in the same window and frame as the body under it.
    // The first cut had this notch widen in step from the same width function;
    // measured, the two layer surfaces present their frames independently and
    // the notch sat a frame off the body (a 35-42 px ledge on a close). It
    // replaces three `states` and a Transition that tweened rWidth on its own
    // InOutCubic while each popup tweened a sizer on another.

    // The notch's own width: its content's, clamped (the pour's W0).
    readonly property int rNaturalWidth: Math.max(
        theme.rNotchMinWidth,
        Math.min(theme.rNotchMaxWidth, rightContent.implicitWidth + theme.notchPadding * 2)
    )
    readonly property int rWidth: root.rNaturalWidth

    // Which pane the flags ask for. The centre, the network panel and audio
    // are mutually exclusive (every trigger runs closeAll() first); the toast
    // shows only when none of them is up.
    readonly property string rightWanted: Popups.notificationsOpen ? "notifications"
                                        : Popups.networkOpen       ? "network"
                                        : Popups.audioOpen         ? "audio"
                                        : root.rightToastShowing   ? "toast" : ""
    // Pushed by RightPanel: whether its toast pane has something to show (per
    // screen — the old global flag let one screen's dismiss close every bar),
    // and that the panel exists at all. The clock does not start before the
    // panel is built: its first build blocks the thread, and an animation
    // started before it would be most of the way through on its first frame.
    property bool rightToastShowing: false
    property bool rightHostReady:    false

    // The pane on screen. Held through a close, so the body shrinks back from
    // the shape it had rather than from the natural notch.
    property string rightPane: ""
    onRightWantedChanged: if (root.rightWanted !== "") root.rightPane = root.rightWanted

    readonly property SurfaceLifecycle rightLife: SurfaceLifecycle {
        open:          root.rightWanted !== "" && root.rightHostReady
        enterDuration: Motion.surfaceEnterSmall
        exitDuration:  Motion.surfaceExitSmall
    }

    // The finished width of the pane (W1): never narrower than the notch it
    // hangs from, so a wide status cluster is not clipped by its own panel.
    readonly property int rightPaneWidth: root.rightPane === "network"       ? theme.networkPopupWidth + theme.notchRadius
                                        : root.rightPane === "notifications" ? theme.notificationsWidth + theme.notchRadius
                                        : root.rightPane === "audio"         ? theme.px(Popups.audioPage === "mixer" ? 300 : 200) + theme.notchRadius
                                        : root.rightPane === "toast"         ? theme.notificationToastWidth + theme.notchRadius
                                        : root.rNaturalWidth
    property real rightTargetW: Math.max(root.rightPaneWidth, root.rNaturalWidth)
    // Switching pane while the panel is up retargets the width over a page
    // beat (progress stays 1); from closed it is simply the new pane's.
    Behavior on rightTargetW {
        enabled: root.rightLife.progress > 0
        MotionMove { role: "page"; curve: Motion.standard }
    }

    // ── Border strip (focus mode) ────────────────────────────────────────────
    // Painted behind the notch content layer. Visible only when focus mode
    // fades the notches out. Uses the same bar color so it reads as a thin
    // edge strip matching the side border strips.
    Rectangle {
        anchors.fill: parent
        color: Theme.background
        opacity: ShellState.focusMode ? 1 : 0
        Behavior on opacity { MotionFade {} }
    }

    // ── Notch content (fades out in focus mode) ──────────────────────────────
    Item {
        anchors.fill: parent
        opacity: ShellState.focusMode ? 0 : 1
        Behavior on opacity { MotionFade {} }
        
        SeamlessBarShape {
            id: barShape
            anchors.fill: parent
            leftWidth:   root.lWidth
            centerWidth: root.cWidth
            rightWidth:  root.rWidth
            rightAttached: root.rightLife.progress > 0

        }

        Item {
            id:           leftNotch
            width:        root.lWidth
            height:       theme.notchHeight
            anchors.left: parent.left
            clip:         true

            LeftContent {
                id: leftContent
                screenName: root.screenName
                anchors.centerIn: parent
            }
        }

        Item {
            id:               centerNotch
            width:            root.cWidth
            height:           theme.notchHeight
            anchors.centerIn: parent

            CenterContent {
                id: centerContent
                screenName: root.screenName
                anchors.centerIn: parent
            }
        }

        Item {
            id:            rightNotch
            width:         root.rWidth
            height:        theme.notchHeight
            anchors.right: parent.right
            
            clip: true

            RightContent {
                id: rightContent
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.rightMargin: theme.notchPadding
            }
        }
    }
}
