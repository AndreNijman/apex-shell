import Quickshell
import Quickshell.Wayland
import QtQuick
import "./src/components"
import "./src/modules/Left"
import "./src/popups"
import "./src/services"
import "./src/windows"
import "./src"

// ─────────────────────────────────────────────────────────────────────────────
// The Floating/labwc session, measured under a real labwc (roadmap §21,
// P1-038). Run through tests/run-labwc-matrix-test.sh, which supplies the
// headless compositor, the private HOME and the filler toplevel.
//
// ── The failure shape this suite exists for ──────────────────────────────────
// Every labwc defect this shell has shipped looked identical from the outside:
// the thing draws perfectly and ignores every click. No error, no warning, no
// log line. A smoke test that opens each popup over IPC and greps for runtime
// errors exits zero over all of them, which is exactly what happened — three
// branches of fixes in August, each found by a person using the session.
//
// So the assertions here are geometric and they are read back off live objects.
// An input region is a rectangle; whether it lands on the thing it is supposed
// to cover is arithmetic, and arithmetic can be checked.
//
// ── What labwc is actually doing in this run ─────────────────────────────────
// Two of the four blocks below are compositor-independent arithmetic and would
// hold on any host: the mask geometry and the dock's capacity. They are run
// under labwc anyway because that is the session where getting them wrong is
// visible — Hyprland clamps an out-of-bounds input region leniently enough that
// enough of it still overlapped the buttons, which is why nobody noticed.
//
// The other two need this host and would be vacuous anywhere else: the bar mask
// and the dismiss surface both take a `Compositor.isLabwc` branch, and on any
// other compositor the assertions would pass over the arm they do not test.
// That is why identity is a hard precondition below and not a skip.
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

    function note(text) { console.log("        " + text) }

    // A window to anchor the popups to. FloatingWindow rather than the shell's
    // own bar: the popups only need an anchor rectangle, and a real TopBar is
    // built separately below where its own mask is the subject.
    FloatingWindow {
        id: host
        title:          "apex-labwc-matrix"
        visible:        true
        implicitWidth:  1280
        implicitHeight: 800
        color:          "black"
    }

    ArchMenu    { id: archMenu;  anchorWindow: host }
    AudioPopup  { id: audio;     anchorWindow: host }
    QuickControl{ id: quick;     anchorWindow: host }

    PopupDismiss {
        id: dismiss
        screenName: Quickshell.screens.length > 0 ? Quickshell.screens[0].name : ""
    }

    TopBar { id: bar }

    // The dock is measured at several widths, so it is built by a Repeater over
    // the budgets rather than mutated in place: a `Row` recomputes maxItems
    // from a binding, and reading it back after an assignment races the binding.
    property var dockBudgets: [0, 25, 27, 56, 200, 4000]
    Item {
        id: dockHost
        Repeater {
            id: docks
            model: root.dockBudgets
            AppDock {
                required property int index
                required property var modelData
                screenName: ""
                availableWidth: modelData
            }
        }
    }

    // ── Phase machine ────────────────────────────────────────────────────────
    // The ArchMenu sizer animates its width and height on a page change, so a
    // read taken immediately after the assignment measures a rectangle that is
    // still moving. Each page therefore gets its own settle window. Nothing
    // here is a fixed sleep standing in for a check: the assertion afterwards
    // is over the geometry, and a value still in flight fails it.
    property var archPages: []
    property int archIndex: -1

    Timer {
        id: phases
        interval: 900
        repeat: true
        running: false
        onTriggered: root._advance()
    }

    Component.onCompleted: {
        console.log("── The session under test ───────────────────────────────")

        // Hard precondition, not a skip. Two blocks below assert the labwc arm
        // of a `Compositor.isLabwc` branch; run anywhere else they would pass
        // over the other arm and report a green labwc suite that never saw
        // labwc. This suite has one host and says so.
        root.check("the shell detects labwc", Compositor.isLabwc,
                   "Compositor.name=" + Compositor.name)
        root.check("no other compositor's identity leaked in",
                   !Compositor.isHyprland && !Compositor.isNiri)
        root.check("an output is present to lay windows out on",
                   Quickshell.screens.length > 0)

        const keys = []
        for (const k in archMenu.pageHeights) keys.push(k)
        root.archPages = keys

        console.log("")
        console.log("── Popup input regions land inside their own surface ─────")
        root._advance()
        phases.running = true
    }

    // maskGeometry asserts the one property that decides whether a popup is
    // clickable at all: the input region is a rectangle inside the surface.
    //
    // Both edges matter. A region above the surface (the power menu's was at
    // y = -27 of a 284px window) loses the top of the menu; a region that runs
    // past the bottom loses the last rows, which is what AudioPopup and
    // QuickControl were doing on BOTH compositors without anyone noticing.
    function maskGeometry(label, proxy, w, h) {
        const detail = "x=" + proxy.x + " y=" + proxy.y
                     + " w=" + proxy.width + " h=" + proxy.height
                     + " surface=" + w + "x" + h
        root.check(label + ": the region starts inside the surface",
                   proxy.x >= 0 && proxy.y >= 0, detail)
        root.check(label + ": the region ends inside the surface",
                   proxy.x + proxy.width <= w && proxy.y + proxy.height <= h, detail)
        root.check(label + ": the region has area",
                   proxy.width > 0 && proxy.height > 0, detail)
        root.note(label + "  " + detail)
    }

    function _advance() {
        root.archIndex++

        if (root.archIndex < root.archPages.length) {
            const page = root.archPages[root.archIndex]
            if (root.archIndex > 0) {
                // Measure the page set on the PREVIOUS tick, now settled.
                const prev = root.archPages[root.archIndex - 1]
                root._measureArch(prev)
            }
            archMenu.page = page
            return
        }

        if (root.archIndex === root.archPages.length) {
            root._measureArch(root.archPages[root.archPages.length - 1])
            root._rest()
            phases.running = false
            console.log("")
            console.log("labwc-matrix: passed=" + root.passed + " failed=" + root.failed)
            Qt.callLater(function() { Qt.exit(root.failed === 0 ? 0 : 1) })
        }
    }

    function _measureArch(page) {
        root.maskGeometry("ArchMenu/" + page, archMenu.mask.item,
                          archMenu.implicitWidth, archMenu.implicitHeight)
        // The window is sized to the largest page, so no page can overflow it.
        // The power page overflowing a stats-sized window by 20px is what drove
        // the input region outside the surface in the first place.
        root.check("ArchMenu/" + page + ": the page fits the window it is drawn in",
                   archMenu.contentWidth + archMenu.fw <= archMenu.implicitWidth
                   && archMenu.contentHeight + archMenu.fh * 2 <= archMenu.implicitHeight,
                   "page=" + archMenu.contentWidth + "x" + archMenu.contentHeight
                   + " window=" + archMenu.implicitWidth + "x" + archMenu.implicitHeight)
    }

    function _rest() {
        root.maskGeometry("AudioPopup", audio.mask.item,
                          audio.implicitWidth, audio.implicitHeight)
        root.maskGeometry("QuickControl", quick.mask.item,
                          quick.implicitWidth, quick.implicitHeight)

        console.log("")
        console.log("── The dismiss surface must not eat the power menu ───────")

        // labwc stacks this Top-layer fullscreen surface above ArchMenu's
        // anchored popup, whichever is instantiated first, so its mask receives
        // every button press before the visible menu can. The bar renders, the
        // buttons highlight, and nothing happens when they are clicked.
        Popups.closeAll()
        Popups.archMenuOpen = true
        root.check("with the power menu open the dismiss surface is unmapped",
                   dismiss.visible === false,
                   "visible=" + dismiss.visible)

        Popups.archMenuOpen = false
        Popups.networkOpen = true
        root.check("with any other popup open it is mapped again",
                   dismiss.visible === true,
                   "visible=" + dismiss.visible)
        Popups.closeAll()
        root.check("with nothing open it is unmapped",
                   dismiss.visible === false,
                   "visible=" + dismiss.visible)

        console.log("")
        console.log("── The bar must not cover labwc's titlebars ──────────────")

        // labwc draws real server-side titlebars. A full-height input mask over
        // the whole width of the bar swallows their iconify, maximise and close
        // buttons wherever they sit under the transparent gaps between notches.
        const regions = bar.mask && bar.mask.regions ? bar.mask.regions : null
        if (!regions || regions.length < 4) {
            root.check("the bar's input mask is readable", false,
                       "regions=" + (regions ? regions.length : "none"))
        } else {
            root.check("the full-width strip is only the painted border",
                       regions[0].height === Theme.borderWidth,
                       "height=" + regions[0].height
                       + " borderWidth=" + Theme.borderWidth
                       + " barHeight=" + bar.implicitHeight)
            let notched = 0
            for (let i = 1; i < regions.length; i++)
                if (regions[i].width > 0) notched++
            root.check("each painted notch keeps its own full-height region",
                       notched === regions.length - 1,
                       "notch regions with width: " + notched
                       + " of " + (regions.length - 1))
            for (let i = 1; i < regions.length; i++) {
                root.check("notch region " + i + " ends inside the bar",
                           regions[i].x >= 0
                           && regions[i].x + regions[i].width <= bar.width
                           && regions[i].height <= bar.implicitHeight,
                           "x=" + regions[i].x + " w=" + regions[i].width
                           + " h=" + regions[i].height + " bar=" + bar.width)
            }
        }

        // The reserved strip has to be the whole bar height on labwc, or the
        // titlebar buttons of a maximised window start inside the right notch.
        root.check("the bar reserves its full height on labwc",
                   bar.exclusiveZone >= Theme.notchHeight,
                   "exclusiveZone=" + bar.exclusiveZone
                   + " notchHeight=" + Theme.notchHeight
                   + " exclusionGap=" + Theme.exclusionGap)

        console.log("")
        console.log("── The dock stays inside the notch it is drawn in ────────")

        // The dock lists foreign toplevels, and the list arrives over a Wayland
        // roundtrip rather than at construction — it is still empty when
        // Component.onCompleted runs. With none published its model is empty
        // and every assertion below is a loop that passes without testing
        // anything, so the filler the runner starts is a precondition here and
        // its absence is a failure, never a skip.
        const tops = ToplevelManager.toplevels ? ToplevelManager.toplevels.values.length : 0
        root.check("the compositor publishes a toplevel for the dock to list",
                   tops > 0, "toplevels=" + tops)
        root.note("toplevels visible to the dock: " + tops)

        // Every icon the dock paints has to be clickable, and the bar's input
        // mask stops at the notch shoulder — so capacity is a function of the
        // width left over, not a constant. A dock that paints six icons into a
        // notch with room for three has three that do nothing.
        let last = -1
        for (let i = 0; i < docks.count; i++) {
            const d = docks.itemAt(i)
            if (!d) {
                root.check("dock " + root.dockBudgets[i] + "px was built", false)
                continue
            }
            const budget = root.dockBudgets[i]
            const shown = d.visibleApplications.length
            const span = shown === 0 ? 0
                       : shown * 26 + (shown - 1) * d.spacing
            root.check("dock at " + budget + "px paints within its budget",
                       span <= budget,
                       "icons=" + shown + " span=" + span + " budget=" + budget)
            root.check("dock at " + budget + "px is capped at five",
                       d.maxItems <= 5, "maxItems=" + d.maxItems)
            root.check("dock at " + budget + "px never fits more than a wider notch",
                       last < 0 || d.maxItems >= last,
                       "maxItems=" + d.maxItems + " previous=" + last)
            last = d.maxItems
            root.note("budget " + budget + "px → maxItems " + d.maxItems
                      + ", painted " + shown)
        }

        const zero = docks.itemAt(0)
        if (zero) {
            root.check("a dock with no room paints nothing",
                       zero.visible === false && zero.visibleApplications.length === 0,
                       "visible=" + zero.visible)
        }
        const wide = docks.itemAt(docks.count - 1)
        if (wide) {
            // Non-vacuity: with a toplevel published and unlimited room the
            // dock must actually list something, or every assertion above held
            // over an empty model.
            root.check("a dock with room lists the running window",
                       wide.visibleApplications.length > 0,
                       "applications=" + wide.applications.length)
        }
    }
}
