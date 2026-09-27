import QtQuick
import Quickshell.Services.Pipewire
import "../../components"
import "../../"

Item {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    property bool showPercentage: false

    implicitWidth:  row.implicitWidth
    implicitHeight: row.implicitHeight

    readonly property var sink: Pipewire.defaultAudioSink

    PwObjectTracker {
        objects: root.sink ? [root.sink] : []
    }

    readonly property string icon: {
        if (!sink?.ready)            return "󰕾"
        if (sink.audio.muted)        return "󰝟"
        if (sink.audio.volume > 0.6) return "󰕾"
        if (sink.audio.volume > 0.2) return "󰖀"
        return "󰕿"
    }

    readonly property int pct: sink?.ready ? Math.round(sink.audio.volume * 100) : 0

    HoverHandler {
        id: hov
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 3

        Text {
            id: iconText
            text:           root.icon
            color:          Popups.audioOpen ? Theme.accentText
                          : hov.hovered ? Theme.textPrimary : Theme.iconDefault
            font.pixelSize: theme.typeIcon
            font.family:    Theme.fontIcon
            anchors.verticalCenter: parent.verticalCenter
            Behavior on color { MotionColor {} }
            OpenPill { shown: Popups.audioOpen }
        }

        Item {
            id: pctWrapper
            property bool show: root.showPercentage || hov.hovered
            implicitWidth: pctW.value
            SpringFollower { id: pctW; role: "page"; target: pctWrapper.show ? pctText.implicitWidth + 2 : 0 }
            implicitHeight: pctText.implicitHeight
            clip: true
            anchors.verticalCenter: parent.verticalCenter
        
            Text {
                id: pctText
                text:           root.pct + "%"
                color:          hov.hovered ? Theme.textPrimary : Theme.textSecondary
                font.pixelSize: theme.typeBodySmall
                font.features:  { "tnum": 1 }
                anchors.verticalCenter: parent.verticalCenter
                Behavior on color { MotionColor {} }
            }
        }
    }

    MouseArea {
        anchors.fill:        parent
        acceptedButtons:     Qt.LeftButton | Qt.RightButton

        onClicked: function(mouse) {
            if (mouse.button === Qt.RightButton) {
                if (root.sink?.ready)
                    root.sink.audio.muted = !root.sink.audio.muted
            } else {
                var next = !Popups.audioOpen
                Popups.closeAll()
                Popups.audioOpen = next
            }
        }
    }
}
