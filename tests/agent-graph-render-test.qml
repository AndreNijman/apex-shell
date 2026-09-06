import Quickshell
import QtQuick
import "./src/theme"
import "./src/services"
import "./src/services/agents"
import "./src/services/agentgraph.js" as Graph
import "./src/services/agenttelemetry.js" as Telemetry

// ─────────────────────────────────────────────────────────────────────────────
// The session graph as Qt builds it. Run via tests/run-agent-graph-render-test.sh.
//
// tests/agentgraph-test.js proves what agentgraph.js DECIDES, over records the
// runtime writes. This proves the other half — the part a node process cannot
// see, because it is a question about the engine:
//
//   1. Does SubagentRow resolve as a type at all? The Agent Center is loaded
//      THROUGH src/services/qmldir, so its directory is not on the import path
//      and a component that is not registered there is invisible to the rows
//      that use it. The failure is not a missing subagent list; it is the
//      whole shell failing to load. A grep over the source cannot tell you
//      that, and an instantiated row can.
//
//   2. Does the card GROW when it is expanded, and shrink back? The row used
//      to be a fixed 52px with `anchors.fill: parent` inside it. A child list
//      added under that would be drawn outside the card, over the next
//      session's row.
//
//   3. Is the child list outside the tap target? The whole card focuses the
//      session's terminal, and a subagent row inside that handler would make
//      every click on the detail do something the reader did not ask for. The
//      test measures the geometry rather than trusting the nesting.
//
//   4. Does a row whose runtime has NO graph offer an expander? A daemon that
//      predates P1-020 writes no `children` key, and every daemon in the
//      shipped image is one of those. A control that is there and does nothing
//      is worse than no control.
//
//   5. And the same two questions for P1-021's telemetry: does the row make
//      room for its third line only when a status line has actually run, and
//      does TelemetryStrip resolve as a type and stay away when nothing has
//      reported a rate-limit window?
//
// It opens ONE window, and that is not carelessness. A Column lays its
// children out in a polish pass, a polish pass is driven by a QQuickWindow,
// and without one the child list keeps height 0 — the run then reports that
// expanding does not grow the card, which is a fact about the test rather than
// about the row. tests/nav-geometry-test.qml opens one for the same reason.
//
// It is a FloatingWindow, never a PanelWindow, inside the private headless
// compositor the harness starts: WAYLAND_DISPLAY and DISPLAY are unset and
// XDG_RUNTIME_DIR is a fresh directory, so there is no session for it to reach
// even if something went wrong.
// ─────────────────────────────────────────────────────────────────────────────

