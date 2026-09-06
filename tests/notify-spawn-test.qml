import Quickshell
import Quickshell.Io
import QtQuick

// ─────────────────────────────────────────────────────────────────────────────
// How many notifications can one Quickshell Process carry? (roadmap P1-022)
//
// Run via tests/run-notify-spawn-test.sh. It opens no window and raises no
// desktop notification.
//
// ── What is being settled ───────────────────────────────────────────────────
//
// AgentService routed every desktop notification through a single `Process`.
// It runs `notify-send --wait`, which does not exit until the notification is
// dismissed or acted on, so that one Process is occupied for as long as the
// notification sits unread — on the machine this was written on, one such
// process had been blocked for four hours and fifty minutes on "Claude is
// waiting for you".
//
// What happens to the notifications raised in the meantime is not in the type
// information. The qmltypes for Process document `command`, `running` and
// `exited` and say nothing about assigning either while it runs. So it is
// asked of the engine, and the answer is asserted here rather than remembered
// in somebody's comment.
//
// ── THE MEASURED ANSWER ─────────────────────────────────────────────────────
//
// A Process holds AT MOST ONE PENDING COMMAND, and a new assignment overwrites
// it. Two consequences, both of which this file pins down:
//
//   Same tick. Two notifications raised from one loop — which is what
//   `_noticeChanges` does when two agents changed state since the last poll —
//   and the FIRST never runs at all. It is replaced in the pending slot before
//   the event loop starts anything.
//
//   While one is blocked. The next command is queued and starts only when the
//   blocked one finally exits. A third assignment DESTROYS the queued second.
//   So of everything raised while a notification sits unread, exactly one
//   survives — the newest — and even that one waits for the user to dismiss
//   the notification that was blocking it.
//
// Put together: six agents needing attention while nobody is at the desk
// produce one notification. That is not a tidiness problem, it is the feature
// not working, and it is invisible — nothing is logged and nothing fails.
//
// ── Nothing here sends a notification ───────────────────────────────────────
//
// Every phase runs `sh -c` appending to a marker file. Standing up a
// notification daemon to count toasts would test the daemon, and running
// `notify-send` against a real session is precisely what this repository has a
// rule against. What is under test is Process.
//
// Each command writes a second line after its sleep, so the file records not
// only which commands ran but whether the blocked one was allowed to FINISH —
// which is what distinguishes "queued behind it" from "killed and replaced",
// and those are different defects with different fixes.
// ─────────────────────────────────────────────────────────────────────────────

