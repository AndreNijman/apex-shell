import Quickshell
import Quickshell.Io
import QtQuick
import "./src/components"
import "./src/services"
import "./src/nexus"
import "./src/popups"
import "./src"

// ─────────────────────────────────────────────────────────────────────────────
// Drive the real KeybindService generator, twice, and say when each write has
// landed. Run by tests/run-hypr-configerrors-test.sh.
//
// The point is that the Lua going into `hyprctl configerrors` is produced by
// the shipped generator against the shipped defaults, not by a fixture that
// agrees with it until one of them is edited.
//
// Two writes, because the criterion is "clean after a generated CHANGE": the
// first is what a fresh login produces, the second is what pressing Save on the
// Keybinds page produces, and only the second exercises the disable-then-rebind
// path that a rebound combo takes.
// ─────────────────────────────────────────────────────────────────────────────

ShellRoot {
    id: root

    readonly property string luaPath:
        Quickshell.env("HOME") + "/.config/hypr/apex/shell-keybinds.lua"

    // Waits for the generator's own Process to have flushed, rather than
    // guessing at a delay: the write is a detached bash, so "the function
    // returned" and "the file is on disk" are different moments.
    property var _wait: Process {
        command: ["bash", "-c",
                  'for _ in $(seq 1 100); do [ -s "$1" ] && exit 0; sleep 0.1; done; exit 1',
                  "--", root.luaPath]
        running: false
        onExited: function (code) {
            if (code !== 0) {
                console.log("GEN-FAILED " + root.luaPath)
                Qt.callLater(Qt.quit)
                return
            }
            if (root._phase === 1) {
                console.log("GEN1-READY")
                root._phase = 2
                root._rebind.start()
            } else {
                console.log("GEN2-READY")
                root._done.start()
            }
        }
    }

    property int _phase: 1

    // A real rebind through the public path the Keybinds page uses: SUPER+T is
    // an APEX default, so moving it makes the generator emit a claim() for the
    // old combo and a bind for the new one.
    property var _rebind: Timer {
        interval: 500
        repeat: false
        onTriggered: {
            KeybindService.applyEdits({ "app-terminal": { mods: "SUPER + SHIFT", key: "T" } })
            root._wait.running = false
            root._wait.running = true
        }
    }

    property var _done: Timer {
        interval: 1500
        repeat: false
        onTriggered: { console.log("GEN-DONE"); Qt.quit() }
    }

    Component.onCompleted: {
        // Touching the singleton constructs it, which reads keybinds.json and
        // writes both artifacts. Nothing else here has to happen for phase 1.
        console.log("GEN-START binds=" + Object.keys(KeybindService.keybinds).length)
        _wait.running = true
    }
}
