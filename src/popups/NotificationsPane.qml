import QtQuick
import "../services/"
import "../"

// ─────────────────────────────────────────────────────────────────────────────
// NotificationsPane — the notification centre's content.
//
// A pane of RightPanel (RIGHT_POUR): the panel draws the body and reveals this
// at its finished layout. `bodyHeight` is the depth the body pours to; it
// follows the list, which clamps itself and scrolls beyond its maximum.
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: root
    required property ThemeSet theme

    readonly property int bodyHeight: notifList.height + theme.popupPadding * 2

    NotificationList {
        id:    notifList
        width: parent.width
    }
}
