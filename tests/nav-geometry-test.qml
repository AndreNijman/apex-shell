import Quickshell
import QtQuick
import "./src"
import "./src/theme"
import "./src/services"
import "./src/nexus"
import "./src/components"

// ─────────────────────────────────────────────────────────────────────────────
// The dashboard and settings navigation, measured. Run via
// tests/run-nav-geometry-test.sh.
//
// ── Why it reads laid-out geometry and not source ───────────────────────────
//
// "The buttons overlap" is a statement about where Qt put two rectangles, and
// nothing about the source of TabSwitcher.qml says where they end up. The pill
// behind a horizontal tab is sized from the width its own icon and label report
// AFTER the font engine has measured them at the current scale factor, and the
// rows of the vertical tab column are spaced by a subtraction that can come out
// negative. Both are numbers only the engine can produce. So this builds the
// REAL TabSwitcher against a live Theme, moves it through every width, height
// and scale factor the shell supports, and reads back the rectangles.
//
// ── Why it opens a window ───────────────────────────────────────────────────
//
// Reluctantly, and with a compositor of its own. A Row positions its children
// in a polish pass, and a polish pass is driven by a QQuickWindow: with no
// window every delegate keeps x = 0 and every measurement reads as a perfect
// stack of overlapping tabs. That is a false FAIL, which is as useless as a
// false PASS. The runner therefore starts a headless wlroots compositor in a
// private XDG_RUNTIME_DIR and refuses to run if WAYLAND_DISPLAY is not the
// socket it just created, which is a stronger guarantee than opening no window:
// there is no session here to draw on.
//
// ── What it asserts ─────────────────────────────────────────────────────────
//
//   horizontal — no two pills overlap, no pill leaves its own slot, no label
//                leaves its pill, the bar is tall enough for the text it holds,
//                and the click target is the whole slot rather than the pill
//   vertical   — no two rows overlap, rows stay inside the column, and a row
//                stays big enough to hit
//   width      — the dashboard fits the output it opens on, together with the
//                two notches it opens between, at every scale
// ─────────────────────────────────────────────────────────────────────────────

