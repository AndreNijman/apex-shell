import QtQuick
import Quickshell
import "../../"

// ============================================================
// TrayMenu — a tray item's context menu, drawn by the shell.
//
// QsMenuAnchor hands the menu to Qt, which draws it as a QWidget
// menu in the stock Fusion style: none of the shell's colours,
// radius or type. This renders the same DBusMenu tree through
// QsMenuOpener in the shell's own card, with rows styled like the
// power menu.
//
// Submenus open in place, with a Back row, instead of cascading
// into a second popup. grabFocus makes the compositor dismiss the
// menu on a click anywhere else; Escape closes it too.
// ============================================================

PopupWindow {
    id: root

    required property Item target
    property var menu: null

    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }

    // Submenus drilled into, outermost first. Empty = the top level.
    property var stack: []
    readonly property var current: stack.length > 0 ? stack[stack.length - 1] : menu

    readonly property int rowH: theme.px(30)
    readonly property int pad: theme.px(6)
    readonly property int radius: Math.min(theme.cornerRadius, theme.px(12))
    property real widest: 0

    function toggle() {
        if (visible) close()
        else {
            stack = []
            widest = 0
            visible = true
        }
    }
    function close() { visible = false }
    function push(entry) { widest = 0; stack = stack.concat([entry]) }
    function pop() { widest = 0; stack = stack.slice(0, -1) }

    anchor.item: target
    anchor.edges: Edges.Bottom | Edges.Left
    anchor.gravity: Edges.Bottom | Edges.Right
    anchor.margins.top: theme.px(6)

    grabFocus: true
    color: "transparent"
    visible: false

    // The WINDOW never changes size; the card inside it does. Entries arrive
    // over D-Bus after the menu is mapped and a submenu changes the row count,
    // and a mapped popup that is resized is not redrawn: measured on labwc, the
    // compositor stretched the first 10px-tall buffer to the new height and the
    // menu showed no rows at all. ArchMenu sizes itself to its largest page for
    // the same reason. The empty part of the window is outside the input mask.
    readonly property int maxW: theme.px(360)
    readonly property int maxH: theme.px(560)
    implicitWidth: maxW + pad * 2
    implicitHeight: maxH
    mask: Region { item: card }

    QsMenuOpener {
        id: opener
        menu: root.current
    }

    // When any entry carries a check or radio mark, every label is indented
    // by the mark's slot so the column of labels stays straight.
    readonly property bool anyCheckable: {
        const v = opener.children.values
        for (let i = 0; i < v.length; i++)
            if (!v[i].isSeparator && v[i].buttonType !== QsMenuButtonType.None) return true
        return false
    }

    Rectangle {
        id: card
        width: Math.max(root.theme.px(180), Math.min(root.maxW, root.widest)) + root.pad * 2
        height: Math.min(root.maxH, list.implicitHeight + root.pad * 2)
        radius: root.radius
        color: Theme.background
        border.color: Theme.border
        border.width: 1

        focus: true
        Keys.onEscapePressed: root.close()

        // Scrolls only when a menu is taller than maxH.
        Flickable {
            anchors.fill: parent
            anchors.margins: root.pad
            contentHeight: list.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            Column {
                id: list
                width: card.width - root.pad * 2
                spacing: 2

                // ── Back, inside a submenu ───────────────────────────
                MenuRow {
                    visible: root.stack.length > 0
                    glyph: "󰁍"
                    label: qsTr("Back")
                    onActivated: root.pop()
                }
                Rectangle {
                    visible: root.stack.length > 0
                    width: parent.width
                    height: 1
                    color: Theme.border
                }

                Repeater {
                    model: opener.children

                    delegate: Loader {
                        id: slot
                        required property var modelData
                        width: list.width
                        sourceComponent: modelData.isSeparator ? separator : entryRow

                        Component {
                            id: separator
                            Item {
                                height: root.pad + 1
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width
                                    height: 1
                                    color: Theme.border
                                }
                            }
                        }

                        Component {
                            id: entryRow
                            MenuRow {
                                entry: slot.modelData
                                label: slot.modelData.text
                                iconSource: slot.modelData.icon
                                enabledRow: slot.modelData.enabled
                                chevron: slot.modelData.hasChildren
                                onActivated: {
                                    if (slot.modelData.hasChildren) {
                                        root.push(slot.modelData)
                                    } else {
                                        slot.modelData.triggered()
                                        root.close()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // One row: optional check/radio mark, optional icon, label, chevron.
    component MenuRow: Rectangle {
        id: row

        property var entry: null
        property string glyph: ""
        property string label: ""
        property string iconSource: ""
        property bool enabledRow: true
        property bool chevron: false
        signal activated()

        readonly property bool checkable: entry !== null
            && entry.buttonType !== QsMenuButtonType.None
        readonly property bool checked: checkable && entry.checkState === Qt.Checked
        readonly property bool lit: hov.hovered && enabledRow
        readonly property color ink: lit ? Theme.fixedDark : Theme.text

        width: parent ? parent.width : 0
        height: root.rowH
        radius: root.radius - 2
        color: lit ? Theme.active : "transparent"
        opacity: enabledRow ? 1 : 0.4
        Behavior on color { MotionColor { role: "state" } }

        readonly property real needed: content.implicitWidth + (chevron ? root.theme.px(24) : 0) + root.theme.px(20)
        onNeededChanged: root.widest = Math.max(root.widest, needed)
        Component.onCompleted: root.widest = Math.max(root.widest, needed)

        Row {
            id: content
            anchors.left: parent.left
            anchors.leftMargin: root.theme.px(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.theme.px(8)

            // Check or radio mark; the slot is kept for alignment when unchecked.
            Text {
                visible: row.checkable || (row.entry !== null && root.anyCheckable)
                width: root.theme.px(14)
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignHCenter
                text: !row.checked ? ""
                    : row.entry.buttonType === QsMenuButtonType.RadioButton ? "●" : "󰄬"
                color: row.lit ? row.ink : Theme.active
                font.pixelSize: root.theme.fs(12)
            }

            Text {
                visible: row.glyph !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: row.glyph
                color: row.ink
                font.pixelSize: root.theme.fs(14)
            }

            Image {
                visible: row.iconSource !== "" && status === Image.Ready
                anchors.verticalCenter: parent.verticalCenter
                width: root.theme.px(16)
                height: root.theme.px(16)
                sourceSize.width: width
                sourceSize.height: height
                source: row.iconSource
                fillMode: Image.PreserveAspectFit
                smooth: true
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: row.label
                color: row.ink
                font.pixelSize: root.theme.fs(13)
            }
        }

        Text {
            visible: row.chevron
            anchors.right: parent.right
            anchors.rightMargin: root.theme.px(10)
            anchors.verticalCenter: parent.verticalCenter
            text: "󰅂"
            color: row.ink
            font.pixelSize: root.theme.fs(12)
        }

        HoverHandler {
            id: hov
            cursorShape: row.enabledRow ? Qt.PointingHandCursor : Qt.ArrowCursor
        }

        MouseArea {
            anchors.fill: parent
            enabled: row.enabledRow
            onClicked: row.activated()
        }
    }
}