ShellRoot {
    id: root

    property int passed: 0
    property int failed: 0

    function check(name, cond, detail) {
        if (cond) {
            root.passed++
            console.log("  PASS  " + name)
        } else {
            root.failed++
            console.log("  FAIL  " + name + (detail ? "  [" + detail + "]" : ""))
        }
    }

    readonly property real now: Date.now() / 1000

    function sub(id, label, started, ended, endedBy) {
        return {
            id: id, kind: "subagent", label: label, started: started,
            ended: ended === undefined ? null : ended,
            ended_by: endedBy === undefined ? null : endedBy,
            parent: null, pid: null, rss_kb: null
        }
    }
    function proc(pid, label, parent, rssKb) {
        return {
            id: "pid:" + pid, kind: "process", label: label,
            started: root.now - 200, ended: null, ended_by: null,
            parent: parent === undefined ? null : parent,
            pid: pid, rss_kb: rssKb
        }
    }

    // apexd's own shape. `children` is ABSENT on the first one on purpose:
    // that is what a daemon which predates the graph writes, and telling it
    // apart from an empty list is the whole point of the field.
    function bare() {
        return {
            id: 1, agent: "claude", program: "claude", args: [],
            cwd: "/home/test/project", project_name: "project", worktree: null,
            state: "working", detail: null, paused: false, sandbox: "project",
            pid: 1000, started: root.now - 600, last_activity: root.now - 3,
            exit_code: null, exit_signal: null, attached: 0
        }
    }
    function withGraph() {
        var s = root.bare()
        s.id = 2
        s.pid = 2000
        s.program = "/usr/bin/claude"
        s.children = [
            root.sub("agent-a", "Explore", root.now - 300, root.now - 100, "reported"),
            root.sub("agent-b", "Plan", root.now - 90),
            // A confined session: the pid is bwrap, so the agent's own binary
            // is a CHILD and the MCP server is a grandchild.
            root.proc(2001, "claude", null, 400000),
            root.proc(2002, "node", "pid:2001", 80000)
        ]
        return s
    }
    function emptyGraph() {
        var s = root.bare()
        s.id = 3
        s.children = []
        return s
    }
    // P1-021. A session whose status line has run: model, context and branch
    // per row, and the account windows that TelemetryStrip says once.
    function withTelemetry() {
        var s = root.bare()
        s.id = 4
        s.children = []
        s.telemetry = {
            model: "Opus 4.5", context_pct: 88.2, branch: "task/p1-021",
            five_hour_pct: 62.5, five_hour_reset: root.now + 7900,
            seven_day_pct: 18.5, seven_day_reset: root.now + 299900,
            observed_at: root.now - 20
        }
        return s
    }

    FloatingWindow {
        id: stage
        width: 640
        height: 600
        visible: true

        Column {
            id: rows
            width: 600
            SessionRow {
                id: bareRow
                width: rows.width
                session: root.bare()
            }
            SessionRow {
                id: graphRow
                width: rows.width
                session: root.withGraph()
            }
            SessionRow {
                id: emptyRow
                width: rows.width
                session: root.emptyGraph()
            }
            SessionRow {
                id: telemetryRow
                width: rows.width
                session: root.withTelemetry()
            }
        }

        TelemetryStrip { id: strip; width: 600; y: 520 }
    }

    // The child list, found by a property only it has rather than by index, so
    // this survives the card's children being reordered.
    function blockOf(row) {
        for (var i = 0; i < row.children.length; i++) {
            var c = row.children[i]
            if (c.hasOwnProperty("spacing") && c.hasOwnProperty("visible")
                && !c.hasOwnProperty("radius"))
                return c
        }
        return null
    }

    Component.onCompleted: measure.start()

    // How tall the card is with nothing expanded, captured before anything is
    // clicked so the growth below is measured against it rather than against a
    // number written down here. `Theme.px` scales, so 52 is not 52.
    property real collapsedHeight: 0

    // A positioner updates its geometry on the next polish, not on assignment,
    // so every measurement that follows a change waits a frame. Reading the
    // height straight after `expanded = true` reports the old one and the test
    // fails for a reason that has nothing to do with the code under test.
    function delegates(block) {
        var n = 0
        for (var i = 0; i < block.children.length; i++)
            if (block.children[i].hasOwnProperty("subtreeCount")) n++
        return n
    }

    Timer {
        id: measure
        interval: 60
        onTriggered: {
            console.log("agent-graph-render: theme background=" + Theme.background)

            // 1. The types resolved. A SubagentRow that is not registered in
            //    src/services/qmldir makes the whole shell fail to load, so
            //    reaching this line at all is half the assertion; the other
            //    half is that the delegates exist.
            root.check("SessionRow and SubagentRow both instantiated",
                       bareRow !== null && graphRow !== null)

            // 2. The runtime's three answers, as the row sees them.
            root.check("a record with no children key reports no graph",
                       bareRow.graphState === "unknown" && !bareRow.hasGraph,
                       bareRow.graphState)
            root.check("an empty children array is not the same answer",
                       emptyRow.graphState === "none" && !emptyRow.hasGraph,
                       emptyRow.graphState)
            root.check("a populated one has a graph",
                       graphRow.graphState === "some" && graphRow.hasGraph,
                       graphRow.graphState)

            // 3. The meta line says it without being expanded.
            root.check("the row states what it started before anything is clicked",
                       Graph.summary(graphRow.session, root.now).indexOf("subagent") >= 0,
                       Graph.summary(graphRow.session, root.now))
            root.check("and says nothing at all when the runtime cannot tell",
                       Graph.summary(bareRow.session, root.now) === "")

            // 4. Collapsed, the card is the row it always was.
            root.collapsedHeight = graphRow.height
            root.check("a collapsed row is the same height as one with no graph",
                       Math.abs(root.collapsedHeight - bareRow.height) < 0.5,
                       root.collapsedHeight + " vs " + bareRow.height)

            graphRow.expanded = true
            afterExpand.start()
        }
    }

    Timer {
        id: afterExpand
        interval: 60
        onTriggered: {
            var block = root.blockOf(graphRow)

            // 5. Expanding grows the CARD, not just the contents. The row was a
            //    fixed height with `anchors.fill` inside it, and a child list
            //    added under that draws over the next session's row.
            root.check("the child list exists once expanded", block !== null)
            root.check("expanding makes the card taller",
                       graphRow.height > root.collapsedHeight + 10,
                       root.collapsedHeight + " -> " + graphRow.height)

            // 6. Two subagents and one process root — the agent's own `claude`
            //    process is lifted out of the way, so `node` is what is drawn.
            root.check("every child got a row",
                       block !== null && root.delegates(block) === 3,
                       block ? String(root.delegates(block)) : "no block")
            root.check("the agent is not drawn underneath itself",
                       graphRow.graphRoots.length === 1
                       && graphRow.graphRoots[0].label === "node",
                       JSON.stringify(graphRow.graphRoots.map(function(r) {
                           return r.label })))

            // 7. The child list is below the tap target. The card's TapHandler
            //    focuses the terminal, and a subagent row inside it would make
            //    reading the detail do something nobody asked for. Measured
            //    against the collapsed card, which IS the header.
            root.check("the child list starts below the clickable header",
                       block !== null && block.y >= root.collapsedHeight - 0.5,
                       block ? (block.y + " vs " + root.collapsedHeight) : "no block")

            graphRow.expanded = false
            afterCollapse.start()
        }
    }

    Timer {
        id: afterCollapse
        interval: 60
        onTriggered: {
            root.check("collapsing returns the card to its original height",
                       Math.abs(graphRow.height - root.collapsedHeight) < 0.5,
                       graphRow.height + " vs " + root.collapsedHeight)

            // ── P1-021 ──────────────────────────────────────────────────────
            root.check("a row with telemetry says the model, the context and the branch",
                       telemetryRow.telemetry !== null
                       && telemetryRow.telemetry.text.indexOf("Opus 4.5") >= 0
                       && telemetryRow.telemetry.text.indexOf("88% context") >= 0
                       && telemetryRow.telemetry.text.indexOf("task/p1-021") >= 0,
                       telemetryRow.telemetry
                           ? telemetryRow.telemetry.text : "no telemetry")
            root.check("and NO account-wide window",
                       telemetryRow.telemetry.text.indexOf("5h") < 0
                       && telemetryRow.telemetry.text.indexOf("7d") < 0,
                       telemetryRow.telemetry.text)
            root.check("a row that has never reported has no telemetry line",
                       bareRow.telemetry === null)
            root.check("the card makes room for the third line, and only then",
                       telemetryRow.height > bareRow.height + 4,
                       bareRow.height + " -> " + telemetryRow.height)

            // TelemetryStrip resolving at all is half the assertion: it is
            // reached through src/services/qmldir, and a component missing
            // from there fails the whole shell rather than the page.
            root.check("TelemetryStrip instantiated", strip !== null)
            root.check("the strip takes the fleet's reading from the freshest session",
                       Telemetry.fleet([root.withTelemetry()], root.now).fiveHour === 62.5)
            root.check("and stays away entirely when nobody has reported a window",
                       Telemetry.fleet([root.bare()], root.now) === null)
            console.log("agent-graph-render: passed=" + root.passed
                        + " failed=" + root.failed)
            Qt.exit(root.failed === 0 ? 0 : 1)
        }
    }
}