ShellRoot {
    id: root

    property int passed: 0
    property int failed: 0
    // Failures tallied by what was asserted rather than listed one per matrix
    // point: 312 points times a dozen assertions is a wall of output in which
    // the fourth distinct defect is invisible.
    property var kinds: ({})
    property var kindOrder: []

    function check(name, cond, detail) {
        if (cond) {
            root.passed++
            return
        }
        root.failed++
        const kind = name.indexOf(": ") >= 0
                   ? name.substring(name.indexOf(": ") + 2)
                   : name
        if (root.kinds[kind] === undefined) {
            root.kinds[kind] = { n: 0, first: name + "  [" + (detail || "") + "]" }
            root.kindOrder.push(kind)
        }
        root.kinds[kind].n++
        console.log("  FAIL  " + name + (detail ? "  [" + detail + "]" : ""))
    }

    function reportKinds() {
        if (root.kindOrder.length === 0)
            return
        console.log("")
        console.log("failures by assertion:")
        for (var i = 0; i < root.kindOrder.length; i++) {
            const k = root.kindOrder[i]
            console.log("  " + String(root.kinds[k].n) + "x  " + k)
            console.log("        e.g. " + root.kinds[k].first)
        }
    }

    // ── The matrix ───────────────────────────────────────────────────────────
    // 0.85 and 1.00 through 2.00 are the buckets Metrics.autoScale can produce
    // plus the percentages a user can dial in by hand: 100, 125, 150, 175, 200.
    readonly property var scales: [0.85, 1.00, 1.20, 1.25, 1.35, 1.50, 1.75, 2.00]

    // Every output APEX is asked to run on, including the developer's own two.
    readonly property var screens: [
        { w: 1280, h:  720, name: "720p"        },
        { w: 1920, h: 1080, name: "1080p"       },
        { w: 2560, h: 1440, name: "1440p"       },
        { w: 3840, h: 2160, name: "4K"          },
        { w: 2560, h: 1080, name: "DP-2 ultrawide" },
        { w: 1920, h: 1200, name: "eDP-1"       }
    ]

    // The dashboard height slider's two ends and its default.
    readonly property var dashHeights: [360, 520, 900]

    // ── Thresholds ───────────────────────────────────────────────────────────
    // A pointer target below about 24 logical pixels is a miss waiting to
    // happen, and a finger wants more. Scaled, because a "pixel" at scale 2 is
    // half the physical size of one at scale 1.
    function minTouch() { return Theme.px(24) }

    // ── Rig ──────────────────────────────────────────────────────────────────
    FloatingWindow {
        id: win
        title:          "apex-nav-geometry"
        visible:        true
        implicitWidth:  1500
        implicitHeight: 1000
        color:          "black"

        Item {
            id: hHost
            y: 0
            width:  884
            height: hSwitcher.implicitHeight
            TabSwitcher {
                id: hSwitcher
                anchors.fill: parent
                orientation:  "horizontal"
                currentPage:  "stats"
                model:        DashboardLayout.tabs
            }
        }

        Item {
            id: vHost
            y: 120
            width:  244
            height: 381
            TabSwitcher {
                id: vSwitcher
                anchors.fill: parent
                orientation:  "vertical"
                currentPage:  vSwitcher.model.length > 0 ? vSwitcher.model[0].key : ""
                model:        root.configTabs
            }
        }
    }

    // The real settings page set, so the count this measures is the count the
    // Config tab draws rather than a number copied into a test and left behind.
    readonly property var configTabs: {
        const out = []
        for (const p of PageRegistry.pages)
            out.push({ "key": p.id, "icon": p.icon, "label": p.title })
        return out
    }

    // ── Reading a switcher back ──────────────────────────────────────────────
    // The delegates are anonymous items inside a Row or a Column that the
    // component does not expose. Found by shape: the one child of the switcher
    // holding exactly as many laid-out children as there are model entries. The
    // Repeater sitting alongside them has no width and is skipped.
    function slotsOf(sw, n) {
        const kids = sw.children
        for (var i = 0; i < kids.length; i++) {
            const c = kids[i]
            if (!c.children || c.width <= 0)
                continue
            const live = []
            for (var j = 0; j < c.children.length; j++)
                if (c.children[j].width > 0 && c.children[j].height > 0)
                    live.push(c.children[j])
            if (live.length === n)
                return live
        }
        return []
    }

    // ── Horizontal ───────────────────────────────────────────────────────────
    function measureHorizontal(label, barWidth) {
        const n = DashboardLayout.tabs.length
        const s = root.slotsOf(hSwitcher, n)
        if (s.length !== n) {
            root.check(label + ": the bar laid out " + n + " tabs", false,
                       "found " + s.length)
            return
        }
        // A Row that has not re-polished leaves every child at x = 0 and reads
        // as a perfect overlap. Refuse to grade a stale layout.
        const last = s[n - 1]
        if (Math.abs(last.x + last.width - barWidth) > 1.5) {
            root.check(label + ": the layout had settled before it was read", false,
                       "last tab ends at " + (last.x + last.width).toFixed(1)
                       + ", bar is " + barWidth)
            return
        }

        var worstGap = 1e9, worstGapAt = ""
        var worstSpill = -1e9, worstSpillAt = ""
        var worstBleed = -1e9, worstBleedAt = ""
        var minTarget = 1e9
        var prevRight = -1e9

        for (var i = 0; i < n; i++) {
            const tab  = s[i]
            const pill = tab.children[0]
            // The pill is centred in its slot; its content is centred in the pill.
            const pl = tab.x + (tab.width - pill.width) / 2
            const pr = pl + pill.width

            if (i > 0 && pl - prevRight < worstGap) {
                worstGap = pl - prevRight
                worstGapAt = DashboardLayout.tabs[i].label
            }
            prevRight = pr

            // A pill wider than the slot it is centred in is the overlap, stated
            // without reference to its neighbour.
            const spill = pill.width - tab.width
            if (spill > worstSpill) {
                worstSpill = spill
                worstSpillAt = DashboardLayout.tabs[i].label
            }

            // Icon and label are drawn from a Row inside the tab; the MouseArea
            // over it is a childless Item of the same width, so the Row is
            // identified by having children of its own. Nothing that is drawn
            // may be wider than the pill drawn behind it.
            var content = null
            for (var k = 0; k < tab.children.length; k++) {
                const c = tab.children[k]
                if (c !== pill && c.width > 0 && c.children && c.children.length > 0)
                    content = c
            }
            if (content) {
                const bleed = content.width - pill.width
                if (bleed > worstBleed) {
                    worstBleed = bleed
                    worstBleedAt = DashboardLayout.tabs[i].label
                }
            } else {
                root.check(label + ": " + DashboardLayout.tabs[i].label
                           + " draws an icon", false, "no content row found")
            }

            // The hit target is the slot, not the pill: a tab whose pill has
            // shrunk must still be clickable across its whole share of the bar.
            var hit = 0
            for (var m = 0; m < tab.children.length; m++)
                if (tab.children[m].width >= tab.width - 0.5
                        && tab.children[m].height >= tab.height - 0.5)
                    hit = Math.max(hit, tab.children[m].width)
            root.check(label + ": " + DashboardLayout.tabs[i].label
                       + "'s hit target is the whole slot", hit >= tab.width - 0.5,
                       "widest full-height child is " + hit.toFixed(1)
                       + " of " + tab.width.toFixed(1))

            minTarget = Math.min(minTarget, tab.width, tab.height)
        }

        root.check(label + ": no two tabs overlap", worstGap >= 0,
                   "closest pair " + worstGapAt + ", gap " + worstGap.toFixed(1) + "px")
        root.check(label + ": every pill stays inside its own slot", worstSpill <= 0,
                   worstSpillAt + " is " + worstSpill.toFixed(1) + "px wider than its slot")
        root.check(label + ": no label is drawn outside its pill", worstBleed <= 0.5,
                   worstBleedAt + " overhangs by " + worstBleed.toFixed(1) + "px")
        root.check(label + ": the click target stays hittable",
                   minTarget >= root.minTouch(),
                   "smallest target " + minTarget.toFixed(1)
                   + "px, floor " + root.minTouch() + "px")
    }

    // The bar has to be at least as tall as the text it holds, or the labels are
    // drawn over whichever page is underneath. Measured from the tallest Text in
    // the bar rather than from the font size, because line height is not the
    // pixel size.
    function measureHorizontalHeight(label) {
        const n = DashboardLayout.tabs.length
        const s = root.slotsOf(hSwitcher, n)
        if (s.length !== n)
            return
        var tallest = 0
        for (var i = 0; i < n; i++) {
            const tab = s[i]
            for (var k = 0; k < tab.children.length; k++) {
                const c = tab.children[k]
                if (!c.children)
                    continue
                for (var j = 0; j < c.children.length; j++)
                    if (c.children[j].visible)
                        tallest = Math.max(tallest, c.children[j].height)
            }
        }
        root.check(label + ": the bar is tall enough for its own text",
                   tallest > 0 && tallest <= hSwitcher.height,
                   "tallest label " + tallest.toFixed(1)
                   + "px in a " + hSwitcher.height + "px bar")
    }

    // ── Vertical ─────────────────────────────────────────────────────────────
    function measureVertical(label, columnHeight) {
        const n = root.configTabs.length
        const s = root.slotsOf(vSwitcher, n)
        if (s.length !== n) {
            root.check(label + ": the column laid out " + n + " rows", false,
                       "found " + s.length)
            return
        }

        var worstGap = 1e9, worstGapAt = ""
        var minRow = 1e9
        var prevBottom = -1e9
        var top = 1e9, bottom = -1e9

        for (var i = 0; i < n; i++) {
            const rowItem = s[i]
            const y = rowItem.mapToItem(vSwitcher, 0, 0).y
            if (i > 0 && y - prevBottom < worstGap) {
                worstGap = y - prevBottom
                worstGapAt = root.configTabs[i].label
            }
            prevBottom = y + rowItem.height
            top = Math.min(top, y)
            bottom = Math.max(bottom, y + rowItem.height)
            minRow = Math.min(minRow, rowItem.height)
        }

        root.check(label + ": no two rows overlap", worstGap >= 0,
                   "closest pair above " + worstGapAt
                   + ", gap " + worstGap.toFixed(1) + "px")
        root.check(label + ": the rows stay inside the column",
                   top >= -0.5 && bottom <= columnHeight + 0.5,
                   "rows span " + top.toFixed(1) + ".." + bottom.toFixed(1)
                   + " in a " + columnHeight + "px column")
        root.check(label + ": a row stays big enough to hit",
                   minRow >= root.minTouch(),
                   "shortest row " + minRow.toFixed(1)
                   + "px, floor " + root.minTouch() + "px")
    }

    // ── Width policy ─────────────────────────────────────────────────────────
    // The dashboard is a centred notch between two edge-anchored ones. It fits
    // when it does not reach either, at the widest those two are allowed to be.
    // windows/TopBar.qml clamps both to Theme.[lr]NotchMaxWidth and pads each by
    // one notch radius, which is what this reproduces.
    function sideRoom() {
        return Math.max(Theme.lNotchMaxWidth, Theme.rNotchMaxWidth)
               + Theme.notchRadius + Theme.spacing
    }

    function measureWidth(label, page, screenW) {
        const w   = DashboardLayout.widthFor(page, screenW)
        const box = w + 2 * Theme.notchRadius     // popups/Dashboard.qml sizer
        const room = screenW - 2 * root.sideRoom()

        root.check(label + ": the dashboard fits the output", box <= screenW,
                   "sizer " + box + "px on a " + screenW + "px output")
        root.check(label + ": the dashboard clears both notches", w <= room,
                   "wants " + w + "px, " + room + "px between the notches")

        // The bar inside it has to be able to hold six tabs. Asserted through
        // the same helper the window uses, so the two cannot drift.
        const bar = DashboardLayout.barWidthFor(page, screenW)
        root.check(label + ": the tab bar gets a usable width",
                   bar >= DashboardLayout.tabs.length * root.minTouch(),
                   "bar " + bar + "px for " + DashboardLayout.tabs.length
                   + " tabs, floor " + (DashboardLayout.tabs.length * root.minTouch()) + "px")
    }

    // The height ShellConfig hands its tab column, from the chrome between the
    // dashboard's outer edge and the column: the sizer's top flare and its 8px
    // content inset, the horizontal tab bar, the Row's 8px margins top and
    // bottom, the column's own 8px top and 6px bottom margins, and the
    // "Open in window" button with its 8px margin.
    function configNavHeight(dashHeight) {
        const content  = Theme.px(dashHeight)
                       - (Theme.notchRadius + DashboardLayout.contentInset)
                       - DashboardLayout.contentInset
        const pageArea = content - hSwitcher.implicitHeight
        return pageArea - 16 - 8 - 6 - Theme.px(30) - 8
    }

    // ── Driver ───────────────────────────────────────────────────────────────
    property var plan: []
    property int pi: -1
    property string origMode: ""
    property real origManual: 1.0

    function buildPlan() {
        const out = []
        for (var a = 0; a < root.scales.length; a++) {
            const sc = root.scales[a]
            for (var b = 0; b < root.screens.length; b++) {
                const scr = root.screens[b]
                for (var c = 0; c < DashboardLayout.tabs.length; c++)
                    out.push({ kind: "h", scale: sc, screen: scr,
                               page: DashboardLayout.tabs[c].key })
            }
            for (var d = 0; d < root.dashHeights.length; d++)
                out.push({ kind: "v", scale: sc, dashHeight: root.dashHeights[d] })
        }
        return out
    }

    function stage(stepData) {
        SettingsService.set("scaleManual", stepData.scale)
        if (stepData.kind === "h") {
            hHost.width  = DashboardLayout.barWidthFor(stepData.page, stepData.screen.w)
            hHost.height = hSwitcher.implicitHeight
        } else {
            vHost.height = root.configNavHeight(stepData.dashHeight)
            vHost.width  = Math.round(
                (DashboardLayout.barWidthFor("config", 1920) - 12) * 0.30)
        }
    }

    function grade(stepData) {
        if (stepData.kind === "h") {
            const tag = "h " + stepData.scale + "x " + stepData.screen.name
                      + " " + stepData.page
            root.measureWidth(tag, stepData.page, stepData.screen.w)
            root.measureHorizontal(tag + " bar=" + hHost.width, hHost.width)
            root.measureHorizontalHeight(tag)
        } else {
            const vtag = "v " + stepData.scale + "x dashHeight=" + stepData.dashHeight
            root.measureVertical(vtag + " col=" + vHost.height, vHost.height)
        }
    }

    Timer {
        id: step
        interval: 90
        repeat: false
        onTriggered: {
            if (root.pi >= 0)
                root.grade(root.plan[root.pi])
            root.pi++
            if (root.pi >= root.plan.length) {
                SettingsService.set("scaleManual", root.origManual)
                SettingsService.set("scaleMode", root.origMode)
                root.reportKinds()
                console.log("")
                console.log("nav-geometry: passed=" + root.passed
                            + " failed=" + root.failed)
                Qt.exit(root.failed === 0 ? 0 : 1)
                return
            }
            root.stage(root.plan[root.pi])
            step.restart()
        }
    }

    Timer {
        interval: 1200
        running:  true
        onTriggered: {
            root.origMode   = SettingsService.scaleMode
            root.origManual = SettingsService.scaleManual
            root.plan = root.buildPlan()
            console.log("[rig] settings home " + Quickshell.env("HOME"))
            console.log("[rig] " + DashboardLayout.tabs.length + " dashboard tabs, "
                        + root.configTabs.length + " settings pages, "
                        + root.plan.length + " matrix points")
            SettingsService.set("scaleMode", "manual")
            step.restart()
        }
    }
}
