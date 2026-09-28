import QtQuick
import Quickshell
import Quickshell.Io
import "../"

// ─────────────────────────────────────────────────────────────────────────────
// LockCapture — the desktop as it was, for the lock screen's first frame.
//
// Andre, 2026-09-27: "make the transition to lock screen actually cleaner and
// sleek not just fading." The lock used to arrive by dropping every window in
// its first frame — the surface opened on the bare wallpaper and only then
// blurred it in. Now each lock surface opens on a picture of its output as it
// was, and that picture recedes into the lock (windows/Lockscreen.qml).
//
// The picture has to exist before the lock engages: once it has, the
// compositor shows nothing but the lock. LockState.lock() asks for it
// (captureRequested) and engages when captured() says every output is done, or
// after 120 ms regardless. Here, per output: grim writes it into the private
// runtime directory (0700, RAM), an Image decodes it into the shared pixmap
// cache — which is where the lock surface finds it, the same URL, without
// touching the file — and the file is removed as soon as it has decoded. It is
// never written anywhere else, never kept past the arrival (dropped a moment
// after the lock engages), and a picture that arrives after the lock has
// engaged is thrown away, not shown.
//
// Off (the lock arrives as before) under Reduce Motion or with motion off,
// where grim is missing, or with no runtime directory to put it in.
// ─────────────────────────────────────────────────────────────────────────────
Scope {
    id: root

    readonly property string runtime: Quickshell.env("XDG_RUNTIME_DIR") || ""
    readonly property string dir: root.runtime + "/rime-shell"

    property bool _grim: false
    property Process _probe: Process {
        running: true
        command: ["sh", "-c", "command -v grim >/dev/null 2>&1"]
        onExited: function (code) { root._grim = code === 0 }
    }
    // A shell that died mid-lock may have left one behind: none survives it.
    property Process _sweep: Process {
        running: root.runtime !== ""
        command: ["sh", "-c", 'rm -f -- "$1"/lockcap-*.ppm', "sh", root.dir]
    }

    Binding {
        target: LockState
        property: "captureEnabled"
        value: root._grim && root.runtime !== "" && !Motion.reduced && Motion.hero > 0
    }

    property int _seq: 0
    property int _pending: 0
    property var _shots: ({})

    Connections {
        target: LockState
        function onCaptureRequested(seq) {
            root._seq = seq
            root._shots = ({})
            const all = shooters.instances
            root._pending = all.length
            if (all.length === 0) { LockState.captured(seq, ({})); return }
            for (let i = 0; i < all.length; i++) all[i].shoot(seq)
        }
        // Engaged: the surfaces have taken their pictures from the cache by
        // now (they load them synchronously as they are built); let go of ours
        // once the arrival is over — each surface keeps its own for the unlock.
        // Unlocked: nothing is left either way.
        function onLockedChanged() {
            if (LockState.locked) root._dropAfter.restart()
            else root._dropAll()
        }
    }
    property Timer _dropAfter: Timer {
        interval: Math.max(1, Motion.hero) + 500
        repeat: false
        onTriggered: root._dropAll()
    }
    function _dropAll() {
        const all = shooters.instances
        for (let i = 0; i < all.length; i++) all[i].drop()
        // The surfaces that arrived hold their own copy (for the unlock, which
        // runs backwards over it); nothing built later in this lock — a
        // monitor plugged in while locked — may open on the desktop.
        LockState.captures = ({})
    }

    // One output's result for request `seq`: its image URL, or "" (failed).
    function _done(seq, name, url) {
        if (seq !== root._seq || root._pending <= 0) return
        if (url !== "") root._shots[name] = url
        root._pending -= 1
        if (root._pending === 0) LockState.captured(seq, root._shots)
    }

    Variants {
        id: shooters
        model: Quickshell.screens

        QtObject {
            id: sh
            required property var modelData
            readonly property string name: sh.modelData ? sh.modelData.name : ""
            property int seq: 0
            property string path: ""

            function shoot(seq) {
                sh.drop()
                sh.seq = seq
                sh.path = root.dir + "/lockcap-" + sh.name + "-" + seq + ".ppm"
                sh.grim.command = ["sh", "-c", 'umask 077 && mkdir -p -- "$1" && exec grim -o "$2" -t ppm "$3"',
                                   "sh", root.dir, sh.name, sh.path]
                sh.grim.running = true
            }
            function drop() {
                sh.grim.running = false
                sh.pre.source = ""
                sh.removeFile()
            }
            function removeFile() {
                if (sh.path === "") return
                sh.rm.command = ["rm", "-f", "--", sh.path]
                sh.rm.running = true
                sh.path = ""
            }

            property Process grim: Process {
                onExited: function (code) {
                    if (code === 0 && sh.path !== "") {
                        sh.pre.source = "file://" + sh.path
                    } else {
                        root._done(sh.seq, sh.name, "")
                        sh.removeFile()
                    }
                }
            }
            property Process rm: Process {}

            // Decoded into the pixmap cache the lock surface reads from. Same
            // URL, same (default) fill mode and size there: a different key
            // would miss the cache and look for the file this removes.
            property Image pre: Image {
                asynchronous: true
                cache: true
                onStatusChanged: {
                    if (status === Image.Ready) {
                        root._done(sh.seq, sh.name, String(source))
                        sh.removeFile()
                    } else if (status === Image.Error) {
                        root._done(sh.seq, sh.name, "")
                        sh.removeFile()
                    }
                }
            }
        }
    }
}
