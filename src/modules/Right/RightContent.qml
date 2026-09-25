import QtQuick
import Quickshell
import "../../components"
import "../../windows"
import "../../"

Item {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    // The TopBar widens the notch for whatever pours out of it (RightPanel);
    // this is only the notch's natural content.
    implicitWidth: contentRow.implicitWidth

    //Behavior on implicitWidth {
    //    NumberAnimation { duration: Theme.animDuration; easing.type: Easing.InOutCubic }
    //}
    implicitHeight: contentRow.implicitHeight

    // ── Status cluster ────────────────────────────────────────────────────────
    // Right-anchored, and it stays put and visible while a right panel is open:
    // the notch widens to the left of it, and the control that opened the
    // panel carries the open state itself (OpenPill, brief §D.5). It used to
    // fade out for a ▾, so the bar lost its readout exactly while the panel
    // showed the same thing.
    Row {
        id: contentRow
        //anchors.centerIn: parent
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6

        // Third-party bar widgets (roadmap §16). Leftmost in the cluster so the
        // shell's own indicators keep the positions users have muscle memory
        // for — a plugin appearing must not move the clock. Collapses to zero
        // width when no plugin is installed, which is the common case.
        PluginWidgets{}

        Network{}
        Audio{}
        Battery{}
        Clock{}
        Notifications{}
    }
}
