pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../"

// UpdateService — startup update checker (30s delay).
// Persistent autoUpdate preference stored in src/user_data/update_prefs.json.
QtObject {
    id: root

    // ── Persistent preference ──────────────────────────────────────────────
    property bool autoUpdate: true

    // ── Live state (drives UpdatePopup) ───────────────────────────────────
    property bool   checking:        false
    property bool   updating:        false
    property bool   updateAvailable: false
    property bool   hasConflict:     false
    property bool   updateSuccess:   false
    
    property int    commitsBehind:   0
    property var    commitMessages:  []
    property string lastError:       ""
    property int _pingAttempts:    0
    property int _pingMaxAttempts: 12
    
    property var _pingRetryTimer: Timer {
        interval: 5000
        repeat:   false
        onTriggered: root._pingCheck()
    }
    
    property var _pingProc: Process {
        command: ["ping", "-c", "1", "-W", "3", "1.1.1.1"]
        running: false
        onExited: function(code) {
            if (code === 0) {
                root._pingAttempts = 0
                root.check()
            } else {
                root._pingAttempts++
                if (root._pingAttempts < root._pingMaxAttempts) {
                    root._pingRetryTimer.restart()
                } else {
                    root._pingAttempts = 0  // silent cancel
                }
            }
        }
    }
    
    function _startConnectivityCheck() {
        root._pingAttempts = 0
        root._pingCheck()
    }
    
    function _pingCheck() {
        root._pingProc.running = false
        root._pingProc.running = true
    }

    // Popup is only shown when autoUpdate is enabled
    readonly property bool showPopup:
        autoUpdate && (
            updateAvailable ||
            updating ||
            hasConflict ||
            updateSuccess ||
            (lastError !== "" && !checking)
        )

    // ── Paths ──────────────────────────────────────────────────────────────
    readonly property string _dir:        Quickshell.shellDir
    readonly property string _cfgPath:    Quickshell.shellDir + "/src/user_data/update_prefs.json"

    // ── Startup: 30s delay ─────────────────────────────────────────────────
    property var _startTimer: Timer {
        interval: 30000
        repeat:   false
        running:  false
        onTriggered: root._startConnectivityCheck()
    }

    // ── Config: init → read → arm timer ───────────────────────────────────
    property var _initProc: Process {
        command: ["bash", "-c",
            // Ensure pref file exists
            "[ -f '" + root._cfgPath + "' ] || " +
            "(mkdir -p \"$(dirname '" + root._cfgPath + "')\" && " +
            "printf '%s' '{\"autoUpdate\":true}' > '" + root._cfgPath + "');\n" +
            // Emit prefs
            "cat '" + root._cfgPath + "'"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var o = JSON.parse(text.trim())
                    if (typeof o.autoUpdate === "boolean")
                        root.autoUpdate = o.autoUpdate
                } catch(e) {}

                if (root.autoUpdate) root._startTimer.start()
            }
        }
    }

    // ── Config: save ──────────────────────────────────────────────────────
    property var _saveProc: Process { command: []; running: false }

    function _saveConfig() {
        var json = JSON.stringify({ autoUpdate: root.autoUpdate })
        _saveProc.command = ["bash", "-c",
            "printf '%s' '" + json.replace(/'/g, "'\\''") +
            "' > '" + root._cfgPath + "'"]
        _saveProc.running = false
        _saveProc.running = true
    }

    // ── Step 1: fetch origin/main ──────────────────────────────────────────
    property var _fetchProc: Process {
        command: ["git", "-C", root._dir, "fetch", "origin", "main", "--quiet"]
        running: false
        onExited: function(code) {
            if (code !== 0) {
                root.checking  = false
                root.lastError = "Could not reach remote. Check your connection."
                return
            }
            _countProc.running = false
            _countProc.running = true
        }
    }

    // ── Step 2: count commits behind ──────────────────────────────────────
    property var _countProc: Process {
        command: ["bash", "-c",
            "git -C '" + root._dir + "' rev-list --count HEAD..origin/main 2>/dev/null"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                var n = parseInt(text.trim())
                root.commitsBehind = isNaN(n) ? 0 : n
                if (root.commitsBehind > 0) {
                    _logProc.running = false
                    _logProc.running = true
                } else {
                    root.checking = false
                }
            }
        }
    }

    // ── Step 3: read commit log ────────────────────────────────────────────
    property var _logProc: Process {
        command: ["bash", "-c",
            "git -C '" + root._dir +
            "' log HEAD..origin/main --oneline --no-decorate 2>/dev/null"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = text.trim()
                    .split("\n")
                    .filter(function(l) { return l.trim() !== "" })
                root.commitMessages  = lines
                root.checking        = false
                root.updateAvailable = true
            }
        }
    }

    // ── Git pull ───────────────────────────────────────────────────────────
    property var _pullProc: Process {
        command: ["git", "-C", root._dir, "pull", "origin", "main"]
        running: false
        onExited: function(code) {
            root.updating = false
            if (code === 0) {
                root.updateAvailable = false
                root.hasConflict     = false
                root.lastError       = ""
                root.updateSuccess   = true
            } else {
                // fetch succeeded earlier, so failure = local changes conflict
                root.hasConflict = true
                root.lastError   = ""
            }
        }
    }

    // ── Stash local changes, then pull ────────────────────────────────────
    // stash pop is intentionally omitted — shell reloads after update anyway.
    // User can `git stash pop` manually if they want changes back.
    property var _stashPullProc: Process {
        command: ["bash", "-c",
            // stash with || true so an empty worktree doesn't abort the whole chain
            "git -C '" + root._dir + "' stash push -m 'brain-shell-pre-update' 2>/dev/null || true; " +
            "git -C '" + root._dir + "' pull origin main 2>&1"]
        running: false
        onExited: function(code) {
            root.updating = false
            if (code === 0) {
                root.updateAvailable = false
                root.hasConflict     = false
                root.lastError       = ""
                root.updateSuccess   = true
            } else {
                root.hasConflict = false
                root.lastError   = "Stash + pull failed. Try manually: git pull origin main"
            }
        }
    }

    // ── Public API ─────────────────────────────────────────────────────────

    function check() {
        if (root.checking || root.updating) return
        root.checking        = true
        root.lastError       = ""
        root.updateAvailable = false
        root.updateSuccess   = false
        root.hasConflict     = false
        _fetchProc.running   = false
        _fetchProc.running   = true
    }

    function applyUpdate() {
        if (root.updating) return
        root.updating        = true
        root.hasConflict     = false
        root.lastError       = ""
        root.updateSuccess   = false
        _pullProc.running    = false
        _pullProc.running    = true
    }

    function stashAndUpdate() {
        if (root.updating) return
        root.updating            = true
        root.hasConflict         = false
        root.lastError           = ""
        root.updateSuccess       = false
        _stashPullProc.running   = false
        _stashPullProc.running   = true
    }

    function dismiss() {
        root.updateAvailable = false
        root.hasConflict     = false
        root.lastError       = ""
        root.updateSuccess   = false
    }

    function disableAutoUpdate() {
        root.autoUpdate      = false
        root.updateAvailable = false
        root.hasConflict     = false
        root.lastError       = ""
        root.updateSuccess   = false
        root._startTimer.stop()
        _saveConfig()
    }

    Component.onCompleted: _initProc.running = true
}