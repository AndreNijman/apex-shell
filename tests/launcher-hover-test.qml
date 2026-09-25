import QtQuick
import QtTest
import Quickshell
import "../src/services"

// ─────────────────────────────────────────────────────────────────────────────
// launcher-hover-test.qml — a pointer that is not moving must not choose the
// launcher row that Enter opens.
//
// Driven by tests/run-launcher-hover-test.sh on a headless compositor. Pointer
// events are QtTest's, sent into the window, so Qt's own hover delivery (the
// synthetic hover it sends when items appear or move under a still pointer)
// is what is exercised, not a call into the launcher's handlers.
//
//   rest   — the pointer rests where row 3 will be, THEN the launcher opens.
//            Rows are created under it. Selection must stay on row 0.
//   refilt — the query changes while the pointer rests there, so rows are
//            destroyed and recreated under it. Selection must follow the
//            keyboard's rule (first result), not the pointer.
//   moved  — the pointer really moves onto row 2. Selection must follow it.
// ─────────────────────────────────────────────────────────────────────────────

ShellRoot {
    PanelWindow {
        id: win
        anchors { top: true; left: true }
        implicitWidth: 720
        implicitHeight: 640
        color: "#101010"

        Loader {
            id: slot
            anchors.fill: parent
            active: false
            sourceComponent: AppLauncher { onScreen: true }
        }

        TestCase {
            id: tc
            name: "LauncherHover"
            when: false
        }

        function report(k, v) { console.log("PROBE " + k + "=" + v) }

        function find(it, pred) {
            if (!it) return null
            if (pred(it)) return it
            for (let i = 0; i < it.children.length; i++) {
                const r = find(it.children[i], pred)
                if (r) return r
            }
            return null
        }
        function list() { return find(slot.item, o => String(o).startsWith("QQuickListView")) }
        function input() { return find(slot.item, o => String(o).startsWith("QQuickTextInput")) }
        function rowCentre(i) {
            const r = list().itemAtIndex(i)
            return r ? r.mapToItem(win.contentItem, r.width / 2, r.height / 2) : null
        }

        property int step: 0
        property var target: null
        property int ticks: 0

        Timer {
            interval: 250; repeat: true; running: true
            onTriggered: {
                win.ticks++
                if (win.ticks > 80) { win.report("result", "TIMEOUT step " + win.step); Qt.quit(); return }
                switch (win.step) {
                case 0:     // learn where row 3 sits, with no pointer in the window
                    slot.active = true; win.step = 1; break
                case 1:
                    if (!slot.item || slot.item.filtered.length < 6 || !win.list().itemAtIndex(3)) break
                    win.target = win.rowCentre(3)
                    win.report("rows", slot.item.filtered.length)
                    slot.active = false; win.step = 2; break
                case 2:     // pointer comes to rest there while nothing is under it
                    tc.mouseMove(win.contentItem, win.target.x - 4, win.target.y)
                    tc.mouseMove(win.contentItem, win.target.x, win.target.y)
                    slot.active = true; win.step = 3; break
                case 3:
                    if (!slot.item || slot.item.filtered.length < 6 || !win.list().itemAtIndex(3)) break
                    win.step = 4; break          // one more tick for hover delivery
                case 4:
                    win.report("rest.sel", slot.item.selIndex); win.step = 5; break
                case 5:     // refilter under the resting pointer
                    win.input().text = "e"; win.step = 6; break
                case 6:
                    win.step = 7; break
                case 7:
                    win.report("refilt.rows", slot.item.filtered.length)
                    win.report("refilt.sel", slot.item.selIndex)
                    win.input().text = ""; win.step = 8; break
                case 8:
                    win.step = 9; break
                case 9: {   // a real move onto row 2
                    const c = win.rowCentre(2)
                    tc.mouseMove(win.contentItem, c.x, c.y - 3)
                    tc.mouseMove(win.contentItem, c.x, c.y)
                    win.step = 10; break
                }
                case 10:
                    win.report("moved.sel", slot.item.selIndex)
                    Qt.quit()
                }
            }
        }
    }
}
