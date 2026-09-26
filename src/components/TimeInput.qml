import QtQuick
import "../"

// TimeInput — reusable HH:MM input
// Props : hours (int, readonly), minutes (int, readonly), minuteStep (int, default 1)
// Call  : initialize(h, m) to push values from outside
//
// The ▲▼ buttons move the digits for the pointer. The wheel used to drive them
// too, and accepted the event on the way, so scrolling past an alarm both reset
// its time and left the page under it standing still.
//
// On the keyboard (UI/UX roadmap v3 Phase 21) each field is a spin box — one Tab
// stop, Up/Down a step, Home/End the ends — and the arrows are pointer targets
// only, as a spin box's are. The digits were a blue-tinted near-white, which a
// light palette turns invisible; they are the palette's text.

Item {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    readonly property int hours:   hVal
    readonly property int minutes: mVal

    property int minuteStep: 1
    property int hVal: 0
    property int mVal: 0

    function initialize(h, m) { hVal = h; mVal = m }

    function zp(n)  { var s = "" + n; return s.length < 2 ? "0" + s : s }
    function incH() { hVal = hVal >= 23 ? 0  : hVal + 1 }
    function decH() { hVal = hVal <= 0  ? 23 : hVal - 1 }
    function incM() { var n = mVal + minuteStep; mVal = n > 59 ? 0 : n }
    function decM() { var n = mVal - minuteStep; mVal = n < 0 ? Math.floor(59 / minuteStep) * minuteStep : n }

    implicitWidth:  _row.implicitWidth
    implicitHeight: _row.implicitHeight

    Row {
        id: _row
        spacing: 8

        // ══ HOURS ═════════════════════════════════════════════════════════════
        Column {
            spacing: 2
            width: 36

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "HH"; font.pixelSize: theme.fs(9); font.weight: Font.Medium
                font.family: "JetBrains Mono"
                color: Theme.textTertiary
            }

            Rectangle {
                width: parent.width; height: 22; radius: 6
                color: hUpH.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.08) : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.04)
                border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.08); border.width: 1
                Behavior on color { MotionColor {} }
                Text { anchors.centerIn: parent; text: "▲"; font.pixelSize: theme.fs(9); color: Theme.textSecondary }
                HoverHandler { id: hUpH; cursorShape: Qt.PointingHandCursor }
                MouseArea { anchors.fill: parent; onClicked: root.incH() }
            }

            Item {
                id: hField
                objectName: "hoursField"
                width: parent.width; height: 30
                activeFocusOnTab: true
                Accessible.role: Accessible.SpinBox
                Accessible.name: "Hours"
                Accessible.description: root.zp(root.hVal)
                Keys.onPressed: function (event) {
                    if      (event.key === Qt.Key_Up)   root.incH()
                    else if (event.key === Qt.Key_Down) root.decH()
                    else if (event.key === Qt.Key_Home) root.hVal = 0
                    else if (event.key === Qt.Key_End)  root.hVal = 23
                    else return
                    event.accepted = true
                }

                Text {
                    anchors.centerIn: parent
                    text: root.zp(root.hVal)
                    font.pixelSize: theme.fs(20); font.weight: Font.Bold
                    font.family: "JetBrains Mono"
                    color: Theme.textPrimary
                }
                Rectangle {
                    anchors.fill: parent; radius: 6
                    color: "transparent"; border.width: 2; border.color: Theme.accentText
                    visible: hField.activeFocus
                }
            }

            Rectangle {
                width: parent.width; height: 22; radius: 6
                color: hDnH.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.08) : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.04)
                border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.08); border.width: 1
                Behavior on color { MotionColor {} }
                Text { anchors.centerIn: parent; text: "▼"; font.pixelSize: theme.fs(9); color: Theme.textSecondary }
                HoverHandler { id: hDnH; cursorShape: Qt.PointingHandCursor }
                MouseArea { anchors.fill: parent; onClicked: root.decH() }
            }
        }

        // Colon
        Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 8
            text: ":"
            font.pixelSize: theme.fs(22); font.weight: Font.Bold
            font.family: "JetBrains Mono"
            color: Theme.textTertiary
        }

        // ══ MINUTES ═══════════════════════════════════════════════════════════
        Column {
            spacing: 2
            width: 36

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "MM"; font.pixelSize: theme.fs(9); font.weight: Font.Medium
                font.family: "JetBrains Mono"
                color: Theme.textTertiary
            }

            Rectangle {
                width: parent.width; height: 22; radius: 6
                color: mUpH.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.08) : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.04)
                border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.08); border.width: 1
                Behavior on color { MotionColor {} }
                Text { anchors.centerIn: parent; text: "▲"; font.pixelSize: theme.fs(9); color: Theme.textSecondary }
                HoverHandler { id: mUpH; cursorShape: Qt.PointingHandCursor }
                MouseArea { anchors.fill: parent; onClicked: root.incM() }
            }

            Item {
                id: mField
                objectName: "minutesField"
                width: parent.width; height: 30
                activeFocusOnTab: true
                Accessible.role: Accessible.SpinBox
                Accessible.name: "Minutes"
                Accessible.description: root.zp(root.mVal)
                Keys.onPressed: function (event) {
                    if      (event.key === Qt.Key_Up)   root.incM()
                    else if (event.key === Qt.Key_Down) root.decM()
                    else if (event.key === Qt.Key_Home) root.mVal = 0
                    else if (event.key === Qt.Key_End)  root.mVal = Math.floor(59 / root.minuteStep) * root.minuteStep
                    else return
                    event.accepted = true
                }

                Text {
                    anchors.centerIn: parent
                    text: root.zp(root.mVal)
                    font.pixelSize: theme.fs(20); font.weight: Font.Bold
                    font.family: "JetBrains Mono"
                    color: Theme.textPrimary
                }
                Rectangle {
                    anchors.fill: parent; radius: 6
                    color: "transparent"; border.width: 2; border.color: Theme.accentText
                    visible: mField.activeFocus
                }
            }

            Rectangle {
                width: parent.width; height: 22; radius: 6
                color: mDnH.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.08) : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.04)
                border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.08); border.width: 1
                Behavior on color { MotionColor {} }
                Text { anchors.centerIn: parent; text: "▼"; font.pixelSize: theme.fs(9); color: Theme.textSecondary }
                HoverHandler { id: mDnH; cursorShape: Qt.PointingHandCursor }
                MouseArea { anchors.fill: parent; onClicked: root.decM() }
            }
        }
    }
}
