import QtQuick
import Quickshell
import "../../"
import "../../components/controls"
import "layouts.js" as Layouts

// ─── LayoutMenu ─────────────────────────────────────────────────────────────
// The layout button's menu: every tiling layout, each as a picture of where
// the windows go, its name, and one line on what it does — so a layout is
// chosen, not found by clicking through them.
//
// It replaces a button that cycled to the next layout on every click, showing
// `><`, `M`, `|3|` or `<3>` (Andre, 2026-09-29: "its so hard to understand what
// each option does, it has to be intuitive"): nothing said what the next
// click would do, and one of the four (monocle) hides every window but one,
// with SUPER+arrow unable to reach the others.
//
// TrayMenu's pattern, for the same reason: a PopupWindow of the bar item with
// grabFocus, so the compositor dismisses it on a click anywhere else and the
// keyboard is its own while it is up — Up/Down share one highlight with the
// pointer, Return/Space choose, Escape closes. No Popups flag: nothing else
// opens it, and the grab already closes it.
// ────────────────────────────────────────────────────────────────────────────

PopupWindow {
    id: root

    required property Item target
    // The layout names Hyprland knows, in menu order (CompositorService.layouts).
    property var layouts: []
    property string current: ""
    signal chosen(string layout)

    // Sized for the output the bar item is on (BarTooltip's reason: a
    // PopupWindow's own `screen` is not the output it is anchored to).
    readonly property ThemeSet theme: ThemeSet {
        scale: Theme.factorForScreen(root.anchor.window ? root.anchor.window.screen : null)
    }

    readonly property int pad:     theme.px(6)
    readonly property int radius:  Math.min(theme.cornerRadius, theme.px(12))
    readonly property int glyphW:  theme.px(30)
    readonly property int glyphH:  theme.px(21)
    readonly property int cardW:   theme.px(330)

    property int curIndex: -1

    function toggle() {
        if (root.visible) { root.close(); return }
        root.curIndex = -1
        // Hang below the notch, not inside it: the button sits in the notch's
        // middle, so its own bottom edge is several pixels above the notch's.
        const p = root.target.mapToItem(null, 0, 0)
        root.anchor.margins.top = Math.max(theme.px(6),
            theme.notchHeight - Math.round(p.y + root.target.height) + theme.px(6))
        root.visible = true
        popIn.restart()
    }
    function close() { root.visible = false }

    function _step(d) {
        const n = root.layouts.length
        if (n === 0) return
        const from = root.curIndex >= 0 ? root.curIndex : root.layouts.indexOf(root.current)
        root.curIndex = from < 0 ? (d > 0 ? 0 : n - 1) : Math.max(0, Math.min(n - 1, from + d))
    }
    function _choose(i) {
        if (i < 0 || i >= root.layouts.length) return
        root.chosen(root.layouts[i])
        root.close()
    }

    anchor.item: target
    anchor.edges: Edges.Bottom | Edges.Left
    anchor.gravity: Edges.Bottom | Edges.Right

    grabFocus: true
    color: "transparent"
    visible: false

    implicitWidth:  card.width
    implicitHeight: card.height

    Rectangle {
        id: card
        width: root.cardW
        height: list.implicitHeight + root.pad * 2
        radius: root.radius
        color: Theme.background
        border.color: Theme.border
        border.width: 1

        focus: true
        Keys.onEscapePressed: root.close()
        Keys.onPressed: function (event) {
            InputModality.key(event)
            if      (event.key === Qt.Key_Down) root._step(1)
            else if (event.key === Qt.Key_Up)   root._step(-1)
            else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                      || event.key === Qt.Key_Space) && root.curIndex >= 0) root._choose(root.curIndex)
            else return
            event.accepted = true
        }

        // TrayMenu's entrance (PIVOT_POP, brief B.8): from the corner at the
        // button, a fade on the state beat and 0.97 → 1 on emphasizedDecel. No
        // exit: a click elsewhere is the compositor dismissing the popup.
        transformOrigin: Item.TopLeft
        ParallelAnimation {
            id: popIn
            NumberAnimation {
                target: card; property: "opacity"; from: 0; to: 1
                duration: Motion.state
                easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.standardDecel
            }
            NumberAnimation {
                target: card; property: "scale"; from: Motion.selection > 0 ? 0.97 : 1; to: 1
                duration: Motion.selection
                easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.emphasizedDecel
            }
        }

        Column {
            id: list
            x: root.pad
            y: root.pad
            width: card.width - root.pad * 2
            spacing: 2

            Text {
                width: parent.width
                leftPadding: root.theme.px(10)
                topPadding: root.theme.px(4)
                bottomPadding: root.theme.px(4)
                text: "Window layout"
                color: Theme.textSecondary
                font.pixelSize: root.theme.typeCaption
                font.weight: Font.DemiBold
            }

            Repeater {
                model: root.layouts

                delegate: Rectangle {
                    id: row
                    required property string modelData
                    required property int index

                    readonly property bool selected: row.modelData === root.current
                    readonly property bool lit: hov.hovered || root.curIndex === row.index

                    Accessible.role: Accessible.MenuItem
                    Accessible.name: Layouts.name(row.modelData) + ". " + Layouts.detail(row.modelData)
                    Accessible.checkable: true
                    Accessible.checked: row.selected
                    Accessible.onPressAction: root._choose(row.index)

                    width: list.width
                    height: Math.max(root.theme.rowHeightTwoLine, words.implicitHeight + root.theme.px(14))
                    radius: root.radius - 2
                    color: row.selected ? Theme.surfaceSelected
                         : row.lit      ? Theme.surfaceHover(Theme.background)
                         :                "transparent"
                    Behavior on color { MotionColor { role: "state" } }

                    LayoutGlyph {
                        id: pic
                        anchors.left: parent.left
                        anchors.leftMargin: root.theme.px(10)
                        anchors.verticalCenter: parent.verticalCenter
                        width: root.glyphW
                        height: root.glyphH
                        layout: row.modelData
                        gap: root.theme.px(2)
                        tileRadius: root.theme.px(2)
                        ink: row.selected ? Theme.accentText : Theme.textPrimary
                        surface: row.color.a > 0 ? row.color : Theme.background
                    }

                    Column {
                        id: words
                        anchors.left: pic.right
                        anchors.leftMargin: root.theme.px(12)
                        anchors.right: check.left
                        anchors.rightMargin: root.theme.px(8)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: root.theme.px(1)

                        Text {
                            width: parent.width
                            text: Layouts.name(row.modelData)
                            color: row.selected ? Theme.accentText : Theme.textPrimary
                            font.pixelSize: root.theme.typeBodyStrong
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                        }
                        Text {
                            width: parent.width
                            visible: text !== ""
                            text: Layouts.detail(row.modelData)
                            color: Theme.textSecondary
                            font.pixelSize: root.theme.typeCaption
                            wrapMode: Text.WordWrap
                        }
                    }

                    // The one in use. The slot is kept on every row so the
                    // words wrap at the same width whichever is chosen.
                    Text {
                        id: check
                        anchors.right: parent.right
                        anchors.rightMargin: root.theme.px(10)
                        anchors.verticalCenter: parent.verticalCenter
                        width: root.theme.px(16)
                        horizontalAlignment: Text.AlignHCenter
                        text: row.selected ? "󰄬" : ""
                        color: Theme.accentText
                        font.family: Theme.fontIcon
                        font.pixelSize: root.theme.typeIcon
                    }

                    HoverHandler {
                        id: hov
                        cursorShape: Qt.PointingHandCursor
                        onHoveredChanged: if (hovered) root.curIndex = row.index
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root._choose(row.index)
                    }
                }
            }

            // Hyprland's layout is one setting for the whole session, not one
            // per workspace, and the menu should not let anyone think otherwise.
            Text {
                width: parent.width
                leftPadding: root.theme.px(10)
                rightPadding: root.theme.px(10)
                topPadding: root.theme.px(4)
                bottomPadding: root.theme.px(2)
                text: "Applies to every workspace."
                color: Theme.textTertiary
                font.pixelSize: root.theme.typeCaption
                wrapMode: Text.WordWrap
            }
        }
    }
}
