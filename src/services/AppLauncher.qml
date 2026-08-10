import QtQuick
import QtQuick.Controls
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

    readonly property var calculation: calculate(query)

    readonly property var filtered: {
        var q = query.toLowerCase().trim()
        if (q === "") return apps
        var matches = apps.filter(function(a) {
            return a.name.toLowerCase().indexOf(q) !== -1
        })
        if (calculation.valid) {
            matches.unshift({
                kind: "calculation",
                name: calculation.expression + " = " + calculation.formatted,
                value: calculation.formatted,
                icon: "",
                exec: ""
            })
        }
        return matches
    }

    // Recursive-descent arithmetic parser. Keeping this local avoids executing
    // launcher input as JavaScript or passing it through a shell.
    function calculate(input) {
        var expression = input.trim()
        var explicit = expression.charAt(0) === "="
        if (explicit) expression = expression.substring(1).trim()
        if (expression === "" || (!explicit && !/[+\-*/%^()]/.test(expression)))
            return { valid: false }

        var pos = 0
        function skipSpace() {
            while (pos < expression.length && /\s/.test(expression.charAt(pos))) pos++
        }
        function primary() {
            skipSpace()
            if (expression.charAt(pos) === "(") {
                pos++
                var grouped = addSubtract()
                skipSpace()
                if (expression.charAt(pos) !== ")") throw "missing close parenthesis"
                pos++
                return grouped
            }

            var start = pos
            var dots = 0
            while (pos < expression.length) {
                var c = expression.charAt(pos)
                if (c >= "0" && c <= "9") {
                    pos++
                } else if (c === "." && dots === 0) {
                    dots++
                    pos++
                } else {
                    break
                }
            }
            if (start === pos || expression.substring(start, pos) === ".") throw "number expected"
            return Number(expression.substring(start, pos))
        }
        function unary() {
            skipSpace()
            if (expression.charAt(pos) === "+") { pos++; return unary() }
            if (expression.charAt(pos) === "-") { pos++; return -unary() }
            return primary()
        }
        function power() {
            var value = unary()
            skipSpace()
            if (expression.charAt(pos) === "^") {
                pos++
                value = Math.pow(value, power())
            }
            return value
        }
        function multiplyDivide() {
            var value = power()
            while (true) {
                skipSpace()
                var op = expression.charAt(pos)
                if (op !== "*" && op !== "/" && op !== "%") return value
                pos++
                var rhs = power()
                if (op === "*") value *= rhs
                else if (op === "/") value /= rhs
                else value %= rhs
            }
        }
        function addSubtract() {
            var value = multiplyDivide()
            while (true) {
                skipSpace()
                var op = expression.charAt(pos)
                if (op !== "+" && op !== "-") return value
                pos++
                var rhs = multiplyDivide()
                value = op === "+" ? value + rhs : value - rhs
            }
        }

        try {
            var result = addSubtract()
            skipSpace()
            if (pos !== expression.length || !isFinite(result)) return { valid: false }
            var formatted = String(Number(result.toPrecision(12)))
            return { valid: true, expression: expression, formatted: formatted }
        } catch (e) {
            return { valid: false }
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
        if (!visible) return
        root.loading   = true
        root.apps      = []
        root.query     = ""
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
        if (entry.kind === "calculation") {
            ClipboardService.copyText(entry.value)
            Popups.dashboardOpen = false
        } else {
            launch(entry.exec)
        }
    }

    // ── Layout ────────────────────────────────────────────────────────────────
    Column {
        anchors.fill: parent
        spacing: 8

        // App list
        Item {
            width:  parent.width
            height: parent.height - searchBar.height - parent.spacing

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
                                    text:           modelData.kind === "calculation"
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
        }

        // Search bar
        Rectangle {
            id: searchBar
            width: parent.width; height: 44; radius: 12
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
                        text:    "Search apps or calculate…"
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
