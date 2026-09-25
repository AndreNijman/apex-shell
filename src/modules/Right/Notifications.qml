import QtQuick
import Quickshell.Services.SystemTray
import "../../components"
import "../../windows"
import "../../"
import "../../services/"

IconBtn {
    text: ShellState.dnd
          ? "󰂛"
          : NotificationService.count > 0 ? "󰂚" : "󰂜"
    textColor: Popups.notificationsOpen ? Theme.accentText : Theme.iconDefault

    OpenPill { shown: Popups.notificationsOpen }

    onClicked: {
        var next = !Popups.notificationsOpen
        Popups.closeAll()
        Popups.notificationsOpen = next
    }
}