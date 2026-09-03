import Quickshell
import QtQuick
import Quickshell.Io
import "./src/components"
import "./src/services"
import "./src/nexus"
import "./src/popups"
import "./src"

// ─────────────────────────────────────────────────────────────────────────────
// Generate the niri keybind file and prove niri itself accepts it.
//
//     quickshell -p tests/niri-keybinds-test.qml
//
// ── Why this has to exist ────────────────────────────────────────────────────
// The generator's output is only ever consumed by niri, and niri rejects a bad
// include WHOLESALE — one unknown action verb and the user loses every binding
// in the file, not just that line. So "it looks right" is not a test; the only
// test is `niri validate` on real output.
//
// ── It writes nothing the shell owns ─────────────────────────────────────────
// `_genKdl()` returns a string. This harness never calls save() or
// _writeFiles(), so nothing under the developer's ~/.config is touched. That is
// deliberate and load-bearing: an earlier suite in this repo reconfigured the
// live desktop it was running on.
// ─────────────────────────────────────────────────────────────────────────────

ShellRoot {
    id: root

    property int passed: 0
    property int failed: 0
    function check(name, cond) {
        if (cond) { root.passed++; console.log("  PASS  " + name) }
        else      { root.failed++; console.log("  FAIL  " + name) }
    }

    readonly property string outPath:
        Quickshell.env("XDG_RUNTIME_DIR") + "/apex-niri-keybinds-test.kdl"

    property string kdl: ""

    property Process _write: Process {
        command: []
        running: false
        onExited: function (code) { root.phase2() }
    }

    property Process _validate: Process {
        command: []
        running: false
        stdout: StdioCollector { id: vout }
        stderr: StdioCollector { id: verr }
        onExited: function (code) { root.phase3(code) }
    }

    // KeybindService loads its model from a FileView, so `keybinds` is empty at
    // Component.onCompleted and _genKdl() returns a binds block with nothing in
    // it. Waiting for the model is the difference between testing the generator
    // and testing an empty string — the first draft of this harness asserted
    // against that empty string and reported 7 failures that were its own fault.
    property Timer _wait: Timer {
        interval: 250
        repeat: true
        running: true
        property int tries: 0
        onTriggered: {
            tries++
            const n = Object.keys(KeybindService.keybinds || {}).length
            if (n > 0) { running = false; root.generate(n) }
            else if (tries > 40) {
                running = false
                console.log("  FAIL  KeybindService never loaded its model")
                console.log("passed=" + root.passed + " failed=" + (root.failed + 1))
                Qt.exit(1)
            }
        }
    }

    function generate(n) {
        check("KeybindService loaded its model (" + n + " bindings)", n > 20)
        root.kdl = KeybindService._genKdl()

        check("the generator produced a binds block", root.kdl.indexOf("binds {") >= 0)

        // The whole point of this branch: app launches now reach niri.
        check("the browser bind is emitted",
              root.kdl.indexOf("apex-open-browser") >= 0)
        check("the terminal bind is emitted",
              root.kdl.indexOf('spawn "alacritty"') >= 0)
        check("the file manager bind is emitted",
              root.kdl.indexOf('spawn "thunar"') >= 0)

        // No unresolved Hyprland variable may reach execvp as a filename.
        check("no unresolved config variable is emitted",
              root.kdl.indexOf('"$') < 0)

        // Native window actions, mapped onto niri's column model.
        check("close-window is emitted",   root.kdl.indexOf("close-window;") >= 0)
        check("column focus is emitted",   root.kdl.indexOf("focus-column-left;") >= 0)
        check("workspace focus carries its reference",
              /focus-workspace "\d+";/.test(root.kdl))

        // What niri genuinely cannot do is REPORTED, not silently dropped.
        check("untranslatable bindings are reported",
              root.kdl.indexOf("no niri equivalent of") >= 0)

        // Write it out for niri to read.
        root._write.command = ["bash", "-c",
            "printf '%s' \"$1\" > \"$2\"", "--", root.kdl, root.outPath]
        root._write.running = true
    }

    function phase2() {
        // `niri validate` parses a config; the generated file is an include
        // fragment, so wrap it in a minimal config that includes nothing else.
        root._validate.command = ["niri", "validate", "--config", root.outPath]
        root._validate.running = true
    }

    function phase3(code) {
        const err = (verr.text || "") + (vout.text || "")
        if (code === 0) {
            check("niri validate accepts the generated file", true)
        } else {
            check("niri validate accepts the generated file", false)
            console.log("      niri said: " + err.split("\n").slice(0, 6).join(" | "))
        }
        console.log("passed=" + root.passed + " failed=" + root.failed)
        Qt.exit(root.failed === 0 ? 0 : 1)
    }
}
