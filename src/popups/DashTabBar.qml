import QtQuick
import "../"
import "../components"
import "../nexus"

// ─────────────────────────────────────────────────────────────────────────────
// DashTabBar — the Dashboard's tab bar: its tabs, and at their end Settings —
// a slot of the same switcher, drawn and spaced like a tab, that opens the
// Nexus instead of switching the page (DashboardLayout.tabBar; TabSwitcher's
// `action` entries).
//
// One component so the Dashboard and tests/nav-geometry-test.qml lay out the
// SAME row.
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: row

    property string currentPage: ""
    signal picked(string key)

    readonly property alias tabs: tabBar
    function reset() { tabBar.reset() }

    implicitHeight: tabBar.implicitHeight

    TabSwitcher {
        id: tabBar
        orientation: "horizontal"
        anchors.fill: parent
        currentPage: row.currentPage
        model:       DashboardLayout.tabBar
        onPageChanged: function (key) { row.picked(key) }
        // Settings: the Nexus, where it was last left; the Dashboard closes.
        onActionTriggered: function (key) {
            if (key !== "settings") return
            Popups.dashboardOpen = false
            NexusState.openAt("", Popups.dashboardScreen)
        }
    }
}
