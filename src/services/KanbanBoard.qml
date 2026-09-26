import QtQuick
import Quickshell.Io
import "../"
import "../components/controls"
import "../components"

// KanbanBoard — three columns, JSON at $HOME/.config/apex-shell/src/user_data/tasks.json.
//
// Key behaviours:
//   • Draft: task only saved when Enter pressed or focus lost with text.
//   • Arrow move: card appears in new column offset by ±dir*36px, springs
//     to 0 with OutBack overshoot (rubber-band feel).
//   • Due date: mini calendar + optional time picker, both optional.
//     Time-only → today's date prepended automatically.
//   • Delete confirm: Enter = confirm, Esc = cancel; only active when overlay
//     is showing; dashboard close cancels automatically.

Item {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes

    focus: true

    // ── Persistent state ──────────────────────────────────────────────────────
    property var    _tasks:    []
    property int    _nextId:   0
    property string _filePath: ""

    // ── Animation tracking ────────────────────────────────────────────────────
    // Plain objects — mutated in-place, no signal needed, checked once per card.
    property var _newCardIds:      ({})   // id → true  (y slide-in on creation)
    property var _entryDirections: ({})   // id → dir   (x spring on column move)

    // ── Delete confirm ────────────────────────────────────────────────────────
    property int delConfirmId: -1   // task id with overlay open, -1 = none

    // ── Due date picker state ─────────────────────────────────────────────────
    property int    pickerTaskId:  -1
    property int    pickerYear:    0
    property int    pickerMonth:   0
    property int    pickerDay:     0     // 0 = date not selected
    property bool   pickerHasTime: false
    property int    pickerTimeH:   12
    property int    pickerTimeM:   0
    property var    pickerDays:    []
    // Opened from the keyboard: focus goes into the picker, and back to the
    // card's Due button when it closes (UI/UX roadmap v3 Phase 21). A pointer
    // open leaves focus alone, so no ring lights for a click.
    property bool   _pickerByKey:  false
    property int    _pickerLastId: -1

    // Cards with their details open, by task id. Every edit replaces _tasks,
    // and the column Repeaters rebuild every card from the new array — so a
    // card's own `showExtra` was lost on each edit: picking an urgency closed
    // the panel the chip sits in, under the pointer as under the keyboard.
    property var    _expanded:     ({})
    function _setExpanded(id, on) {
        const m = Object.assign({}, root._expanded)
        if (on) m[id] = true
        else    delete m[id]
        root._expanded = m
    }
    // The same rebuild destroys the control that has focus. A keyboard edit
    // names the control it came from, and focus is put back on the rebuilt
    // card's twin once the Repeater has made it.
    function _refocus(id, what, arg) {
        Qt.callLater(function () {
            const col = root._columnOf(id)
            const t = col >= 0 ? colRepeater.itemAt(col) : null
            const c = t ? t._cardFor(id) : null
            if (c) c.focusControl(what, arg)
        })
    }

    readonly property var _monthNames: [
        "January","February","March","April","May","June",
        "July","August","September","October","November","December"
    ]
    readonly property var _dowNames: ["Su","Mo","Tu","We","Th","Fr","Sa"]

    // ── Boot: resolve $HOME → create file if missing → load ──────────────────
    Process {
        command: ["bash", "-c", "echo $HOME"]
        running: true
        stdout: SplitParser {
            onRead: function(line) {
                var h = line.trim()
                if (h === "") return
                root._filePath = h + "/.config/apex-shell/src/user_data/tasks.json"
                mkProc.command = [
                    "bash", "-c",
                    "[ -f '" + root._filePath + "' ] || " +
                    "(mkdir -p \"$HOME/.config/apex-shell/src/user_data\" && " +
                    "printf '%s' '{\"tasks\":[],\"nextId\":0}' > '" + root._filePath + "')"
                ]
                mkProc.running = false; mkProc.running = true
            }
        }
    }

    Process {
        id: mkProc; command: []; running: false
        onRunningChanged: {
            if (!running && root._filePath !== "") {
                rdProc.command = ["cat", root._filePath]
                rdProc.running = false; rdProc.running = true
            }
        }
    }

    Process {
        id: rdProc; command: []; running: false
        stdout: StdioCollector {
            id: rdBuf
            onStreamFinished: {
                try {
                    var o = JSON.parse(rdBuf.text)
                    root._tasks  = o.tasks  || []
                    root._nextId = o.nextId || 0
                } catch(e) { root._tasks = []; root._nextId = 0 }
            }
        }
    }

    // ── Save ──────────────────────────────────────────────────────────────────
    function _save() {
        if (_filePath === "") return
        var s = JSON.stringify({ tasks: _tasks, nextId: _nextId })
        wrProc.command = [
            "bash", "-c",
            "printf '%s' \"$1\" > \"$2\"",
            "--", s, _filePath
        ]
        wrProc.running = false; wrProc.running = true
    }
    Process { id: wrProc; command: []; running: false }

    // ── Reset state when dashboard closes ─────────────────────────────────────
    Connections {
        target: Popups
        function onDashboardOpenChanged() {
            if (!Popups.dashboardOpen) {
                root.delConfirmId = -1
                root.pickerTaskId = -1
            }
        }
    }

    // ── Mutations ─────────────────────────────────────────────────────────────
    function _addTask(col, title) {
        var id   = root._nextId++
        var list = root._tasks.slice()
        list.unshift({ id: id, title: title, column: col, urgency: "", dueDate: "" })
        root._newCardIds = Object.assign({}, root._newCardIds, { [id]: true })
        root._tasks = list
        _save()
    }

    function _moveTask(id, dir) {
        var list = root._tasks.slice()
        for (var i = 0; i < list.length; i++) {
            if (list[i].id !== id) continue
            var nc = list[i].column + dir
            if (nc < 0 || nc > 2) return
            // Record direction before model changes so new card can read it
            root._entryDirections = Object.assign({}, root._entryDirections, { [id]: dir })
            list[i] = Object.assign({}, list[i], { column: nc })
            break
        }
        root._tasks = list
        _save()
    }

    function _removeTask(id) {
        root._tasks = root._tasks.filter(function(t) { return t.id !== id })
        if (root.delConfirmId === id) root.delConfirmId = -1
        _save()
    }

    // Which column a task id is currently in, or -1 if it no longer exists —
    // looked up before a mutation so the keyboard delete path (below) can
    // hand focus back to the column the task actually came from (UI/UX
    // roadmap v3 Phase 21).
    function _columnOf(id) {
        for (var i = 0; i < root._tasks.length; i++)
            if (root._tasks[i].id === id) return root._tasks[i].column
        return -1
    }

    function _patchTask(id, key, val) {
        var list = root._tasks.slice()
        for (var i = 0; i < list.length; i++) {
            if (list[i].id !== id) continue
            var t = Object.assign({}, list[i]); t[key] = val; list[i] = t; break
        }
        root._tasks = list
        _save()
    }

    // ── Urgency helpers ───────────────────────────────────────────────────────
    function _urgColor(u) {
        if (u === "high")   return Theme.danger
        if (u === "medium") return Theme.warning
        if (u === "low")    return Theme.success
        return "transparent"
    }
    function _urgLabel(u) {
        if (u === "high")   return "High"
        if (u === "medium") return "Med"
        if (u === "low")    return "Low"
        return ""
    }

    // ── Due date helpers ──────────────────────────────────────────────────────
    function _zp2(n) { return n < 10 ? "0" + n : "" + n }

    function _formatDue(s) {
        if (!s || s === "") return ""
        var months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        var now = new Date()
        var todayStr = now.getFullYear() + "-" + _zp2(now.getMonth()+1) + "-" + _zp2(now.getDate())
        var datePart = s.length >= 10 ? s.substring(0, 10) : ""
        var timePart = s.length >= 16 ? s.substring(11, 16) : ""
        var dateLabel = ""
        if (datePart !== "") {
            if (datePart === todayStr) dateLabel = "Today"
            else {
                var dp = datePart.split("-")
                dateLabel = months[parseInt(dp[1]) - 1] + " " + parseInt(dp[2])
            }
        }
        if (dateLabel !== "" && timePart !== "") return dateLabel + "  " + timePart
        if (dateLabel !== "") return dateLabel
        if (timePart !== "") return "Today  " + timePart
        return ""
    }

    // ── Picker helpers ────────────────────────────────────────────────────────
    function _openPicker(taskId) {
        root._pickerLastId = taskId
        root.pickerTaskId  = taskId
        var now = new Date()
        root.pickerYear    = now.getFullYear()
        root.pickerMonth   = now.getMonth()
        root.pickerDay     = 0
        root.pickerHasTime = false
        root.pickerTimeH   = 12
        root.pickerTimeM   = 0

        for (var i = 0; i < root._tasks.length; i++) {
            if (root._tasks[i].id !== taskId) continue
            var s = root._tasks[i].dueDate || ""
            if (s === "") break
            var dp2 = s.length >= 10 ? s.substring(0, 10) : ""
            var tp  = s.length >= 16 ? s.substring(11, 16) : ""
            if (dp2 !== "") {
                var p = dp2.split("-")
                root.pickerYear  = parseInt(p[0])
                root.pickerMonth = parseInt(p[1]) - 1
                root.pickerDay   = parseInt(p[2])
            }
            if (tp !== "") {
                var tParts = tp.split(":")
                root.pickerTimeH   = parseInt(tParts[0]) || 0
                root.pickerTimeM   = parseInt(tParts[1]) || 0
                root.pickerHasTime = true
            }
            break
        }
        _rebuildPickerDays()
    }

    function _rebuildPickerDays() {
        var firstDow   = new Date(root.pickerYear, root.pickerMonth, 1).getDay()
        var daysInMon  = new Date(root.pickerYear, root.pickerMonth + 1, 0).getDate()
        var daysInPrev = new Date(root.pickerYear, root.pickerMonth, 0).getDate()
        var days = []
        for (var p = firstDow - 1; p >= 0; p--)
            days.push({ n: daysInPrev - p, cur: false })
        for (var d = 1; d <= daysInMon; d++)
            days.push({ n: d, cur: true })
        var tail = 42 - days.length
        for (var t = 1; t <= tail; t++)
            days.push({ n: t, cur: false })
        root.pickerDays = days
    }

    onPickerYearChanged:  _rebuildPickerDays()
    onPickerMonthChanged: _rebuildPickerDays()

    onPickerTaskIdChanged: {
        if (root.pickerTaskId >= 0 || root._pickerLastId < 0) return
        const id = root._pickerLastId, byKey = root._pickerByKey
        root._pickerLastId = -1
        root._pickerByKey  = false
        if (!byKey) return
        const col = root._columnOf(id)
        const t = col >= 0 ? colRepeater.itemAt(col) : null
        if (!t) return
        t._curId = id
        const c = t._cardFor(id)
        if (c) c.focusDue()
        else   t.flick.forceActiveFocus()
    }

    function _commitPicker() {
        if (root.pickerTaskId < 0) return
        var datePart = "", timePart = ""
        if (root.pickerDay > 0) {
            var m = root.pickerMonth + 1
            datePart = root.pickerYear + "-" + _zp2(m) + "-" + _zp2(root.pickerDay)
        }
        if (root.pickerHasTime)
            timePart = _zp2(root.pickerTimeH) + ":" + _zp2(root.pickerTimeM)

        var result = ""
        if (datePart !== "" && timePart !== "") result = datePart + " " + timePart
        else if (datePart !== "") result = datePart
        else if (timePart !== "") {
            var now = new Date()
            result = now.getFullYear() + "-" + _zp2(now.getMonth()+1) + "-" + _zp2(now.getDate())
                     + " " + timePart
        }
        _patchTask(root.pickerTaskId, "dueDate", result)
        root.pickerTaskId = -1
    }

    // ── Delete keyboard handler ───────────────────────────────────────────────
    // Grabs focus when delete confirm opens; Enter = delete, Esc = cancel.
    // Both branches look the task's column up BEFORE mutating anything, then
    // hand focus back to that column's list — this Item itself is never a Tab
    // stop, so without this, confirming or cancelling by keyboard left focus
    // stranded on an invisible Item (UI/UX roadmap v3 Phase 21).
    Item {
        id: deleteKeyHandler
        Keys.onReturnPressed: function(ev) {
            if (root.delConfirmId >= 0) {
                const id  = root.delConfirmId
                const col = root._columnOf(id)
                ev.accepted = true
                const t = col >= 0 ? colRepeater.itemAt(col) : null
                if (t) t._removeCard(id)
                else   root._removeTask(id)
            }
        }
        Keys.onEscapePressed: function(ev) {
            if (root.delConfirmId >= 0) {
                const id  = root.delConfirmId
                const col = root._columnOf(id)
                root.delConfirmId = -1
                ev.accepted = true
                const t = col >= 0 ? colRepeater.itemAt(col) : null
                if (t) t.flick.forceActiveFocus()
            }
        }
    }

    onDelConfirmIdChanged: {
        if (delConfirmId >= 0) deleteKeyHandler.forceActiveFocus()
    }

    // ── Column defs ───────────────────────────────────────────────────────────
    readonly property var colDefs: [
        { idx: 0, label: "To Do"   },
        { idx: 1, label: "Ongoing" },
        { idx: 2, label: "Done"    }
    ]

    // ── Column layout ─────────────────────────────────────────────────────────
    Row {
        id: mainRow
        anchors.fill: parent
        anchors.topMargin: 8
        spacing: 8

        Repeater {
            id: colRepeater
            model: root.colDefs

            delegate: Item {
                id: colItem
                required property var modelData

                readonly property int    cIdx:   modelData.idx
                readonly property string cLabel: modelData.label
                readonly property var    cTasks: {
                    var ci = cIdx
                    return root._tasks.filter(function(t) { return t.column === ci })
                }

                property bool draftOpen: false

                // ── Keyboard (UI/UX roadmap v3 Phase 21) ─────────────────────────
                // This column's card list is ONE Tab stop; _curId is the highlighted
                // card's stable task id. -1 means "nothing highlighted" — 0 is a
                // REAL task id (root._nextId starts at 0), so 0 cannot double as the
                // empty sentinel the way it could look like it should.
                property int _curId: -1
                property alias flick: taskFlick

                function _idList() { return colItem.cTasks.map(function(t) { return t.id }) }
                function _stepCard(d) {
                    const list = colItem._idList()
                    if (list.length === 0) return
                    const i = list.indexOf(colItem._curId)
                    colItem._curId = i < 0 ? list[d > 0 ? 0 : list.length - 1]
                                           : list[Math.max(0, Math.min(list.length - 1, i + d))]
                }
                function _cardFor(id) {
                    for (let i = 0; i < taskRepeater.count; i++) {
                        const c = taskRepeater.itemAt(i)
                        if (c && c.taskData && c.taskData.id === id) return c
                    }
                    return null
                }
                // Moves a card to the adjacent column — exactly the call the card's
                // own ◀ / ▶ buttons make — and keeps it highlighted by handing that
                // column's list the focus. Ctrl+Left/Right and the buttons both call
                // this; it takes the id explicitly rather than reading _curId because
                // a card's buttons stay reachable (via card.open) even when a
                // DIFFERENT card is the column's highlighted one.
                function _moveCardTo(id, dir) {
                    const nc = colItem.cIdx + dir
                    if (nc < 0 || nc > 2) return
                    root._moveTask(id, dir)
                    const target = colRepeater.itemAt(nc)
                    if (target) { target._curId = id; target.flick.forceActiveFocus() }
                }
                // Which id should take the highlight once `id` is gone — the next
                // card, or the previous if `id` was last (HistoryTab's removeEntry
                // pattern) — picked before the removal so onActiveFocusChanged never
                // has to guess afterwards.
                function _pickNextAfterRemoval(id) {
                    const list = colItem._idList()
                    const i = list.indexOf(id)
                    if (i < 0) return -1
                    return i + 1 < list.length ? list[i + 1] : (i > 0 ? list[i - 1] : -1)
                }
                function _removeCard(id) {
                    colItem._curId = colItem._pickNextAfterRemoval(id)
                    root._removeTask(id)
                    colItem.flick.forceActiveFocus()
                }

                width:  (mainRow.width - mainRow.spacing * 2) / 3
                height: parent.height

                Rectangle {
                    anchors.fill: parent; radius: theme.cornerRadius
                    color:        Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.03)
                    border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07); border.width: 1
                }

                Column {
                    anchors { fill: parent; margins: 10 }
                    spacing: 8

                    // Header
                    Item {
                        width: parent.width; height: 26

                        Row {
                            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                            spacing: 7
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: colItem.cLabel; color: Theme.active
                                font.pixelSize: theme.fs(12); font.weight: Font.DemiBold
                            }
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: cntT.implicitWidth + 10; height: 16; radius: 8
                                color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.12)
                                Text {
                                    id: cntT; anchors.centerIn: parent
                                    text: colItem.cTasks.length
                                    color: Theme.active; font.pixelSize: theme.fs(9); font.weight: Font.Bold
                                }
                            }
                        }

                        // Add (+) button — column-level, an ordinary Tab stop.
                        ApexPressable {
                            id: addBtn
                            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                            width: 22; height: 22; radius: 6; hitMargin: 5
                            Accessible.name: "Add task to " + colItem.cLabel
                            onActivated: { colItem.draftOpen = true; draftTimer.restart() }
                            Rectangle {
                                anchors.fill: parent; radius: parent.radius
                                color: addBtn.hovered
                                    ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.18)
                                    : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.05)
                                border.color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.20)
                                border.width: 1
                                Behavior on color { MotionColor { role: "state" } }
                            }
                            Text { anchors.centerIn: parent; text: "+"; color: Theme.active; font.pixelSize: theme.fs(15) }
                            ApexFocusRing { target: addBtn }
                        }
                    }

                    Rectangle { width: parent.width; height: 1; color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07) }

                    Timer {
                        id: draftTimer; interval: 50
                        onTriggered: if (colItem.draftOpen) draftInput.forceActiveFocus()
                    }

                    // Content area
                    Item {
                        width:  parent.width
                        height: parent.height - 26 - 1 - parent.spacing * 2

                        // Draft card — slides in from top
                        Item {
                            id: draftWrap; z: 2; width: parent.width
                            height: colItem.draftOpen ? draftRect.implicitHeight + 6 : 0
                            clip:   true
                            Behavior on height { MotionMove { role: "surfaceEnterSmall" } }

                            Rectangle {
                                id: draftRect
                                anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 3 }
                                radius: 8
                                color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.06)
                                border.color: draftInput.activeFocus
                                    ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.50)
                                    : Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.22)
                                border.width: 1
                                implicitHeight: draftInput.contentHeight + 24
                                Behavior on border.color { MotionColor { role: "state" } }

                                Text {
                                    anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                                    visible: draftInput.text === ""
                                    text: "Task title…"; color: Theme.textTertiary; font.pixelSize: theme.fs(12)
                                }

                                TextInput {
                                    id: draftInput
                                    activeFocusOnTab: colItem.draftOpen
                                    anchors { left: parent.left; right: parent.right; leftMargin: 10; rightMargin: 10; verticalCenter: parent.verticalCenter }
                                    color: Theme.text; font.pixelSize: theme.fs(12)
                                    wrapMode: TextInput.WordWrap
                                    selectionColor: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.35)

                                    function commit() {
                                        var t = text.trim()
                                        if (t !== "") root._addTask(colItem.cIdx, t)
                                        colItem.draftOpen = false; text = ""
                                        root.forceActiveFocus()
                                    }

                                    Keys.onReturnPressed: function(ev) { commit(); ev.accepted = true }
                                    Keys.onEscapePressed: function(ev) { colItem.draftOpen = false; text = ""; ev.accepted = true; root.forceActiveFocus() }
                                    onActiveFocusChanged: if (!activeFocus && colItem.draftOpen) commit()
                                }
                            }
                        }

                        // Task list — ONE Tab stop for the whole column (UI/UX
                        // roadmap v3 Phase 21). Up/Down move the highlight, Return
                        // toggles the highlighted card's extra fields (what its own
                        // ▾/▴ does), Ctrl+Left/Right move it a column over, Delete
                        // starts its delete confirmation — the same calls the card's
                        // own buttons make. A column with no cards is not a Tab stop.
                        Flickable {
                            id: taskFlick
                            anchors.top:       draftWrap.bottom
                            // 3 px past the column on every side, the cards inset by
                            // the same 3: they sit where they did, and the clip
                            // leaves room for the highlighted card's ring.
                            anchors.left:      parent.left
                            anchors.right:     parent.right
                            anchors.leftMargin:  -3
                            anchors.rightMargin: -3
                            anchors.topMargin: (colItem.draftOpen ? 4 : 0) - 3
                            height:            parent.height - draftWrap.height - (colItem.draftOpen ? 4 : 0) + 6
                            contentWidth:      width
                            contentHeight:     taskCol.implicitHeight + 10
                            clip:              true
                            boundsBehavior:    Flickable.StopAtBounds

                            activeFocusOnTab: colItem.cTasks.length > 0
                            Accessible.role: Accessible.List
                            Accessible.name: colItem.cLabel
                            onActiveFocusChanged: if (activeFocus && colItem._idList().indexOf(colItem._curId) < 0) colItem._stepCard(1)
                            Keys.onPressed: function (event) {
                                if      (event.key === Qt.Key_Down) colItem._stepCard(1)
                                else if (event.key === Qt.Key_Up)   colItem._stepCard(-1)
                                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                    const c = colItem._cardFor(colItem._curId)
                                    if (c) c.primary()
                                } else if (event.key === Qt.Key_Left && (event.modifiers & Qt.ControlModifier)) {
                                    if (colItem._curId >= 0) colItem._moveCardTo(colItem._curId, -1)
                                } else if (event.key === Qt.Key_Right && (event.modifiers & Qt.ControlModifier)) {
                                    if (colItem._curId >= 0) colItem._moveCardTo(colItem._curId, 1)
                                } else if (event.key === Qt.Key_Delete) {
                                    const c = colItem._cardFor(colItem._curId)
                                    if (c) c.startDelete()
                                } else return
                                event.accepted = true
                                // Keep the highlighted card in view.
                                const r = colItem._cardFor(colItem._curId)
                                if (r) {
                                    const top = r.mapToItem(taskFlick.contentItem, 0, 0).y - 3
                                    const bot = top + r.height + 6
                                    if (top < taskFlick.contentY) taskFlick.contentY = Math.max(0, top)
                                    else if (bot > taskFlick.contentY + taskFlick.height)
                                        taskFlick.contentY = bot - taskFlick.height
                                }
                            }

                            Column {
                                id: taskCol
                                x: 3; y: 3
                                width: parent.width - 6; spacing: 6

                                Repeater {
                                    id: taskRepeater
                                    model: colItem.cTasks
                                    delegate: TaskCard {
                                        required property var modelData
                                        width:    parent.width
                                        taskData: modelData
                                        colIdx:   colItem.cIdx
                                        col:      colItem
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Picker dim overlay ────────────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent; z: 29
        visible: root.pickerTaskId >= 0
        color:   Qt.rgba(0, 0, 0, 0.35)
        MouseArea { anchors.fill: parent; onClicked: root.pickerTaskId = -1 }
    }

    // ── Date / time picker popup ──────────────────────────────────────────────
    Rectangle {
        id: datePicker
        z:              30
        anchors.centerIn: parent
        visible:        root.pickerTaskId >= 0

        width:  230
        height: pickerCol.implicitHeight + 24
        radius: theme.cornerRadius
        color: Qt.rgba(
            Math.min(1, Theme.background.r + 0.06),
            Math.min(1, Theme.background.g + 0.06),
            Math.min(1, Theme.background.b + 0.06), 0.98)
        border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.15); border.width: 1

        // Swallow clicks so they don't reach the dim overlay below
        MouseArea { anchors.fill: parent; onClicked: {} }

        // On the keyboard: a keyboard open lands on the day grid, Tab stays
        // inside (Done wraps to ‹, ‹ back to Done), Escape closes it.
        onVisibleChanged: if (visible && root._pickerByKey) Qt.callLater(function () { dayGrid.forceActiveFocus() })
        Keys.onEscapePressed: function (event) { root.pickerTaskId = -1; event.accepted = true }

        Column {
            id: pickerCol
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
            spacing: 8

            // ── Month nav ──────────────────────────────────────────────────────
            Item {
                width: parent.width; height: 22
                ApexPressable {
                    id: prevMonthBtn
                    anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                    width: 20; height: 20; hitMargin: 6
                    KeyNavigation.backtab: doneBtn
                    Accessible.name: "Previous month"
                    onActivated: {
                        if (root.pickerMonth === 0) { root.pickerMonth = 11; root.pickerYear-- }
                        else root.pickerMonth--
                    }
                    Text {
                        anchors.centerIn: parent
                        text: "‹"; font.pixelSize: theme.fs(17)
                        color: prevMonthBtn.hovered ? Theme.textPrimary : Theme.textTertiary
                        Behavior on color { MotionColor {} }
                    }
                    ApexFocusRing { target: prevMonthBtn }
                }
                Text {
                    anchors.centerIn: parent
                    text:  root._monthNames[root.pickerMonth].substring(0,3) + "  " + root.pickerYear
                    color: Theme.text; font.pixelSize: theme.fs(11); font.weight: Font.DemiBold
                }
                ApexPressable {
                    id: nextMonthBtn
                    anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                    width: 20; height: 20; hitMargin: 6
                    Accessible.name: "Next month"
                    onActivated: {
                        if (root.pickerMonth === 11) { root.pickerMonth = 0; root.pickerYear++ }
                        else root.pickerMonth++
                    }
                    Text {
                        anchors.centerIn: parent
                        text: "›"; font.pixelSize: theme.fs(17)
                        color: nextMonthBtn.hovered ? Theme.textPrimary : Theme.textTertiary
                        Behavior on color { MotionColor {} }
                    }
                    ApexFocusRing { target: nextMonthBtn }
                }
            }

            // ── Day-of-week headers ────────────────────────────────────────────
            Item {
                width: parent.width; height: 14
                Row {
                    anchors.fill: parent
                    Repeater {
                        model: root._dowNames
                        delegate: Text {
                            width: Math.floor(parent.parent.width / 7)
                            horizontalAlignment: Text.AlignHCenter
                            text: modelData; font.pixelSize: theme.fs(8); font.weight: Font.Bold
                            color: Theme.textTertiary
                        }
                    }
                }
            }

            // ── Day grid ──────────────────────────────────────────────────────
            Grid {
                id: dayGrid
                width: parent.width; columns: 7; rows: 6
                readonly property real cW: width / 7
                readonly property real cH: 24

                // ONE Tab stop, as a date picker is: Left/Right a day, Up/Down
                // a week (both cross into the next month), Page Up/Down a month,
                // Home/End the month's ends, Return is Done. Before a day is
                // chosen the ring sits on today (or the 1st) and nothing is
                // selected — Tabbing past the grid must not pick a date.
                activeFocusOnTab: true
                Accessible.role: Accessible.List
                Accessible.name: "Day"
                Accessible.description: root.pickerDay > 0
                    ? root.pickerDay + " " + root._monthNames[root.pickerMonth] + " " + root.pickerYear
                    : "No day chosen"
                readonly property int cursorDay: {
                    if (root.pickerDay > 0) return root.pickerDay
                    const now = new Date()
                    return now.getFullYear() === root.pickerYear && now.getMonth() === root.pickerMonth
                           ? now.getDate() : 1
                }
                function _goto(t) {
                    root.pickerYear  = t.getFullYear()
                    root.pickerMonth = t.getMonth()
                    root.pickerDay   = t.getDate()
                }
                Keys.onPressed: function (event) {
                    const dim = new Date(root.pickerYear, root.pickerMonth + 1, 0).getDate()
                    const d   = root.pickerDay > 0 ? root.pickerDay : dayGrid.cursorDay
                    const k   = event.key
                    const step = k === Qt.Key_Right ? 1 : k === Qt.Key_Left ? -1
                               : k === Qt.Key_Down  ? 7 : k === Qt.Key_Up   ? -7 : 0
                    if (step !== 0)
                        dayGrid._goto(new Date(root.pickerYear, root.pickerMonth,
                                               root.pickerDay > 0 ? d + step : d))
                    else if (k === Qt.Key_PageUp || k === Qt.Key_PageDown) {
                        const m = new Date(root.pickerYear, root.pickerMonth + (k === Qt.Key_PageDown ? 1 : -1), 1)
                        const mdim = new Date(m.getFullYear(), m.getMonth() + 1, 0).getDate()
                        dayGrid._goto(new Date(m.getFullYear(), m.getMonth(), Math.min(d, mdim)))
                    }
                    else if (k === Qt.Key_Home) root.pickerDay = 1
                    else if (k === Qt.Key_End)  root.pickerDay = dim
                    else if (k === Qt.Key_Return || k === Qt.Key_Enter) root._commitPicker()
                    else return
                    event.accepted = true
                }

                Repeater {
                    model: root.pickerDays
                    delegate: ApexPressable {
                        id: dayBtn
                        required property var modelData
                        required property int index
                        width: dayGrid.cW; height: dayGrid.cH
                        radius: Math.min(dayGrid.cW, dayGrid.cH) / 2   // matches the circular hit target, for the focus ring
                        interactive: modelData.cur
                        // ApexPressable dims a non-interactive control to 0.38 opacity
                        // (it means "disabled" there); here it just means "not this
                        // month", which the original always drew at full opacity —
                        // only the digit's colour dims. Cancelled so the look doesn't
                        // change. Packed 7-wide, so no hitMargin — an enlarged hit
                        // area here would just steal clicks from the next cell.
                        opacity: 1
                        activeFocusOnTab: false     // the grid is the one stop
                        Accessible.name: modelData.cur ? ("" + modelData.n) : ""
                        onActivated: root.pickerDay = modelData.n

                        readonly property bool isSel: modelData.cur && modelData.n === root.pickerDay
                        readonly property bool isNow: {
                            var n = new Date()
                            return modelData.cur &&
                                   modelData.n   === n.getDate() &&
                                   root.pickerMonth === n.getMonth() &&
                                   root.pickerYear  === n.getFullYear()
                        }

                        Rectangle {
                            anchors.centerIn: parent
                            width: Math.min(dayGrid.cW, dayGrid.cH) - 2; height: width; radius: width / 2
                            color: dayBtn.isSel
                                ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.82)
                                : dayBtn.isNow ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.12)
                                        : dayBtn.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.08) : "transparent"
                            border.color: dayBtn.isNow && !dayBtn.isSel ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.35) : "transparent"
                            border.width: 1
                            Behavior on color { MotionColor { role: "state" } }

                            Text {
                                anchors.centerIn: parent
                                text: dayBtn.modelData.n
                                font.pixelSize: theme.fs(9); font.weight: dayBtn.isSel ? Font.Bold : Font.Normal
                                color: dayBtn.isSel ? Theme.background
                                    : dayBtn.modelData.cur ? Theme.textPrimary : Theme.textTertiary
                            }
                        }
                        Rectangle {
                            anchors.centerIn: parent
                            width: Math.min(dayGrid.cW, dayGrid.cH) + 2; height: width; radius: width / 2
                            color: "transparent"; border.width: 2; border.color: Theme.accentText
                            visible: dayGrid.activeFocus && dayBtn.modelData.cur && dayBtn.modelData.n === dayGrid.cursorDay
                        }
                    }
                }
            }

            Rectangle { width: parent.width; height: 1; color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.08) }

            // ── Time row ──────────────────────────────────────────────────────
            Item {
                width: parent.width; height: timeInner.implicitHeight

                Row {
                    id: timeInner
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 10

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "⏰"; font.pixelSize: theme.fs(13)
                    }

                    // Controls when time is set
                    Row {
                        spacing: 4; visible: root.pickerHasTime
                        anchors.verticalCenter: parent.verticalCenter

                        // ── Hour col ──────────────────────────────────────────
                        Column {
                            spacing: 2; anchors.verticalCenter: parent.verticalCenter
                            ApexPressable {
                                id: hourUpBtn
                                width: 26; height: 18; radius: 4; hitMargin: 1   // 2px Column spacing either side
                                Accessible.name: "Increase hour"
                                onActivated: root.pickerTimeH = (root.pickerTimeH + 1) % 24
                                Rectangle {
                                    anchors.fill: parent; radius: parent.radius
                                    color: hourUpBtn.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.12) : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.05)
                                    border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10); border.width: 1
                                    Behavior on color { MotionColor {} }
                                }
                                Text { anchors.centerIn: parent; text: "▲"; font.pixelSize: theme.fs(7); color: Theme.textSecondary }
                                ApexFocusRing { target: hourUpBtn }
                            }
                            Rectangle {
                                width: 26; height: 24; radius: 4
                                color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07); border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10); border.width: 1
                                Text {
                                    anchors.centerIn: parent
                                    text: root._zp2(root.pickerTimeH)
                                    font.pixelSize: theme.fs(13); font.family: "JetBrains Mono"; font.weight: Font.Bold
                                    color: Theme.active
                                }
                            }
                            ApexPressable {
                                id: hourDownBtn
                                width: 26; height: 18; radius: 4; hitMargin: 1
                                Accessible.name: "Decrease hour"
                                onActivated: root.pickerTimeH = (root.pickerTimeH + 23) % 24
                                Rectangle {
                                    anchors.fill: parent; radius: parent.radius
                                    color: hourDownBtn.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.12) : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.05)
                                    border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10); border.width: 1
                                    Behavior on color { MotionColor {} }
                                }
                                Text { anchors.centerIn: parent; text: "▼"; font.pixelSize: theme.fs(7); color: Theme.textSecondary }
                                ApexFocusRing { target: hourDownBtn }
                            }
                        }

                        Text { anchors.verticalCenter: parent.verticalCenter; text: ":"; font.pixelSize: theme.fs(15); font.weight: Font.Bold; color: Theme.text }

                        // ── Minute col ────────────────────────────────────────
                        Column {
                            spacing: 2; anchors.verticalCenter: parent.verticalCenter
                            ApexPressable {
                                id: minUpBtn
                                width: 26; height: 18; radius: 4; hitMargin: 1
                                Accessible.name: "Increase minute"
                                onActivated: root.pickerTimeM = (root.pickerTimeM + 5) % 60
                                Rectangle {
                                    anchors.fill: parent; radius: parent.radius
                                    color: minUpBtn.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.12) : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.05)
                                    border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10); border.width: 1
                                    Behavior on color { MotionColor {} }
                                }
                                Text { anchors.centerIn: parent; text: "▲"; font.pixelSize: theme.fs(7); color: Theme.textSecondary }
                                ApexFocusRing { target: minUpBtn }
                            }
                            Rectangle {
                                width: 26; height: 24; radius: 4
                                color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07); border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10); border.width: 1
                                Text {
                                    anchors.centerIn: parent
                                    text: root._zp2(root.pickerTimeM)
                                    font.pixelSize: theme.fs(13); font.family: "JetBrains Mono"; font.weight: Font.Bold
                                    color: Theme.active
                                }
                            }
                            ApexPressable {
                                id: minDownBtn
                                width: 26; height: 18; radius: 4; hitMargin: 1
                                Accessible.name: "Decrease minute"
                                onActivated: root.pickerTimeM = (root.pickerTimeM + 55) % 60
                                Rectangle {
                                    anchors.fill: parent; radius: parent.radius
                                    color: minDownBtn.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.12) : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.05)
                                    border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10); border.width: 1
                                    Behavior on color { MotionColor {} }
                                }
                                Text { anchors.centerIn: parent; text: "▼"; font.pixelSize: theme.fs(7); color: Theme.textSecondary }
                                ApexFocusRing { target: minDownBtn }
                            }
                        }

                        // Clear time ✕
                        ApexPressable {
                            id: clearTimeBtn
                            anchors.verticalCenter: parent.verticalCenter
                            width: 18; height: 18; radius: 9; hitMargin: 2
                            Accessible.name: "Remove time"
                            onActivated: root.pickerHasTime = false
                            Rectangle {
                                anchors.fill: parent; radius: parent.radius
                                color: clearTimeBtn.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.14) : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.05)
                                Behavior on color { MotionColor {} }
                            }
                            Text { anchors.centerIn: parent; text: "✕"; font.pixelSize: theme.fs(8); color: Theme.textSecondary }
                            ApexFocusRing { target: clearTimeBtn }
                        }
                    }

                    // "Add time" pill (shown when no time set)
                    ApexPressable {
                        id: addTimeBtn
                        visible: !root.pickerHasTime
                        anchors.verticalCenter: parent.verticalCenter
                        width: addTL.implicitWidth + 18; height: 24; radius: 12; hitMargin: 4
                        Accessible.name: "Add time"
                        onActivated: { root.pickerHasTime = true; root.pickerTimeH = 12; root.pickerTimeM = 0 }
                        Rectangle {
                            anchors.fill: parent; radius: parent.radius
                            color: addTimeBtn.hovered
                                ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.15)
                                : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.06)
                            border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10); border.width: 1
                            Behavior on color { MotionColor {} }
                        }
                        Text {
                            id: addTL; anchors.centerIn: parent
                            text: "Add time"; font.pixelSize: theme.fs(10)
                            color: addTimeBtn.hovered ? Theme.active : Theme.textSecondary
                            Behavior on color { MotionColor {} }
                        }
                        ApexFocusRing { target: addTimeBtn }
                    }
                }
            }

            Rectangle { width: parent.width; height: 1; color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.08) }

            // ── Clear / Done ───────────────────────────────────────────────────
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 10; bottomPadding: 0

                ApexPressable {
                    id: pickerClearBtn
                    width: 86; height: 28; radius: 8; hitMargin: 2
                    Accessible.name: "Clear due date"
                    onActivated: { root._patchTask(root.pickerTaskId, "dueDate", ""); root.pickerTaskId = -1 }
                    Rectangle {
                        anchors.fill: parent; radius: parent.radius
                        color: pickerClearBtn.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10) : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.05)
                        border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10); border.width: 1
                        Behavior on color { MotionColor {} }
                    }
                    Text { anchors.centerIn: parent; text: "Clear"; font.pixelSize: theme.fs(11); color: Theme.textSecondary }
                    ApexFocusRing { target: pickerClearBtn }
                }

                ApexPressable {
                    id: doneBtn
                    width: 86; height: 28; radius: 8; hitMargin: 2
                    KeyNavigation.tab: prevMonthBtn
                    Accessible.name: "Save due date"
                    onActivated: root._commitPicker()
                    Rectangle {
                        anchors.fill: parent; radius: parent.radius
                        color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, doneBtn.hovered ? 0.28 : 0.16)
                        border.color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.38); border.width: 1
                        Behavior on color { MotionColor {} }
                    }
                    Text {
                        anchors.centerIn: parent; text: "Done"
                        font.pixelSize: theme.fs(11); font.weight: Font.Medium; color: Theme.active
                    }
                    ApexFocusRing { target: doneBtn }
                }
            }
        }
    }

    // ── TaskCard ──────────────────────────────────────────────────────────────
    component TaskCard: Item {
        id: card

        property var taskData
        property int colIdx
        // The enclosing column delegate (UI/UX roadmap v3 Phase 21) — passed in
        // rather than looked up by id, since this component is defined at file
        // scope and has no id-scope access to "colItem" from inside its own body.
        property Item col: null

        readonly property bool showExtra: !!root._expanded[card.taskData.id]
        property real xEntry:    0
        property real dragX:     0

        readonly property bool isDelConfirm: root.delConfirmId === taskData.id

        // Highlighted by the keyboard: its buttons join the Tab order. "open"
        // covers the one inline panel a card has (its extra fields) — mirrors
        // WifiTab's netRow.keyed / netRow.open.
        readonly property bool keyed: card.col !== null && card.col._curId === card.taskData.id
        readonly property bool open:  card.showExtra

        Accessible.role: Accessible.ListItem
        Accessible.name: card.taskData.title

        // What Return on the column list does, and what the ▾/▴ button does —
        // there is no "click the card body" handler today, so the expand
        // chevron is the only existing analogue of "clicking its body".
        function primary() { root._setExpanded(card.taskData.id, !card.showExtra) }
        // What the ✕ delete button does; Delete on the column list too.
        function startDelete() { root.delConfirmId = card.taskData.id }
        // Where a keyboard-opened date picker hands focus back.
        function focusDue() { dueBtn.forceActiveFocus() }
        function focusControl(what, arg) {
            if (what === "urgency") { const b = urgRepeater.itemAt(arg); if (b) b.forceActiveFocus() }
            else if (what === "title") titleInput.forceActiveFocus()
            else dueBtn.forceActiveFocus()
        }

        height: cardBg.implicitHeight + 2

        transform: [
            Translate { x: card.dragX + card.xEntry },
            // Tilt: the card leans a little toward where it is being dragged.
            // Bound straight to dragX, with no animation of its own: while the
            // pointer owns the drag the lean follows the finger, and on release
            // it settles back with dragX's own return (snapAnim), so the two can
            // never disagree. It used to sit on an underdamped spring and wobble.
            Rotation {
                origin.x: card.width / 2; origin.y: card.height / 2
                axis { x: 0; y: 1; z: 0 }
                angle: (card.dragX / 65.0) * -5
            }
        ]

        // Lift: the card compresses slightly while it is held, on the press
        // tokens so grabbing it answers as fast as pressing a button does.
        scale: dragHandler.active ? 0.97 : 1.0
        Behavior on scale {
            MotionMove {
                role:  dragHandler.active ? "pressIn" : "pressOut"
                curve: Motion.fastSpatial
            }
        }

        // Column jumps and reflow glide rather than teleport — as a stack
        // settles, without the overshoot the old underdamped springs had.
        Behavior on x { MotionMove { role: "notificationShift" } }
        Behavior on y { MotionMove { role: "notificationShift" } }

        // ── Entry animation ────────────────────────────────────────────────────
        // New cards: no x offset (draft gives enough visual feedback).
        // Moved cards: appear at ±36px in move direction, spring to 0.
        Component.onCompleted: {
            var id = card.taskData.id
            if (root._newCardIds[id]) {
                delete root._newCardIds[id]
                // No extra animation — draft open/close is the creation affordance
            } else if (root._entryDirections[id] !== undefined) {
                var dir = root._entryDirections[id]
                delete root._entryDirections[id]
                // dir=1 (moved right) → the card arrives from the left of its
                // new place; dir=-1 from the right. No offset under Reduce Motion.
                card.xEntry = dir * Motion.travel(24)
                xSpringAnim.restart()
            }
        }

        // Settle into place, decelerating — the arrival of a moved card.
        NumberAnimation {
            id: xSpringAnim
            target:   card; property: "xEntry"; to: 0
            duration: Motion.surfaceEnterSmall
            easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.emphasizedDecel
        }

        // ── Swipe to move ─────────────────────────────────────────────────────
        DragHandler {
            id: dragHandler
            target: null
            xAxis.enabled: true; yAxis.enabled: false; dragThreshold: 12
            
            onActiveChanged: {
                if (!active) {
                    var d = card.dragX; snapAnim.start()
                    var dir = d > 0 ? 1 : -1
                    if (Math.abs(d) > 50 && card.colIdx + dir >= 0 && card.colIdx + dir <= 2)
                        root._moveTask(card.taskData.id, dir)
                }
            }
            onTranslationChanged: {
                if (active) card.dragX = Math.max(-65, Math.min(65, translation.x))
            }
        }

        // Release: the card returns from wherever the pointer let go of it,
        // decelerating into place. (It used to snap back on an elastic curve
        // and wobble; APEX's physics is continuity, not bounce.)
        NumberAnimation {
            id: snapAnim; target: card; property: "dragX"; to: 0
            duration: Motion.selection
            easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.fastSpatial
        }

        // Dynamic Glow: stronger, smoother color tinting
        readonly property real dragAmt:  Math.abs(dragX) / 65.0
        readonly property color dragTint: {
            if (dragX >  2) return Qt.rgba(Theme.success.r, Theme.success.g, Theme.success.b, dragAmt * 0.35)
            if (dragX < -2) return Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, dragAmt * 0.35)
            return "transparent"
        }

        // ── Card body ─────────────────────────────────────────────────────────
        Rectangle {
            id: cardBg
            width: parent.width; radius: 8
            color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.05)
            border.color: {
                var u = card.taskData.urgency
                if (u === "high")   return Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.45)
                if (u === "medium") return Qt.rgba(Theme.warning.r, Theme.warning.g, Theme.warning.b, 0.35)
                if (u === "low")    return Qt.rgba(Theme.success.r, Theme.success.g, Theme.success.b, 0.35)
                return Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10)
            }
            border.width: 1
            Behavior on border.color { MotionColor { role: "state" } }
            implicitHeight: body.implicitHeight + 18

            // Keyboard highlight ring — cardBg has no clip: true, so an outset
            // ring (like WifiTab's) is safe here; nothing crops it.
            Rectangle {
                anchors.fill: parent; anchors.margins: -3
                radius: cardBg.radius + 3
                color: "transparent"; border.width: 2; border.color: Theme.accentText
                visible: card.keyed && card.col !== null && card.col.flick.activeFocus
            }

            // Drag direction tint
            Rectangle {
                anchors.fill: parent; radius: parent.radius; color: card.dragTint
                Behavior on color { MotionColor { role: "state" } }
            }

            Column {
                id: body
                anchors { left: parent.left; right: parent.right; leftMargin: 10; rightMargin: 10; top: parent.top; topMargin: 9 }
                spacing: 6

                // Title (inline edit). Not an unconditional Tab stop (rule of thumb
                // elsewhere in this pass is "raw TextInputs get activeFocusOnTab:
                // true") — it is always rendered, so that would make every card in
                // every column its own Tab stop and defeat "one Tab stop per
                // column". Gated like the card's other buttons instead.
                TextInput {
                    id: titleInput
                    width: parent.width
                    activeFocusOnTab: card.keyed || card.open
                    text:           card.taskData.title
                    color:          Theme.text; font.pixelSize: theme.fs(12); font.weight: Font.Medium
                    wrapMode:       TextInput.WordWrap
                    selectionColor: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.35)
                    onEditingFinished: {
                        var t = text.trim()
                        if (t === "" || t === card.taskData.title) return
                        if (titleInput.activeFocus) root._refocus(card.taskData.id, "title")
                        root._patchTask(card.taskData.id, "title", t)
                    }
                }

                // Badges row
                Row {
                    visible: card.taskData.urgency !== "" || (card.taskData.dueDate || "") !== ""
                    spacing: 6
                    Rectangle {
                        visible: card.taskData.urgency !== ""
                        anchors.verticalCenter: parent.verticalCenter
                        width: urgL.implicitWidth + 12; height: 16; radius: 8
                        color: root._urgColor(card.taskData.urgency); opacity: 0.85
                        Text { id: urgL; anchors.centerIn: parent; text: root._urgLabel(card.taskData.urgency); font.pixelSize: theme.fs(9); font.weight: Font.Bold; color: Theme.fixedDark }
                    }
                    Row {
                        visible: (card.taskData.dueDate || "") !== ""
                        anchors.verticalCenter: parent.verticalCenter; spacing: 3
                        Text { text: "📅"; font.pixelSize: theme.fs(9) }
                        Text { text: root._formatDue(card.taskData.dueDate || ""); font.pixelSize: theme.fs(9); color: Theme.textSecondary }
                    }
                }

                // Expandable extra fields
                Column {
                    visible: card.showExtra; width: parent.width; spacing: 6

                    // Urgency picker
                    Row {
                        spacing: 5
                        Text { anchors.verticalCenter: parent.verticalCenter; text: "Urgency"; font.pixelSize: theme.fs(9); color: Theme.textSecondary }
                        Repeater {
                            id: urgRepeater
                            model: ["", "low", "medium", "high"]
                            delegate: ApexPressable {
                                id: urgBtn
                                required property string modelData
                                required property int index
                                property bool sel: card.taskData.urgency === modelData
                                width: uT.implicitWidth + 12; height: 17; radius: 9
                                hitMargin: 2   // Row spacing is 5 — a full ~7px margin would overlap the next chip
                                activeFocusOnTab: card.keyed || card.open
                                Accessible.name: "Urgency " + (modelData === "" ? "None" : modelData)
                                // Refocus first: the patch rebuilds the cards
                                // synchronously, and this handler's context dies
                                // with this chip (root reads undefined after it).
                                onActivated: {
                                    if (urgBtn.focusVisible) root._refocus(card.taskData.id, "urgency", index)
                                    root._patchTask(card.taskData.id, "urgency", modelData)
                                }
                                Rectangle {
                                    anchors.fill: parent; radius: parent.radius
                                    color: urgBtn.sel ? (urgBtn.modelData === "" ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.15) : root._urgColor(urgBtn.modelData))
                                               : (urgBtn.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10) : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.05))
                                    border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, urgBtn.sel ? 0.20 : 0.08); border.width: 1
                                    Behavior on color { MotionColor { role: "state" } }
                                }
                                Text {
                                    id: uT; anchors.centerIn: parent; font.pixelSize: theme.fs(9)
                                    text: urgBtn.modelData === "" ? "None" : urgBtn.modelData.charAt(0).toUpperCase() + urgBtn.modelData.slice(1)
                                    color: (urgBtn.sel && urgBtn.modelData !== "") ? Theme.fixedDark : Theme.textSecondary
                                }
                                ApexFocusRing { target: urgBtn }
                            }
                        }
                    }

                    // Due date button row
                    Row {
                        spacing: 6
                        Text { anchors.verticalCenter: parent.verticalCenter; text: "Due"; font.pixelSize: theme.fs(9); color: Theme.textSecondary }

                        ApexPressable {
                            id: dueBtn
                            anchors.verticalCenter: parent.verticalCenter
                            width:  dueLbl.implicitWidth + 20; height: 20; radius: 10
                            hitMargin: 3   // Row spacing to the clear ✕ is 6
                            activeFocusOnTab: card.keyed || card.open
                            Accessible.name: (card.taskData.dueDate || "") !== "" ? "Change due date, " + root._formatDue(card.taskData.dueDate) : "Set due date"
                            onActivated: { root._pickerByKey = dueBtn.focusVisible; root._openPicker(card.taskData.id) }
                            Rectangle {
                                anchors.fill: parent; radius: parent.radius
                                color: dueBtn.hovered
                                    ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.15)
                                    : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07)
                                border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.12); border.width: 1
                                Behavior on color { MotionColor {} }
                            }
                            Text {
                                id: dueLbl; anchors.centerIn: parent; font.pixelSize: theme.fs(9)
                                text:  (card.taskData.dueDate || "") !== "" ? root._formatDue(card.taskData.dueDate) : "Set due date"
                                color: (card.taskData.dueDate || "") !== "" ? Theme.active : Theme.textSecondary
                                Behavior on color { MotionColor { role: "state" } }
                            }
                            ApexFocusRing { target: dueBtn }
                        }

                        // Clear ✕
                        ApexPressable {
                            id: clrDueBtn
                            visible: (card.taskData.dueDate || "") !== ""
                            anchors.verticalCenter: parent.verticalCenter
                            width: 16; height: 16; radius: 8; hitMargin: 3
                            activeFocusOnTab: card.keyed || card.open
                            Accessible.name: "Clear due date"
                            onActivated: {
                                if (clrDueBtn.focusVisible) root._refocus(card.taskData.id, "due")   // this button goes
                                root._patchTask(card.taskData.id, "dueDate", "")
                            }
                            Rectangle {
                                anchors.fill: parent; radius: parent.radius
                                color: clrDueBtn.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.12) : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.05)
                                Behavior on color { MotionColor { role: "state" } }
                            }
                            Text { anchors.centerIn: parent; text: "✕"; font.pixelSize: theme.fs(8); color: Theme.textSecondary }
                            ApexFocusRing { target: clrDueBtn }
                        }
                    }
                }

                // Action bar
                Item {
                    width: parent.width; height: 22

                    // ▾/▴ extra fields — isolated from other buttons, full hitMargin.
                    ApexPressable {
                        id: expandBtn
                        anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                        width: 20; height: 20; radius: 5; hitMargin: 6
                        activeFocusOnTab: card.keyed || card.open
                        Accessible.name: card.showExtra ? "Collapse task details" : "Expand task details"
                        onActivated: card.primary()
                        Rectangle {
                            anchors.fill: parent; radius: parent.radius
                            color: expandBtn.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10) : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.04)
                            Behavior on color { MotionColor {} }
                        }
                        Text { anchors.centerIn: parent; text: card.showExtra ? "▴" : "▾"; font.pixelSize: theme.fs(9); color: expandBtn.hovered ? Theme.textPrimary : Theme.textTertiary }
                        ApexFocusRing { target: expandBtn }
                    }

                    Row {
                        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                        spacing: 4

                        // ← left — grouped with 4px spacing, so hitMargin is capped
                        // well under the (32-20)/2 nominal value to avoid stealing
                        // clicks meant for its neighbour.
                        ApexPressable {
                            id: leftBtn
                            visible: card.colIdx > 0
                            width: 20; height: 20; radius: 5; hitMargin: 2
                            activeFocusOnTab: card.keyed || card.open
                            Accessible.name: "Move task left"
                            onActivated: card.col._moveCardTo(card.taskData.id, -1)
                            Rectangle {
                                anchors.fill: parent; radius: parent.radius
                                color: leftBtn.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10) : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.04)
                                Behavior on color { MotionColor {} }
                            }
                            Text { anchors.centerIn: parent; text: "←"; font.pixelSize: theme.fs(10); color: leftBtn.hovered ? Theme.textPrimary : Theme.textSecondary }
                            ApexFocusRing { target: leftBtn }
                        }

                        // → right
                        ApexPressable {
                            id: rightBtn
                            visible: card.colIdx < 2
                            width: 20; height: 20; radius: 5; hitMargin: 2
                            activeFocusOnTab: card.keyed || card.open
                            Accessible.name: "Move task right"
                            onActivated: card.col._moveCardTo(card.taskData.id, 1)
                            Rectangle {
                                anchors.fill: parent; radius: parent.radius
                                color: rightBtn.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10) : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.04)
                                Behavior on color { MotionColor {} }
                            }
                            Text { anchors.centerIn: parent; text: "→"; font.pixelSize: theme.fs(10); color: rightBtn.hovered ? Theme.textPrimary : Theme.textSecondary }
                            ApexFocusRing { target: rightBtn }
                        }

                        // ✕ delete — opens the confirmation overlay below.
                        ApexPressable {
                            id: delBtn
                            width: 20; height: 20; radius: 5; hitMargin: 2
                            activeFocusOnTab: card.keyed || card.open
                            Accessible.name: "Delete task"
                            onActivated: card.startDelete()
                            Rectangle {
                                anchors.fill: parent; radius: parent.radius
                                color: delBtn.hovered ? Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b,0.20) : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.04)
                                Behavior on color { MotionColor {} }
                            }
                            Text {
                                anchors.centerIn: parent; text: "✕"; font.pixelSize: theme.fs(10)
                                color: Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, delBtn.hovered ? 1.0 : 0.60)
                                Behavior on color { MotionColor {} }
                            }
                            ApexFocusRing { target: delBtn }
                        }
                    }
                }
            }

            // ── Delete confirmation overlay ────────────────────────────────────
            Rectangle {
                anchors.fill: parent; radius: parent.radius
                visible: card.isDelConfirm
                color: Qt.rgba(
                    Math.min(1, Theme.background.r + 0.05),
                    Math.min(1, Theme.background.g + 0.05),
                    Math.min(1, Theme.background.b + 0.05), 0.96)

                Column {
                    anchors.centerIn: parent; spacing: 10
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "Delete task?"; color: Theme.text; font.pixelSize: theme.fs(12); font.weight: Font.Medium
                    }
                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter; spacing: 8
                        // Only visible while this overlay is showing, so — like
                        // WifiTab's own Forget-confirm Cancel/Forget — an ordinary
                        // Tab stop rather than gated on card.keyed || card.open.
                        ApexPressable {
                            id: cancelDelBtn
                            width: 64; height: 24; radius: 6; hitMargin: 4
                            Accessible.name: "Keep task"
                            // Returns focus to the button that opened this overlay,
                            // not the column list — mirrors WifiTab's Cancel-forget.
                            onActivated: { root.delConfirmId = -1; delBtn.forceActiveFocus() }
                            Rectangle {
                                anchors.fill: parent; radius: parent.radius
                                color: cancelDelBtn.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10) : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.05)
                                border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10); border.width: 1
                                Behavior on color { MotionColor {} }
                            }
                            Text { anchors.centerIn: parent; text: "Cancel"; font.pixelSize: theme.fs(11); color: Theme.textSecondary }
                            ApexFocusRing { target: cancelDelBtn }
                        }
                        ApexPressable {
                            id: confirmDelBtn
                            width: 64; height: 24; radius: 6; hitMargin: 4
                            Accessible.name: "Delete task permanently"
                            // Removes the card that owns this very button — hands
                            // focus back to the column list, per rule 6.
                            onActivated: card.col._removeCard(card.taskData.id)
                            Rectangle {
                                anchors.fill: parent; radius: parent.radius
                                color: confirmDelBtn.hovered ? Theme.dangerFillHover : Theme.dangerFill
                                Behavior on color { MotionColor {} }
                            }
                            Text { anchors.centerIn: parent; text: "Delete"; font.pixelSize: theme.fs(11); font.weight: Font.Bold; color: Theme.fixedLight }
                            ApexFocusRing { target: confirmDelBtn }
                        }
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "↵ confirm · ⎋ cancel"; font.pixelSize: theme.fs(9)
                        color: Theme.textTertiary
                    }
                }
            }
        }
    }
}
