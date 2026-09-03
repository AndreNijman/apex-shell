import QtQuick
import Quickshell
import "../../components"
import "../../windows"
import "../../"

Item {
    id: root

    // The TopBar State handles expanding the notch for notifications/network/toasts
    implicitWidth: contentRow.implicitWidth

    //Behavior on implicitWidth {
    //    NumberAnimation { duration: Theme.animDuration; easing.type: Easing.InOutCubic }
    //}
    implicitHeight: contentRow.implicitHeight

    // ── Normal content — fades out when any right popup opens ─────────────────
    Row {
        id: contentRow
        //anchors.centerIn: parent
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6

        opacity: (Popups.notificationsOpen || Popups.networkOpen) ? 0 : 1
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 150 } }

        // Third-party bar widgets (roadmap §16). Leftmost in the cluster so the
        // shell's own indicators keep the positions users have muscle memory
        // for — a plugin appearing must not move the clock. Collapses to zero
        // width when no plugin is installed, which is the common case.
        PluginWidgets{}

        Network{}
        Audio{}
        Battery{}
        Clock{}
        Notifications{}
    }

    // ── Open indicator — fades in when any right popup opens ──────────────────
    Text {
        anchors.centerIn: parent
        text:           "▾"
        color:          Theme.active
        font.pixelSize: Theme.fs(14)
        opacity:        (Popups.notificationsOpen || Popups.networkOpen) ? 1 : 0
        visible:        opacity > 0
        Behavior on opacity { NumberAnimation { duration: 150 } }
    }
}
