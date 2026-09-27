import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.SystemTray
import "../../components"
import "../../components/controls"
import "../../"

RowLayout {
    id: root

    readonly property bool hasItems: SystemTray.items.values.length > 0
    visible: hasItems
    spacing: 2

    // The background apps toggle. A circled ellipsis said "more", not
    // "background apps" (Andre, 2026-09-27: "i still dont think the
    // background tasks icon shouts background tasks"), and no single glyph
    // says it either, so the toggle says it twice: Material's dock-window (a
    // window with another behind it) and, while the row is folded, HOW MANY
    // apps are running back there — "N active apps" is how a phone says the
    // same thing. Open is the bar's own open state (accent glyph on the
    // OpenPill, as the notch's panes show it) instead of a filled twin, which
    // the dock-window has none of. The count folds away while the icons are
    // out: they are the count then.
    //
    // It comes FIRST and the icons unfold to its right. After it, they grew
    // leftward and pushed it out from under the pointer, which then rested on
    // the first app's icon: a second click meant to fold the row activated
    // that app instead (measured in the nested harness).
    ApexPressable {
        id: toggle

        readonly property int count: SystemTray.items.values.length
        readonly property bool open: trayRow.isOpen

        Layout.alignment: Qt.AlignVCenter
        implicitWidth: toggleRow.implicitWidth
        implicitHeight: theme.px(20)
        radius: height / 2
        pressedScale: 0.96
        hitMargin: Math.max(0, (theme.hitBar - implicitHeight) / 2)
        Accessible.name: toggle.open ? "Hide background apps"
                       : "Background apps, " + toggle.count + " running"
        onActivated: trayRow.isOpen = !trayRow.isOpen

        readonly property color _ink: toggle.open || toggle.pressed ? Theme.accentText
                                    : toggle.hovered ? Theme.textPrimary : Theme.iconDefault

        Row {
            id: toggleRow
            anchors.verticalCenter: parent.verticalCenter

            Item {
                implicitWidth: toggle.implicitHeight
                implicitHeight: toggle.implicitHeight

                OpenPill { shown: toggle.open }
                Text {
                    anchors.centerIn: parent
                    text: "\u{f10ac}"
                    font.family: Theme.fontIcon
                    font.pixelSize: toggle.theme.typeIcon
                    color: toggle._ink
                    Behavior on color { MotionColor { role: "hover" } }
                }
            }

            // The gap is inside the fold, so it closes with the number.
            Item {
                id: countWrap
                readonly property real gap: 3   // the volume and battery readouts' gap
                anchors.verticalCenter: parent.verticalCenter
                implicitWidth: countW.value
                implicitHeight: countText.implicitHeight
                clip: true
                SpringFollower { id: countW; role: "page"; target: toggle.open ? 0 : countWrap.gap + countText.implicitWidth + 2 }

                Text {
                    id: countText
                    x: countWrap.gap
                    anchors.verticalCenter: parent.verticalCenter
                    text: String(toggle.count)
                    color: toggle.hovered ? Theme.textPrimary : Theme.textSecondary
                    font.pixelSize: toggle.theme.typeBodySmall
                    font.features: { "tnum": 1 }
                    Behavior on color { MotionColor {} }
                }
            }
        }

        ApexFocusRing { target: toggle }

        BarTooltip {
            target: toggle
            text: toggle.open ? "Hide background apps"
                : toggle.count === 1 ? "1 app running in the background"
                : toggle.count + " apps running in the background"
            shown: toggle.hovered && !toggle.pressed
        }
    }

    RowLayout {
        id: trayRow
        Layout.alignment: Qt.AlignVCenter
        property bool isOpen: false

        visible: opacity > 0
        opacity: isOpen ? 1 : 0
        Layout.preferredWidth: isOpen ? implicitWidth : 0
        clip: true
        spacing: 2

        // The shell's beats (UI/UX Phase 1): the row opens like a small
        // surface and its icons arrive on the content fade.
        Behavior on opacity { MotionFade { role: "fadeIn" } }
        Behavior on Layout.preferredWidth { MotionMove { role: "surfaceEnterSmall"; curve: Motion.emphasizedDecel } }

        Repeater {
            model: SystemTray.items
            delegate: MouseArea {
                id: trayItem

                required property var modelData

                width: 26
                height: 26
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton

                // No fill: in the bar the icon alone answers a hover (brief
                // §D.6, as IconBtn does). An application's icon cannot be
                // recoloured, so it lifts from a quieter rest instead.
                Item {
                    anchors.fill: parent

                    Image {
                        opacity: trayItem.containsMouse ? 1.0 : 0.8
                        Behavior on opacity { MotionFade { role: "hover" } }
                        width: 16
                        height: 16
                        anchors.centerIn: parent
                        source: trayItem.modelData.icon
                        sourceSize.width: 16
                        sourceSize.height: 16
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                    }
                }

                // A press hides the label until the pointer leaves, so it is
                // not left standing next to the menu the press opened.
                property bool tipSuppressed: false
                onPressed: tipSuppressed = true
                onExited: tipSuppressed = false

                BarTooltip {
                    target: trayItem
                    text: trayItem.modelData.tooltipTitle || trayItem.modelData.title || trayItem.modelData.id || ""
                    shown: trayItem.containsMouse && !trayItem.tipSuppressed && !trayMenu.visible
                }

                onClicked: (mouse) => {
                    if (mouse.button === Qt.MiddleButton) {
                        modelData.secondaryActivate()
                    } else if (mouse.button === Qt.RightButton || modelData.onlyMenu) {
                        if (modelData.hasMenu) trayMenu.toggle()
                    } else {
                        modelData.activate()
                    }
                }

                onWheel: (wheel) => {
                    const horizontal = Math.abs(wheel.angleDelta.x) > Math.abs(wheel.angleDelta.y)
                    const delta = horizontal ? wheel.angleDelta.x : wheel.angleDelta.y
                    modelData.scroll(delta, horizontal)
                    wheel.accepted = true
                }

                TrayMenu {
                    id: trayMenu
                    target: trayItem
                    menu: trayItem.modelData.menu
                }
            }
        }
    }
}
