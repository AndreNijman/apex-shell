import Quickshell
import QtQuick

// ─────────────────────────────────────────────────────────────────────────────
// terminal-entry-test.qml — what actually happens when the shell launches a
// desktop entry that says `Terminal=true`.
//
// Driven by tests/run-terminal-entry-test.sh, which stages the fixture entries,
// the recorder they exec and the terminal stub, then grades the sentinels this
// leaves behind. Nothing here asserts; it launches and reports. Grading a file
// that a detached process writes some milliseconds later belongs in the runner,
// which can wait for it.
//
// Three launches, in order, each into its own sentinel:
//
//   raw    — DesktopEntry.execute() on a Terminal=true entry, called exactly the
//            way src/services/AppLauncher.qml used to call it. This measures
//            Quickshell, not APEX, and it is the reason the rest exists.
//   termed — the same entry through the shell's own launch path.
//   plain  — a Terminal=false entry through the shell's own launch path, which
//            must NOT acquire a terminal. A "fix" that wrapped everything would
//            pass the middle case and be wrong.
//
// The QML never imports src/. It is launched with the shell's services on the
// import path when they exist and without them when they do not, so the raw
// measurement can be taken against a tree that has no routing in it yet.
// ─────────────────────────────────────────────────────────────────────────────

ShellRoot {
    id: root

    property int phase: 0
    property string routeVia: Quickshell.env("APEX_PROBE_ROUTE") || "raw"

    function report(k, v) {
        console.log("PROBE " + k + "=" + v)
    }

    function describe(tag, e) {
        if (!e) {
            root.report(tag + ".found", "0")
            return
        }
        root.report(tag + ".found", "1")
        root.report(tag + ".id", e.id)
        root.report(tag + ".runInTerminal", e.runInTerminal ? "1" : "0")
        root.report(tag + ".execString", e.execString)
        root.report(tag + ".command", JSON.stringify(e.command))
        root.report(tag + ".workingDirectory", e.workingDirectory)
    }

    // DesktopEntries is NOT populated at Component.onCompleted, and the first
    // lookup is what primes the scan. The first version of this probe reported
    // `term.found=0` from onCompleted and then launched that same entry
    // successfully one tick later; moving the read into the timer without
    // keeping the priming read made the launch fail instead. Both symptoms are
    // the same lazy scan. So: prime here, and below, WAIT for the fixtures
    // rather than assume a fixed number of ticks is enough.
    Component.onCompleted: {
        root.report("route", root.routeVia)
        DesktopEntries.byId("apex-probe-term")
        root.report("primed.count", DesktopEntries.applications.values.length)
        step.start()
    }

    property int waited: 0

    // One launch per tick, so a sentinel that appears can only have come from
    // the launch that was running when it did.
    Timer {
        id: step
        interval: 400
        repeat: true
        running: false
        onTriggered: {
            const t = DesktopEntries.byId("apex-probe-term")
            const p = DesktopEntries.byId("apex-probe-plain")

            if (root.phase === 0) {
                if (!t || !p) {
                    root.waited += 1
                    if (root.waited < 25)
                        return
                    root.report("fixtures.timedout", "1")
                }
                root.describe("term", t)
                root.describe("plain", p)
                root.phase = 1
                return
            }

            root.phase += 1
            if (root.phase === 2) {
                // The raw call, made exactly the way AppLauncher.qml made it.
                // Taken on every tree, because the routing decision rests on
                // this one returning "no terminal".
                if (t) {
                    root.report("raw.launched", "1")
                    t.execute()
                } else {
                    root.report("raw.launched", "0")
                }
            } else if (root.phase === 3) {
                if (root.routeVia === "shell" && t) {
                    root.report("termed.launched", "1")
                    root.shellLaunch(t)
                } else {
                    root.report("termed.launched", "0")
                }
            } else if (root.phase === 4) {
                if (root.routeVia === "shell" && p) {
                    root.report("plain.launched", "1")
                    root.shellLaunch(p)
                } else {
                    root.report("plain.launched", "0")
                }
            } else if (root.phase >= 9) {
                step.stop()
                console.log("PROBE done=1")
                Qt.quit()
            }
        }
    }

    // Resolved lazily so this file loads on a tree that has no DesktopExec yet.
    // `createQmlObject` against the services directory is how the probe reaches
    // a singleton it must not import at the top of the file.
    property var _exec: null
    function shellLaunch(e) {
        if (!root._exec) {
            try {
                root._exec = Qt.createQmlObject(
                    'import QtQuick; import "./src/services"; '
                    + 'QtObject { function go(e) { DesktopExec.launch(e) } }',
                    root, "probe-exec")
            } catch (err) {
                root.report("shellLaunch.error", String(err))
                return
            }
        }
        root._exec.go(e)
    }
}