ShellRoot {
    id: root

    readonly property string dir: Quickshell.env("APEX_NOTIFY_TEST_DIR") || "/tmp"

    property int passed: 0
    property int failed: 0

    function check(name, cond, detail) {
        if (cond) { root.passed++; console.log("  PASS  " + name) }
        else { root.failed++; console.log("  FAIL  " + name + (detail ? "  [" + detail + "]" : "")) }
    }

    // ── The three subjects ───────────────────────────────────────────────────
    // A: one Process, two commands assigned in the same tick.
    // B: one Process, two more assigned while the first is still running.
    // C: Quickshell.execDetached — the replacement — under B's exact timing.
    property var procA: Process { command: []; running: false }
    property var procB: Process { command: []; running: false }

    // blockAllReads, so text() is a synchronous read of what is on disk right
    // now. Without it the read returns before it has happened and every file
    // reads empty — which looks exactly like "no command ran", and an earlier
    // version of this test drew precisely that wrong conclusion with four
    // confident FAILs.
    property var viewA: FileView {
        path: root.dir + "/a.txt"; preload: false; blockAllReads: true; printErrors: false
    }
    property var viewB: FileView {
        path: root.dir + "/b.txt"; preload: false; blockAllReads: true; printErrors: false
    }
    property var viewC: FileView {
        path: root.dir + "/c.txt"; preload: false; blockAllReads: true; printErrors: false
    }

    // `tag` on entry, `tag-done` on exit. The pair is what tells a queued
    // command apart from one that killed what it replaced.
    function write(target, tag, sleepFor) {
        return ["sh", "-c",
                "printf '%s\\n' " + tag + " >> " + target
                + (sleepFor > 0
                   ? "; sleep " + sleepFor + "; printf '%s-done\\n' " + tag + " >> " + target
                   : "")]
    }

    function lines(view) {
        var t = ""
        try { t = view.text() } catch (e) { return [] }
        if (!t) return []
        return String(t).split("\n").filter(function(l) { return l.length > 0 })
    }

    Component.onCompleted: {
        console.log("── how many notifications one Process can carry ──")

        // A — same tick, the shape of two agents changing state in one poll.
        root.procA.command = root.write(root.dir + "/a.txt", "first", 3)
        root.procA.running = true
        root.procA.command = root.write(root.dir + "/a.txt", "second", 0)
        root.procA.running = true

        // B — the first is started and left running, standing in for a
        // `notify-send --wait` nobody has dismissed.
        root.procB.command = root.write(root.dir + "/b.txt", "first", 3)
        root.procB.running = true

        // C — the replacement, under B's timing exactly.
        Quickshell.execDetached(root.write(root.dir + "/c.txt", "first", 3))

        atOneSecond.start()
    }

    // A second in, which is longer than the poll interval this stands in for
    // and well short of the three-second sleep, so the first is genuinely
    // mid-run when the second arrives.
    property var atOneSecond: Timer {
        interval: 1000
        repeat: false
        onTriggered: {
            root.check("the first command is still running when the second arrives",
                       root.procB.running === true)
            root.procB.command = root.write(root.dir + "/b.txt", "second", 0)
            root.procB.running = true
            Quickshell.execDetached(root.write(root.dir + "/c.txt", "second", 0))
            atTwoSeconds.start()
        }
    }

    // A third, half a second later and still inside the first's sleep. This is
    // the assignment that shows the pending slot holds ONE command: it
    // overwrites the second, which then never runs at all.
    property var atTwoSeconds: Timer {
        interval: 500
        repeat: false
        onTriggered: {
            root.procB.command = root.write(root.dir + "/b.txt", "third", 0)
            root.procB.running = true
            Quickshell.execDetached(root.write(root.dir + "/c.txt", "third", 0))
            settle.start()
        }
    }

    // Long enough for the three-second sleep to finish and for anything queued
    // behind it to run. Without that margin a queued command would read as a
    // lost one, which is the opposite finding.
    property var settle: Timer {
        interval: 4000
        repeat: false
        onTriggered: {
            var a = root.lines(root.viewA)
            var b = root.lines(root.viewB)
            var c = root.lines(root.viewC)

            console.log("  same tick, one Process:      " + JSON.stringify(a))
            console.log("  while blocked, one Process:  " + JSON.stringify(b))
            console.log("  while blocked, execDetached: " + JSON.stringify(c))

            // The fixture has to have run at all. A build where nothing
            // executed reads as "the Process dropped everything", which is the
            // wrong conclusion drawn from an empty file — and an earlier
            // version of this test made exactly that mistake.
            root.check("the fixture ran (every phase produced at least one line)",
                       a.length >= 1 && b.length >= 1 && c.length >= 1,
                       JSON.stringify([a, b, c]))

            // ── A ────────────────────────────────────────────────────────────
            root.check("two commands in one tick run ONE of them",
                       a.length === 1, JSON.stringify(a))
            root.check("and it is the LAST — the first never started",
                       a[0] === "second", JSON.stringify(a))

            // ── B ────────────────────────────────────────────────────────────
            root.check("a blocked command is not killed by the ones behind it",
                       b.indexOf("first-done") !== -1, JSON.stringify(b))
            root.check("of two commands raised while it was blocked, only one ran",
                       b.filter(function(l) { return l === "second" || l === "third" })
                        .length === 1, JSON.stringify(b))
            root.check("and the one that ran is the newest — the middle one was destroyed",
                       b.indexOf("third") !== -1 && b.indexOf("second") === -1,
                       JSON.stringify(b))
            root.check("it did not run until the blocked one had finished",
                       b.indexOf("third") > b.indexOf("first-done"), JSON.stringify(b))

            // ── C ────────────────────────────────────────────────────────────
            root.check("execDetached loses none of the three",
                       c.indexOf("first") !== -1 && c.indexOf("second") !== -1
                       && c.indexOf("third") !== -1, JSON.stringify(c))
            root.check("and does not make them wait for the blocked one",
                       c.indexOf("third") < c.indexOf("first-done"), JSON.stringify(c))

            console.log("notify-spawn: passed=" + root.passed + " failed=" + root.failed)
            Qt.exit(root.failed === 0 ? 0 : 1)
        }
    }
}
