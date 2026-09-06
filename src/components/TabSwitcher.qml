import QtQuick
import QtQuick.Controls
import "../"

// Unified tab switcher — horizontal or vertical.
//
// orientation: "horizontal" (default) — Row, tabs spaced across the parent width
//              "vertical"             — Column, tabs spaced down the parent height
//
// Horizontal: icon + label pill, bottom divider. Used by the Dashboard, the
//             Config page's own sub-tabs, the network popup and the clock card.
// Vertical:   icon pill, with a label where the model carries one. Used by the
//             audio popup and the Config page's settings list.
//
// Model: [{ key: string, icon: string, label?: string }]
// label is optional — only rendered in horizontal orientation.
//
// Sizing contract:
//   Horizontal — parent MUST set width.  implicitHeight is Theme.px(40).
//   Vertical   — parent MUST set height. implicitWidth  is Theme.px(40).
//
// ── Why the horizontal row has tiers ────────────────────────────────────────
// The pill used to be sized `icon + label + 24` and centred inside a cell of
// `width / count`, with nothing relating the two numbers. Whenever the cell
// came out narrower than the pill — a scaled-up shell, a dashboard squeezed by
// a small output, a longer label — the pills grew straight through each other
// and the six dashboard tabs overlapped. That is the bug a user reported.
//
// So the row adapts, in this order:
//
//   comfortable  equal cells, full padding, icon + label      (the 1080p look)
//   compact      cells sized to their own label and centred as a group, tighter
//                padding; every word stays. Worth about a fifth of the row,
//                because an equal cell has to fit "Config" and then gives the
//                same room to "Home".
//   icons        labels drop, and the SELECTED tab keeps its label, so the
//                section you are in is always named rather than left as a bare
//                glyph. Every other tab names itself on hover and to a screen
//                reader, and its pill is at least as wide as it is tall so it
//                stays a target.
//   squeeze      equal cells, icon only, pill clamped to its cell
//
// The tier is chosen from icon and label text widths. Those are font-engine
// results and do not vary with the tier, which is what makes them safe to
// decide it: a tier derived from the pills it produces oscillates between two
// answers forever.
//
// Under all four tiers sits the invariant they exist to make presentable — a
// pill is never wider than its cell less `_tabGap`. Tabs cannot overlap even if
// every tier picks wrong.
//
// Keyboard: Tab reaches the row, Left/Right walk it, Space or Return selects.

