import Quickshell
import QtQuick
import "./src/theme"
import "./src/services"
import "./src/windows"
import "./src/popups"
import "./src"

// ─────────────────────────────────────────────────────────────────────────────
// Dashboard navigation geometry. Run via tests/run-dashboard-nav-test.sh, which
// drives it across a matrix of resolutions and scale factors under a headless
// compositor.
//
// This measures. It builds the real TopBar and the real Dashboard on the real
// output, opens the dashboard on every page in turn, and reads the rendered x
// and width of every tab and every notch out of the scene graph. Nothing here
// re-derives a layout the shell would have computed differently, and nothing
// here is a screenshot somebody has to look at.
//
// What it asserts, per page and per matrix row:
//
//   • no two tab pills overlap, in scene coordinates
//   • every pill is inside the tab bar, the tab bar inside the dashboard, and
//     the dashboard inside the output
//   • every tab keeps a click and touch target of at least Theme.px(24) square
//   • the selected tab is always named — a label on screen, whatever the tier
//   • no two entries in Config's settings list overlap, and the list stays
//     inside its own column
//   • the three top-bar notches do not overlap each other or run off the bar,
//     with the dashboard open and with it closed
//   • each notch's content fits inside it, which is where tray clipping hides
//
// The environment picks the row:
//   APEX_NAV_SCALE_MODE   auto | manual   (default auto)
//   APEX_NAV_SCALE        the manual factor, when mode is manual
//   APEX_NAV_LABEL        a name for the row, echoed into the output
// ─────────────────────────────────────────────────────────────────────────────

