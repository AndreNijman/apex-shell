import QtQuick
import QtQuick.Controls
import Quickshell.Io
import Quickshell
import "../"
import "answer.js" as Answer

// AppLauncher — scrollable app list + top search bar.
// Lives inside Dashboard.qml on the "launcher" page.
// Dashboard is PanelWindow with WlrKeyboardFocus.OnDemand,
// so TextInput receives keys without extra wiring.
//
// A query starting with "?" is an ANSWER query, not an app search: it is
// evaluated locally when it is plain arithmetic and otherwise sent to
// Wolfram|Alpha, and the answer is shown as a row in this list. Without the "?"
// no arithmetic is parsed and no network call is made — an app search costs
// exactly what it always did.
//
// ── Plugin rows (roadmap §16, the launcher-provider extension point) ─────────
// `providers` below hosts every granted launcher-provider plugin. Its rows are
// APPENDED to the app results, never merged into the ranking: apps first, in
// the order the frecency sort put them, then plugin rows in provider order.
// A plugin adds to this list and cannot reorder it.
//
// Provider rows carry `kind: "plugin"` and are handled at the TOP of
// activate(), before the branches that run a DesktopEntry or hand an Exec
// string to `bash -c`. That ordering is the whole reason a plugin row is safe:
// the row objects come out of Manifest.launcherResults(), which builds them
// from an allowlist and cannot emit an `entry` or an `exec` — but the branch
// order is the second lock on the same door, and it is what the static suite
// asserts. See the PLUGIN OUTPUT section of src/services/plugins/manifest.js.

