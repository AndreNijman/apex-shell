import Quickshell
import QtQuick
import "./src/theme"
import "./src/services"
import "./src/services/agents"
import "./src/services/agentstate.js" as AgentState

// ─────────────────────────────────────────────────────────────────────────────
// What an agent card actually renders. Run via tests/run-agent-state-render-test.sh.
//
// tests/agent-state-test.js does the arithmetic over the source. This does the
// other half: it builds the REAL StateBadge and the REAL SessionRow against a
// live Theme and reads back the colours Qt resolved, so the things only the
// engine can answer get answered.
//
// Three of those, and each has been wrong at some point in this file's history:
//
//   1. Does Theme[token] resolve at all? agentstate.js hands out a token NAME
//      and StateBadge looks it up with [], so a token that exists on Colors and
//      not on Theme, or a typo in the table, produces `undefined` — which QML
//      silently coerces to black. A grep cannot see that; an instantiated
//      badge can.
//
//   2. Does it RE-resolve when the palette moves? A [] lookup is only useful
//      here if the binding re-runs on a wallpaper change. The test drives that
//      directly: it writes a light palette into Colors, waits a frame, and
//      requires every badge to have moved to the light branch.
//
//   3. Does the page still collapse to white? That is the defect, stated as an
//      assertion over rendered output rather than over source: no state's
//      colour may be the palette's own foreground.
//
// It opens no window. ShellRoot with no PanelWindow and no FloatingWindow draws
// nothing, and the harness gives it a compositor of its own regardless.
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

    // apex-agent-core/src/protocol.rs, enum AgentState.
    readonly property var states: [
        "starting", "working", "waiting_for_user", "permission_request",
        "complete", "failed", "exited"
    ]
    // The five the roadmap requires to be told apart.
    readonly property var distinct: [
        "working", "waiting_for_user", "permission_request", "failed", "complete"
    ]

    // ── colour maths, the same WCAG 2.1 formula Colors.qml uses ──────────────
    function lin(v) {
        return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
    }
    function lum(c) {
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
    function contrast(a, b) {
        var ya = lum(a), yb = lum(b)
        return ya > yb ? (ya + 0.05) / (yb + 0.05) : (yb + 0.05) / (ya + 0.05)
    }
    function hex(c) { return String(c) }

    // A synthetic SessionInfo. The shapes are apexd's: exit_code and
    // exit_signal are null while a session is alive, and the shell's `live`
    // test is exactly that pair being null.
    function session(state) {
        var terminal = (state === "complete" || state === "failed" || state === "exited")
        return {
            id: 1,
            agent: "claude",
            state: state,
            cwd: "/home/test/project",
            project_name: "project",
            worktree: null,
            paused: false,
            started: 1000,
            last_activity: 1060,
            exit_code: terminal ? (state === "failed" ? 3 : 0) : null,
            exit_signal: null
        }
    }

    // ── the things under test ────────────────────────────────────────────────
    Item {
        id: stage
        width: 600
        height: 800

        Repeater {
            id: badges
            model: root.states
            delegate: StateBadge {
                required property string modelData
                sessionState: modelData
                size: 26
            }
        }

        Column {
            id: rows
            width: 560
            Repeater {
                id: sessionRows
                model: root.states
                delegate: SessionRow {
                    required property string modelData
                    width: rows.width
                    session: root.session(modelData)
                }
            }
        }
    }

    // Find a badge's chip and glyph without adding a test-only property to the
    // component. Identified by a property only that type has, so this survives
    // the children being reordered.
    function childOfType(item, marker) {
        for (var i = 0; i < item.children.length; i++)
            if (item.children[i].hasOwnProperty(marker))
                return item.children[i]
        return null
    }
    function chipOf(badge)  { return root.childOfType(badge, "radius") }
    function glyphOf(badge) { return root.childOfType(badge, "font") }

    function badgeFor(state) {
        for (var i = 0; i < badges.count; i++) {
            var b = badges.itemAt(i)
            if (b && b.sessionState === state) return b
        }
        return null
    }

    // ── the assertions, run once per palette ─────────────────────────────────
    function measure(label) {
        console.log("[" + label + "] background=" + root.hex(Theme.background)
                    + " text=" + root.hex(Theme.text)
                    + " subtext=" + root.hex(Theme.subtext)
                    + " darkSurface=" + Theme.darkSurface)

        // The card a row actually paints, so contrast is measured against the
        // ground the badge sits on rather than against the page behind it.
        var card  = Qt.rgba(Theme.background.r * 0.97 + Theme.text.r * 0.03,
                            Theme.background.g * 0.97 + Theme.text.g * 0.03,
                            Theme.background.b * 0.97 + Theme.text.b * 0.03, 1)
        var hover = Qt.rgba(Theme.background.r * 0.93 + Theme.text.r * 0.07,
                            Theme.background.g * 0.93 + Theme.text.g * 0.07,
                            Theme.background.b * 0.93 + Theme.text.b * 0.07, 1)

        var tones = {}
        var resolved = true
        for (var i = 0; i < root.states.length; i++) {
            var s = root.states[i]
            var b = root.badgeFor(s)
            if (!b) { resolved = false; continue }
            tones[s] = root.hex(b.toneColor)
            // A token that does not exist on Theme comes back undefined and QML
            // coerces it to #000000. Nothing in the palette is pure black, so
            // this is a reliable tell.
            if (tones[s] === "#000000") resolved = false
            console.log("    " + s + "  tone=" + b.tone
                        + "  colour=" + tones[s]
                        + "  weight=" + b.weight
                        + "  contrast(card)=" + root.contrast(b.toneColor, card).toFixed(2))
        }
        root.check(label + ": every state resolved a real colour through Theme[token]",
                   resolved, JSON.stringify(tones))

        // 1. the five are five
        var seen = {}, dupes = []
        for (var d = 0; d < root.distinct.length; d++) {
            var c = tones[root.distinct[d]]
            if (seen[c]) dupes.push(seen[c] + " and " + root.distinct[d] + " are both " + c)
            seen[c] = root.distinct[d]
        }
        root.check(label + ": the five states render five different colours",
                   dupes.length === 0, dupes.join("; "))

        // 2. the defect. Four of seven used to be Theme.text or Theme.subtext.
        var collapsed = []
        for (var e = 0; e < root.distinct.length; e++) {
            var st = root.distinct[e]
            if (tones[st] === root.hex(Theme.text)) collapsed.push(st + "=text")
            if (tones[st] === root.hex(Theme.subtext)) collapsed.push(st + "=subtext")
        }
        root.check(label + ": no state renders as the palette's own foreground",
                   collapsed.length === 0, collapsed.join(", "))

        // 3. contrast on the ground it is drawn on, hovered included
        var worst = 99, worstAt = ""
        for (var f = 0; f < root.states.length; f++) {
            var t = root.badgeFor(root.states[f]).toneColor
            var r1 = root.contrast(t, card), r2 = root.contrast(t, hover)
            if (r1 < worst) { worst = r1; worstAt = root.states[f] + " on card" }
            if (r2 < worst) { worst = r2; worstAt = root.states[f] + " on hover" }
        }
        root.check(label + ": every state clears 4.5:1 on the card and hovered ("
                   + worst.toFixed(2) + ":1 worst, " + worstAt + ")",
                   worst >= 4.5)

        // 4. the glyph on a filled badge
        var worstFill = 99, worstFillAt = ""
        for (var g = 0; g < root.states.length; g++) {
            var bg = root.badgeFor(root.states[g])
            if (bg.weight !== "solid") continue
            var glyph = root.glyphOf(bg)
            var chip = root.chipOf(bg)
            var r = root.contrast(glyph.color, chip.color)
            if (r < worstFill) { worstFill = r; worstFillAt = root.states[g] }
        }
        root.check(label + ": a filled badge's glyph reads on its fill ("
                   + worstFill.toFixed(2) + ":1 worst, " + worstFillAt + ")",
                   worstFill >= 4.5)

        return tones
    }

    property var darkTones: ({})

    Timer {
        interval: 900
        running: true
        repeat: false
        onTriggered: {
            // ── the weights, which are the non-hue channel ───────────────────
            var weights = {}
            for (var i = 0; i < root.states.length; i++) {
                var b = root.badgeFor(root.states[i])
                weights[root.states[i]] = b ? b.weight : "?"
            }
            root.check("blocked and failed are the only filled badges",
                       weights["permission_request"] === "solid"
                       && weights["failed"] === "solid"
                       && weights["working"] !== "solid"
                       && weights["waiting_for_user"] !== "solid"
                       && weights["complete"] !== "solid",
                       JSON.stringify(weights))
            root.check("complete and working are told apart by shape as well as colour",
                       weights["complete"] !== weights["working"])

            // A chip is drawn for the states that have one, and not for the
            // ones that do not — the weight has to reach the geometry, not just
            // the table.
            var solidChip = root.chipOf(root.badgeFor("failed"))
            var plainChip = root.chipOf(root.badgeFor("complete"))
            root.check("a solid badge paints its fill",
                       String(solidChip.color) === String(root.badgeFor("failed").toneColor))
            root.check("a plain badge paints no fill",
                       plainChip.color.a === 0, String(plainChip.color))

            // ── every row built, with real records ───────────────────────────
            var built = 0
            for (var r = 0; r < sessionRows.count; r++)
                if (sessionRows.itemAt(r)) built++
            root.check("a SessionRow builds for every runtime state",
                       built === root.states.length, built + " of " + root.states.length)

            // ── the dark palette, as shipped ─────────────────────────────────
            root.darkTones = root.measure("dark")

            // ── and now a light one ──────────────────────────────────────────
            // matugen's own light-scheme output for the default wallpaper. The
            // shell does not pass -m light today; the point is that the tokens
            // are already correct for the day it does, and that the lookup
            // re-resolves when a wallpaper change moves the palette.
            Colors.background = "#faf9fb"
            Colors.text       = "#1b1c1e"
            Colors.subtext    = "#44474d"
            Colors.active     = "#000613"
            lightPass.start()
        }
    }

    Timer {
        id: lightPass
        interval: 400
        repeat: false
        onTriggered: {
            root.check("a light surface is recognised as one",
                       Theme.darkSurface === false,
                       "darkSurface=" + Theme.darkSurface)

            var lightTones = root.measure("light")

            var moved = 0
            for (var i = 0; i < root.distinct.length; i++)
                if (lightTones[root.distinct[i]] !== root.darkTones[root.distinct[i]])
                    moved++
            root.check("every state colour re-resolved when the palette changed ("
                       + moved + " of " + root.distinct.length + ")",
                       moved === root.distinct.length)

            console.log("agent-state-render: passed=" + root.passed
                        + " failed=" + root.failed)
            Qt.exit(root.failed === 0 ? 0 : 1)
        }
    }
}
