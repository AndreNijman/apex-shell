import QtQuick
import "../../"
import "../../components"

Item {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    required property var service

    // Top-aligned under a section label (UI/UX Phase 17): it sat centred in a
    // tall card of its own. Up and down in the same colour — green for one and
    // the accent for the other said nothing.
    implicitHeight: col.implicitHeight
    Column {
        id: col
        anchors { top: parent.top; left: parent.left; right: parent.right }
        spacing: theme.spaceS

        SectionLabel { text: "Network"; width: parent.width }

        Column {
            width:   parent.width
            spacing: theme.px(4)
            StatRow { width: parent.width; label: "Interface"; value: root.service.iface }
            StatRow { width: parent.width; label: "↑ Upload";   value: root.service.upSpeed }
            StatRow { width: parent.width; label: "↓ Download"; value: root.service.downSpeed }
        }
    }
}
