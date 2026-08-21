pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// ─────────────────────────────────────────────────────────────────────────────
// LauncherState — pinned apps and launch history.
//
// Keyed on DesktopEntry.id (the .desktop basename), which is stable across
// renames of the visible Name, across locale changes, and across the app moving
// between /usr/share and a Flatpak export. Keying on the display name would
// silently lose a pin the first time an app retitled itself.
//
// ── Ranking ─────────────────────────────────────────────────────────────────
// "Recent" is frecency, not recency: a raw most-recently-used list is dominated
// by whatever was opened last, so the app you launch fifty times a day loses its
// spot to a one-off. Each launch adds a weight that decays with age, so
// something used constantly stays near the top and a single stray launch fades
// out within a few days.
//
// Persisted to user_data/launcher.json, written debounced so a burst of launches
// is one write.
// ─────────────────────────────────────────────────────────────────────────────

Singleton {
    id: root

    // Ordered, newest pin last. Order is preserved so users can arrange them.
    property var pinned: []

    // { id: { count, last } } — last is epoch ms.
    property var history: ({})

    property bool _loaded: false

    readonly property string _path: Quickshell.env("HOME") + "/.config/apex-shell/src/user_data/launcher.json"

    // Half-life for a launch's contribution, in days. Two weeks means a daily
    // driver stays ranked while last month's one-off does not.
    readonly property real halfLifeDays: 14

    function isPinned(id) {
        return root.pinned.indexOf(id) >= 0
    }

    function togglePin(id) {
        if (!id || id === "")
            return
        if (root.isPinned(id))
            root.pinned = root.pinned.filter(x => x !== id)
        else
            root.pinned = root.pinned.concat([id])
        root._save()
    }

    function recordLaunch(id) {
        if (!id || id === "")
            return
        const h = ({})
        for (const k in root.history)
            h[k] = root.history[k]
        const prev = h[id]
        h[id] = {
            "count": (prev ? prev.count : 0) + 1,
            "last": Date.now()
        }
        root.history = h
        root._save()
    }

    // Exponential decay on age since last launch, weighted by launch count.
    function score(id) {
        const e = root.history[id]
        if (!e)
            return 0
        const ageDays = (Date.now() - e.last) / 86400000
        return e.count * Math.pow(0.5, ageDays / root.halfLifeDays)
    }

    // Ids with any history, best first, capped.
    function topRecent(limit) {
        const ids = []
        for (const k in root.history)
            ids.push(k)
        ids.sort((a, b) => root.score(b) - root.score(a))
        return ids.slice(0, limit === undefined ? 8 : limit)
    }

    function clearHistory() {
        root.history = ({})
        root._save()
    }

    // ── Persistence ─────────────────────────────────────────────────────────
    readonly property Timer _saveTimer: Timer {
        interval: 400
        repeat: false
        onTriggered: root._write()
    }

    function _save() {
        if (root._loaded)
            root._saveTimer.restart()
    }

    readonly property FileView _file: FileView {
        path: root._path

        // On a fresh install this file does not exist yet. That is the normal
        // first-run state, not a fault, and Quickshell would otherwise log a
        // read failure on every startup until the user pins something.
        printErrors: false

        onLoaded: {
            try {
                const o = JSON.parse(text() || "{}")
                if (Array.isArray(o.pinned))
                    root.pinned = o.pinned.filter(x => typeof x === "string")
                if (o.history && typeof o.history === "object") {
                    const h = ({})
                    for (const k in o.history) {
                        const e = o.history[k]
                        if (!e)
                            continue
                        const c = parseInt(e.count)
                        const l = parseFloat(e.last)
                        if (!isNaN(c) && !isNaN(l))
                            h[k] = { "count": c, "last": l }
                    }
                    root.history = h
                }
            } catch (e) {
                console.log("LauncherState: parse failed:", e)
            }
            root._loaded = true
        }

        // No file yet on a fresh install: that is the normal first-run state,
        // not an error. Mark loaded so the first pin actually persists.
        onLoadFailed: root._loaded = true
    }

    readonly property Process _writeProc: Process {
        command: []
        running: false
    }

    function _write() {
        const payload = JSON.stringify({
            "pinned": root.pinned,
            "history": root.history
        })
        // Write via a temp file and rename so a crash mid-write cannot leave a
        // truncated JSON that fails to parse on next start.
        root._writeProc.command = ["sh", "-c", "mkdir -p \"$(dirname \"$1\")\" && printf '%s' \"$2\" > \"$1.tmp\" && mv \"$1.tmp\" \"$1\"", "--", root._path, payload]
        root._writeProc.running = false
        root._writeProc.running = true
    }
}
