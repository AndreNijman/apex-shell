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

    // ── Which pairs are graded in full ───────────────────────────────────────
    // "Representative scaling", in the roadmap's words. A scale factor divides
    // an output into logical pixels, and past a point there are not enough of
    // them left to draw a desktop in: 1280x720 at 175% is 731x411, which is
    // smaller than the dashboard's own minimum at that scale. Grading a shell
    // against it measures nothing about the shell.
    //
    // 1024x600 is the floor — the smallest panel anyone still ships — so a pair
    // is representative when the output keeps at least that much logical space.
    // The pairs this excludes are still exercised below, on the assertions that
    // remain meaningful there: the layout must degrade, not collapse.
    function representative(scr, sc) {
        return sc <= Math.min(scr.w / 1024, scr.h / 600) + 1e-9
    }

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
    // The delegates are anonymous items inside a Row, or inside a Column inside
    // a Flickable's content item. The component exposes none of it, so they are
    // found by shape: the first container anywhere beneath the switcher holding
    // exactly as many laid-out children as there are model entries. The Repeater
    // alongside them has no size and is skipped.
    //
    // Searched to a depth rather than one level down, because a fix that moves
    // the delegates one nesting level must not quietly turn every assertion into
    // "found 0" — which is still a FAIL, but the wrong one.
    function slotsOf(item, n, depth) {
        if (!item || !item.children || depth < 0)
            return []
        const live = []
        for (var j = 0; j < item.children.length; j++) {
            const c = item.children[j]
            if (c.width > 0 && c.height > 0)
                live.push(c)
        }
        if (live.length === n && n > 0)
            return live
        for (var i = 0; i < item.children.length; i++) {
            const found = root.slotsOf(item.children[i], n, depth - 1)
            if (found.length === n)
                return found
        }
        return []
    }

    // The icon-and-label Row inside one tab: the first descendant that has
    // children and whose children carry text.
    function contentRowOf(item, depth) {
        if (!item || !item.children || depth < 0)
            return null
        for (var i = 0; i < item.children.length; i++) {
            const c = item.children[i]
            if (c.children && c.children.length > 0 && c.width > 0) {
                for (var j = 0; j < c.children.length; j++)
                    if (c.children[j].text !== undefined)
                        return c
            }
        }
        for (var k = 0; k < item.children.length; k++) {
            const f = root.contentRowOf(item.children[k], depth - 1)
            if (f)
                return f
        }
        return null
    }

    // A Flickable somewhere under the switcher, identified by the two
    // properties only a Flickable has. Null when the layout does not use one.
    function scrollerOf(item, depth) {
        if (!item || depth < 0)
            return null
        if (item.contentHeight !== undefined && item.boundsBehavior !== undefined)
            return item
        if (!item.children)
            return null
        for (var i = 0; i < item.children.length; i++) {
            const f = root.scrollerOf(item.children[i], depth - 1)
            if (f)
                return f
        }
        return null
    }

    // ── Horizontal ───────────────────────────────────────────────────────────
    function measureHorizontal(label, barWidth) {
        const n = DashboardLayout.tabs.length
        const s = root.slotsOf(hSwitcher, n, 4)
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

            // Icon and label are drawn from a Row. Found wherever it is —
            // beside the pill or inside it — as the first descendant holding
            // Text items. Nothing drawn may be wider than the pill behind it.
            const content = root.contentRowOf(tab, 3)
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
        const s = root.slotsOf(hSwitcher, n, 4)
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
        const s = root.slotsOf(vSwitcher, n, 4)
        if (s.length !== n) {
            root.check(label + ": the column laid out " + n + " rows", false,
                       "found " + s.length)
            return
        }

        var worstGap = 1e9, worstGapAt = ""
        var minRow = 1e9
        var prevBottom = -1e9
        var top = 1e9, bottom = -1e9
        var worstLabelBleed = -1e9, worstLabelAt = ""

        for (var i = 0; i < n; i++) {
            const rowItem = s[i]
            // Mapped rather than read from .y: once the rows live inside a
            // Flickable's content item, .y is relative to a thing that scrolls.
            const y = rowItem.mapToItem(vSwitcher, 0, 0).y
            if (i > 0 && y - prevBottom < worstGap) {
                worstGap = y - prevBottom
                worstGapAt = root.configTabs[i].label
            }
            prevBottom = y + rowItem.height
            top = Math.min(top, y)
            bottom = Math.max(bottom, y + rowItem.height)
            minRow = Math.min(minRow, rowItem.height)

            const content = root.contentRowOf(rowItem, 3)
            if (content) {
                const right = content.mapToItem(vSwitcher, 0, 0).x + content.width
                if (right - vSwitcher.width > worstLabelBleed) {
                    worstLabelBleed = right - vSwitcher.width
                    worstLabelAt = root.configTabs[i].label
                }
            }
        }

        // Rows that do not fit have to go somewhere. Scrolling is the deliberate
        // answer and overlapping is the defect, so the bound depends on which
        // one the component chose: a scroller's own content height when it is
        // scrolling, the column otherwise.
        const scroller = root.scrollerOf(vSwitcher, 3)
        const scrolling = scroller !== null && scroller.interactive
        const bound = scrolling ? scroller.contentHeight : columnHeight

        root.check(label + ": no two rows overlap", worstGap >= 0,
                   "closest pair above " + worstGapAt
                   + ", gap " + worstGap.toFixed(1) + "px")
        root.check(label + ": the rows stay inside what holds them",
                   top >= -0.5 && bottom <= bound + 0.5,
                   "rows span " + top.toFixed(1) + ".." + bottom.toFixed(1)
                   + " in " + (scrolling ? "a " + bound + "px scroller"
                                         : "a " + bound + "px column"))
        root.check(label + ": rows that overflow are reachable by scrolling",
                   bottom <= columnHeight + 0.5 || scrolling,
                   "rows reach " + bottom.toFixed(1) + " in a " + columnHeight
                   + "px column and nothing scrolls")
        root.check(label + ": a scrolling column clips what it hides",
                   !scrolling || scroller.clip,
                   "the scroller paints outside its viewport")
        root.check(label + ": a row stays big enough to hit",
                   minRow >= root.minTouch(),
                   "shortest row " + minRow.toFixed(1)
                   + "px, floor " + root.minTouch() + "px")
        root.check(label + ": no label is drawn outside the column",
                   worstLabelBleed <= 0.5,
                   worstLabelAt + " overhangs by " + worstLabelBleed.toFixed(1) + "px")
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

    // What has to hold even where the geometry is hopeless.
    function measureDegraded(label, page, screenW) {
        const w   = DashboardLayout.widthFor(page, screenW)
        const bar = DashboardLayout.barWidthFor(page, screenW)
        root.check(label + ": the dashboard keeps a positive width", w > 0,
                   "width " + w)
        root.check(label + ": the dashboard still fits the output", w <= screenW,
                   "width " + w + " on a " + screenW + "px output")
        root.check(label + ": the tab bar keeps a positive width", bar > 0,
                   "bar " + bar)

        const n = DashboardLayout.tabs.length
        const s = root.slotsOf(hSwitcher, n, 4)
        if (s.length !== n) {
            root.check(label + ": the bar still lays out " + n + " tabs", false,
                       "found " + s.length)
            return
        }
        var worstGap = 1e9
        var prevRight = -1e9
        for (var i = 0; i < n; i++) {
            const tab  = s[i]
            const pill = tab.children[0]
            const pl = tab.x + (tab.width - pill.width) / 2
            if (i > 0)
                worstGap = Math.min(worstGap, pl - prevRight)
            prevRight = pl + pill.width
        }
        root.check(label + ": no two tabs overlap even here", worstGap >= 0,
                   "closest gap " + worstGap.toFixed(1) + "px")
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
                const full = root.representative(scr, sc)
                for (var c = 0; c < DashboardLayout.tabs.length; c++)
                    out.push({ kind: full ? "h" : "stress", scale: sc, screen: scr,
                               page: DashboardLayout.tabs[c].key })
            }
            for (var d = 0; d < root.dashHeights.length; d++)
                out.push({ kind: "v", scale: sc, dashHeight: root.dashHeights[d] })
        }
        return out
    }

    function stage(stepData) {
        SettingsService.set("scaleManual", stepData.scale)
        if (stepData.kind === "h" || stepData.kind === "stress") {
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
        } else if (stepData.kind === "stress") {
            // A scale this output cannot carry. Not graded on fitting between
            // the notches or on the touch floor — neither is achievable, and
            // asserting them would only ever say "1280x720 is not a 4K panel".
            // Graded on degrading rather than collapsing: a width that is still
            // a width, six tabs, and no two of them on top of each other.
            const stag = "stress " + stepData.scale + "x " + stepData.screen.name
                       + " " + stepData.page
            root.measureDegraded(stag, stepData.page, stepData.screen.w)
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
