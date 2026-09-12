import Quickshell
import QtQuick
import "./src"
import "./src/nexus"
ShellRoot {
    Item {
        width: 900; height: 640
        Repeater {
            model: PageRegistry.pages
            delegate: Loader { required property var modelData; anchors.fill: parent; visible: false; sourceComponent: modelData.component }
        }
    }
    Timer { interval: 2500; running: true; onTriggered: Qt.exit(0) }
}
