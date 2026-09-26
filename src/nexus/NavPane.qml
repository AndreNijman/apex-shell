import QtQuick
import "../"
import "../components"
import "../components/controls"

// NavPane — the page list down the left of the Nexus window.
//
// Built from PageRegistry, so it never drifts from the pages that actually
// exist. Selection is by page id, not index, so reordering the registry cannot
// silently change which page a keybind opens.
//
// ── One selection, travelling (UI/UX roadmap v3 Phase 7 / 13) ───────────────
// Each row used to own an active tint and cross-fade it, so the selection
// vanished from one row and reappeared on another. Now one pill — tint and
// accent bar together — travels to the chosen row on the selection beat
// (emphasizedDecel); the rows draw only their hover, and the label colour
// changes at once on the state beat so the choice reads before the pill
// lands. It arms after its first placement, so a Nexus that opens does not
// slide its pill in from the top.
Item {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    required property string currentPage

    signal pageSelected(string id)

    implicitWidth: 240

    // ── Keyboard (UI/UX roadmap v3 Phase 21) ─────────────────────────────────
    // One Tab stop for the whole list, like a tab list: Up and Down move the
    // selection a page at a time (reveal() keeps it in view), Home and End jump
    // to the ends. Its rows were pointer-only; a row clicked never takes focus,
    // so the ring on the pill is keyboard-only by construction.
    activeFocusOnTab: true
    readonly property bool focusVisible: root.activeFocus
    Accessible.role: Accessible.PageTabList
    Accessible.name: "Settings pages"
    function _stepTo(i) {
        const list = PageRegistry.pages
        if (list.length === 0) return
        i = Math.max(0, Math.min(list.length - 1, i))
        if (list[i].id !== root.currentPage) root.pageSelected(list[i].id)
    }
    function _index() {
        const list = PageRegistry.pages
        for (let i = 0; i < list.length; i++) if (list[i].id === root.currentPage) return i
        return 0
    }
    Keys.onPressed: function(event) {
        if      (event.key === Qt.Key_Down) root._stepTo(root._index() + 1)
        else if (event.key === Qt.Key_Up)   root._stepTo(root._index() - 1)
        else if (event.key === Qt.Key_Home) root._stepTo(0)
        else if (event.key === Qt.Key_End)  root._stepTo(PageRegistry.pages.length - 1)
        else return
        event.accepted = true
    }

    // Scrolls, and is clipped to the window. The list is sixteen pages and
    // growing; as a bare Column it simply ran past the bottom of the Settings
    // window on a short screen, drawing "Pair a device" … "Misc" over whatever
    // was underneath and leaving them half off the card.
    // The heading stays put (UI/UX Phase 17): it was the first item in the
    // scrolled column, so a long page list scrolled it away (Keybinds) or out
    // of sight entirely (Misc). The page title's role, as the page's own title.
    Item {
        id: navHeader
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: root.theme.px(56)
        Text {
            anchors {
                left: parent.left
                leftMargin: root.theme.px(20)
                verticalCenter: parent.verticalCenter
                verticalCenterOffset: root.theme.px(5)
            }
            text: "Settings"
            color: Theme.textPrimary
            font.pixelSize: root.theme.typePageTitle
            font.weight: Font.DemiBold
        }
    }

    Flickable {
        id: flick
        anchors { top: navHeader.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }
        clip: true
        contentWidth: width
        contentHeight: col.height + root.theme.px(20)
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        // Keep the selected page in view when something other than a click
        // selects it — a keybind or a deep link to a page near the bottom.
        function reveal() {
            // Not before the list has a height: run then, "keep the selected
            // row in view" scrolled it to the bottom of a 0 px viewport, and
            // the offset stuck once the list was laid out — Nexus opened with
            // its current page (and the header) scrolled out of sight above.
            if (flick.height <= 0) return
            const list = PageRegistry.pages
            for (let i = 0; i < list.length; i++) {
                if (list[i].id !== root.currentPage) continue
                const item = pages.itemAt(i)
                if (!item) return
                const pad = root.theme.px(10)
                // The slot's top, so a group's first page brings its heading.
                const top = col.y + item.y
                const bottom = col.y + item.y + item.row.y + item.row.height
                if (top < flick.contentY)
                    flick.contentY = Math.max(0, top - pad)
                else if (bottom > flick.contentY + flick.height)
                    flick.contentY = Math.min(flick.contentHeight - flick.height, bottom - flick.height + pad)
                return
            }
        }

    // The shared selection. A sibling of the Column, not in it: the Column
    // would position it as a row.
    Rectangle {
        id: sel
        readonly property Item target: {
            // itemAt() is null until the Repeater has built the row and does
            // not notify when it has; `count` does, so the pill finds its row
            // on the first open instead of only after the first page change.
            if (pages.count === 0) return null
            const list = PageRegistry.pages
            for (let i = 0; i < list.length; i++)
                if (list[i].id === root.currentPage) return pages.itemAt(i)
            return null
        }
        // The slot's row, and where it sits in the list: below its group label.
        readonly property Item targetRow: sel.target ? sel.target.row : null
        property bool _placed: false
        visible: sel.target !== null
        x: col.x
        // On springs that keep their velocity through a second page change
        // mid-travel (SpringFollower: exact at any refresh rate).
        y: selY.value
        width: col.width
        height: selH.value
        SpringFollower { id: selY; live: sel._placed
                         target: sel.targetRow ? col.y + sel.target.y + sel.targetRow.y : 0 }
        SpringFollower { id: selH; live: sel._placed
                         target: sel.targetRow ? sel.targetRow.height : 0 }
        radius: theme.radiusM
        color: Theme.surfaceSelected
        onTargetChanged: if (sel.target && !sel._placed) armTimer.restart()
        Timer { id: armTimer; interval: 0; onTriggered: sel._placed = true }
        ApexFocusRing { target: root; targetRadius: sel.radius }

        // Active marker: a bar rather than only a tint, so the selected page
        // is still obvious at low contrast or with a pale accent.
        Rectangle {
            anchors {
                left: parent.left
                verticalCenter: parent.verticalCenter
            }
            width: theme.px(3)
            height: parent.height * 0.55
            radius: width
            color: Theme.active
        }
    }

    Column {
        id: col

        x: root.theme.px(10)
        y: root.theme.px(2)
        width: flick.width - root.theme.px(20)
        spacing: theme.px(2)

        Repeater {
            id: pages
            model: PageRegistry.pages

            // A slot per page: the group's section label above the first page
            // of each group (UI/UX Phase 19b), then the row. The pill and the
            // keep-in-view logic target the ROW (slot.row), so the selection
            // never covers a heading.
            delegate: Item {
                id: slot

                required property var modelData
                required property int index
                readonly property bool firstOfGroup: slot.index === 0
                    || PageRegistry.pages[slot.index - 1].group !== slot.modelData.group
                readonly property Item row: row

                width: parent.width
                height: (slot.firstOfGroup ? groupLabel.height : 0) + row.height

                SectionLabel {
                    id: groupLabel
                    visible: slot.firstOfGroup
                    width: parent.width
                    // CfgSection's slot: 18 for the first, 30 after, the text
                    // 6 above the rows; inset to the rows' icon column.
                    height: slot.firstOfGroup ? root.theme.px(slot.index === 0 ? 18 : 30) : 0
                    verticalAlignment: Text.AlignBottom
                    bottomPadding: root.theme.px(6)
                    leftPadding: root.theme.px(14)
                    text: slot.modelData.group || ""
                }

                Rectangle {
                    id: row

                    readonly property var modelData: slot.modelData
                    y: slot.firstOfGroup ? groupLabel.height : 0

                    readonly property bool active: root.currentPage === row.modelData.id
                    Accessible.role: Accessible.PageTab
                    Accessible.name: row.modelData.title
                    Accessible.selectable: true
                    Accessible.selected: row.active

                    width: parent.width
                    // 36, not 44: sixteen pages nearly fit the sheet without
                    // scrolling (brief §E "Nav rows", §F.8).
                    height: theme.controlComfortable
                    radius: theme.radiusM
                    // Hover only; the selection is the shared pill above.
                    color: !row.active && hov.hovered
                           ? Theme.surfaceHover(Theme.background) : "transparent"

                    Behavior on color { MotionColor {} }

                    Text {
                        id: icon
                        anchors {
                            left: parent.left
                            leftMargin: theme.px(14)
                            verticalCenter: parent.verticalCenter
                        }
                        text: row.modelData.icon
                        color: row.active ? Theme.accentText : Theme.iconDefault
                        font.pixelSize: theme.fs(15)
                        Behavior on color { MotionColor { role: "state" } }
                    }

                    Text {
                        anchors {
                            left: icon.right
                            leftMargin: theme.px(11)
                            right: parent.right
                            rightMargin: theme.px(8)
                            verticalCenter: parent.verticalCenter
                        }
                        text: row.modelData.title
                        // Selection is fill and colour, never bold (brief §C.4).
                        color: row.active ? Theme.textPrimary : Theme.textSecondary
                        font.pixelSize: theme.fs(12)
                        elide: Text.ElideRight
                        Behavior on color { MotionColor { role: "state" } }
                    }

                    HoverHandler { id: hov; cursorShape: Qt.PointingHandCursor }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.pageSelected(row.modelData.id)
                    }
                }
            }
        }
    }
    }

    onCurrentPageChanged: Qt.callLater(flick.reveal)
    Component.onCompleted: Qt.callLater(flick.reveal)
    Connections {
        target: flick
        function onHeightChanged() { Qt.callLater(flick.reveal) }
    }
}
