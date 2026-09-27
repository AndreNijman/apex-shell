import QtQuick
import "../"
import "../components/controls"
import "../nexus"

// ─────────────────────────────────────────────────────────────────────────────
// SettingsDoor — the way into Settings from the Dashboard's tab bar.
//
// Settings have one home, the Nexus: a window of its own, not a Dashboard tab
// (UI/UX Phase 19 removed the Config tab — it was a second host of every page).
// That left no visible way in: a keybind, the launcher's search, IPC. Andre,
// 2026-09-27: "people will have no idea how to reach a kind of config/settings".
//
// So the tab bar ends with this: drawn like a tab — the same pill, glyph, label
// and hover — so it is found where the tabs are, but set apart by a hairline
// and never selected, because it does not switch the page; it opens the Nexus
// (where it was last left) and the Dashboard gets out of its way.
//
//   showLabel   the tab bar's own verbosity (TabSwitcher.hShowLabels): spelt
//               out beside spelt-out tabs, a bare gear beside bare icons
//   metrics     the TabSwitcher it sits beside, for its sizes
//
// `labelledWidth` is what it needs WITH its label. The Dashboard reserves that
// whatever the label is doing, so the tab bar's width never depends on the
// label and the label never on the tab bar's width (no layout loop).
// ─────────────────────────────────────────────────────────────────────────────
ApexPressable {
    id: door

    required property Item metrics
    property bool showLabel: true
    readonly property string label: qsTr("Settings")
    readonly property string glyph: "󰒓"

    readonly property real _pad: door.metrics.hPadMax
    // Air and the hairline before the pill, then the pill with its label.
    readonly property real _lead: 2 * door.metrics.hGutter
    readonly property real labelledWidth:
        door._lead + probeIcon.implicitWidth + door.metrics.hIconGap + probeLabel.implicitWidth + 2 * door._pad
    readonly property real _contentWidth: icon.implicitWidth + (word.visible ? door.metrics.hIconGap + word.implicitWidth : 0)

    implicitHeight: door.metrics.implicitHeight
    implicitWidth: door.labelledWidth
    radius: pill.radius
    Accessible.name: door.label
    Accessible.description: qsTr("Open the settings window")

    onActivated: {
        Popups.dashboardOpen = false
        NexusState.openAt("", Popups.dashboardScreen)
    }

    // Measures its label as the tab bar measures its own: glyphs arrive by
    // font fallback, so a probe rather than FontMetrics.
    Text { id: probeIcon; visible: false; text: door.glyph; font.pixelSize: door.metrics.hIconSize }
    Text { id: probeLabel; visible: false; text: door.label; font.pixelSize: door.metrics.hLabelSize }

    // Set apart from the tabs: it is an action, not a place.
    Rectangle {
        anchors.right: pill.left
        anchors.rightMargin: door.metrics.hGutter
        anchors.verticalCenter: parent.verticalCenter
        width: 1
        height: Math.round(pill.height * 0.5)
        color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10)
    }

    Rectangle {
        id: pill
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: door._contentWidth + 2 * door._pad
        height: Math.max(0, parent.height - door.theme.px(8))
        radius: height / 2
        color: door.hovered || door.pressed ? door.stateLayer() : "transparent"
        Behavior on color { MotionColor { role: "state" } }
        ApexFocusRing { target: door }

        Row {
            anchors.centerIn: parent
            spacing: word.visible ? door.metrics.hIconGap : 0
            Text {
                id: icon
                anchors.verticalCenter: parent.verticalCenter
                text: door.glyph
                font.pixelSize: door.metrics.hIconSize
                color: door.hovered ? Theme.textPrimary : Theme.textSecondary
                Behavior on color { MotionColor { role: "state" } }
            }
            Text {
                id: word
                anchors.verticalCenter: parent.verticalCenter
                visible: door.showLabel
                text: door.label
                font.pixelSize: door.metrics.hLabelSize
                color: icon.color
            }
        }
    }

    // The tab bar's own bottom divider, continued under the door.
    Rectangle {
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07)
    }

}