Item {
    id: root

    // ── State ─────────────────────────────────────────────────────────────────
    property var  apps:     root._appEntries
    property bool loading:  false
    property int  selIndex: -1
    property string query:  ""

    readonly property bool   answerMode:  query.trim().charAt(0) === "?"
    readonly property string answerQuery: answerMode ? query.trim().substring(1).trim() : ""

    // Local arithmetic first: it is instant, works offline, and spends no API
    // quota on "?12*7".
    readonly property var calculation: answerMode ? Answer.calculate(answerQuery) : ({ valid: false })

    // With no query: pinned apps first, then frecency-ranked recents, then
    // everything else alphabetically. That ordering is the whole point of an
    // empty launcher — an alphabetical list starting at "Alacritty" is useless
    // as a default view.
    //
    // With a query: name matches first, then keyword/comment matches, so typing
    // "browser" finds Firefox via its Keywords even though the name does not
    // contain it. Within each tier, more-used apps rank higher.
    readonly property var filtered: {
        const q = query.trim()
        if (answerMode) return answerRows()

        if (q === "") {
            const seen = ({})
            const out = []

            for (const id of LauncherState.pinned) {
                const a = root._byId[id]
                if (a && !seen[id]) { seen[id] = true; out.push(root._tag(a, "pinned")) }
            }
            for (const id of LauncherState.topRecent(6)) {
                const a = root._byId[id]
                if (a && !seen[id]) { seen[id] = true; out.push(root._tag(a, "recent")) }
            }
            for (const a of root.apps)
                if (!seen[a.id]) out.push(a)

            return out
        }

        const ql = q.toLowerCase()
        const nameHits = []
        const metaHits = []

        for (const a of root.apps) {
            if (a.name.toLowerCase().indexOf(ql) !== -1) {
                nameHits.push(a)
                continue
            }
            const meta = (a.keywords + " " + a.comment + " " + a.categories).toLowerCase()
            if (meta.indexOf(ql) !== -1)
                metaHits.push(a)
        }

        const byUse = (x, y) => LauncherState.score(y.id) - LauncherState.score(x.id)
        nameHits.sort(byUse)
        metaHits.sort(byUse)
        // Plugin rows last, and only in this branch. The empty-query view is
        // pinned/recent/all-apps and has no query to answer; the "?" branch
        // returned above.
        return nameHits.concat(metaHits).concat(providers.rows)
    }

    // ── The launcher-provider extension point ─────────────────────────────────
    // Non-visual: it hosts one Loader per granted provider, feeds each the
    // debounced query, and exposes the sanitised rows. See PluginLauncher.qml.
    PluginLauncher {
        id: providers
        query: root.query
    }

    // Shallow copy carrying a badge, so the same app object can appear tagged in
    // the pinned/recent tiers without mutating the shared entry.
    function _tag(a, tier) {
        return {
            "kind": a.kind, "name": a.name, "exec": a.exec, "icon": a.icon,
            "categories": a.categories, "keywords": a.keywords,
            "comment": a.comment, "entry": a.entry, "id": a.id, "tier": tier
        }
    }

    readonly property var _byId: {
        const m = ({})
        for (const a of root.apps)
            m[a.id] = a
        return m
    }

    // Rows shown in "?" mode. Wolfram state is read live, so the row updates in
    // place from "asking" to the answer without rebuilding the list.
    function answerRows() {
        if (answerQuery === "")
            return [{ kind: "hint", name: "Type a question after ?  —  e.g. ?density of aluminium * 2",
                      value: "", icon: "", exec: "" }]

        var rows = []
        if (calculation.valid) {
            rows.push({ kind: "calculation",
                        name:  calculation.expression + " = " + calculation.formatted,
                        value: calculation.formatted, icon: "", exec: "" })
            return rows
        }

        if (!_usedWolfram)
            rows.push({ kind: "hint", name: "Press Enter or wait to ask Wolfram|Alpha",
                        value: "", icon: "", exec: "" })
        else if (WolframService.busy)
            rows.push({ kind: "hint", name: "Asking Wolfram|Alpha…", value: "", icon: "", exec: "" })
        else if (WolframService.queryText === answerQuery && WolframService.answer !== "")
            rows.push({ kind: "answer", name: WolframService.answer,
                        value: WolframService.answer, icon: "", exec: "" })
        else if (WolframService.queryText === answerQuery && WolframService.error !== "")
            rows.push({ kind: "hint", name: WolframService.error, value: "", icon: "", exec: "" })
        else
            rows.push({ kind: "hint", name: "Press Enter or wait to ask Wolfram|Alpha",
                        value: "", icon: "", exec: "" })
        return rows
    }

    // True once this launcher session has actually used WolframService. It
    // gates every other reference to the singleton so a plain app search never
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

    // ── Load apps ─────────────────────────────────────────────────────────────
    // Opening the launcher used to spawn `python3 src/scripts/list_apps.py`,
    // which walked every XDG applications directory and parsed every .desktop
    // file with configparser, then serialised the lot to JSON — a Python
    // interpreter start plus a full filesystem scan on every single open.
    //
    // Quickshell already maintains exactly this index natively: DesktopEntries
    // watches the XDG directories and keeps parsed entries live, so the list is
    // available with no process, no scan and no wait. It also honours the parts
    // of the spec the script did not: entries are launched through
    // DesktopEntry.execute(), which handles Terminal=true, Path=, and Exec field
    // codes properly instead of pasting the Exec line into `bash -c`.
    //
    // `loading` is retained but is now effectively always false; the list is
    // ready synchronously.
    readonly property var _appEntries: {
        const out = []
        for (const e of DesktopEntries.applications.values) {
            if (e.noDisplay)
                continue
            const nm = (e.name ?? "").trim()
            if (nm === "")
                continue
            out.push({
                "kind": "app",
                "name": nm,
                "exec": e.execString ?? "",
                "icon": e.icon ?? "",
                "categories": e.categories ?? "",
                "keywords": e.keywords ?? "",
                "comment": e.comment ?? "",
                "entry": e,
                // Stable key for pinning and history: the .desktop basename,
                // which survives renames of the visible Name and locale changes.
                "id": e.id ?? ""
            })
        }
        out.sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()))
        return out
    }

    onVisibleChanged: {
        askDebounce.stop()
        _forgetAnswer()
        if (!visible)
            return
        root.query     = ""
        root.selIndex  = root.apps.length > 0 ? 0 : -1
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
            ClipboardService.copyText(entry.value)
            Popups.dashboardOpen = false
            return
        }
        if (entry.entry) {
            LauncherState.recordLaunch(entry.id)
            entry.entry.execute()
            Popups.dashboardOpen = false
            return
        }
        launch(entry.exec)
    }

    // ── Layout ────────────────────────────────────────────────────────────────
    Item {
        anchors.fill: parent

        // App list
        Item {
            anchors {
                top: searchBar.bottom
                left: parent.left
                right: parent.right
                bottom: parent.bottom
                topMargin: 8
            }

            // Loading state
            Column {
                anchors.centerIn: parent
                spacing: 12
                visible: root.loading

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "󰣪"; font.pixelSize: Theme.fs(32)
                    color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.3)
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text:           "Loading apps…"
                    color:          Qt.rgba(1,1,1,0.25)
                    font.pixelSize: Theme.fs(13)
                }
            }

            // Empty / no results state
            Column {
                anchors.centerIn: parent
                spacing: 10
                visible: !root.loading && root.filtered.length === 0

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

            // App list
            ListView {
                id: appList
                anchors.fill: parent
                visible: !root.loading && root.filtered.length > 0
                model:   root.filtered
                clip:    true
                spacing: 3
                boundsBehavior: Flickable.StopAtBounds

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
                    required property var modelData
                    required property int index

                    // Answer/hint rows carry prose, not an app name: they wrap
                    // and grow instead of eliding, which is the whole point of
                    // showing the result inline.
                    readonly property bool isText: modelData.kind === "answer"
                                                   || modelData.kind === "calculation"
                                                   || modelData.kind === "hint"

                    width:  appList.width - 8
                    height: isText ? Math.max(46, label.implicitHeight + 26) : 46
                    radius: 9

                    readonly property bool isSel: root.selIndex === index

                    color: isSel
                           ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.14)
                           : rowH.hovered ? Qt.rgba(1,1,1,0.06) : "transparent"
                    border.color: isSel
                                  ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.28)
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

                        // App icon
                        Item {
                            width: 28; height: 28
                            anchors.verticalCenter: parent.verticalCenter

                            Image {
                                id: ico
                                anchors.fill: parent
                                source: {
                                    var s = modelData.icon
                                    if (!s || s === "")    return ""
                                    if (s.startsWith("/")) return "file://" + s
                                    return "image://icon/" + s
                                }
                                fillMode:          Image.PreserveAspectFit
                                smooth:            true
                                sourceSize.width:  28
                                sourceSize.height: 28
                            }

                            // Letter fallback
                            Rectangle {
                                anchors.fill: parent
                                radius:       7
                                color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.18)
                                visible: ico.status !== Image.Ready || modelData.icon === ""
                                Text {
                                    anchors.centerIn: parent
                                    text: {
                                        if (modelData.kind === "answer") return "󰪚"
                                        if (modelData.kind === "calculation") return "󰃬"
                                        if (modelData.kind === "hint") return "󰋼"
                                        return modelData.name.charAt(0).toUpperCase()
                                    }
                                    font.pixelSize: Theme.fs(13); font.bold: true
                                    color:          Theme.active
                                }
                            }
                        }

                        // App name, or the answer text
                        Column {
                            width: parent.width - 28 - parent.spacing
                                   - (pinBtn.visible ? pinBtn.width + parent.spacing : 0)
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1

                            Text {
                                id: label
                                width:          parent.width
                                text:           modelData.name
                                font.pixelSize: Theme.fs(13)
                                color:          isSel ? Theme.active : Theme.text
                                wrapMode:       isText ? Text.Wrap : Text.NoWrap
                                elide:          isText ? Text.ElideNone : Text.ElideRight
                                maximumLineCount: isText ? 8 : 1
                                Behavior on color { ColorAnimation { duration: 100 } }
                            }

                            // Provenance for a plugin row, and only for a
                            // plugin row. `detail` always ends in the plugin's
                            // name AS THE HOST GRANTED IT — the plugin does not
                            // supply that part, so a row cannot claim to have
                            // come from the shell. Composed in
                            // Manifest.launcherResults() rather than here, so
                            // the composition is asserted headlessly instead of
                            // eyeballed on a developer's screen.
                            Text {
                                width:          parent.width
                                visible:        modelData.kind === "plugin"
                                                && (modelData.detail ?? "") !== ""
                                text:           modelData.detail ?? ""
                                font.pixelSize: Theme.fs(10)
                                color:          Qt.rgba(1, 1, 1, 0.32)
                                elide:          Text.ElideRight
                                maximumLineCount: 1
                            }
                        }

                        // Pin toggle. Shown for a pinned app always (so the state
                        // is visible, not just discoverable) and otherwise only on
                        // hover or selection, to keep the list quiet.
                        Text {
                            id: pinBtn
                            anchors.verticalCenter: parent.verticalCenter
                            visible: !isText && (modelData.id ?? "") !== ""
                                     && (LauncherState.isPinned(modelData.id) || rowH.hovered || isSel)
                            text:   LauncherState.isPinned(modelData.id) ? "󰐃" : "󰤱"
                            font.pixelSize: Theme.fs(13)
                            color:  LauncherState.isPinned(modelData.id)
                                        ? Theme.active
                                        : Qt.rgba(1, 1, 1, pinArea.containsMouse ? 0.75 : 0.30)
                            Behavior on color { ColorAnimation { duration: 100 } }

                            MouseArea {
                                id: pinArea
                                anchors.fill: parent
                                anchors.margins: -6
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: LauncherState.togglePin(modelData.id)
                            }
                        }
                    }

                    HoverHandler { id: rowH; cursorShape: Qt.PointingHandCursor }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        // Sits under the pin button, which has its own MouseArea.
                        onEntered: root.selIndex = index
                        onClicked: function (mouse) {
                            if (mouse.button === Qt.RightButton) {
                                if ((modelData.id ?? "") !== "")
                                    LauncherState.togglePin(modelData.id)
                                return
                            }
                            root.activate(modelData)
                        }
                    }
                }
            }
        }

        // Search bar
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
                        text:    "Search apps   ·   ? asks a question"
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

                        Keys.onReturnPressed: {
                            if (root.selIndex >= 0 && root.selIndex < root.filtered.length)
                                root.activate(root.filtered[root.selIndex])
                        }

                        Keys.onEscapePressed: {
                            if (text !== "") {
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