ShellRoot {
    id: root

    readonly property string rowLabel: Quickshell.env("APEX_NAV_LABEL") || "row"
    readonly property string scaleMode: Quickshell.env("APEX_NAV_SCALE_MODE") || "auto"
    readonly property real   manualScale: parseFloat(Quickshell.env("APEX_NAV_SCALE") || "1.0")

    readonly property var screen0: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null

    property int passed: 0
    property int failed: 0

    // Sub-pixel slack. Cells are width/count, which is rarely a whole number.
    readonly property real eps: 0.51

    // Smallest pointer target, in logical pixels. Deliberately NOT scaled by the
    // shell's factor: a compositor's scale already makes a logical pixel bigger
    // on a denser panel, and a finger is the same size whatever the shell's
    // idea of 12px is.
    readonly property int minTarget: 24

    // Whether the shell's own minimum bar fits the output at all: the three
    // notch minimums are 1080p tokens like everything else, so a large manual
    // scale on a small screen asks for a bar wider than the display. Rows in
    // that state still have to prove nothing OVERLAPS; they cannot be asked to
    // prove nothing is clipped, because the content is bigger than the screen.
    readonly property bool shellFitsOutput:
        Theme.lNotchMinWidth + Theme.cNotchMinWidth + Theme.rNotchMinWidth
        + 2 * Theme.notchRadius <= bar.width

    function check(name, cond) {
        if (cond) {
            root.passed++;
            console.log("  PASS  " + name);
        } else {
            root.failed++;
            console.log("  FAIL  " + name);
        }
    }

    // ── Scene-graph helpers ──────────────────────────────────────────────────
    function collect(item, prefix, out) {
        if (!item)
            return out;
        if (item.objectName && item.objectName.indexOf(prefix) === 0)
            out.push(item);
        const kids = item.children;
        for (var i = 0; i < kids.length; i++)
            collect(kids[i], prefix, out);
        return out;
    }

    function first(item, prefix) {
        const hits = collect(item, prefix, []);
        return hits.length > 0 ? hits[0] : null;
    }

    // Left edge and width in the window's own coordinates, which is what
    // "does this run off the screen" has to be asked in.
    function rect(item) {
        const p = item.mapToItem(null, 0, 0);
        return {
            "left": p.x,
            "top": p.y,
            "right": p.x + item.width,
            "bottom": p.y + item.height,
            "w": item.width,
            "h": item.height
        };
    }

    function fmt(v) {
        return Math.round(v * 10) / 10;
    }

    // "Is this tab showing a word, or only a glyph?" asked of the scene graph
    // rather than of a property on the component. The icons are single
    // characters and the labels are not, which is enough to tell them apart —
    // and asking this way means the same test file runs against the layout
    // before the fix, which is the only way its failure means anything.
    function showsAWord(item) {
        if (!item)
            return false;
        if (item.text !== undefined && item.font !== undefined
            && item.visible && String(item.text).length > 1)
            return true;
        const kids = item.children;
        for (var i = 0; i < kids.length; i++)
            if (showsAWord(kids[i]))
                return true;
        return false;
    }

    // ── The shell under test ─────────────────────────────────────────────────
    TopBar {
        id: bar
        screen: root.screen0
    }

    Dashboard {
        id: dash
        anchorWindow: bar
    }

    // ── Assertions ───────────────────────────────────────────────────────────
    readonly property var pages: ["home", "stats", "agents", "kanban", "launcher", "config"]

    function measurePage(page) {
        const tag = root.rowLabel + " " + page;

        const content = dash.contentItem;
        const tabBar = first(content, "dashboard-tabbar");
        const sizer = first(content, "dashboard-sizer");

        if (!tabBar || !sizer) {
            root.check(tag + ": the dashboard tab bar was found", false);
            return;
        }

        // Scoped to the dashboard's own bar. Pages carry tab switchers of their
        // own — the clock card has four — and sweeping the whole window would
        // measure those against the dashboard's bar and call it an overlap.
        const pills = collect(tabBar, "tabswitcher-pill:", []);
        const tabs = collect(tabBar, "tabswitcher-tab:", []);

        root.check(tag + ": all six tabs are present (got " + pills.length + ")",
                   pills.length === 6 && tabs.length === 6);
        if (pills.length < 2)
            return;

        const barR = rect(tabBar);
        const sizerR = rect(sizer);

        // Ordered left to right so "the next one" means what it says.
        const boxes = pills.map(rect).sort(function (a, b) {
            return a.left - b.left;
        });

        console.log("  [geom] " + tag
            + " tier=" + (tabBar.sizeTier !== undefined ? tabBar.sizeTier : "none")
            + " screen=" + (root.screen0 ? root.screen0.width + "x" + root.screen0.height : "?")
            + " shellScale=" + Metrics.scale
            + " pagew=" + Popups.dashboardPageWidth
            + " sizer=" + root.fmt(sizerR.w) + "x" + root.fmt(sizerR.h)
            + " bar=" + root.fmt(barR.w)
            + " pills=" + boxes.map(function (b) {
                return root.fmt(b.left) + "+" + root.fmt(b.w);
            }).join(","));

        // 1 — no two tabs overlap.
        var worstGap = Infinity;
        for (var i = 0; i + 1 < boxes.length; i++)
            worstGap = Math.min(worstGap, boxes[i + 1].left - boxes[i].right);
        root.check(tag + ": no two tabs overlap (tightest gap " + root.fmt(worstGap) + "px)",
                   worstGap >= -root.eps);

        // 2 — nothing escapes its container, at any level.
        var inBar = true;
        for (var j = 0; j < boxes.length; j++)
            if (boxes[j].left < barR.left - root.eps || boxes[j].right > barR.right + root.eps)
                inBar = false;
        root.check(tag + ": every tab is inside the tab bar", inBar);

        root.check(tag + ": the tab bar is inside the dashboard",
                   barR.left >= sizerR.left - root.eps && barR.right <= sizerR.right + root.eps);

        root.check(tag + ": the dashboard is inside the output ("
                   + root.fmt(sizerR.w) + " of " + dash.width + ")",
                   sizerR.left >= -root.eps
                   && sizerR.right <= dash.width + root.eps
                   && sizerR.bottom <= dash.height + root.eps);

        // 3 — the tabs stay hittable.
        var smallest = Infinity;
        for (var k = 0; k < tabs.length; k++)
            smallest = Math.min(smallest, tabs[k].width, tabs[k].height);
        root.check(tag + ": every tab is at least " + root.minTarget + "px both ways (smallest "
                   + root.fmt(smallest) + ")",
                   smallest >= root.minTarget - root.eps);

        // 4 — the tier may drop labels, but never the one that says where you are.
        const selected = collect(tabBar, "tabswitcher-tab:" + page, []);
        root.check(tag + ": the selected tab is named on screen",
                   selected.length === 1 && root.showsAWord(selected[0]));
    }

    // Config's own page list runs down the left of the tab, and it is the one
    // that overlaps on an ordinary 1080p desk: nine settings pages at a fixed 60
    // each into a column with room for six, so the spacing went negative and the
    // entries stacked on top of one another.
    function measureSettingsList() {
        const tag = root.rowLabel + " config-list";
        const content = dash.contentItem;
        const column = first(content, "config-pagelist");

        if (!column) {
            root.check(tag + ": the settings list was found", false);
            return;
        }

        const entries = collect(column, "tabswitcher-vtab:", []);
        root.check(tag + ": the settings list has its entries (got " + entries.length + ")",
                   entries.length >= 2);
        if (entries.length < 2)
            return;

        const colR = rect(column);
        const boxes = entries.map(rect).sort(function (a, b) {
            return a.top - b.top;
        });

        var worstGap = Infinity;
        for (var i = 0; i + 1 < boxes.length; i++)
            worstGap = Math.min(worstGap, boxes[i + 1].top - boxes[i].bottom);

        console.log("  [list] " + tag
            + " entries=" + boxes.length
            + " column=" + root.fmt(colR.h)
            + " entry=" + root.fmt(boxes[0].h)
            + " gap=" + root.fmt(worstGap));

        root.check(tag + ": no two settings entries overlap (tightest gap "
                   + root.fmt(worstGap) + "px)",
                   worstGap >= -root.eps);

        var inside = true;
        for (var j = 0; j < boxes.length; j++)
            if (boxes[j].top < colR.top - root.eps || boxes[j].bottom > colR.bottom + root.eps)
                inside = false;
        root.check(tag + ": every settings entry is inside its column", inside);

        root.check(tag + ": every settings entry is at least " + root.minTarget + "px tall",
                   boxes[0].h >= root.minTarget - root.eps);
    }

    function measureBar(state) {
        const tag = root.rowLabel + " bar/" + state;

        const l = bar.lWidth;
        const c = bar.cWidth;
        const r = bar.rWidth;
        const w = bar.width;
        const shoulder = Theme.notchRadius;

        // The centre notch is centred, so its left edge sits at (w - c) / 2.
        const leftGap = (w - c) / 2 - shoulder - l;
        const rightGap = (w - c) / 2 - shoulder - r;

        console.log("  [bar]  " + tag + " width=" + w
            + " l=" + l + " c=" + c + " r=" + r
            + " clearance=" + root.fmt(leftGap) + "/" + root.fmt(rightGap));

        root.check(tag + ": the centre notch fits the bar (" + c + " of " + w + ")",
                   c <= w + root.eps);
        root.check(tag + ": the left notch clears the centre one (" + root.fmt(leftGap) + "px)",
                   leftGap >= -root.eps);
        root.check(tag + ": the right notch clears the centre one (" + root.fmt(rightGap) + "px)",
                   rightGap >= -root.eps);

        // Each notch clips its content, so content wider than the notch is a
        // silently truncated workspace strip or system tray.
        if (!root.shellFitsOutput) {
            console.log("  [bar]  " + tag + " out of range: the shell's minimum bar is "
                + (Theme.lNotchMinWidth + Theme.cNotchMinWidth + Theme.rNotchMinWidth
                   + 2 * Theme.notchRadius)
                + "px on a " + w + "px output, so clipping is the only way to fit;"
                + " the overlap assertions above still stand");
            return;
        }

        const named = [["left", l], ["center", c], ["right", r]];
        for (var i = 0; i < named.length; i++) {
            const side = named[i][0];
            const item = first(bar.contentItem, "topbar-content:" + side);
            if (!item)
                continue;
            const need = item.implicitWidth + (side === "center" ? 0 : Theme.notchPadding * 2);
            console.log("  [bar]  " + tag + " " + side + "Content implicitWidth="
                + root.fmt(item.implicitWidth) + " notch=" + named[i][1]);
            root.check(tag + ": the " + side + " notch does not clip its content ("
                       + root.fmt(need) + " into " + named[i][1] + ")",
                       need <= named[i][1] + root.eps);
        }
    }

    // ── Drive ────────────────────────────────────────────────────────────────
    // One tick per step so every binding, Behavior and Repeater has settled
    // before anything is read. Animations are off — see reduceMotion below —
    // so a tick only has to outlast a layout pass.
    property int step: 0

    Timer {
        id: driver
        interval: 400
        running: false
        repeat: true
        onTriggered: {
            const n = root.pages.length;

            if (root.step === 0) {
                // Closed-bar geometry, before the dashboard claims the notch.
                root.measureBar("closed");
                Popups.dashboardScreen = root.screen0 ? root.screen0.name : "";
                Popups.dashboardPage = root.pages[0];
                Popups.dashboardOpen = true;
            } else if (root.step === 1) {
                root.measureBar("open");
                root.measurePage(root.pages[0]);
                Popups.dashboardPage = root.pages[1];
            } else if (root.step <= n) {
                // One page per tick. Pages are built on first visit, so the tick
                // that selects a page is never the tick that measures it.
                const idx = root.step - 1;
                root.measurePage(root.pages[idx]);
                if (idx + 1 < n)
                    Popups.dashboardPage = root.pages[idx + 1];
            } else if (root.step === n + 1) {
                // Config is last, and its page list is a second lazily built
                // level, so it gets a tick of its own.
                root.measureSettingsList();
            } else {
                Popups.dashboardOpen = false;
                console.log("");
                console.log("row=" + root.rowLabel
                    + " passed=" + root.passed + " failed=" + root.failed);
                Qt.exit(root.failed === 0 ? 0 : 1);
            }
            root.step++;
        }
    }

    Timer {
        id: settle
        interval: 900
        running: true
        repeat: false
        onTriggered: {
            // Animations off: every Behavior in the shell reads
            // Theme.animDuration, so this makes the geometry settle in one pass
            // instead of somewhere inside a 320ms curve.
            SettingsService.set("reduceMotion", true);
            if (root.scaleMode === "manual") {
                SettingsService.set("scaleManual", root.manualScale);
                SettingsService.set("scaleMode", "manual");
            } else {
                SettingsService.set("scaleMode", "auto");
            }
            console.log("[row] " + root.rowLabel
                + " output=" + (root.screen0 ? root.screen0.name : "none")
                + " logical=" + (root.screen0 ? root.screen0.width + "x" + root.screen0.height : "?")
                + " scaleMode=" + root.scaleMode
                + " shellScale=" + Metrics.scale);
            driver.start();
        }
    }
}
