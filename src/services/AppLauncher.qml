import QtQuick
import QtQuick.Controls
import Quickshell.Io
import Quickshell
import "../"
import "../components"
import "../nexus"
import "answer.js" as Answer
import "search.js" as Search

// AppLauncher — APEX Search: one text field over apps, files, settings,
// windows, clipboard, calculator, commands, projects, agents, SSH hosts and
// package search (roadmap §15).
//
// Lives inside Dashboard.qml on the "launcher" page. Dashboard is a PanelWindow
// with WlrKeyboardFocus.Exclusive, so TextInput receives keys without extra
// wiring.
//
// This file is the SURFACE. It ranks nothing, decides nothing about what may
// run, and builds no command line. Every one of those lives in
// src/services/search.js, driven through SearchService — because no CI runner
// has a compositor, and a launcher with system reach cannot have its safety
// rules in a QML binding that nothing checks.
//
// ── "?" is unchanged, and that is deliberate ────────────────────────────────
// A query starting with "?" is an ANSWER query: evaluated locally when it is
// plain arithmetic and otherwise sent to Wolfram|Alpha. It is the one thing
// here that leaves the machine, and it stays exactly as it was — including
// `_usedWolfram`, which gates every reference to the singleton so a plain
// search never instantiates it, never reads its credential file and never
// resets it. Search.parseQuery routes "?" to a scope every provider gate
// refuses, and manifest.js's launcherWantsProviders() already refused it for
// plugins, so no provider of either kind can put a row where the answer goes.
//
// ── Plugin rows (roadmap §16, the launcher-provider extension point) ────────
// `providers` below hosts every granted launcher-provider plugin. Its rows are
// APPENDED to the ranked built-in results, never merged into the ranking: the
// shell's rows first, then plugin rows in provider order. A plugin adds to this
// list and cannot reorder it. Provider rows carry `kind: "plugin"` and are
// handled at the TOP of activate(), before the branches that run a DesktopEntry
// or hand an Exec string to `bash -c`.
//
// ── THE PREVIEW, WHICH IS THE POINT OF §15's FOURTH BULLET ──────────────────
//
// "Actions should have clear permissions and previews before destructive system
// changes."
//
// Every row carries a class from search.js's ACTIONS table — safe, changes, or
// destructive — and the class is a property of the action, never of the row, so
// a provider cannot label a reboot safe.
//
//   * A non-safe row is visibly different before it is read: a coloured badge
//     with the class and the privilege it needs, and its own glyph.
//   * Enter on a non-safe row opens the preview. It does not run it. The
//     preview shows what the action does, what privilege it needs, whether it
//     can be undone, and THE EXACT ARGV — for a package it also runs
//     `apex resolve`, which is read-only and needs no root.
//   * Committing needs a different gesture: Ctrl+Enter, or the Run control
//     inside the preview. A held Enter cannot repeat through both stages,
//     because the second stage is not Enter.
//   * Ctrl+Enter straight from the list, with no preview open, does nothing.
//     Search.commitDecision() requires the previewed row and the selected row
//     to be the same non-empty row, which is the clause that makes the preview
//     mandatory rather than merely available.
// ──────────────────────────────────────────────────────────────────────────────

