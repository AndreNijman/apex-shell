import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import "../../services"
import "../../"

// Compact task dock for labwc. Hyprland already provides fast directional
// focus in its tiling layout; labwc is a stacking compositor and needs a visible
// way to recover, raise, minimize and close overlapping windows.
Row {
    id: root

    required property string screenName
    required property int availableWidth
    readonly property int maxItems: Math.min(5,
        Math.max(0, Math.floor((availableWidth + spacing) / (26 + spacing))))
    readonly property var applications: Compositor.isLabwc ? _applications() : []
    readonly property var visibleApplications: applications.slice(0, maxItems)

    visible: Compositor.isLabwc && applications.length > 0 && maxItems > 0
    spacing: 2

    function _onThisScreen(toplevel) {
        const screens = toplevel.screens
        if (!screens || screens.length === 0 || root.screenName === "")
            return true
        for (const screen of screens)
            if (screen && screen.name === root.screenName)
                return true
        return false
    }

    function _applications() {
        const result = []
        const byKey = ({})

        // Pins keep their user-selected order and remain launchable when closed.
        for (const id of LauncherState.pinned) {
            const entry = DesktopEntries.byId(id)
            if (!entry)
                continue
            const app = { key: entry.id, entry: entry, appId: "", toplevels: [] }
            result.push(app)
            byKey[entry.id] = app
        }

        // Add one icon per application, not one per dialog/window.
        for (const toplevel of ToplevelManager.toplevels.values) {
            if (!toplevel || toplevel.parent || !root._onThisScreen(toplevel))
                continue

            const appId = (toplevel.appId || "").trim()
            const entry = appId === "" ? null : DesktopEntries.heuristicLookup(appId)
            const key = entry ? entry.id : (appId !== "" ? appId.toLowerCase() : null)
            if (!key) {
                // Some clients publish neither appId nor title. Keep each such
                // window recoverable instead of dropping it from the dock.
                result.push({
                    key: toplevel,
                    entry: null,
                    appId: "",
                    toplevels: [toplevel]
                })
                continue
            }

            let app = byKey[key]
            if (!app) {
                app = { key: key, entry: entry, appId: appId, toplevels: [] }
                result.push(app)
                byKey[key] = app
            }
            app.toplevels = app.toplevels.concat([toplevel])
        }

        return result
    }

    function _primary(app) {
        for (const toplevel of app.toplevels)
            if (toplevel.activated)
                return toplevel
        return app.toplevels.length > 0 ? app.toplevels[0] : null
    }

    function _activate(app) {
        let toplevel = _primary(app)
        if (toplevel) {
            if (toplevel.activated && app.toplevels.length > 1) {
                const current = app.toplevels.indexOf(toplevel)
                toplevel = app.toplevels[(current + 1) % app.toplevels.length]
                toplevel.minimized = false
                toplevel.activate()
            } else if (toplevel.activated && !toplevel.minimized) {
                toplevel.minimized = true
            } else {
                toplevel.minimized = false
                toplevel.activate()
            }
        } else if (app.entry) {
            app.entry.execute()
            LauncherState.recordLaunch(app.entry.id)
        }
    }

    Repeater {
        model: root.visibleApplications

        delegate: MouseArea {
            id: appButton
            required property var modelData

            readonly property bool active: {
                for (const toplevel of modelData.toplevels)
                    if (toplevel.activated)
                        return true
                return false
            }
            readonly property string appName: modelData.entry
                ? modelData.entry.name
                : (modelData.appId || (modelData.toplevels[0] ? modelData.toplevels[0].title : "Application"))

            width: 26
            height: 26
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
            cursorShape: Qt.PointingHandCursor

            Rectangle {
                anchors.fill: parent
                radius: 6
                color: appButton.active
                    ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.16)
                    : appButton.containsMouse
                        ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.09)
                        : "transparent"
                Behavior on color { ColorAnimation { duration: 120 } }

                Image {
                    id: appIcon
                    width: 16
                    height: 16
                    anchors.centerIn: parent
                    source: appButton.modelData.entry && appButton.modelData.entry.icon
                        ? "image://icon/" + appButton.modelData.entry.icon
                        : ""
                    sourceSize.width: 16
                    sourceSize.height: 16
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                }

                Text {
                    anchors.centerIn: parent
                    visible: appIcon.status !== Image.Ready
                    text: "󰣆"
                    color: appButton.active ? Theme.active : Theme.icon
                    font.pixelSize: Theme.fs(15)
                }

                Rectangle {
                    width: appButton.modelData.toplevels.length > 0 ? 10 : 4
                    height: 2
                    radius: 1
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 1
                    color: appButton.active ? Theme.active : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.35)
                }
            }

            ToolTip.visible: containsMouse
            ToolTip.delay: 500
            ToolTip.text: appName

            onClicked: function(mouse) {
                if (mouse.button === Qt.MiddleButton) {
                    const toplevel = root._primary(modelData)
                    if (toplevel) toplevel.close()
                } else {
                    root._activate(modelData)
                }
            }
        }
    }

}
