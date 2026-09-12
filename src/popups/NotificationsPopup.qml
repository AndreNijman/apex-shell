import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../components"
import "../shapes/"
import "../services/"
import "../"

PopupWindow {
    id: root
    // MEASURED: a PopupWindow's own `screen` is NOT the one it is

    // anchored to. On two headless outputs the popup anchored to the

    // bar on the 3840x2160 output reported the 1920x1080 one and

    // would have been sized at 1.0 — silently, on the monitor the

    // global factor was never for. The anchor window is given its

    // screen by shell.qml, so it is the one that knows.

    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForScreen(root.anchorWindow ? root.anchorWindow.screen : null) }


    required property var anchorWindow

    readonly property int popupWidth:   theme.notificationsWidth
    readonly property int maxHeight:    700
    readonly property int fw:           theme.notchRadius
    readonly property int fh:           theme.notchRadius
    readonly property int animDuration: Theme.animDuration

    // Fixed — never zero, never dynamic
    implicitWidth:  popupWidth +fw
    implicitHeight: maxHeight

    // Right-aligned directly under the expanded right pill: the window top sits
    // exactly at the pill's bottom edge, so the pill-right shape's flush top
    // joins the pill with no wallpaper sliver.
    // Edges.Bottom grows downward horizontally centred on the anchor point, so
    // the point is the desired popup centre-x — its right edge lands flush at
    // the screen edge, its left edge at the expanded pill's left edge.
    anchor.window: root.anchorWindow
    anchor.rect: Qt.rect(
        anchorWindow.width - root.implicitWidth / 2,
        theme.notchHeight,
        0,
        0
    )
    anchor.gravity:    Edges.Bottom
    anchor.adjustment: PopupAdjustment.None

    color:   "transparent"
    visible: windowVisible
    mask: Region { item: sizer }

    // ── Visibility gate ───────────────────────────────────────
    // Window stays alive until the close animation finishes.
    property bool windowVisible: false

    // Shared by the open signal and by LazyPopup, which calls this right after
    // building the window — the popup does not exist for the signal that opens
    // it the first time.
    function applyOpenState() {
        closeTimer.stop()
        root.windowVisible = true
    }

    Connections {
        target: Popups
        function onNotificationsOpenChanged() {
            if (Popups.notificationsOpen) {
                root.applyOpenState()
            } else {
                closeTimer.restart()
            }
        }
    }

    Timer {
        id:       closeTimer
        interval: root.animDuration + 20
        // Guarded, because reopening inside the close animation leaves this
        // timer pending: unguarded it would blank the freshly opened window.
        onTriggered: if (!Popups.notificationsOpen) root.windowVisible = false
    }
    
    // ── Sizer ─────────────────────────────────────────────────
    // Anchored top-right so it grows leftward + downward from
    // the right notch — mirroring how Dashboard grows from center.
    Item {
        id:            sizer
        anchors.top:   parent.top
        anchors.right: parent.right
        clip:          true

        // Width: rNotchMinWidth → notificationsWidth  (matches the pill width)
        width: Popups.notificationsOpen
               ? theme.notificationsWidth + root.fw
               : theme.rNotchMinWidth + root.fw

        // Height: collapsed → full content height (top is flush with the pill)
        height: Popups.notificationsOpen
                ? notifList.height + theme.popupPadding * 2
                : 0

        Behavior on width  { NumberAnimation { duration: root.animDuration; easing.type: Easing.InOutCubic } }
        Behavior on height { NumberAnimation { duration: root.animDuration; easing.type: Easing.InOutCubic } }

        // ── Background ─────────────────────────────────────────
        // Flush-top card merging into the pill above (S-waist at the left join).
        PopupShape {
            anchors.fill: parent
            attachedEdge: "pill-right"
            color:        Theme.background
            radius:       theme.cornerRadius
        }

        // ── Content ────────────────────────────────────────────
        // Fades in slowly after expansion, fades out fast on close.
        Item {
            anchors {
                fill:         parent
                topMargin:    theme.popupPadding
                leftMargin:   theme.popupPadding
                rightMargin:  theme.popupPadding
                bottomMargin: 4
            }

            opacity: Popups.notificationsOpen ? 1 : 0
            Behavior on opacity {
                NumberAnimation {
                    duration: Popups.notificationsOpen
                              ? root.animDuration * 0.5
                              : root.animDuration * 0.15
                }
            }

            NotificationList {
                id:    notifList
                width: parent.width
            }
        }
    }
}