Item {
    id: root

    property var    model:       []
    property string currentPage: ""
    property string orientation: "horizontal"   // "horizontal" | "vertical"

    signal pageChanged(string key)

    // ── Default page & reset ──────────────────────────────────────────────────
    // defaultPage auto-resolves to the first model entry.
    // Call reset() from the popup's close handler to restore it off-screen.
    property string defaultPage: model.length > 0 ? model[0].key : ""

    function reset() {
        pageChanged(defaultPage)
    }

    implicitWidth:  orientation === "vertical"   ? Theme.px(40) : 0
    implicitHeight: orientation === "horizontal" ? Theme.px(40) : 0

    readonly property int count: root.model ? root.model.length : 0

    // ── Selection ─────────────────────────────────────────────────────────────
    // Shared by the wheel handler and the arrow keys so the two can never
    // disagree about what "the next tab" means.
    function step(delta) {
        if (root.count === 0)
            return
        const keys = root.model.map(function (m) { return m.key })
        var idx = keys.indexOf(root.currentPage)
        if (idx < 0)
            idx = 0
        idx = (idx + delta + keys.length) % keys.length
        root.pageChanged(keys[idx])
        root.carryFocusTo(idx)
    }

    // Move keyboard focus along with the selection, but only when the row
    // already had it. Without the check a wheel scroll over the tabs would pull
    // focus off whatever the user was typing into.
    function carryFocusTo(idx) {
        const rep = root.orientation === "vertical" ? vRepeater : hRepeater
        var held = false
        for (var i = 0; i < rep.count; i++) {
            const item = rep.itemAt(i)
            if (item && item.activeFocus) {
                held = true
                break
            }
        }
        if (!held)
            return
        const target = rep.itemAt(idx)
        if (target)
            target.forceActiveFocus(Qt.TabFocusReason)
    }

    // ── Scroll cooldown ───────────────────────────────────────────────────────
    property bool scrollBusy: false

    Timer {
        id: scrollCooldown
        interval: 300
        repeat:   false
        onTriggered: root.scrollBusy = false
    }

    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: function(event) {
            if (root.scrollBusy)
                return
            root.scrollBusy = true
            scrollCooldown.restart()
            root.step(event.angleDelta.y < 0 ? 1 : -1)
        }
    }

    // ── Horizontal metrics ────────────────────────────────────────────────────
    // _padComfort + _gapComfort is 24 at scale 1.0, which is what the pill was
    // padded by before the tiers existed — the comfortable tier is the old look
    // to the pixel on the panel the shell was calibrated on.
    readonly property int _padComfort: Theme.px(18)   // pill padding, both sides
    readonly property int _padCompact: Theme.px(10)
    readonly property int _padIcon:    Theme.px(10)
    readonly property int _gapComfort: Theme.px(6)    // icon → label
    readonly property int _gapCompact: Theme.px(4)
    readonly property int _tabGap:     Theme.px(4)    // clear space between pills
    readonly property int _pillInset:  Theme.px(8)    // bar height − pill height

    readonly property int  _pillHeight: Math.max(Theme.px(16), root.height - root._pillInset)
    readonly property real _cellWidth:  root.count > 0 ? root.width / root.count : 0

    // Icon and label widths across the tabs, at the one font size the row uses:
    // the widest of each, which is what an equal-cell tier has to fit, and the
    // total, which is what a content-sized tier has to fit. Kept by the
    // delegates rather than derived, because a Repeater's items cannot be
    // reached from a binding — see remeasure().
    property real _widestIcon:  0
    property real _widestLabel: 0
    property real _sumIcon:     0
    property real _sumLabel:    0

    function remeasure() {
        var wi = 0, wl = 0, si = 0, sl = 0
        for (var i = 0; i < hRepeater.count; i++) {
            const item = hRepeater.itemAt(i)
            if (!item)
                continue
            wi = Math.max(wi, item.iconWidth)
            wl = Math.max(wl, item.labelWidth)
            si += item.iconWidth
            sl += item.labelWidth
        }
        root._widestIcon  = wi
        root._widestLabel = wl
        root._sumIcon     = si
        root._sumLabel    = sl
    }

    readonly property string sizeTier: {
        if (root.orientation !== "horizontal" || root.count === 0)
            return "comfortable"

        // Equal cells have to fit the WIDEST tab in every cell, so "Home" is
        // given as much room as "Config" and most of it goes unused.
        const widest = root._widestIcon + root._widestLabel
        if (widest + root._gapComfort + root._padComfort + root._tabGap <= root._cellWidth)
            return "comfortable"

        // Sizing each cell to its own label buys that waste back, and tightening
        // the padding buys a little more. Both together are worth about a fifth
        // of the row before a single word has to go.
        const compactRow = root._sumIcon + root._sumLabel
            + root.count * (root._gapCompact + root._padCompact + root._tabGap)
        if (compactRow <= root.width)
            return "compact"

        // Icon-only, except for whichever tab is selected. Priced against the
        // longest label, because any of them can be the selected one.
        const iconPill = Math.max(root._widestIcon + root._padIcon, root._pillHeight)
        const activePill = widest + root._gapCompact + root._padCompact
        if ((root.count - 1) * (iconPill + root._tabGap) + activePill + root._tabGap <= root.width)
            return "icons"

        return "squeeze"
    }

    // ── HORIZONTAL layout — Row ───────────────────────────────────────────────
    // The Row sizes itself to its cells and is centred. Under the equal-cell
    // tiers that adds up to the full width and the centring does nothing; under
    // the content-sized ones the group is narrower than the bar and sits in the
    // middle of it.
    Row {
        id: hRow
        visible: root.orientation === "horizontal"
        height:  root.height
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter:   parent.verticalCenter

        Repeater {
            id: hRepeater
            model: root.orientation === "horizontal" ? root.model : []

            onCountChanged: root.remeasure()

            delegate: Item {
                id: hTab
                objectName: "tabswitcher-tab:" + modelData.key

                readonly property bool isActive: root.currentPage === modelData.key
                readonly property bool showLabel:
                    modelData.label !== undefined && modelData.label !== ""
                    && (root.sizeTier === "comfortable"
                        || root.sizeTier === "compact"
                        || (root.sizeTier === "icons" && hTab.isActive))

                // Font-engine widths. They do not vary with the tier, which is
                // what makes the tier safe to derive from them.
                readonly property real iconWidth:  hIcon.implicitWidth
                readonly property real labelWidth: hLabelSize.implicitWidth

                onIconWidthChanged:  root.remeasure()
                onLabelWidthChanged: root.remeasure()
                Component.onCompleted: root.remeasure()

                readonly property int pad:
                    root.sizeTier === "comfortable" ? root._padComfort
                  : hTab.showLabel                  ? root._padCompact
                  :                                   root._padIcon
                readonly property int gap:
                    root.sizeTier === "comfortable" ? root._gapComfort : root._gapCompact

                // An icon-only pill is at least as wide as it is tall, so it
                // reads as a circle and stays a real click and touch target
                // rather than a glyph-sized sliver.
                readonly property real naturalWidth:
                    hTab.showLabel
                        ? hTab.iconWidth + hTab.gap + hTab.labelWidth + hTab.pad
                        : Math.max(hTab.iconWidth + hTab.pad, root._pillHeight)

                // The two equal-cell tiers keep the row evenly divided; the two
                // that gave that up size each cell to what is in it and let the
                // Row centre the group.
                width: (root.sizeTier === "compact" || root.sizeTier === "icons")
                    ? hTab.naturalWidth + root._tabGap
                    : root._cellWidth
                height: hRow.height

                Behavior on width {
                    NumberAnimation { duration: Theme.animDuration; easing.type: Easing.InOutCubic }
                }

                activeFocusOnTab: true

                Accessible.role: Accessible.PageTab
                Accessible.name: (modelData.label !== undefined && modelData.label !== "")
                    ? modelData.label : modelData.key
                Accessible.selected: hTab.isActive
                Accessible.onPressAction: root.pageChanged(modelData.key)

                Keys.onLeftPressed:  root.step(-1)
                Keys.onRightPressed: root.step(1)
                Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Space
                        || event.key === Qt.Key_Return
                        || event.key === Qt.Key_Enter) {
                        root.pageChanged(modelData.key)
                        event.accepted = true
                    }
                }

                // The label's natural width, measured whether or not the label
                // is on screen. Reading it off the visible Text would make the
                // measurement disappear the moment the icons tier hid it, and
                // the row could never climb back out of that tier.
                Text {
                    id: hLabelSize
                    visible: false
                    text:           modelData.label ?? ""
                    font.pixelSize: Theme.fs(12)
                    font.weight:    Font.Medium
                }

                // Pill background
                Rectangle {
                    id: hBg
                    objectName: "tabswitcher-pill:" + modelData.key
                    anchors.centerIn: parent

                    // The invariant: a pill never outgrows its own cell.
                    width:  Math.min(hTab.naturalWidth, hTab.width - root._tabGap)
                    height: root._pillHeight
                    radius: height / 2
                    clip:   true

                    color: hTab.isActive
                    ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.18)
                    : (hHov.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07) : "transparent")

                    Behavior on color { ColorAnimation { duration: 120 } }

                    // Icon + label
                    Row {
                        anchors.centerIn: parent
                        spacing: hTab.showLabel ? hTab.gap : 0

                        Text {
                            id: hIcon
                            text:           modelData.icon
                            font.pixelSize: Theme.fs(14)
                            anchors.verticalCenter: parent.verticalCenter
                            color: hTab.isActive
                            ? Theme.active
                            : (hHov.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.75)
                                            : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.4))
                            Behavior on color { ColorAnimation { duration: 120 } }
                        }

                        Text {
                            id: hLabel
                            visible:        hTab.showLabel
                            text:           modelData.label ?? ""
                            font.pixelSize: Theme.fs(12)
                            font.weight:    hTab.isActive ? Font.Medium : Font.Normal
                            anchors.verticalCenter: parent.verticalCenter
                            color: hTab.isActive
                            ? Theme.active
                            : (hHov.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.75)
                                            : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.4))
                            Behavior on color { ColorAnimation { duration: 120 } }
                        }
                    }
                }

                // Keyboard focus ring. Drawn outside the pill's clip so it is
                // still a ring when the pill is a circle.
                Rectangle {
                    anchors.fill:  hBg
                    radius:        hBg.radius
                    color:         "transparent"
                    border.width:  Theme.px(2)
                    border.color:  Theme.active
                    visible:       hTab.activeFocus
                }

                // A tab that has dropped its label says what it is on hover, so
                // the icons tier is never a row of unexplained glyphs.
                ToolTip.visible: hHov.hovered && !hTab.showLabel
                                 && modelData.label !== undefined && modelData.label !== ""
                ToolTip.text:    modelData.label ?? ""
                ToolTip.delay:   400

                HoverHandler { id: hHov; cursorShape: Qt.PointingHandCursor }
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        hTab.forceActiveFocus(Qt.MouseFocusReason)
                        root.pageChanged(modelData.key)
                    }
                }
            }
        }
    }

    // Bottom divider — horizontal only
    Rectangle {
        visible:        root.orientation === "horizontal"
        anchors.bottom: parent.bottom
        anchors.left:   parent.left
        anchors.right:  parent.right
        height:         1
        color:          Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07)
    }

    // ── VERTICAL layout — Column ──────────────────────────────────────────────
    // Same overlap problem, same answer: the row of tabs is given the height it
    // actually has rather than a fixed 60 per tab. Where they no longer fit, the
    // tabs shorten and the gaps close, instead of the spacing going negative and
    // stacking the tabs on top of each other.
    Column {
        id: vCol
        anchors.centerIn: parent
        visible: root.orientation === "vertical"
        width:   root.width

        // The floor is 24 unscaled px on purpose. Every other number here is a
        // 1080p token multiplied by the shell's scale, but a pointer target is
        // measured against a finger, not against the shell — scaling the floor
        // is what pushes a nine-entry list out of a column it would otherwise
        // have fitted.
        readonly property int tabH: Math.max(
            24,
            Math.min(Theme.px(60),
                     root.count > 0 ? root.height / root.count : Theme.px(60)))

        spacing: root.count > 1
            ? Math.max(0, (root.height - root.count * tabH) / (root.count - 1))
            : 0

        readonly property bool hasLabels:
            root.count > 0 &&
            root.model[0].label !== undefined &&
            root.model[0].label !== ""

        Repeater {
            id: vRepeater
            model: root.orientation === "vertical" ? root.model : []

            delegate: Rectangle {
                id: vTab
                objectName: "tabswitcher-vtab:" + modelData.key

                readonly property bool isActive: root.currentPage === modelData.key

                width:  vCol.width
                height: vCol.tabH
                radius: Theme.cornerRadius * 2
                clip:   true

                color: vTab.isActive
                    ? Theme.active
                    : (vHov.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.08) : "transparent")

                Behavior on color { ColorAnimation { duration: 120 } }

                activeFocusOnTab: true

                Accessible.role: Accessible.PageTab
                Accessible.name: (modelData.label !== undefined && modelData.label !== "")
                    ? modelData.label : modelData.key
                Accessible.selected: vTab.isActive
                Accessible.onPressAction: root.pageChanged(modelData.key)

                Keys.onUpPressed:   root.step(-1)
                Keys.onDownPressed: root.step(1)
                Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Space
                        || event.key === Qt.Key_Return
                        || event.key === Qt.Key_Enter) {
                        root.pageChanged(modelData.key)
                        event.accepted = true
                    }
                }

                // Icon-only (no label)
                Text {
                    visible:          !vCol.hasLabels
                    anchors.centerIn: parent
                    text:             modelData.icon
                    font.pixelSize:   Theme.fs(16)
                    color: vTab.isActive ? Theme.background : Theme.text
                    Behavior on color { ColorAnimation { duration: 120 } }
                }

                // Icon + label row
                Row {
                    visible: vCol.hasLabels
                    anchors {
                        left:           parent.left
                        leftMargin:     Theme.px(16)
                        verticalCenter: parent.verticalCenter
                    }
                    spacing: Theme.px(12)

                    Text {
                        text:           modelData.icon
                        font.pixelSize: Theme.fs(15)
                        anchors.verticalCenter: parent.verticalCenter
                        color: vTab.isActive
                            ? Theme.background
                            : (vHov.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.80)
                                            : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.42))
                        Behavior on color { ColorAnimation { duration: 120 } }
                    }

                    Text {
                        text:           modelData.label ?? ""
                        font.pixelSize: Theme.fs(12)
                        font.weight:    vTab.isActive ? Font.Medium : Font.Normal
                        anchors.verticalCenter: parent.verticalCenter
                        color: vTab.isActive
                            ? Theme.background
                            : (vHov.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.80)
                                            : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.42))
                        Behavior on color { ColorAnimation { duration: 120 } }
                    }
                }

                // Keyboard focus ring, same as the horizontal row's.
                Rectangle {
                    anchors.fill: parent
                    radius:       parent.radius
                    color:        "transparent"
                    border.width: Theme.px(2)
                    border.color: Theme.active
                    visible:      vTab.activeFocus
                }

                HoverHandler { id: vHov; cursorShape: Qt.PointingHandCursor }
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        vTab.forceActiveFocus(Qt.MouseFocusReason)
                        root.pageChanged(modelData.key)
                    }
                }
            }
        }
    }
}
