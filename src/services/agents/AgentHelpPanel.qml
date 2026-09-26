import QtQuick
import QtQuick.Controls
import "../"
import "../../"

// ─── AgentHelpPanel ───────────────────────────────────────────────────────────
// "How Agents & Workspaces work", in full (roadmap §43).
//
// An overlay inside the Agents page rather than a window of its own. A window
// would be a second thing to position, a second thing to close and a second
// keyboard-focus owner on the Wayland overlay layer; the page it explains is
// two pixels behind it, and the dashboard already dismisses on a click outside.
// KanbanBoard's date picker is the same shape.
//
// Contents live in AgentHelpContent. Nothing here decides what the guide says,
// so a wording change is one file and a layout change is the other.

Item {
    id: panel
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    anchors.fill: parent
    z: 50
    visible: AgentHelp.panelOpen

    readonly property var _section: {
        const all = AgentHelpContent.sections
        for (var i = 0; i < all.length; i++)
            if (all[i].id === AgentHelp.section) return all[i]
        return all[0]
    }

    // ── Escape closes the guide, and only the guide ───────────────────────────
    // Dashboard.qml:262 closes the whole dashboard on Escape. On `panel` itself
    // (UI/UX roadmap v3 Phase 21) rather than on a sibling proxy item: the nav
    // list and the close button are now real Tab stops INSIDE `card`, and an
    // unhandled key only propagates up the FOCUSED item's own ancestor chain —
    // a sibling never sees it. `panel` is the one item every focusable control
    // in the guide sits under, so it is where this has to live.
    Keys.onEscapePressed: function (ev) {
        if (!AgentHelp.panelOpen) return
        AgentHelp.close()
        panel.closedByKey()
        ev.accepted = true
    }

    // Closed from the keyboard (Escape, or Close activated by a key): the page
    // puts the keys back on the entry that opens the guide. A pointer close
    // moves nothing, so no ring lights for a click.
    signal closedByKey()

    // Hidden while the Dashboard is still open: the page keeps the keys. Not
    // when the Dashboard itself closes — it resets its own focus then, and
    // this would undo it.
    onVisibleChanged: {
        if (panel.visible) { panel._keyNav = false; panel._first().forceActiveFocus() }
        else if (panel.parent && Popups.dashboardOpen) panel.parent.forceActiveFocus()
    }

    // A modal guide owns the keys while it is up (UI/UX roadmap v3 Phase 21):
    // it opens on its section list, so the arrows work at once, and Tab and
    // Shift+Tab stay inside it, between the list and Close — they used to walk
    // on into the tab bar and the help strip BEHIND it. The trap is
    // KeyNavigation on the two stops: Qt moves Tab focus at the focused item,
    // so an ancestor's Keys never sees it. The section ring waits for a key,
    // so a guide opened with the pointer lights nothing.
    property bool _keyNav: false
    function _first() { return nav.activeFocusOnTab ? nav : closeBtn }
    Keys.onPressed: function (ev) { panel._keyNav = true }

    // ── Dim the page behind ───────────────────────────────────────────────────
    // Plain decimals, not a palette token: this has to darken whatever the page
    // is showing, so it must not follow the theme. Same call as KanbanBoard's
    // picker scrim.
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.45)
        MouseArea {
            anchors.fill: parent
            onClicked: AgentHelp.close()
        }
    }

    Rectangle {
        id: card
        anchors.fill: parent
        anchors.margins: theme.px(4)
        radius: theme.cornerRadius
        color: Theme.background
        border.width: 1
        border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.12)

        // Swallow clicks, or they reach the scrim and close the guide.
        MouseArea { anchors.fill: parent; onClicked: {} }

        // ── Title bar ─────────────────────────────────────────────────────────
        Item {
            id: titleBar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: theme.px(14)
            anchors.rightMargin: theme.px(8)
            height: theme.px(38)

            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: AgentHelpContent.entryLabel
                color: Theme.text
                font.pixelSize: theme.fs(13)
                font.bold: true
            }

            SmallIconButton {
                id: closeBtn
                KeyNavigation.tab:     panel._first()
                KeyNavigation.backtab: panel._first()
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                icon: "󰅖"
                tip: "Close  ·  Escape"
                onActivated: {
                    const byKey = closeBtn.focusVisible   // it takes no focus on a press
                    AgentHelp.close()
                    if (byKey) panel.closedByKey()
                }
            }
        }

        Rectangle {
            id: rule
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: titleBar.bottom
            height: 1
            color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10)
        }

        // ── Left: the sections ────────────────────────────────────────────────
        // A tab list (UI/UX roadmap v3 Phase 21), same pattern as NavPane: one
        // Tab stop for the whole column, Up/Down move the section, Home/End
        // jump to the ends. Visuals are untouched — a click still recolours
        // one row directly, with no shared sliding pill to introduce.
        Column {
            id: nav
            anchors.left: parent.left
            anchors.top: rule.bottom
            anchors.bottom: parent.bottom
            anchors.margins: theme.px(8)
            width: Math.min(theme.px(184), Math.floor(card.width * 0.32))
            spacing: theme.px(2)

            activeFocusOnTab: AgentHelpContent.sections.length > 1
            KeyNavigation.tab:     closeBtn
            KeyNavigation.backtab: closeBtn
            Accessible.role: Accessible.PageTabList
            Accessible.name: "Guide sections"

            function _stepTo(i) {
                const list = AgentHelpContent.sections
                if (list.length === 0) return
                i = Math.max(0, Math.min(list.length - 1, i))
                if (list[i].id !== AgentHelp.section) AgentHelp.section = list[i].id
            }
            function _index() {
                const list = AgentHelpContent.sections
                for (let i = 0; i < list.length; i++) if (list[i].id === AgentHelp.section) return i
                return 0
            }
            Keys.onPressed: function (event) {
                panel._keyNav = true          // it accepts its keys: the panel never sees them
                if      (event.key === Qt.Key_Down) nav._stepTo(nav._index() + 1)
                else if (event.key === Qt.Key_Up)   nav._stepTo(nav._index() - 1)
                else if (event.key === Qt.Key_Home) nav._stepTo(0)
                else if (event.key === Qt.Key_End)  nav._stepTo(AgentHelpContent.sections.length - 1)
                else return
                event.accepted = true
            }

            Repeater {
                model: AgentHelpContent.sections

                delegate: Rectangle {
                    id: navItem
                    required property var modelData

                    readonly property bool current: modelData.id === AgentHelp.section

                    Accessible.role: Accessible.PageTab
                    Accessible.name: navItem.modelData.title
                    Accessible.selectable: true
                    Accessible.selected: navItem.current

                    width: nav.width
                    height: theme.px(30)
                    radius: theme.px(7)
                    color: navItem.current
                        ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.22)
                        : navHover.hovered
                          ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07)
                          : "transparent"

                    Behavior on color { MotionColor { role: "state" } }

                    Row {
                        anchors.fill: parent
                        anchors.leftMargin: theme.px(9)
                        anchors.rightMargin: theme.px(6)
                        spacing: theme.px(8)

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: theme.px(16)
                            horizontalAlignment: Text.AlignHCenter
                            text: navItem.modelData.icon
                            font.pixelSize: theme.fs(12)
                            color: navItem.current ? Theme.active : Theme.subtext
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - theme.px(24) - parent.spacing
                            text: navItem.modelData.title
                            elide: Text.ElideRight
                            font.pixelSize: theme.fs(11)
                            color: navItem.current ? Theme.text : Theme.subtext
                        }
                    }

                    // Keyboard highlight — outset, list-focus only, same shape
                    // as the other two panes' row rings. Drawn only for the
                    // current section: there is no separate "keyed but not
                    // selected" state here, unlike Wi-Fi/Clipboard's rows —
                    // arrowing IS choosing, the way NavPane and TabSwitcher do.
                    Rectangle {
                        anchors.fill: parent; anchors.margins: -3
                        radius: navItem.radius + 3
                        color: "transparent"; border.width: 2; border.color: Theme.accentText
                        visible: navItem.current && nav.activeFocus && panel._keyNav
                    }

                    HoverHandler { id: navHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: AgentHelp.section = navItem.modelData.id }
                }
            }
        }

        // ── Right: the section itself ─────────────────────────────────────────
        ScrollView {
            id: body
            anchors.left: nav.right
            anchors.right: parent.right
            anchors.top: rule.bottom
            anchors.bottom: parent.bottom
            anchors.leftMargin: theme.px(6)
            anchors.rightMargin: theme.px(10)
            anchors.topMargin: theme.px(4)
            anchors.bottomMargin: theme.px(8)
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            // Scroll back to the top when the section changes. Landing halfway
            // down a page you have never read is disorienting, and the
            // ScrollView keeps its offset across a model swap otherwise.
            Connections {
                target: AgentHelp
                function onSectionChanged() {
                    if (body.contentItem) body.contentItem.contentY = 0
                }
            }

            Column {
                width: body.availableWidth - theme.px(6)
                spacing: 0

                Item { width: 1; height: theme.px(2) }

                Repeater {
                    model: panel._section ? panel._section.blocks : []

                    delegate: AgentHelpBlock {
                        required property var modelData
                        width: parent.width
                        block: modelData
                    }
                }

                Item { width: 1; height: theme.px(14) }
            }
        }
    }
}
