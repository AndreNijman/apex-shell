pragma Singleton
import QtQuick
import Quickshell.Services.Notifications
import "../../"

// ─────────────────────────────────────────────────────────────
// NotificationService — global singleton
// ─────────────────────────────────────────────────────────────

NotificationServer {
    id: root

    bodyMarkupSupported:   true
    bodySupported:         true
    actionsSupported:      true
    keepOnReload:          true
    
    signal notificationAdded(var notification)
    
    property var list: []
    readonly property int count: list.length

    // The last notification that was announced for a toast.
    //
    // The toast window is lazy-loaded, so it cannot be listening when the
    // notification that should create it arrives. This lets the window pick
    // that one up at construction instead of silently swallowing it. Written
    // only where notificationAdded is emitted, so Do Not Disturb and the
    // startup grace below still suppress toasts.
    property var lastToast: null

    property bool _ready: false
    
    // Assign the Timer to a named property to avoid the default property error
    property Timer _startupTimer: Timer {
        interval: 500 
        running: true
        onTriggered: root._ready = true
    }
    
    onNotification: function(n) {
        n.tracked = true

        if (root.list.includes(n)) return 

        root.list = [n, ...root.list]
        
        if (ShellState.dnd) return
        
        if (root._ready) {
            root.lastToast = n
            root.notificationAdded(n)
        }

         n.onClosed.connect(function() {
            root.list = root.list.filter(function(x) { return x !== n })
        })
    }

    function dismissAll() {
        if (!root.list) return
        const list = [...root.list]
        for (const n of list) n.dismiss()
    }
}
