import QtQuick
import "../"
import "../components"

// ─────────────────────────────────────────────────────────────────────────────
// DashTabBar — the Dashboard's tab bar: its tabs, and at their end the door to
// Settings (SettingsDoor.qml).
//
// One component so the Dashboard and tests/nav-geometry-test.qml lay out the
// SAME row: the door's labelled width is reserved at the bar's end, the tabs
// share what is left, and the door is spelt out exactly when the tabs are.
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: row

    property string currentPage: ""
    signal picked(string key)

    readonly property alias tabs: tabBar
    readonly property alias door: settingsDoor
    function reset() { tabBar.reset() }

    implicitHeight: tabBar.implicitHeight

    TabSwitcher {
        id: tabBar
        orientation: "horizontal"
        width:       row.width - settingsDoor.labelledWidth
        height:      row.height
        currentPage: row.currentPage
        model:       DashboardLayout.tabs
        onPageChanged: function (key) { row.picked(key) }
    }
    SettingsDoor {
        id: settingsDoor
        anchors.right: parent.right
        width:     settingsDoor.labelledWidth
        height:    row.height
        metrics:   tabBar
        showLabel: tabBar.hShowLabels
    }
}