Item {
    id: root

    // "A user can genuinely see this right now" — window visibility AND page
    // selection AND not locked, handed down by Dashboard. Item `visible` is not
    // a substitute: an Item inside a hidden window still reports visible, which
    // is how the stats page once kept six pollers running after the dashboard
    // was closed.
    property bool onScreen: false

    property int  selIndex: -1
    property string query: ""

    readonly property bool   answerMode:  query.trim().charAt(0) === "?"
    readonly property string answerQuery: answerMode ? query.trim().substring(1).trim() : ""

    // Local arithmetic first: it is instant, works offline, and spends no API
    // quota on "?12*7".
    readonly property var calculation: answerMode ? Answer.calculate(answerQuery) : ({ valid: false })

    // ── Demand ────────────────────────────────────────────────────────────────
    // Nothing in the search stack runs unless this page is in front of someone.
    ServiceRef { service: SearchService; active: root.onScreen }
    // Window enumeration costs a subprocess on Hyprland, so the windows
    // provider's data source is refcounted too and handed back on close.
    ServiceRef { service: CompositorService.windowsRef; active: root.onScreen }

    // The query goes to the service only while this page is live, so a second
    // monitor's copy of the dashboard cannot write over the one being typed in.
    Binding {
        target: SearchService
        property: "query"
        value: root.query
        when: root.onScreen
    }

    // ── Results ───────────────────────────────────────────────────────────────
    readonly property var filtered: {
        if (answerMode) return answerRows()
        if (query.trim() === "") return SearchService.restingRows
        return SearchService.results.concat(providers.rows)
    }

    // ── The launcher-provider extension point ─────────────────────────────────
    // Non-visual: it hosts one Loader per granted provider, feeds each the
    // debounced query, and exposes the sanitised rows. See PluginLauncher.qml.
    PluginLauncher {
        id: providers
        query: root.query
    }

    // ── The preview ───────────────────────────────────────────────────────────
    // `previewRow` is the row the panel is describing. `previewId` is its
    // identity, and the commit rule compares it against the identity of the row
    // that is selected RIGHT NOW — so a preview left open while the selection
    // moved cannot commit the row it is no longer pointing at.
    property var previewRow: null
    readonly property string previewId: Search.rowId(root.previewRow)
    readonly property var previewInfo:
        root.previewRow ? SearchService.preview(root.previewRow) : null

    readonly property var selectedRow:
        (root.selIndex >= 0 && root.selIndex < root.filtered.length)
            ? root.filtered[root.selIndex] : null
    readonly property string selectedId: Search.rowId(root.selectedRow)

    function closePreview() {
        root.previewRow = null
        SearchService.forgetResolve()
    }

    function openPreview(row) {
        root.previewRow = row
        // `apex resolve` is started HERE — by activation — and never by
        // selection. Arrowing down twenty package rows must not run twenty of
        // them: resolve reaches the package metadata and dnf5 may refresh it
        // over the network.
        const info = SearchService.preview(row)
        if (info && info.resolves)
            SearchService.resolve(row.arg)
    }

    // ── The one decision point ────────────────────────────────────────────────
    // Every path that could run something — Enter, Ctrl+Enter, a click on a
    // row, the Run control — arrives here, and the verdict comes from
    // search.js. There is deliberately no second route: a click handler that
    // called activate() directly would be a way to run a destructive action
    // with no preview, and it would be invisible to every test that matters.
    function press(key, ctrl) {
        const row = root.selectedRow
        if (!row) return

        const verdict = Search.commitDecision({
            "klass":       row.klass,
            "key":         key,
            "ctrl":        ctrl === true,
            "previewedId": root.previewId,
            "selectedId":  root.selectedId
        })

        if (verdict === Search.COMMIT.PREVIEW) {
            root.openPreview(row)
            return
        }
        if (verdict === Search.COMMIT.RUN) {
            root.activate(row)
            return
        }
        // COMMIT.REFUSE. A Ctrl+Enter that arrived with no preview open, or
        // with the selection somewhere else, does nothing at all — it does not
        // fall through to a preview, because a chord that sometimes previews
        // and sometimes runs is a chord nobody can trust.
    }

    // ── Rows shown in "?" mode ────────────────────────────────────────────────
    // Wolfram state is read live, so the row updates in place from "asking" to
    // the answer without rebuilding the list.
    function answerRows() {
        if (answerQuery === "")
            return [{ kind: "hint", name: "Type a question after ?  —  e.g. ?density of aluminium * 2",
                      klass: "safe", payload: "", icon: "", glyph: "󰋼" }]

        var rows = []
        if (calculation.valid) {
            rows.push({ kind: "calculation",
                        name:  calculation.expression + " = " + calculation.formatted,
                        klass: "safe", payload: calculation.formatted,
                        icon: "", glyph: "󰃬" })
            return rows
        }

        if (!_usedWolfram)
            rows.push({ kind: "hint", name: "Press Enter or wait to ask Wolfram|Alpha",
                        klass: "safe", payload: "", icon: "", glyph: "󰋼" })
        else if (WolframService.busy)
            rows.push({ kind: "hint", name: "Asking Wolfram|Alpha…",
                        klass: "safe", payload: "", icon: "", glyph: "󰋼" })
        else if (WolframService.queryText === answerQuery && WolframService.answer !== "")
            rows.push({ kind: "answer", name: WolframService.answer,
                        klass: "safe", payload: WolframService.answer,
                        icon: "", glyph: "󰪚" })
        else if (WolframService.queryText === answerQuery && WolframService.error !== "")
            rows.push({ kind: "hint", name: WolframService.error,
                        klass: "safe", payload: "", icon: "", glyph: "󰋼" })
        else
            rows.push({ kind: "hint", name: "Press Enter or wait to ask Wolfram|Alpha",
                        klass: "safe", payload: "", icon: "", glyph: "󰋼" })
        return rows
    }

    // True once this launcher session has actually used WolframService. It
    // gates every other reference to the singleton so a plain search never
    // instantiates it, never reads its credential file and never resets it.
    property bool _usedWolfram: false

    function _forgetAnswer() {
        if (!_usedWolfram) return
        WolframService.reset()
        _usedWolfram = false
    }

    function _askWolfram() {
        _usedWolfram = true
        WolframService.ask(answerQuery)
    }

    // A question is only sent once typing pauses, and never when the local
    // parser already answered it.
    onQueryChanged: {
        askDebounce.stop()
        root.closePreview()
        if (!answerMode || answerQuery === "" || calculation.valid) {
            _forgetAnswer()
            return
        }
        if (!_usedWolfram || WolframService.queryText !== answerQuery)
            askDebounce.restart()
    }

    Timer {
        id: askDebounce
        interval: 500
        onTriggered: {
            if (root.answerMode && root.answerQuery !== "" && !root.calculation.valid)
                root._askWolfram()
        }
    }

    onVisibleChanged: {
        askDebounce.stop()
        _forgetAnswer()
        root.closePreview()
        if (!visible)
            return
        root.query     = ""
        root.selIndex  = 0
        searchInput.text = ""
        focusTimer.restart()
    }

    Timer {
        id: focusTimer
        interval: 60
        onTriggered: searchInput.forceActiveFocus()
    }

    // ── Launch ────────────────────────────────────────────────────────────────
    Process {
        id: launcher
        command: []
        running: false
    }

    // Launch a plain Exec string. Only used for entries that arrived without a
    // DesktopEntry behind them; DesktopEntries-backed rows go through
    // entry.execute(), which respects Terminal=, Path= and Exec field codes.
    function launch(exec) {
        launcher.command = ["bash", "-c", "setsid " + exec + " &>/dev/null &"]
        launcher.running = false
        launcher.running = true
        Popups.dashboardOpen = false
    }

    function activate(entry) {
        if (entry.kind === "hint") {
            // Enter on "waiting to ask" sends the question immediately instead
            // of waiting out the debounce; on any other hint there is nothing
            // to do and the launcher stays open.
            if (root.answerMode && root.answerQuery !== "" && !root.calculation.valid
                && !(root._usedWolfram && WolframService.busy)) {
                askDebounce.stop()
                root._askWolfram()
            }
            return
        }
        // ── A plugin row ──────────────────────────────────────────────────────
        // Handled here, ABOVE the DesktopEntry and Exec branches below. A row
        // that fell through to those would be running a command chosen by
        // third-party code, which is the `system` permission — refused at load,
        // by design. Manifest.launcherResults() cannot produce a row carrying
        // `entry` or `exec`, and this branch means the ordering does not
        // depend on that staying true.
        //
        // What is copied is the row's TITLE — the string the user just read.
        // A provider row has no hidden payload, so there is nothing here that
        // could put something other than the visible text on the clipboard.
        // The plugin is then told which of its rows was chosen, by index, so it
        // can react inside whatever it was granted.
        if (entry.kind === "plugin") {
            ClipboardService.copyText(entry.name)
            providers.notifyActivated(entry.pluginId, entry.index)
            Popups.dashboardOpen = false
            return
        }
        if (entry.kind === "answer" || entry.kind === "calculation") {
            ClipboardService.copyText(entry.payload)
            Popups.dashboardOpen = false
            return
        }
        // ── A built-in row that names an action ───────────────────────────────
        // Reached only through press() → Search.commitDecision(), which is why
        // there is no class check here: by the time a non-safe row arrives, the
        // rule has already been applied and a preview has already been shown.
        // Putting a second check here would be a second rule, free to drift.
        if ((entry.action ?? "") !== "") {
            root._perform(entry)
            return
        }
        if (entry.kind === "clip") {
            ClipboardService.copyEntry(entry.payload)
            Popups.dashboardOpen = false
            return
        }
        if (entry.kind === "window") {
            CompositorService.focusWindow(entry.payload)
            Popups.dashboardOpen = false
            return
        }
        if (entry.kind === "setting") {
            NexusState.openAt(entry.payload, Popups.dashboardScreen)
            Popups.dashboardOpen = false
            return
        }
        if (entry.kind === "command" && entry.payload === "agents") {
            Popups.dashboardPage = "agents"
            return
        }
        if (entry.entry) {
            LauncherState.recordLaunch(entry.payload)
            entry.entry.execute()
            Popups.dashboardOpen = false
            return
        }
        launch(entry.exec)
    }

    // Perform an action from the ACTIONS table. Two mechanisms and no third:
    // the compositor adapter for the actions that are compositor operations,
    // and SearchService.runAction — which builds the argv from the table — for
    // everything else. Neither one takes a command from a row.
    function _perform(row) {
        if (row.action === "window.close") {
            CompositorService.closeWindow(row.arg)
            root.closePreview()
            Popups.dashboardOpen = false
            return
        }
        if (SearchService.runAction(row)) {
            root.closePreview()
            Popups.dashboardOpen = false
        }
    }

    // A folder row does not open a file manager; it continues the search inside
    // itself, which is what a path-completing text field is for.
    function _isFolder(row) {
        return row && row.kind === "file"
               && String(row.payload).charAt(String(row.payload).length - 1) === "/"
    }

    // ── Layout ────────────────────────────────────────────────────────────────
    Item {
        anchors.fill: parent

        // Results
        Item {
            anchors {
                top: searchBar.bottom
                left: parent.left
                right: parent.right
                bottom: previewPanel.visible ? previewPanel.top : parent.bottom
                topMargin: 8
                bottomMargin: previewPanel.visible ? 10 : 0
            }

            // Empty / no results state
            Column {
                anchors.centerIn: parent
                spacing: 10
                visible: root.filtered.length === 0

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text:           root.query !== "" ? "󰩄" : "󱗃"
                    font.pixelSize: Theme.fs(28)
                    color:          Qt.rgba(1,1,1,0.18)
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text:           root.query !== "" ? "No results" : "No apps found"
                    color:          Qt.rgba(1,1,1,0.25)
                    font.pixelSize: Theme.fs(13)
                }
            }

            ListView {
                id: appList
                anchors.fill: parent
                visible: root.filtered.length > 0
                clip:    true
                spacing: 3
                boundsBehavior: Flickable.StopAtBounds

                // ── Why the model is a COUNT and the row is looked up ──────────
                // `model: <JS array>` recreates every delegate whenever the
                // array's CONTENTS change — measured on Qt 6.10.3: a 3-element
                // model reports created=6, destroyed=3 after one content
                // change. A search result list is exactly that shape: the array
                // is rebuilt on every keystroke, so an array model would
                // destroy and rebuild every delegate as the user types, and a
                // Behavior does not animate a freshly created object's initial
                // binding — the colour and border animations below would
                // silently stop running.
                //
                // An integer model does not fix the count changing (it cannot;
                // the number of results genuinely varies), but it makes a query
                // that returns the SAME number of rows — every keystroke inside
                // a directory, every arrow key, every arriving subprocess
                // answer — reuse its delegates instead of rebuilding them.
                model: root.filtered.length

                ScrollBar.vertical: ScrollBar {
                    policy: ScrollBar.AsNeeded
                    contentItem: Rectangle {
                        implicitWidth:  3
                        implicitHeight: 40
                        radius:         1.5
                        color:          Qt.rgba(1, 1, 1, 0.22)
                    }
                    background: Item {}
                }

                delegate: Rectangle {
                    id: rowItem
                    required property int index
                    readonly property var modelData: root.filtered[rowItem.index] ?? null

                    // Answer/hint rows carry prose, not a name: they wrap and
                    // grow instead of eliding, which is the whole point of
                    // showing the result inline.
                    readonly property bool isText: rowItem.modelData
                        && (rowItem.modelData.kind === "answer"
                            || rowItem.modelData.kind === "calculation"
                            || rowItem.modelData.kind === "hint")

                    readonly property string klass:
                        rowItem.modelData ? (rowItem.modelData.klass ?? "safe") : "safe"
                    readonly property bool isDestructive: rowItem.klass === "destructive"
                    readonly property bool isChanging:    rowItem.klass === "changes"

                    width:  appList.width - 8
                    height: isText ? Math.max(46, label.implicitHeight + 26) : 46
                    radius: 9

                    readonly property bool isSel: root.selIndex === rowItem.index

                    color: isSel
                           ? (isDestructive ? Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.16)
                                            : Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.14))
                           : rowH.hovered ? Qt.rgba(1,1,1,0.06) : "transparent"
                    border.color: isSel
                                  ? (isDestructive ? Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.50)
                                                   : Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.28))
                                  : rowH.hovered ? Qt.rgba(1,1,1,0.08) : "transparent"
                    border.width: 1

                    Behavior on color        { ColorAnimation { duration: 100 } }
                    Behavior on border.color { ColorAnimation { duration: 100 } }

                    Row {
                        anchors {
                            left:   parent.left;  leftMargin:  12
                            right:  parent.right; rightMargin: 12
                            verticalCenter: parent.verticalCenter
                        }
                        spacing: 12

                        Item {
                            width: 28; height: 28
                            anchors.verticalCenter: parent.verticalCenter

                            Image {
                                id: ico
                                anchors.fill: parent
                                source: {
                                    var s = rowItem.modelData ? (rowItem.modelData.icon ?? "") : ""
                                    if (!s || s === "")    return ""
                                    if (s.startsWith("/")) return "file://" + s
                                    return "image://icon/" + s
                                }
                                fillMode:          Image.PreserveAspectFit
                                smooth:            true
                                sourceSize.width:  28
                                sourceSize.height: 28
                            }

                            // Glyph fallback. A non-safe row gets a warning
                            // colour here as well as a badge: the shape and the
                            // colour are both readable before the text is, and
                            // §15 asks for destructive actions to be
                            // distinguishable from a search result at a glance.
                            Rectangle {
                                anchors.fill: parent
                                radius:       7
                                color: rowItem.isDestructive ? Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.22)
                                     : rowItem.isChanging    ? Qt.rgba(Theme.warning.r, Theme.warning.g, Theme.warning.b, 0.20)
                                     : Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.18)
                                visible: ico.status !== Image.Ready
                                         || !rowItem.modelData
                                         || (rowItem.modelData.icon ?? "") === ""
                                Text {
                                    anchors.centerIn: parent
                                    text: {
                                        if (!rowItem.modelData) return ""
                                        const g = rowItem.modelData.glyph ?? ""
                                        if (g !== "") return g
                                        return String(rowItem.modelData.name).charAt(0).toUpperCase()
                                    }
                                    font.pixelSize: Theme.fs(13); font.bold: true
                                    color: rowItem.isDestructive ? Theme.danger
                                         : rowItem.isChanging    ? Theme.warning
                                         : Theme.active
                                }
                            }
                        }

                        Column {
                            width: parent.width - 28 - parent.spacing
                                   - (badge.visible ? badge.width + parent.spacing : 0)
                                   - (pinBtn.visible ? pinBtn.width + parent.spacing : 0)
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1

                            Text {
                                id: label
                                width:          parent.width
                                text:           rowItem.modelData ? rowItem.modelData.name : ""
                                font.pixelSize: Theme.fs(13)
                                color:          rowItem.isSel ? Theme.active : Theme.text
                                wrapMode:       rowItem.isText ? Text.Wrap : Text.NoWrap
                                elide:          rowItem.isText ? Text.ElideNone : Text.ElideRight
                                maximumLineCount: rowItem.isText ? 8 : 1
                                Behavior on color { ColorAnimation { duration: 100 } }
                            }

                            // The second line. For a plugin row `detail` always
                            // ends in the plugin's name AS THE HOST GRANTED IT,
                            // composed in Manifest.launcherResults() rather than
                            // here, so a row cannot claim to have come from the
                            // shell. For a built-in it names the provider and,
                            // for an action, the privilege it needs.
                            Text {
                                width:          parent.width
                                visible:        rowItem.modelData
                                                && (rowItem.modelData.detail ?? "") !== ""
                                text:           rowItem.modelData ? (rowItem.modelData.detail ?? "") : ""
                                font.pixelSize: Theme.fs(10)
                                color:          Qt.rgba(1, 1, 1, 0.32)
                                elide:          Text.ElideRight
                                maximumLineCount: 1
                            }
                        }

                        // ── The class badge ───────────────────────────────────
                        // Present on every row that changes the system and on no
                        // row that does not, so "this one is different" is
                        // visible without reading a word of it.
                        Rectangle {
                            id: badge
                            anchors.verticalCenter: parent.verticalCenter
                            visible: rowItem.isDestructive || rowItem.isChanging
                            width:   badgeText.implicitWidth + 14
                            height:  18
                            radius:  9
                            color:   rowItem.isDestructive ? Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.22)
                                                           : Qt.rgba(Theme.warning.r, Theme.warning.g, Theme.warning.b, 0.18)
                            Text {
                                id: badgeText
                                anchors.centerIn: parent
                                text: rowItem.isDestructive ? "cannot be undone" : "changes system"
                                font.pixelSize: Theme.fs(9)
                                color: rowItem.isDestructive ? Theme.danger : Theme.warning
                            }
                        }

                        // Pin toggle, for application rows only. Shown for a
                        // pinned app always (so the state is visible, not just
                        // discoverable) and otherwise only on hover or
                        // selection, to keep the list quiet.
                        Text {
                            id: pinBtn
                            anchors.verticalCenter: parent.verticalCenter
                            visible: rowItem.modelData && rowItem.modelData.kind === "app"
                                     && (rowItem.modelData.payload ?? "") !== ""
                                     && (LauncherState.isPinned(rowItem.modelData.payload)
                                         || rowH.hovered || rowItem.isSel)
                            text: rowItem.modelData && LauncherState.isPinned(rowItem.modelData.payload)
                                      ? "󰐃" : "󰤱"
                            font.pixelSize: Theme.fs(13)
                            color: rowItem.modelData && LauncherState.isPinned(rowItem.modelData.payload)
                                        ? Theme.active
                                        : Qt.rgba(1, 1, 1, pinArea.containsMouse ? 0.75 : 0.30)
                            Behavior on color { ColorAnimation { duration: 100 } }

                            MouseArea {
                                id: pinArea
                                anchors.fill: parent
                                anchors.margins: -6
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: LauncherState.togglePin(rowItem.modelData.payload)
                            }
                        }
                    }

                    HoverHandler { id: rowH; cursorShape: Qt.PointingHandCursor }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        // Sits under the pin button, which has its own MouseArea.
                        onEntered: root.selIndex = rowItem.index
                        onClicked: function (mouse) {
                            if (mouse.button === Qt.RightButton) {
                                if (rowItem.modelData && rowItem.modelData.kind === "app"
                                    && (rowItem.modelData.payload ?? "") !== "")
                                    LauncherState.togglePin(rowItem.modelData.payload)
                                return
                            }
                            root.selIndex = rowItem.index
                            // The SAME decision point the keyboard uses. A click
                            // on a destructive row opens the preview; it does not
                            // run it.
                            root.press("enter", false)
                        }
                    }
                }
            }
        }

        // ── The preview panel ─────────────────────────────────────────────────
        // Anchored to the bottom, above nothing, and it takes the space the list
        // was using rather than floating over it: the row that is about to run
        // has to stay visible while its consequences are being read.
        Rectangle {
            id: previewPanel
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: previewCol.implicitHeight + 24
            radius: 12
            visible: root.previewInfo !== null
            color: root.previewInfo && root.previewInfo.klass === "destructive"
                       ? Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.10)
                       : Qt.rgba(Theme.warning.r, Theme.warning.g, Theme.warning.b, 0.08)
            border.width: 1
            border.color: root.previewInfo && root.previewInfo.klass === "destructive"
                       ? Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.45)
                       : Qt.rgba(Theme.warning.r, Theme.warning.g, Theme.warning.b, 0.35)

            Column {
                id: previewCol
                anchors {
                    left: parent.left; right: parent.right; top: parent.top
                    leftMargin: 14; rightMargin: 14; topMargin: 12
                }
                spacing: 6

                Text {
                    width: parent.width
                    text: root.previewInfo
                          ? (root.previewInfo.klass === "destructive"
                             ? "󰀦  " + root.previewInfo.title
                             : "󰑓  " + root.previewInfo.title)
                          : ""
                    font.pixelSize: Theme.fs(13)
                    font.bold: true
                    color: root.previewInfo && root.previewInfo.klass === "destructive"
                               ? Theme.danger : Theme.warning
                    elide: Text.ElideRight
                }

                Text {
                    width: parent.width
                    text: root.previewInfo ? root.previewInfo.what : ""
                    font.pixelSize: Theme.fs(11)
                    color: Qt.rgba(1, 1, 1, 0.72)
                    wrapMode: Text.WordWrap
                }

                // Permissions, plainly. §15: "Actions should have clear
                // permissions."
                Text {
                    width: parent.width
                    text: root.previewInfo ? "Runs as: " + root.previewInfo.permission : ""
                    font.pixelSize: Theme.fs(10)
                    color: Qt.rgba(1, 1, 1, 0.45)
                    wrapMode: Text.WordWrap
                }

                Text {
                    width: parent.width
                    text: root.previewInfo
                          ? (root.previewInfo.undoes === ""
                             ? "This cannot be undone."
                             : "To undo: " + root.previewInfo.undoes)
                          : ""
                    font.pixelSize: Theme.fs(10)
                    color: root.previewInfo && root.previewInfo.undoes === ""
                               ? Theme.danger : Qt.rgba(1, 1, 1, 0.45)
                    wrapMode: Text.WordWrap
                }

                // The exact command. Composed by search.js from the same argv
                // that will be executed, so what is shown and what is run
                // cannot be built separately and drift.
                Rectangle {
                    width: parent.width
                    height: cmdText.implicitHeight + 12
                    radius: 6
                    color: Qt.rgba(0, 0, 0, 0.28)
                    visible: root.previewInfo && root.previewInfo.commandLine !== ""
                    Text {
                        id: cmdText
                        anchors { fill: parent; margins: 6 }
                        text: root.previewInfo ? root.previewInfo.commandLine : ""
                        font.family: "monospace"
                        font.pixelSize: Theme.fs(10)
                        color: Qt.rgba(1, 1, 1, 0.7)
                        wrapMode: Text.WrapAnywhere
                    }
                }

                // For a package, the preview is not prose this shell wrote: it
                // is `apex resolve`, which is read-only and needs no root.
                Text {
                    width: parent.width
                    visible: root.previewInfo !== null && root.previewInfo.resolves
                    text: SearchService.resolveBusy
                              ? "Checking which source APEX would use…"
                              : (SearchService.resolveText === ""
                                 ? "apex resolve had nothing to say about that name."
                                 : SearchService.resolveText)
                    font.family: "monospace"
                    font.pixelSize: Theme.fs(10)
                    color: Qt.rgba(1, 1, 1, 0.55)
                    wrapMode: Text.WrapAnywhere
                    maximumLineCount: 8
                    elide: Text.ElideRight
                }

                Row {
                    spacing: 8

                    Rectangle {
                        width: runText.implicitWidth + 26
                        height: 28
                        radius: 8
                        color: root.previewInfo && root.previewInfo.klass === "destructive"
                                   ? (runHov.hovered ? Theme.dangerFillHover : Theme.dangerFill)
                                   : (runHov.hovered ? Qt.darker(Theme.warning, 1.7) : Qt.darker(Theme.warning, 2.2))
                        Behavior on color { ColorAnimation { duration: 120 } }
                        Text {
                            id: runText
                            anchors.centerIn: parent
                            text: "Run  ·  Ctrl+Enter"
                            font.pixelSize: Theme.fs(11)
                            font.bold: true
                            color: Theme.fixedLight
                        }
                        HoverHandler { id: runHov; cursorShape: Qt.PointingHandCursor }
                        // The mouse and touch commit path. It goes through the
                        // same decision function the keyboard does, with a key
                        // of its own rather than a pretended Ctrl.
                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.press("button", false)
                        }
                    }

                    Rectangle {
                        width: cancelText.implicitWidth + 26
                        height: 28
                        radius: 8
                        color: cancelHov.hovered ? Qt.rgba(1,1,1,0.12) : Qt.rgba(1,1,1,0.06)
                        Behavior on color { ColorAnimation { duration: 120 } }
                        Text {
                            id: cancelText
                            anchors.centerIn: parent
                            text: "Cancel  ·  Esc"
                            font.pixelSize: Theme.fs(11)
                            color: Theme.text
                        }
                        HoverHandler { id: cancelHov; cursorShape: Qt.PointingHandCursor }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.closePreview()
                        }
                    }
                }
            }
        }

        // ── Search bar ────────────────────────────────────────────────────────
        Rectangle {
            id: searchBar
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 44; radius: 12
            color: Qt.rgba(1,1,1,0.06)
            border.color: searchInput.activeFocus
                          ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.50)
                          : Qt.rgba(1,1,1,0.12)
            border.width: 1
            Behavior on border.color { ColorAnimation { duration: 120 } }

            Row {
                anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                spacing: 10

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰍉"; font.pixelSize: Theme.fs(16)
                    color: searchInput.activeFocus
                           ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.7)
                           : Qt.rgba(1,1,1,0.35)
                    Behavior on color { ColorAnimation { duration: 120 } }
                }

                Item {
                    width: parent.width - 26 - parent.spacing
                    height: parent.height
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text:    "Search  ·  install …  ·  ssh …  ·  ~/  ·  > commands  ·  ? asks"
                        color:   Qt.rgba(1,1,1,0.22)
                        font.pixelSize: Theme.fs(13)
                        visible: searchInput.text === ""
                    }

                    TextInput {
                        id: searchInput
                        anchors { fill: parent; topMargin: 2; bottomMargin: 2 }
                        verticalAlignment: TextInput.AlignVCenter
                        color:          Theme.text
                        font.pixelSize: Theme.fs(13)
                        selectionColor: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.35)
                        clip: true

                        onTextChanged: {
                            root.query    = text
                            root.selIndex = root.filtered.length > 0 ? 0 : -1
                            if (root.filtered.length > 0)
                                appList.positionViewAtIndex(0, ListView.Beginning)
                        }

                        Keys.onUpPressed: {
                            if (root.selIndex > 0) {
                                root.selIndex--
                                appList.positionViewAtIndex(root.selIndex, ListView.Contain)
                            }
                        }

                        Keys.onDownPressed: {
                            if (root.selIndex < root.filtered.length - 1) {
                                root.selIndex++
                                appList.positionViewAtIndex(root.selIndex, ListView.Contain)
                            }
                        }

                        // Tab completes a folder into the search box rather than
                        // opening it, which is what a path-completing field is
                        // for and what stops Enter meaning two different things
                        // on the same row.
                        Keys.onTabPressed: function (event) {
                            const row = root.selectedRow
                            if (root._isFolder(row)) {
                                searchInput.text = row.payload
                                searchInput.cursorPosition = searchInput.text.length
                                event.accepted = true
                                return
                            }
                            event.accepted = false
                        }

                        // ── The only key that can run anything ────────────────
                        // Plain Return is "enter"; Return with Control is
                        // "commit". They are different logical keys so a held
                        // Return cannot repeat through a preview into a commit —
                        // the second stage is a chord the first one is not.
                        Keys.onReturnPressed: function (event) {
                            const ctrl = (event.modifiers & Qt.ControlModifier) !== 0
                            const row = root.selectedRow
                            if (!ctrl && root._isFolder(row)) {
                                searchInput.text = row.payload
                                searchInput.cursorPosition = searchInput.text.length
                                return
                            }
                            root.press(ctrl ? "commit" : "enter", ctrl)
                        }
                        Keys.onEnterPressed: function (event) {
                            const ctrl = (event.modifiers & Qt.ControlModifier) !== 0
                            root.press(ctrl ? "commit" : "enter", ctrl)
                        }

                        Keys.onEscapePressed: {
                            if (root.previewInfo !== null) {
                                root.closePreview()
                            } else if (text !== "") {
                                text = ""
                            } else {
                                Popups.dashboardOpen = false
                            }
                        }
                    }
                }
            }
        }
    }
}
