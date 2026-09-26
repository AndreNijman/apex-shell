import QtQuick
import "../../"
import "../../components"

// Power Profile panel — the named tiers apexd will actually accept, backed by
// PowerProfileService. The count is deliberately not repeated here: this comment
// said "5 named tiers (Ultra Max … Power Saver)" for a whole release after apexd
// had dropped two of them, so it documented buttons that could only fail. The
// list lives in PowerProfileService and nowhere else.
//
// The GPU Mode (envycontrol Integrated/Hybrid) selector was removed: this
// machine has only the Radeon 780M iGPU, no NVIDIA dGPU.
Item {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    required property var powerProfileService

    // Top-aligned, the profiles in one row (UI/UX Phase 17): three pills stacked
    // in the middle of the widest card on the page.
    implicitHeight: col.implicitHeight
    Column {
        id: col
        anchors { top: parent.top; left: parent.left; right: parent.right }
        spacing: theme.spaceS

        SectionLabel { text: "Power profile"; width: parent.width }

        Flow {
            width: parent.width
            spacing: theme.px(6)
            Repeater {
                model: root.powerProfileService.profiles
                ProfileButton {
                    required property var modelData
                    label:     modelData.label
                    active:    root.powerProfileService.current === modelData.id
                    enabled:   true
                    onClicked: root.powerProfileService.setProfile(modelData.id)
                }
            }
        }
    }
}
