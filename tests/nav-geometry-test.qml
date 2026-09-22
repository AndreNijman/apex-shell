import Quickshell
import QtQuick
import "./src"
import "./src/theme"
import "./src/services"
import "./src/nexus"
import "./src/components"
import "./src/components/config"

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
// socket it created, which is a stronger guarantee than opening no window:
// there is no session here to draw on.
//
// ── What it asserts ─────────────────────────────────────────────────────────
//
//   horizontal — no two pills overlap, no pill leaves its own slot, no label
//                leaves its pill, the bar is tall enough for the text it holds,
//                and the click target is the whole slot rather than the pill
//   vertical   — no two rows overlap, rows stay inside the column or scroll,
//                a row stays big enough to hit, no label leaves the pane
//   vertical,   — and where the rows do fit, they reach both ends of the
//   short        column with equal gaps rather than bunching in the middle
//   width      — the dashboard fits the output it opens on, together with the
//                two notches it opens between, at every scale
//   pages      — every settings page PageRegistry declares, laid out in a pane
//                the size the Nexus window gives it: no two rows on top of
//                each other, no row wider than the pane, and no line of text
//                outside the row that is supposed to contain it
//
// The page block is P0-024's third criterion. It is here rather than in a suite
// of its own because it is the same question — where did Qt put the rectangles,
// at every scale — and because the settle detection, the stale-layout refusal
// and the unusable-host verdict all had to exist before it could be asked at
// all. A second harness would have had to grow its own copies.
//
// ── Hosts it cannot run on ──────────────────────────────────────────────────
//
// A Hyprland nested inside a headless compositor comes up, hands the shell a
// 0x0 output and then never asks its Qt client for another frame, so the layout
// stops re-polishing and every rectangle read back is the previous matrix
// point. The suite detects that — the geometry has to AGREE with the size just
// staged, not only hold still — and stops with "unusable-host" rather than
// reporting a few hundred overlaps that are an artefact of the harness.
// labwc and sway on the wlroots headless backend drive it correctly.
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

    // The scales and pane widths the settings pages are laid out at. 0.85 and
    // 2.00 are the ends of the range the shell supports; 1.00 and 1.50 are the
    // two a person is most likely to be on.
    readonly property var pageScales: [0.85, 1.00, 1.50, 2.00]

    // 560 is what a 920-wide Nexus card leaves after the 244px navigation pane
    // and the margins; 360 is the narrower one the dashboard's Config tab hands
    // a page at 70% of a 1080p bar.
    readonly property var pagePanes: [560, 360]

    // Unscaled column heights for the three-tab switcher, in the range the
    // audio popup lives in. Every one of them has room for three rows at every
    // scale in the matrix, which is the point: this is the case where the
    // component has slack and has to decide what to do with it.
    readonly property var shortColumns: [200, 300, 420]

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

        // A settings page, in a pane the size the Nexus window hands one. The
        // Loader is swapped per matrix point rather than ten pages being built
        // at once: a hidden page still lays out, and ten of them in the same
        // window would make every settle read the wrong one's rectangles.
        Item {
            id: pageHost
            x: 1000
            y: 0
            width:  560
            height: 520
            Loader {
                id: pageLoader
                anchors.fill: parent

                // A page that holds a ServiceRef gated on `onScreen` draws
                // NOTHING until something says it is on screen: the service
                // never polls, so every row behind what the service found stays
                // invisible. Nexus.qml binds this to the window's visibility;
                // a Loader in a test that never sets it is a page measured in
                // the one state no user ever sees.
                //
                // The Firewall page is entirely that shape — all four of its row
                // groups are behind a FirewallService condition — so it laid out
                // zero rows and this suite reported 16 failures for it, at every
                // scale and both pane widths. Setting it here is what production
                // does, and if the property is ever renamed the page goes back to
                // zero rows and the "at least one row" assertion says so, which
                // is why this needs no list of which pages have one.
                onLoaded: if (item && item.onScreen !== undefined)
                              item.onScreen = true
            }
        }

        // The other vertical switcher in the shell, and the one the nine-row
        // column's fix nearly broke. Three icon-only tabs down the side of the
        // audio popup, sized the way AudioControl.qml sizes them: height from
        // the parent, width left to implicitWidth.
        Item {
            id: vShortHost
            y: 520
            width:  vShortSwitcher.implicitWidth
            height: 381
            TabSwitcher {
                id: vShortSwitcher
                height:       parent.height
                orientation:  "vertical"
                currentPage:  "output"
                model:        root.audioTabs
            }
        }
    }

    // src/services/AudioControl.qml's switcher model, icon-only and three long.
    readonly property var audioTabs: [
        { key: "output", icon: "󰕾" },
        { key: "input",  icon: "󰍬" },
        { key: "mixer",  icon: "󰾝" }
    ]

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
    //
    // `pred` narrows the shape when the count alone does not. Nine rows is a
    // number nothing else in the tree happens to have; three is not — a row
    // delegate's own children, or a 1px divider beside two pills, will match a
    // bare count and hand back a "row" one pixel tall. Every laid-out child has
    // to satisfy it, so a container with five children of which three pass is
    // still rejected rather than silently accepted three-fifths of the way.
    function slotsOf(item, n, depth, pred) {
        if (!item || !item.children || depth < 0)
            return []
        const live = []
        var laidOut = 0
        for (var j = 0; j < item.children.length; j++) {
            const c = item.children[j]
            if (c.width > 0 && c.height > 0) {
                laidOut++
                if (!pred || pred(c))
                    live.push(c)
            }
        }
        if (live.length === n && laidOut === n && n > 0)
            return live
        for (var i = 0; i < item.children.length; i++) {
            const found = root.slotsOf(item.children[i], n, depth - 1, pred)
            if (found.length === n)
                return found
        }
        return []
    }

    // The rows of a vertical switcher: as wide as the switcher, and tall enough
    // to be a row rather than a rule.
    function vRowsOf(sw, n) {
        return root.slotsOf(sw, n, 4, function (c) {
            return Math.abs(c.width - sw.width) <= 1.5 && c.height >= 4
        })
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

    // ── Reading a settings page back ─────────────────────────────────────────
    // By what an object IS. A CfgRow is the only thing in the tree carrying
    // both `effect` and `hoverable`; a CfgButton is the only thing carrying
    // both `variant` and `label`. Neither is matched on a type name, because
    // the QML engine does not hand one out and a name comparison would be a
    // string that goes stale silently.
    function partsOf(item, pred, out, depth) {
        if (!item || depth < 0) return out
        if (pred(item)) out.push(item)
        const kids = item.children
        if (kids)
            for (var i = 0; i < kids.length; i++)
                root.partsOf(kids[i], pred, out, depth - 1)
        return out
    }

    // A CfgRow is the only thing in the tree carrying both `effect` and
    // `hoverable`. The Keybinds page draws none — it has its own BindRow, which
    // is the only thing carrying both `action` and `pendingCombo` — and a
    // definition that missed it would have reported that page as "laid out
    // nothing" at every point rather than measuring it.
    function isRow(o)  {
        return (o.effect !== undefined && o.hoverable !== undefined)
            || (o.action !== undefined && o.pendingCombo !== undefined)
    }
    function isCtl(o)  { return o.variant !== undefined && o.label !== undefined }
    function isText(o) { return o.text !== undefined && o.wrapMode !== undefined }

    function livePartsOf(page, pred) {
        const all = root.partsOf(page, pred, [], 12)
        const out = []
        for (const o of all)
            if (o.visible && o.width > 0.5 && o.height > 0.5)
                out.push(o)
        return out
    }

    // ── A settings page, measured ────────────────────────────────────────────
    //
    // Vertical containment is deliberately NOT asserted against the pane: a page
    // scrolls, so a row below the fold is correctly outside it. What is asserted
    // is scroll-independent — that rows do not sit on top of each other, that
    // none is wider than the pane it is in, and that every line of text is
    // inside the row that draws it.
    //
    // The last one is the assertion that has teeth. A CfgRow's height is a
    // constant chosen for the number of lines it expects, so a row that grows a
    // line and does not grow its height clips it, and nothing else in the suite
    // would notice: the row's own rectangle is fine, its neighbours are fine,
    // and the sentence is simply gone.
    //
    // ── What this block does NOT reach ──────────────────────────────────────
    // A row behind a backend condition. The stubs on PATH answer every page
    // with an empty machine, so a section that appears only when the blueprint
    // is readable, or when a rollback is available, is invisible here and its
    // rows are not measured. That is a real gap and it is stated rather than
    // papered over: the two rows in the tree that carry an `effect` are both
    // behind such a condition, so the assertion that a deferred row grows to
    // fit its caption lives in tests/settings-controls-test.qml, on a fixture
    // where it can be made to appear.
    function measurePage(label, pane) {
        const page = pageLoader.item
        if (!page) {
            root.check(label + ": the page built", false, "loader is empty")
            return
        }
        const rows = root.livePartsOf(page, root.isRow)
        if (rows.length === 0) {
            root.check(label + ": the page laid out at least one row", false,
                       "found none")
            return
        }

        var worstOverlap = -1e9, worstOverlapAt = ""
        var worstSpill   = -1e9, worstSpillAt   = ""
        var worstClip    = -1e9, worstClipAt    = ""
        var worstCtl     = -1e9, worstCtlAt     = ""

        // Sorted by where they ended up rather than by the order they were
        // found: the walk order is the object tree's, and two sections' rows
        // interleave in it.
        const placed = []
        for (const r of rows) {
            const p = r.mapToItem(page, 0, 0)
            placed.push({ item: r, top: p.y, bottom: p.y + r.height,
                          left: p.x, right: p.x + r.width })
        }
        placed.sort(function (a, b) { return a.top - b.top })

        for (var i = 0; i < placed.length; i++) {
            const r = placed[i]

            if (i > 0) {
                const over = placed[i - 1].bottom - r.top
                if (over > worstOverlap) {
                    worstOverlap = over
                    worstOverlapAt = "row " + i + " starts "
                                   + over.toFixed(1) + "px above the one before it"
                }
            }

            const spill = Math.max(-r.left, r.right - pane)
            if (spill > worstSpill) {
                worstSpill = spill
                worstSpillAt = "row " + i + " spans " + r.left.toFixed(1)
                             + ".." + r.right.toFixed(1) + " in a " + pane + "px pane"
            }

            for (const tx of root.livePartsOf(r.item, root.isText)) {
                if (String(tx.text) === "") continue
                const tp = tx.mapToItem(r.item, 0, 0)
                const out = Math.max(-tp.y, tp.y + tx.height - r.item.height)
                if (out > worstClip) {
                    worstClip = out
                    worstClipAt = "\"" + String(tx.text).substring(0, 34)
                                + "\" sits " + out.toFixed(1)
                                + "px outside a row " + r.item.height.toFixed(1) + "px tall"
                }
            }
        }

        for (const c of root.livePartsOf(page, root.isCtl)) {
            const cp = c.mapToItem(page, 0, 0)
            const out = Math.max(-cp.x, cp.x + c.width - pane)
            if (out > worstCtl) {
                worstCtl = out
                worstCtlAt = "\"" + String(c.label).substring(0, 20) + "\" ends "
                           + (cp.x + c.width).toFixed(1) + " in a " + pane + "px pane"
            }
        }

        root.check(label + ": no two rows overlap", worstOverlap <= 1.5, worstOverlapAt)
        root.check(label + ": no row is wider than the pane", worstSpill <= 1.5, worstSpillAt)
        root.check(label + ": no text is drawn outside its row", worstClip <= 1.0, worstClipAt)
        root.check(label + ": no control is pushed out of the pane",
                   worstCtl <= 1.5, worstCtlAt)
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

    // ── Vertical, short ──────────────────────────────────────────────────────
    // The nine-row column and the three-row one pull in opposite directions and
    // one component serves both. Giving every row a fixed gap stops nine rows
    // overlapping in a column too short for them, and it also bunches three
    // rows into the middle of a column that has room to spare — which is what
    // the audio popup is, and what the first pass at the overlap did to it.
    //
    // So the spread is asserted, not just the absence of an overlap. Stated in
    // what a reader can see rather than in the component's own arithmetic: if
    // the rows together are shorter than the column, they reach both its ends
    // and the gaps between them are equal. A test that recomputed vSpacing here
    // would agree with the component about a bunched column as readily as about
    // a spread one.
    function measureVerticalSpread(label, columnHeight) {
        const n = root.audioTabs.length
        const s = root.vRowsOf(vShortSwitcher, n)
        if (s.length !== n) {
            root.check(label + ": the column laid out " + n + " rows", false,
                       "found " + s.length)
            return
        }

        var sumRows = 0
        var top = 1e9, bottom = -1e9
        var minGap = 1e9, maxGap = -1e9
        var minRow = 1e9
        var prevBottom = -1e9

        for (var i = 0; i < n; i++) {
            const rowItem = s[i]
            const y = rowItem.mapToItem(vShortSwitcher, 0, 0).y
            if (i > 0) {
                const gap = y - prevBottom
                minGap = Math.min(minGap, gap)
                maxGap = Math.max(maxGap, gap)
            }
            prevBottom = y + rowItem.height
            sumRows += rowItem.height
            minRow   = Math.min(minRow, rowItem.height)
            top      = Math.min(top, y)
            bottom   = Math.max(bottom, y + rowItem.height)
        }

        root.check(label + ": no two rows overlap", minGap >= 0,
                   "closest gap " + minGap.toFixed(1) + "px")
        root.check(label + ": a row stays big enough to hit",
                   minRow >= root.minTouch(),
                   "shortest row " + minRow.toFixed(1)
                   + "px, floor " + root.minTouch() + "px")
        root.check(label + ": the rows stay inside the column",
                   top >= -0.5 && bottom <= columnHeight + 0.5,
                   "rows span " + top.toFixed(1) + ".." + bottom.toFixed(1)
                   + " in a " + columnHeight + "px column")

        // Only where there is slack to spread. Integer spacing loses at most
        // one pixel per gap, which is the tolerance below and not a fudge.
        if (sumRows < columnHeight - (n - 1)) {
            root.check(label + ": a short list spreads over the column it was given",
                       bottom - top >= columnHeight - (n - 1) - 0.5,
                       n + " rows totalling " + sumRows.toFixed(1)
                       + "px cover only " + (bottom - top).toFixed(1)
                       + "px of a " + columnHeight + "px column")
            root.check(label + ": the gaps it spreads into are equal",
                       maxGap - minGap <= 1.5,
                       "gaps run " + minGap.toFixed(1) + ".." + maxGap.toFixed(1) + "px")
        }
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
        const w   = DashboardLayout.widthFor(Metrics, page, screenW)
        const box = w + 2 * Theme.notchRadius     // popups/Dashboard.qml sizer
        const room = screenW - 2 * root.sideRoom()

        root.check(label + ": the dashboard fits the output", box <= screenW,
                   "sizer " + box + "px on a " + screenW + "px output")
        root.check(label + ": the dashboard clears both notches", w <= room,
                   "wants " + w + "px, " + room + "px between the notches")

        // The bar inside it has to be able to hold six tabs. Asserted through
        // the same helper the window uses, so the two cannot drift.
        const bar = DashboardLayout.barWidthFor(Metrics, page, screenW)
        root.check(label + ": the tab bar gets a usable width",
                   bar >= DashboardLayout.tabs.length * root.minTouch(),
                   "bar " + bar + "px for " + DashboardLayout.tabs.length
                   + " tabs, floor " + (DashboardLayout.tabs.length * root.minTouch()) + "px")
    }

    // What has to hold even where the geometry is hopeless.
    function measureDegraded(label, page, screenW) {
        const w   = DashboardLayout.widthFor(Metrics, page, screenW)
        const bar = DashboardLayout.barWidthFor(Metrics, page, screenW)
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
                       - (Theme.notchRadius + DashboardLayout.contentInset(Metrics))
                       - DashboardLayout.contentInset(Metrics)
        const pageArea = content - hSwitcher.implicitHeight
        return pageArea - 16 - 8 - 6 - Theme.px(30) - 8
    }

    // ── Driver ───────────────────────────────────────────────────────────────
    property var plan: []
    property int pi: -1
    property string origMode: ""
    property real origManual: 1.0

    // ── Waiting for the layout instead of hoping ─────────────────────────────
    // A fixed delay between changing a width and reading the rectangles is a
    // guess about how fast the compositor delivers frame callbacks, and it is
    // wrong on at least one: a Hyprland nested inside a headless host throttles
    // them hard enough that a 90ms tick reads the PREVIOUS matrix point, which
    // then fails assertions about a geometry it was never in.
    //
    // So nothing is graded until the geometry stops moving: the same numbers
    // twice in a row is settled, anything else waits. The retry cap turns a
    // layout that never settles into one loud failure rather than a hang.
    property string lastSignature: ""
    property int settleTries: 0
    property int stuck: 0
    readonly property int settleMax: 40

    // Which of the two vertical rigs a step drives, or null for a horizontal one.
    function vRigFor(stepData) {
        if (stepData.kind === "vShort")
            return { sw: vShortSwitcher, host: vShortHost,
                     n: root.audioTabs.length, short: true }
        if (stepData.kind === "v" || stepData.kind === "liveV")
            return { sw: vSwitcher, host: vHost, n: root.configTabs.length }
        return null
    }

    // Does what Qt laid out match the width or height that was asked for?
    function agreesWithStage(stepData) {
        if (stepData.kind === "page") {
            const pg = pageLoader.item
            if (!pg) return false
            // The page has to have been resized to the pane that was just
            // staged, and to have laid something out inside it. A page still
            // reporting the previous pane's width is a stale read, which is the
            // whole reason this function exists.
            return Math.abs(pg.width - pageHost.width) <= 1.5
                && root.livePartsOf(pg, root.isRow).length > 0
        }
        const v  = root.vRigFor(stepData)
        const sw = v ? v.sw : hSwitcher
        const n  = v ? v.n  : DashboardLayout.tabs.length
        const s  = (v && v.short) ? root.vRowsOf(sw, n) : root.slotsOf(sw, n, 4)
        if (s.length !== n)
            return false
        if (v)
            return Math.abs(s[0].width - v.host.width) <= 1.5
        const last = s[n - 1]
        return Math.abs(last.x + last.width - hHost.width) <= 1.5
    }

    function signatureOf(stepData) {
        if (stepData.kind === "page") {
            const pg = pageLoader.item
            if (!pg) return "incomplete:0"
            const rows = root.livePartsOf(pg, root.isRow)
            if (rows.length === 0) return "incomplete:0"
            var sig = "p" + stepData.pageIndex + ":" + pageHost.width + ":"
            for (const r of rows) {
                const q = r.mapToItem(pg, 0, 0)
                sig += q.x.toFixed(2) + "," + q.y.toFixed(2) + ","
                     + r.width.toFixed(2) + "," + r.height.toFixed(2) + ";"
            }
            return sig
        }
        const v  = root.vRigFor(stepData)
        const sw = v ? v.sw : hSwitcher
        const n  = v ? v.n  : DashboardLayout.tabs.length
        const s  = (v && v.short) ? root.vRowsOf(sw, n) : root.slotsOf(sw, n, 4)
        if (s.length !== n)
            return "incomplete:" + s.length
        var out = v ? "v" + v.host.height + ":" : "h" + hHost.width + ":"
        for (var i = 0; i < n; i++) {
            const it = s[i]
            const p  = it.mapToItem(sw, 0, 0)
            out += p.x.toFixed(2) + "," + p.y.toFixed(2) + ","
                 + it.width.toFixed(2) + "," + it.height.toFixed(2) + ","
                 + (it.children.length > 0 ? it.children[0].width.toFixed(2) : "-") + ";"
        }
        return out
    }

    // ── The output this run is on ────────────────────────────────────────────
    // Everything else here drives Theme.scale by hand, which makes the suite
    // say the same thing whatever the compositor hands it — useful for coverage
    // and useless as evidence that a particular monitor is fine. So the run
    // opens on the output it was given, at the scale Metrics derives for that
    // output on its own, and grades the real thing before it starts pretending.
    // Run it under a compositor set to 2560x1080 and this block is about
    // 2560x1080.
    readonly property var liveScreen: {
        const s = Metrics.referenceScreen
        return { w: s ? s.width : 0, h: s ? s.height : 0,
                 name: (s ? s.name : "none") + " as-is" }
    }

    function buildPlan() {
        const out = []
        // The live output first, before scaleMode is forced to manual. Left out
        // entirely when the compositor has not published a size: grading a
        // 0x0 output measures the compositor's startup, not the shell.
        if (root.liveScreen.w > 0 && root.liveScreen.h > 0) {
            for (var l = 0; l < DashboardLayout.tabs.length; l++)
                out.push({ kind: "live", screen: root.liveScreen,
                           page: DashboardLayout.tabs[l].key })
            for (var m = 0; m < root.dashHeights.length; m++)
                out.push({ kind: "liveV", dashHeight: root.dashHeights[m] })
        }

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
            for (var e = 0; e < root.shortColumns.length; e++)
                out.push({ kind: "vShort", scale: sc,
                           columnBase: root.shortColumns[e] })
        }

        // Every settings page, at the four scales that bracket the range, in
        // the two pane widths the Nexus window and the dashboard's Config tab
        // hand one. The full eight-scale sweep is what the tab column needs
        // because its spacing is arithmetic on the height; a page's rows are
        // stacked by a Column and the failure mode is a row that does not grow
        // with its text, which the ends and the middle catch.
        for (var f = 0; f < root.pageScales.length; f++)
            for (var g = 0; g < root.pagePanes.length; g++)
                for (var h = 0; h < PageRegistry.pages.length; h++)
                    out.push({ kind: "page", scale: root.pageScales[f],
                               pane: root.pagePanes[g], pageIndex: h })
        return out
    }

    function stage(stepData) {
        const live = stepData.kind === "live" || stepData.kind === "liveV"
        if (live) {
            SettingsService.set("scaleMode", "auto")
        } else {
            SettingsService.set("scaleMode", "manual")
            SettingsService.set("scaleManual", stepData.scale)
        }
        if (stepData.kind === "page") {
            pageHost.width  = stepData.pane
            pageHost.height = 520
            const wanted = PageRegistry.pages[stepData.pageIndex].component
            if (pageLoader.sourceComponent !== wanted)
                pageLoader.sourceComponent = wanted
        } else if (stepData.kind === "vShort") {
            // Scaled, because the popup this stands for is: its switcher takes
            // the popup's height and the popup is drawn in Theme.px.
            vShortHost.height = Theme.px(stepData.columnBase)
        } else if (stepData.kind === "h" || stepData.kind === "stress"
                || stepData.kind === "live") {
            hHost.width  = DashboardLayout.barWidthFor(Metrics, stepData.page, stepData.screen.w)
            hHost.height = hSwitcher.implicitHeight
        } else {
            vHost.height = root.configNavHeight(stepData.dashHeight)
            vHost.width  = Math.round(
                (DashboardLayout.barWidthFor(Metrics, "config",
                    live ? root.liveScreen.w : 1920) - 12) * 0.30)
        }
    }

    function grade(stepData) {
        if (stepData.kind === "live") {
            const ltag = "live " + stepData.screen.name + " @"
                       + Metrics.scale + "x " + stepData.page
            root.measureWidth(ltag, stepData.page, stepData.screen.w)
            root.measureHorizontal(ltag + " bar=" + hHost.width, hHost.width)
            root.measureHorizontalHeight(ltag)
        } else if (stepData.kind === "liveV") {
            root.measureVertical("live " + root.liveScreen.name + " @"
                                 + Metrics.scale + "x dashHeight="
                                 + stepData.dashHeight + " col=" + vHost.height,
                                 vHost.height)
        } else if (stepData.kind === "h") {
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
        } else if (stepData.kind === "page") {
            root.measurePage("page " + stepData.scale + "x "
                             + PageRegistry.pages[stepData.pageIndex].id
                             + " pane=" + stepData.pane, stepData.pane)
        } else if (stepData.kind === "vShort") {
            root.measureVerticalSpread(
                "vShort " + stepData.scale + "x col=" + vShortHost.height,
                vShortHost.height)
        } else {
            const vtag = "v " + stepData.scale + "x dashHeight=" + stepData.dashHeight
            root.measureVertical(vtag + " col=" + vHost.height, vHost.height)
        }
    }

    Timer {
        id: step
        interval: 45
        repeat: false
        onTriggered: {
            if (root.pi >= 0) {
                const sig = root.signatureOf(root.plan[root.pi])
                // Two conditions, and stability alone is not enough: a layout
                // that stopped updating is perfectly stable at the wrong size.
                // It also has to AGREE with the size that was staged.
                const ready = sig === root.lastSignature
                            && sig.indexOf("incomplete") !== 0
                            && root.agreesWithStage(root.plan[root.pi])
                if (!ready && root.settleTries < root.settleMax) {
                    root.lastSignature = sig
                    root.settleTries++
                    step.restart()
                    return
                }
                if (root.settleTries >= root.settleMax) {
                    // A host that cannot drive Qt's layout is not a failing
                    // shell, and reporting it as 240 overlapping tabs would be a
                    // lie in the loudest possible font. Three points in a row
                    // that never move is the host, not the code — a Hyprland
                    // nested inside a headless compositor does exactly this,
                    // because its Qt client is never asked for another frame.
                    root.stuck++
                    if (root.stuck >= 3) {
                        console.log("nav-geometry: unusable-host — the layout did"
                                    + " not re-polish after " + root.stuck
                                    + " staged changes, so nothing here was measured")
                        Qt.exit(2)
                        return
                    }
                    root.check("point " + root.pi + ": the layout settled within "
                               + root.settleMax + " ticks", false, sig.substring(0, 80))
                } else {
                    root.stuck = 0
                }
                root.grade(root.plan[root.pi])
            }
            root.pi++
            root.settleTries = 0
            root.lastSignature = ""
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

    // Wait for the compositor to publish an output before deciding what the
    // live block is. A nested Hyprland reports 0x0 for the first second or so,
    // and a plan built off that grades the shell against a screen with no size.
    property int bootTries: 0

    Timer {
        id: boot
        interval: 300
        running:  true
        repeat:   true
        onTriggered: {
            root.bootTries++
            const s = Metrics.referenceScreen
            const sized = s && s.width > 0 && s.height > 0
            if (!sized && root.bootTries < 40)
                return
            boot.running = false
            if (!sized)
                console.log("[rig] the compositor never published an output size;"
                            + " the live-output block is skipped")
            root.origMode   = SettingsService.scaleMode
            root.origManual = SettingsService.scaleManual
            root.plan = root.buildPlan()
            console.log("[rig] settings home " + Quickshell.env("HOME"))
            console.log("[rig] output " + root.liveScreen.name.replace(" as-is", "")
                        + " " + root.liveScreen.w + "x" + root.liveScreen.h
                        + " autoScale=" + Metrics.autoScale)
            console.log("[rig] " + DashboardLayout.tabs.length + " dashboard tabs, "
                        + root.configTabs.length + " settings pages, "
                        + root.audioTabs.length + " audio tabs, "
                        + (root.pageScales.length * root.pagePanes.length
                           * PageRegistry.pages.length) + " page layouts, "
                        + root.plan.length + " matrix points")
            step.restart()
        }
    }
}
