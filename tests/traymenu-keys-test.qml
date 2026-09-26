import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.SystemTray
import "./src/services"
import "./src"
import "./src/modules/Right"

// The tray menu's keyboard model (UI/UX roadmap v3 Phase 21), for
// tests/run-traymenu-keys-test.sh: the REAL TrayMenu on the one tray item
// tests/lib/fake-tray-item.py registers on a private bus, driven through the
// functions its key handler calls.
//
// grabFocus is off HERE ONLY: a grabbing popup opened without a pointer
// click's serial is dismissed by the compositor at once (measured: 62-135 ms
// after it maps, before any key), and this harness has no pointer to click
// with. In the shell the menu opens from a click and keeps its grab.
ShellRoot {
    PanelWindow {
        id: bar
        anchors { top: true; left: true; right: true }
        implicitHeight: 40
        color: "transparent"

        Item { id: anchorItem; x: 100; y: 7; width: 26; height: 26 }
        readonly property var item: SystemTray.items.values.length > 0 ? SystemTray.items.values[0] : null
        onItemChanged: if (bar.item) console.warn("TRAYTEST ITEM")

        TrayMenu {
            id: tm
            target: anchorItem
            grabFocus: false
            menu: bar.item ? bar.item.menu : null
            onVisibleChanged: console.warn(visible ? "TRAYTEST OPEN" : "TRAYTEST CLOSED")
        }

        IpcHandler {
            target: "traytest"
            function open(): string   { if (!tm.visible) tm.toggle(); return "open" }
            function step(d: int): string {
                tm._step(d)
                return tm.curItem ? tm.curItem.label : "(none)"
            }
            function rows(): int      { return tm._rows().length }
            function choose(): string {
                const cur = tm.curItem
                if (!cur) return "(none)"
                const label = cur.label
                cur.activated()
                return label
            }
        }
    }
}
