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

    // ── The deduplication key (roadmap P1-022) ────────────────────────────────
    //
    // A hint the server would otherwise discard. Quickshell exposes only the
    // hints named here, so without this line `n.hints["x-apex-key"]` is
    // undefined and every lookup below silently answers "no such
    // notification" — which reads exactly like a shell that is not the
    // notification server at all.
    //
    // The key identifies WHAT A NOTIFICATION IS ABOUT, and it is set by
    // whatever raised it (see src/services/notifybus.js). It lives on the wire
    // rather than in a variable here for a reason worth stating: the shell is
    // the notification server for the whole session, so a notification about
    // an agent can arrive from AgentService, from a hook, or from a program
    // nobody has written yet, and only a key that travels with the
    // notification can make those the same piece of news.
    extraHints: ["x-apex-key"]

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

    // ── Lookup and retraction by key ─────────────────────────────────────────
    //
    // Both walk the tracked list rather than keeping an index. The list is the
    // notifications currently on screen — a handful, on a busy day a few dozen
    // — and an index would be a second thing to keep in step with `closed`,
    // with a stale entry pointing at a notification the user already swept
    // away. A short walk that cannot be wrong beats a map that can.

    // The server's own id for the notification currently standing under this
    // key, or 0. That id is what `notify-send --replace-id` needs to rewrite a
    // notification in place instead of stacking a second one under it.
    function byKey(key) {
        if (!key || !root.list) return null
        for (const n of root.list) {
            const h = n.hints
            if (h && h["x-apex-key"] === key) return n
        }
        return null
    }

    function idForKey(key) {
        const n = root.byKey(key)
        return n ? n.id : 0
    }

    // Close the notification standing under this key, because what it says has
    // stopped being true. Distinct from the user dismissing it: nobody read
    // this one, and leaving it up would mean a lock screen full of agents
    // asking for attention they no longer want.
    function retract(key) {
        const n = root.byKey(key)
        if (n) n.dismiss()
        return !!n
    }
}
