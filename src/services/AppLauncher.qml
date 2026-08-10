import QtQuick
import QtQuick.Controls
import QtWebEngine
import Quickshell.Io
import Quickshell
import "../"

// AppLauncher — scrollable app list + bottom search bar.
// Lives inside Dashboard.qml on the "launcher" page.
// Dashboard is PanelWindow with WlrKeyboardFocus.OnDemand,
// so TextInput receives keys without extra wiring.

Item {
    id: root

    // ── State ─────────────────────────────────────────────────────────────────
    property var  apps:     []
    property bool loading:  true
    property int  selIndex: -1
    property string query:  ""
    property string wolframUrl: ""

    readonly property var wolfram: wolframQuery(query)
    readonly property bool showingWolfram: wolframUrl !== ""
    readonly property bool shouldAutoQuery: {
        if (!wolfram.valid)
            return false
        if (wolfram.explicit || looksComputational(query))
            return true
        var q = query.toLowerCase().trim()
        return !apps.some(function(app) {
            return app.name.toLowerCase().indexOf(q) !== -1
        })
    }

    Shortcut {
        enabled: root.showingWolfram
        sequences: [StandardKey.Cancel]
        context: Qt.WindowShortcut
        onActivated: root.wolframUrl = ""
    }

    readonly property var filtered: {
        var q = query.trim()
        if (q === "") return apps
        var matches = wolfram.explicit ? [] : apps.filter(function(a) {
            return a.name.toLowerCase().indexOf(q.toLowerCase()) !== -1
        })
        if (wolfram.valid) {
            var entry = {
                kind: "wolfram",
                name: "Wolfram|Alpha  ·  " + wolfram.query,
                value: wolfram.query,
                icon: "",
                exec: ""
            }
            if (wolfram.explicit || matches.length === 0 || looksComputational(q))
                matches.unshift(entry)
            else
                matches.push(entry)
        }
        return matches
    }

    function wolframQuery(input) {
        var value = input.trim()
        var explicit = false
        if (value.charAt(0) === "=") {
            explicit = true
            value = value.substring(1).trim()
        } else if (/^(wa|wolfram(?:\s*alpha)?)\s+/i.test(value)) {
            explicit = true
            value = value.replace(/^(wa|wolfram(?:\s*alpha)?)\s+/i, "").trim()
        }
        return { valid: value !== "", explicit: explicit, query: value }
    }

    function looksComputational(input) {
        return /[0-9+\-*/%^=()]/.test(input)
            || /\b(integrate|differentiate|derive|solve|factor|plot|limit|sum|convert|weather|distance|population|molar|matrix|statistics)\b/i.test(input)
    }

    function scheduleWolframQuery() {
        wolframDebounce.stop()
        root.wolframUrl = ""
        if (searchInput.text !== root.query)
            searchInput.text = root.query
        if (root.shouldAutoQuery)
            wolframDebounce.restart()
    }

    onQueryChanged: scheduleWolframQuery()
    onShouldAutoQueryChanged: scheduleWolframQuery()

    Timer {
        id: wolframDebounce
        interval: 650
        onTriggered: {
            if (root.shouldAutoQuery)
                root.wolframUrl = "https://www.wolframalpha.com/input?i="
                                + encodeURIComponent(root.wolfram.query)
        }
    }

    // ── Load apps ─────────────────────────────────────────────────────────────
    Process {
        id: listProc
        command: ["python3", Quickshell.shellDir + "/src/scripts/list_apps.py"]
        running: false
        stdout: StdioCollector {
            id: listBuf
            onStreamFinished: {
                try   { root.apps = JSON.parse(listBuf.text) }
                catch (e) { root.apps = [] }
                root.loading  = false
                root.selIndex = root.apps.length > 0 ? 0 : -1
            }
        }
    }

    onVisibleChanged: {
        if (!visible) {
            root.wolframUrl = ""
            return
        }
        root.loading   = true
        root.apps      = []
        root.query     = ""
        root.wolframUrl = ""
        root.selIndex  = -1
        searchInput.text = ""
        listProc.running = false
        listProc.running = true
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

    function launch(exec) {
        launcher.command = ["bash", "-c", "setsid " + exec + " &>/dev/null &"]
        launcher.running = false
        launcher.running = true
        Popups.dashboardOpen = false
    }

    function activate(entry) {
        if (entry.kind === "wolfram") {
            root.wolframUrl = "https://www.wolframalpha.com/input?i="
                            + encodeURIComponent(entry.value)
        } else {
            launch(entry.exec)
        }
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
                    text: "󰣪"; font.pixelSize: 32
                    color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.3)
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text:           "Loading apps…"
                    color:          Qt.rgba(1,1,1,0.25)
                    font.pixelSize: 13
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
                    font.pixelSize: 28
                    color:          Qt.rgba(1,1,1,0.18)
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text:           root.query !== "" ? "No results" : "No apps found"
                    color:          Qt.rgba(1,1,1,0.25)
                    font.pixelSize: 13
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

                    width:  appList.width - 8
                    height: 46
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
                                    text:           modelData.kind === "wolfram"
                                                    ? "󰪚"
                                                    : modelData.name.charAt(0).toUpperCase()
                                    font.pixelSize: 13; font.bold: true
                                    color:          Theme.active
                                }
                            }
                        }

                        // App name
                        Text {
                            width: parent.width - 28 - parent.spacing
                            anchors.verticalCenter: parent.verticalCenter
                            text:           modelData.name
                            font.pixelSize: 13
                            color:          isSel ? Theme.active : Theme.text
                            elide:          Text.ElideRight
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

            Loader {
                anchors.fill: parent
                active: root.showingWolfram
                sourceComponent: Component {
                    Rectangle {
                        id: wolframPane
                        color: Theme.background

                        WebEngineProfilePrototype {
                            id: wolframProfilePrototype
                            storageName: "apex-wolfram-alpha"
                        }
                        property var wolframProfile: wolframProfilePrototype.instance()

                        Connections {
                            target: wolframPane.wolframProfile
                            function onDownloadRequested(download) {
                                download.accept()
                            }
                        }

                        Column {
                            anchors.fill: parent
                            spacing: 8

                            Rectangle {
                                width: parent.width
                                height: 40
                                radius: 8
                                color: Qt.rgba(1, 1, 1, 0.06)
                                border.color: Qt.rgba(1, 1, 1, 0.10)

                                Row {
                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    spacing: 4

                                    ToolButton {
                                        width: 40
                                        height: 40
                                        text: "󰅖"
                                        font.pixelSize: 16
                                        onClicked: root.wolframUrl = ""
                                    }

                                    ToolButton {
                                        width: 40
                                        height: 40
                                        text: "󰁍"
                                        font.pixelSize: 16
                                        enabled: webView.canGoBack
                                        opacity: enabled ? 1 : 0.3
                                        onClicked: webView.goBack()
                                    }

                                    Text {
                                        width: parent.width - 176
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: webView.title || "Wolfram|Alpha"
                                        color: Theme.text
                                        font.pixelSize: 12
                                        elide: Text.ElideRight
                                    }

                                    ToolButton {
                                        width: 40
                                        height: 40
                                        text: "󰏌"
                                        font.pixelSize: 16
                                        onClicked: Qt.openUrlExternally(webView.url)
                                    }

                                    ToolButton {
                                        width: 40
                                        height: 40
                                        text: "󰑐"
                                        font.pixelSize: 16
                                        onClicked: webView.reload()
                                    }
                                }
                            }

                            Item {
                                width: parent.width
                                height: parent.height - 48
                                clip: true

                                WebEngineView {
                                    id: webView
                                    anchors.fill: parent
                                    url: root.wolframUrl
                                    focus: false
                                    profile: wolframPane.wolframProfile

                                    onNewWindowRequested: function(request) {
                                        if (request.userInitiated)
                                            request.openIn(webView)
                                    }
                                    onFullScreenRequested: function(request) {
                                        request.accept()
                                    }
                                    onPermissionRequested: function(permission) {
                                        var origin = String(permission.origin)
                                        if (/^https:\/\/([^.]+\.)*wolframalpha\.com(?::|\/|$)/i.test(origin))
                                            permission.grant()
                                        else
                                            permission.deny()
                                    }
                                }

                                Rectangle {
                                    anchors.top: parent.top
                                    width: parent.width * webView.loadProgress / 100
                                    height: 2
                                    color: Theme.active
                                    visible: webView.loading
                                }
                            }
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
                    text: "󰍉"; font.pixelSize: 16
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
                        text:    "Search apps or ask Wolfram|Alpha…"
                        color:   Qt.rgba(1,1,1,0.22)
                        font.pixelSize: 13
                        visible: searchInput.text === ""
                    }

                    TextInput {
                        id: searchInput
                        anchors { fill: parent; topMargin: 2; bottomMargin: 2 }
                        verticalAlignment: TextInput.AlignVCenter
                        color:          Theme.text
                        font.pixelSize: 13
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
                            if (root.showingWolfram) {
                                root.wolframUrl = ""
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
