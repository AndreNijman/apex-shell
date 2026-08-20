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

    readonly property var filtered: {
        var q = query.trim()
        if (q === "") return apps
        if (answerMode) return answerRows()
        return apps.filter(function(a) {
            return a.name.toLowerCase().indexOf(q.toLowerCase()) !== -1
        })
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
                "entry": e
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
        if (entry.kind === "answer" || entry.kind === "calculation") {
            ClipboardService.copyText(entry.value)
            Popups.dashboardOpen = false
            return
        }
        if (entry.entry) {
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
                        Text {
                            id: label
                            width: parent.width - 28 - parent.spacing
                            anchors.verticalCenter: parent.verticalCenter
                            text:           modelData.name
                            font.pixelSize: Theme.fs(13)
                            color:          isSel ? Theme.active : Theme.text
                            wrapMode:       isText ? Text.Wrap : Text.NoWrap
                            elide:          isText ? Text.ElideNone : Text.ElideRight
                            maximumLineCount: isText ? 8 : 1
                            Behavior on color { ColorAnimation { duration: 100 } }
                        }
                    }

                    HoverHandler { id: rowH; cursorShape: Qt.PointingHandCursor }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered:    root.selIndex = index
                        onClicked:    root.activate(modelData)
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
