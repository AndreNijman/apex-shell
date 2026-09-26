import QtQuick
import QtQuick.Controls.Basic
import "../../"
import "../../components"

Item {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    required property var service

    readonly property bool _scrollable: flickable.contentHeight > flickable.height

    // ── Header ──────────────────────────────────────────────────────────────
    Item {
        id: headerRow
        anchors {
            top:   parent.top
            left:  parent.left
            right: parent.right
        }
        implicitHeight: headerLabel.implicitHeight
        height:         implicitHeight

        SectionLabel {
            id: headerLabel
            anchors.left: parent.left
            text: "Disks"
        }

        Text {
            visible:        root.service.disks.length > 0
            anchors {
                right:          parent.right
                rightMargin:    8
                verticalCenter: parent.verticalCenter
            }
            text:           root.service.disks.length
            font.pixelSize: theme.typeCaption
            font.weight:    Font.Medium
            color:          Theme.textTertiary
        }
    }

    // ── Standalone scrollbar — lives outside the Flickable ──────────────────
    ScrollBar {
        id: vScroll
        visible:     root._scrollable
        orientation: Qt.Vertical
        anchors {
            top:         flickable.top
            bottom:      flickable.bottom
            right:       parent.right
            rightMargin: 3
        }
        // Manually bind to Flickable
        size:     flickable.visibleArea.heightRatio
        position: flickable.visibleArea.yPosition
        onPositionChanged: if (active) flickable.contentY = position * flickable.contentHeight

        contentItem: Rectangle {
            implicitWidth:  2
            implicitHeight: 20
            radius:         width / 2
            color:          Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.5)
            opacity:        vScroll.active ? 1.0 : 0.0
            Behavior on opacity { MotionFade {} }
        }

        background: Rectangle {
            implicitWidth: 2
            radius:        width / 2
            color:         Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.08)
        }
    }

    // ── Flickable — stops before the scrollbar lane ──────────────────────────
    Flickable {
        id: flickable
        anchors {
            top:          headerRow.bottom
            topMargin:    6
            left:         parent.left
            right:        parent.right
            rightMargin:  root._scrollable ? 12 : 8
            bottom:       parent.bottom
            bottomMargin: 4
            leftMargin:   8
        }
        clip:           true
        contentHeight:  diskColumn.implicitHeight
        contentWidth:   width
        boundsBehavior: Flickable.StopAtBounds

        flickDeceleration:    2500
        maximumFlickVelocity: 1200

        Column {
            id: diskColumn
            width:   flickable.width
            spacing: 10

            Repeater {
                model: root.service.disks

                delegate: DiskBar {
                    width:    parent.width
                    source:   modelData.source
                    mount:    modelData.mount
                    usedPct:  modelData.usedPct
                    usedStr:  modelData.usedStr
                    totalStr: modelData.totalStr
                }
            }
        }
    }
}
