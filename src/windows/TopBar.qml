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
            height: Compositor.isLabwc ? Theme.borderWidth : root.implicitHeight
        }
        Region {
            x: 0; y: 0
            width: Compositor.isLabwc && !ShellState.focusMode
                ? root.lWidth + Theme.notchRadius : 0
            height: root.implicitHeight
        }
        Region {
            x: Math.round((root.width - root.cWidth) / 2) - Theme.notchRadius
            y: 0
            width: Compositor.isLabwc && !ShellState.focusMode
                ? root.cWidth + Theme.notchRadius * 2 : 0
            height: root.implicitHeight
        }
        Region {
            x: root.width - root.rWidth - Theme.notchRadius; y: 0
            width: Compositor.isLabwc && !ShellState.focusMode
                ? root.rWidth + Theme.notchRadius : 0
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

    Binding { target: ShellState; property: "topBarLWidth"; value: root.lWidth }
    Binding { target: ShellState; property: "topBarCWidth"; value: root.cWidth }
    Binding { target: ShellState; property: "topBarRWidth"; value: root.rWidth }

    // ── Caffeine — Wayland idle-inhibit while ShellState.caffeine is on ───────
    // One inhibitor per bar window (always mapped); any active inhibitor stops
    // the compositor's idle timers, so hypridle never dims/locks/suspends.
    IdleInhibitor {
        window:  root
        enabled: ShellState.caffeine
    }

    // ── Height shrinks to a border strip in focus mode ───────────────────────
    // Safe to animate on PanelWindow (anchored, no position jank).
    // PopupWindow is the one that must never have animated implicitHeight.
    implicitHeight: ShellState.focusMode ? Theme.borderWidth : Theme.notchHeight
    Behavior on implicitHeight {
        NumberAnimation { duration: Theme.animDuration; easing.type: Easing.InOutCubic }
    }

    // labwc adds real server-side titlebars. Reserve the complete bar height so
    // their iconify/maximize/close buttons start below the right notch instead
    // of sharing its last few rows. Hyprland keeps its existing spacing.
    exclusiveZone: ShellState.focusMode ? 0
        : (Compositor.isLabwc
            ? Math.max(Theme.notchHeight, Theme.exclusionGap)
            : Theme.exclusionGap)
    Behavior on exclusiveZone {
        NumberAnimation {
            duration: Compositor.isLabwc ? 0 : Theme.animDuration
            easing.type: Easing.InOutCubic
        }
    }

    readonly property int lWidth: Math.max(
        Theme.lNotchMinWidth,
        Math.min(Theme.lNotchMaxWidth,
                 leftContent.implicitWidth + Theme.notchPadding * 2)
    )

    // cWidth uses Popups.dashboardPageWidth when the dashboard is open,
    // so the center notch tracks the active tab's declared width.
    property int cWidth: Popups.dashboardOpen && Popups.dashboardScreen === root.screenName
        ? Popups.dashboardPageWidth
        : Math.max(
            Theme.cNotchMinWidth,
            Math.min(Theme.cNotchMaxWidth,
                     centerContent.implicitWidth + Theme.notchPadding * 2)
          )
    Behavior on cWidth {
        NumberAnimation { duration: Theme.animDuration; easing.type: Easing.InOutCubic }
    }

    // Width matches sizer open width: popupWidth + notchRadius (fw) in both popups
    property int rWidth: Math.max(
        Theme.rNotchMinWidth,
        Math.min(Theme.rNotchMaxWidth, rightContent.implicitWidth + Theme.notchPadding * 2)
    )

    // ── Border strip (focus mode) ────────────────────────────────────────────
    // Painted behind the notch content layer. Visible only when focus mode
    // fades the notches out. Uses the same bar color so it reads as a thin
    // edge strip matching the side border strips.
    Rectangle {
        anchors.fill: parent
        color: Theme.background
        opacity: ShellState.focusMode ? 1 : 0
        Behavior on opacity {
            NumberAnimation { duration: Theme.animDuration; easing.type: Easing.InOutCubic }
        }
    }

    // ── Notch content (fades out in focus mode) ──────────────────────────────
    Item {
        anchors.fill: parent
        opacity: ShellState.focusMode ? 0 : 1
        Behavior on opacity {
            NumberAnimation { duration: Theme.animDuration; easing.type: Easing.InOutCubic }
        }
        
        states: [
        State {
            name: "notifications"
            when: Popups.notificationsOpen
            PropertyChanges { target: root; rWidth: Theme.notificationsWidth + Theme.notchRadius }
        },
        State {
            name: "network"
            when: Popups.networkOpen && !Popups.notificationsOpen
            PropertyChanges { target: root; rWidth: Theme.networkPopupWidth + Theme.notchRadius }
        },
        State {
            name: "toast"
            when: Popups.notificationToastOpen && !Popups.notificationsOpen && !Popups.networkOpen
            // Matches the toast card width exactly (standardised pill-popup)
            PropertyChanges { target: root; rWidth: Theme.notificationToastWidth + Theme.notchRadius }
        }
    ]

    transitions: [
        Transition {
            // This animation ONLY runs when switching between popups (and toasts) and the base state.
            NumberAnimation { property: "rWidth"; duration: Theme.animDuration; easing.type: Easing.InOutCubic }
        }
    ]

        SeamlessBarShape {
            id: barShape
            anchors.fill: parent
            leftWidth:   root.lWidth
            centerWidth: root.cWidth
            rightWidth:  root.rWidth

            // Un-round the right notch's bottom-left corner while a pill-popup
            // hangs under it, so pill + popup merge into one straight edge.
            rightBottomRadius: (Popups.notificationsOpen || Popups.networkOpen
                                || Popups.notificationToastOpen)
                ? 0 : Theme.notchRadius
            Behavior on rightBottomRadius {
                NumberAnimation { duration: Theme.animDuration; easing.type: Easing.InOutCubic }
            }
        }

        Item {
            id:           leftNotch
            width:        root.lWidth
            height:       Theme.notchHeight
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
            height:           Theme.notchHeight
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
            height:        Theme.notchHeight
            anchors.right: parent.right
            
            clip: true

            RightContent {
                id: rightContent
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.rightMargin: Theme.notchPadding
            }
        }
    }
}
