import QtQuick
import Quickshell
import Quickshell.Services.Notifications
import "../"
import "../../"
import "../../components/controls"

// ─────────────────────────────────────────────────────────────────────────────
// NotificationList — the notification centre's stack (NotificationsPane, in
// RightPanel). UI/UX roadmap v3 Phase 11, STACK_REFLOW.
//
// The panel around it pours (RIGHT_POUR); inside it only the cards move, as
// objects occupying space rather than list rows being reassigned:
//   * a new card arrives from the right, x +24 → 0 with its fade, over the
//     notificationShift beat on emphasizedDecel, and the cards below make
//     room over the same beat, starting at the same instant;
//   * a card that leaves goes right, x → +40 and out, quickly (state beat,
//     standardAccel), and the rest close the gap at the same instant — not
//     after it has gone;
//   * a card can be dragged sideways: it follows the pointer 1:1 and fades as
//     it goes; let go past 40 % of its width, or faster than 600 px/s, and it
//     keeps going at the release speed (at least 900 px/s) and is dismissed;
//     otherwise it settles back, with no overshoot;
//   * Clear all lets them go bottom-up, 20 ms apart, 100 ms in all.
// Under Reduce Motion nothing travels: cards fade over the hover beat and the
// stack closes up at once.
//
// ── Why the model is a ScriptModel ───────────────────────────────────────────
// It was NotificationService.list itself, a JS array replaced on every change.
// A ListView given a new array resets and rebuilds every delegate, so no card
// could ever arrive or leave, and nothing could make room. ScriptModel diffs
// successive arrays by identity into real inserts and removes.
//
// And the model's values are plain JS wrappers, one per notification, not the
// notifications: closing a notification DESTROYS it, and a ListView whose
// model value is a destroyed QObject tears the delegate down on the spot, with
// no exit at all (measured: a JS value got its full remove transition, the
// destroyed QObject none). A leaving card also keeps its own copy of what it
// shows, since the notification behind it is gone by the time it leaves.
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes

    // Clear all: every card takes its place in the bottom-up stagger from the
    // order they were in when it was asked for, BEFORE anything is dismissed —
    // by the time a card's exit runs, its notification is gone.
    signal clearRequested(var order)

    // One wrapper per notification, stable for as long as it is listed, so
    // ScriptModel's identity diff sees the same value across list changes.
    // The cache is mutated, not reassigned: it must not be a dependency.
    readonly property var _store: ({ cache: ({}) })
    readonly property var entries: {
        const prev = root._store.cache, next = {}, out = []
        for (const n of NotificationService.list) {
            if (!n) continue
            let w = prev[n.id]
            if (!w || w.note !== n) w = { note: n }
            next[n.id] = w
            out.push(w)
        }
        root._store.cache = next
        return out
    }
    function clearAll() {
        root.clearRequested(NotificationService.list.slice())
        NotificationService.dismissAll()
        root._curId = null
    }

    // ── Keyboard ──────────────────────────────────────────────────────────
    // The card stack is ONE Tab stop: Up and Down move a highlight over the
    // cards in display order, Return/Enter/Space invokes the highlighted
    // card's own "default" action if the notification declared one (the
    // org.freedesktop.Notifications convention for what a body click would
    // invoke — this pane draws no click handler on the card body itself,
    // only its labelled action buttons and the ✕, so Return is a no-op
    // unless the app asked for one), and Delete/BackSpace dismiss it. A
    // dismissed card hands the highlight to the next one (or the previous,
    // if it was last), so clearing several with the keyboard reads down the
    // list instead of snapping back to the top each time.
    //
    // The sentinel is null, not "" or 0: ids are the server's own `uint`
    // (org.freedesktop.Notifications never assigns 0 to a live
    // notification), and unlike WifiTab's placeholder row this pane never
    // synthesizes an entry, so there is no resting value a real id could
    // collide with.
    property var _curId: null
    readonly property var _cardIds: root.entries.map(function (w) { return w.note.id })
    function _stepCard(d) {
        const list = root._cardIds
        if (list.length === 0) return
        const i = list.indexOf(root._curId)
        root._curId = i < 0 ? list[d > 0 ? 0 : list.length - 1]
                            : list[Math.max(0, Math.min(list.length - 1, i + d))]
    }
    function _cardFor(id) {
        for (let i = 0; i < contentList.count; i++) {
            const item = contentList.itemAtIndex(i)
            if (item && item.notification && item.notification.id === id) return item
        }
        return null
    }
    // Shared by the list's Delete/BackSpace and the card's own ✕ — "the same
    // call" both make. Dismiss, then move the highlight to the next card, or
    // the previous one if the dismissed card was last; with none left, hand
    // focus nowhere, so the pane can still take Escape.
    function _dismissCard(id) {
        const list = root._cardIds
        const i = list.indexOf(id)
        if (i < 0) return
        const nextId = i + 1 < list.length ? list[i + 1] : (i > 0 ? list[i - 1] : null)
        const c = root._cardFor(id)
        c?.notification?.dismiss()
        root._curId = nextId
        if (nextId !== null) contentList.forceActiveFocus()
    }


    width:  360

    // Total height: header + list area (or empty state)
    height: header.height
            + (NotificationService.count > 0 ? listArea.height : emptyState.height)

    // ── Header ─────────────────────────────────────────────────
    Item {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 44

        Text {
            // Left-aligned, like every other pane's heading (it was centred).
            anchors { left: parent.left; leftMargin: 4; verticalCenter: parent.verticalCenter }
            text:           "Notifications"
            color:          Theme.text
            font.pixelSize: theme.fs(14)
            font.bold:      true
        }

        // Clear-all — only visible when there are notifications
        ApexPressable {
            id:      clearBtn
            anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
            width:   clearLabel.width + 16
            height:  26
            radius:  13
            hitMargin: 3
            visible: NotificationService.count > 0
            Accessible.name: "Clear all notifications"
            onActivated: root.clearAll()

            Rectangle {
                anchors.fill: parent
                radius:       parent.radius
                color:        clearBtn.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10) : "transparent"
                Behavior on color { MotionColor {} }
            }
            Text {
                id:               clearLabel
                anchors.centerIn: parent
                text:             "Clear all"
                color:            Theme.subtext
                font.pixelSize:   theme.fs(12)
            }
            ApexFocusRing { target: clearBtn }
        }
    }

    // Divider — only when list is non-empty
    Rectangle {
        id: divider
        anchors { top: header.bottom; left: parent.left; right: parent.right }
        height:  1
        color:   Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.06)
        visible: NotificationService.count > 0
    }

    // ── Scrollable list ─────────────────────────────────────────
    Item {
        id:      listArea
        anchors { top: divider.bottom; left: parent.left; right: parent.right }
        // Clamp to maxListHeight — ListView scrolls inside
        height:  Math.min(contentList.contentHeight, maxListHeight)
        visible: NotificationService.count > 0

        readonly property int maxListHeight: 440

        ListView {
            id:             contentList
            // Always its scroll maximum, not the list area's height: a ListView
            // releases a card whose exit is still running the moment the card
            // falls outside its extent, and sized to its content it shrank the
            // instant a card was removed — every exit was cut to 0 ms
            // (measured). The list area still reports the content's height,
            // which is what the panel pours to; the panel's body clips the rest.
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height:         listArea.maxListHeight
            model:          ScriptModel { values: root.entries }
            // Only while the list actually scrolls. Clipped always, the
            // viewport shrank the instant a card was removed and cut off the
            // cards still moving up into the gap; the panel's own body, which
            // retargets over the same beat, bounds them instead.
            clip:           contentList.contentHeight > listArea.maxListHeight
            spacing:        1
            boundsBehavior: Flickable.StopAtBounds

            // ── Keyboard — the stack is ONE Tab stop ────────────────────
            activeFocusOnTab: root._cardIds.length > 0
            Accessible.role: Accessible.List
            Accessible.name: "Notifications"
            onActiveFocusChanged: if (activeFocus && root._cardIds.indexOf(root._curId) < 0) root._stepCard(1)
            Keys.onPressed: function (event) {
                if      (event.key === Qt.Key_Down) root._stepCard(1)
                else if (event.key === Qt.Key_Up)   root._stepCard(-1)
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                    const c = root._cardFor(root._curId)
                    if (c) c.primary()
                } else if (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) {
                    root._dismissCard(root._curId)
                } else return
                event.accepted = true
                // Keep the highlighted card in view.
                const i = root._cardIds.indexOf(root._curId)
                if (i >= 0) contentList.positionViewAtIndex(i, ListView.Contain)
            }

            delegate: NotificationCard {
                required property var modelData
                width:        ListView.view.width
                notification: modelData.note
            }

            // Arrival: from the right, with its fade — a beat after the rest
            // begin making room, so it does not land on the card still
            // leaving its slot (design review 2). Nested, so targeted.
            add: Transition {
                id: arriveTrans
                SequentialAnimation {
                    PropertyAction { target: arriveTrans.ViewTransition.item; property: "opacity"; value: 0 }
                    PauseAnimation { duration: Motion.contentDelay }
                    ParallelAnimation {
                        NumberAnimation {
                            target: arriveTrans.ViewTransition.item
                            property: "x"; from: Motion.travel(theme.px(24)); to: 0
                            duration: Motion.notificationShift
                            easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.emphasizedDecel
                        }
                        NumberAnimation {
                            target: arriveTrans.ViewTransition.item
                            property: "opacity"; from: 0; to: 1
                            duration: Math.max(Motion.notificationShift, Motion.hover)
                            easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.effects
                        }
                    }
                }
            }
            // Leaving: to the right and out, after its place in a Clear all.
            remove: Transition {
                id: removeTrans
                SequentialAnimation {
                    PauseAnimation {
                        duration: Math.min(Motion.staggerCap, Motion.staggerStep
                                  * (removeTrans.ViewTransition.item ? removeTrans.ViewTransition.item.leaveRank : 0))
                    }
                    // An explicit target: animations nested in a group do not
                    // inherit the transition's item, and without one the whole
                    // exit ran in 0 ms and the card vanished (measured).
                    ParallelAnimation {
                        NumberAnimation {
                            target: removeTrans.ViewTransition.item
                            property: "x"; to: Motion.travel(theme.px(40))
                            duration: Motion.state
                            easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.standardAccel
                        }
                        // Gone on the content beat, ahead of its own slide and
                        // before the card below has risen into its slot.
                        NumberAnimation {
                            target: removeTrans.ViewTransition.item
                            property: "opacity"; to: 0
                            duration: Motion.fadeOut
                            easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.effects
                        }
                    }
                }
            }
            // Closing up after a removal waits a beat, so the card rising
            // into the gap does not run into the one still leaving it.
            removeDisplaced: Transition {
                id: closeUpTrans
                SequentialAnimation {
                    PauseAnimation { duration: Motion.contentDelay }
                    NumberAnimation {
                        target: closeUpTrans.ViewTransition.item
                        property: "y"; to: closeUpTrans.ViewTransition.destination.y
                        duration: Motion.notificationShift
                        easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.standard
                    }
                }
                NumberAnimation { property: "x"; to: 0; duration: Motion.notificationShift }
                NumberAnimation { property: "opacity"; to: 1; duration: Motion.hover }
            }
            // Making room for an arrival starts at once.
            displaced: Transition {
                NumberAnimation {
                    property: "y"
                    duration: Motion.notificationShift
                    easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.standard
                }
                // A card displaced while it was still arriving finishes arriving.
                NumberAnimation { property: "x"; to: 0; duration: Motion.notificationShift }
                NumberAnimation { property: "opacity"; to: 1; duration: Motion.hover }
            }
        }

        // Fade overlay when clipped
        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height:  28
            visible: contentList.contentHeight > listArea.maxListHeight
            gradient: Gradient {
                orientation: Gradient.Vertical
                GradientStop { position: 0.0; color: "transparent" }
                // The panel's own colour: a fixed dark blue here showed as a
                // band on every palette but one.
                GradientStop { position: 1.0; color: Theme.background }
            }
        }
    }

    // ── Empty state ─────────────────────────────────────────────
    Item {
        id:      emptyState
        anchors { top: header.bottom; left: parent.left; right: parent.right }
        height:  80
        visible: NotificationService.count === 0

        Column {
            anchors.centerIn: parent
            spacing:          6

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text:           "󰂚"
                // Decorative, not text: a quiet mark, not the tertiary text role.
                color:          Theme.outlineStrong
                font.pixelSize: theme.fs(28)
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text:           "No notifications"
                color:          Theme.subtext
                font.pixelSize: theme.fs(12)
            }
        }
    }

    // ── NotificationCard ── inline component ────────────────────
    component NotificationCard: Item {
        id: card

        // A guarded object property, not a var: when the notification is
        // closed and destroyed it becomes null AND says so, which is what
        // switches the card over to its own copy (`live` below).
        required property QtObject notification

        // Highlighted by the keyboard: its buttons join the Tab order.
        readonly property bool keyed: !!card.notification && root._curId === card.notification.id
        // The card's default action, for Return/Enter/Space on the list: the
        // notification's own "default" action (the org.freedesktop.Notifications
        // convention for what clicking the body would invoke). This pane draws
        // no click handler on the card body itself — only the labelled action
        // buttons and the ✕ — so this is a no-op unless the app declared one.
        function primary() {
            for (const a of card.tActions)
                if (a && a.identifier === "default") { a.invoke(); return }
        }
        Accessible.role: Accessible.ListItem
        Accessible.name: card.tApp !== "" ? (card.tApp + ": " + card.tSummary) : card.tSummary

        // ── What it shows ────────────────────────────────────────────────────
        // Read straight from the notification while there is one — so the
        // card has its real height the moment it is created, which is when
        // the list lays it out and starts the others making room — and from
        // the card's own copy once it is gone (see the header).
        readonly property bool   live:     !!card.notification
        readonly property string tApp:     card.live ? (card.notification.appName ?? "") : card.sApp
        readonly property string tSummary: card.live ? (card.notification.summary ?? "") : card.sSummary
        readonly property string tBody:    card.live ? (card.notification.body ?? "")    : card.sBody
        readonly property string tIcon:    card.live ? (card.notification.appIcon ?? "") : card.sIcon
        readonly property var    tActions: card.live ? (card.notification.actions ?? []) : card.sActions
        readonly property int    tUrgency: card.live ? (card.notification.urgency ?? NotificationUrgency.Normal) : card.sUrgency

        property string sApp:     ""
        property string sSummary: ""
        property string sBody:    ""
        property string sIcon:    ""
        property var    sActions: []
        property int    sUrgency: NotificationUrgency.Normal
        function _snap() {
            const n = card.notification
            if (!n) return
            card.sApp     = n.appName ?? ""
            card.sSummary = n.summary ?? ""
            card.sBody    = n.body ?? ""
            card.sIcon    = n.appIcon ?? ""
            card.sActions = n.actions ?? []
            card.sUrgency = n.urgency ?? NotificationUrgency.Normal
        }
        onNotificationChanged: card._snap()
        Component.onCompleted: card._snap()
        Connections {
            target: card.notification
            ignoreUnknownSignals: true
            function onSummaryChanged() { card._snap() }
            function onBodyChanged()    { card._snap() }
            function onAppIconChanged() { card._snap() }
            function onActionsChanged() { card._snap() }
        }

        // Its place in a Clear all — how many cards were below it — read by
        // the list's remove transition: bottom-up, staggerStep apart, never
        // more than staggerCap in all. 0 for a card leaving on its own.
        property int leaveRank: 0
        Connections {
            target: root
            function onClearRequested(order) {
                const i = order.indexOf(card.notification)
                card.leaveRank = i < 0 ? 0 : order.length - 1 - i
            }
        }

        // Urgency accent color
        readonly property color urgencyColor: {
            switch (card.tUrgency) {
                case NotificationUrgency.Critical: return Theme.danger
                case NotificationUrgency.Low:      return Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.25)
                default:                           return Theme.active
            }
        }

        height: cardRow.height + 20
        readonly property int actionH: 22
        // Counted on the conditions the lines are SHOWN on, never on `visible`:
        // `visible` is the effective visibility, false while any ancestor is
        // hidden, so a card built while the centre was closed counted no lines,
        // took the icon's 32 px and kept it — the cards sat jammed together
        // until something else made the list lay out again (design review 2).
        readonly property real textHeight: {
            let h = 0, n = 0
            for (const t of [appLine, summaryLine, bodyLine])
                if (t.text !== "") { h += t.implicitHeight; n++ }
            if (card.tActions.length > 0) { h += card.actionH; n++ }   // a Row's implicitHeight is polish-time too
            return h + Math.max(0, n - 1) * textCol.spacing
        }

        // ── Drag to dismiss ──────────────────────────────────────────────────
        // The card follows the pointer 1:1 on x and fades by up to half as it
        // goes. Released past 40 % of its width, or flicked faster than
        // 600 px/s, it carries on at the release speed (at least 900 px/s) and
        // is dismissed; otherwise it settles back without overshoot.
        property real dragX: 0
        readonly property bool dragging: drag.active
        DragHandler {
            id: drag
            target: null
            xAxis.enabled: true
            yAxis.enabled: false
            onActiveTranslationChanged: if (active) card.dragX = activeTranslation.x
            onActiveChanged: if (!active) card._release(centroid.velocity.x)
        }
        function _release(vx) {
            const w = Math.max(1, card.width)
            if (Math.abs(card.dragX) > 0.4 * w || Math.abs(vx) > 600) {
                const dir = card.dragX !== 0 ? Math.sign(card.dragX) : Math.sign(vx)
                const to = dir * (w + theme.px(24))
                const speed = Math.max(Math.abs(vx), 900)                    // px/s
                settle.stop()
                fling.to = to
                fling.duration = Motion.travel(1) > 0
                                 ? Math.round(1000 * Math.abs(to - card.dragX) / speed) : 0
                fling.start()
            } else {
                settle.duration = Math.round(Motion.settle * Math.min(1, Math.abs(card.dragX) / w))
                settle.start()
            }
        }
        NumberAnimation {
            id: settle
            target: card; property: "dragX"; to: 0
            easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.standardDecel
        }
        NumberAnimation {
            id: fling
            target: card; property: "dragX"
            easing.type: Easing.Linear
            onFinished: card.notification?.dismiss()
        }

        Item {
            id: face
            width: parent.width; height: parent.height
            transform: Translate { x: card.dragX }
            opacity: 1 - 0.5 * Math.min(1, Math.abs(card.dragX) / Math.max(1, card.width))

        // Hover background
        Rectangle {
            anchors.fill: parent
            color:        cardHover.containsMouse ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.05) : "transparent"
            Behavior on color { MotionColor {} }
        }

        // Left urgency accent bar
        Rectangle {
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
            width:   3
            color:   card.urgencyColor
            opacity: 0.85
        }

        // Content row
        Row {
            id: cardRow
            anchors {
                left:        parent.left; leftMargin:  12
                right:       parent.right; rightMargin:  8
                top:         parent.top;   topMargin:   10
            }
            spacing: 10
            // Summed from the texts' own heights, not textCol.implicitHeight:
            // a Column computes that at polish time, one step AFTER the list
            // has laid out a new card — so a card arrived at its icon's height,
            // the cards below made room for that, and when it grew they were
            // left where the transition had put them, under it.
            height:  Math.max(iconArea.height, card.textHeight)

            // App icon
            Item {
                id:     iconArea
                width:  32
                height: 32

                Image {
                    id:        iconImg
                    anchors.fill: parent
                    source: {
                        var ic = card.tIcon
                        if (ic === "") return ""
                        if (ic.startsWith("/")) return "file://" + ic
                        return "image://icon/" + ic
                    }
                    fillMode:          Image.PreserveAspectFit
                    smooth:            true
                    visible:           status === Image.Ready
                    sourceSize.width:  32
                    sourceSize.height: 32
                }

                // Letter fallback
                Rectangle {
                    anchors.fill: parent
                    radius:       width / 2
                    color:        Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.08)
                    visible:      iconImg.status !== Image.Ready

                    Text {
                        anchors.centerIn: parent
                        text:           (card.tApp !== "" ? card.tApp : "?").charAt(0).toUpperCase()
                        color:          Theme.text
                        font.pixelSize: theme.fs(14)
                        font.bold:      true
                    }
                }
            }

            // Text column
            Column {
                id:     textCol
                // Leave room for dismiss button
                width: cardRow.width - iconArea.width - dismissBtn.width - (cardRow.spacing * 2)
                spacing: 3

                // App name
                Text {
                    id:             appLine
                    width:          parent.width
                    text:           card.tApp
                    color:          Theme.subtext
                    font.pixelSize: theme.fs(11)
                    elide:          Text.ElideRight
                    visible:        text !== ""
                }

                // Summary
                Text {
                    id:               summaryLine
                    width:            parent.width
                    text:             card.tSummary
                    color:            Theme.text
                    font.pixelSize:   theme.fs(13)
                    font.bold:        true
                    wrapMode:         Text.WordWrap
                    maximumLineCount: 2
                    elide:            Text.ElideRight
                    visible:          text !== ""
                }

                // Body
                Text {
                    id:               bodyLine
                    width:            parent.width
                    text:             card.tBody
                    color:            Theme.subtext
                    font.pixelSize:   theme.fs(12)
                    wrapMode:         Text.WordWrap
                    maximumLineCount: 3
                    elide:            Text.ElideRight
                    textFormat:       Text.StyledText
                    visible:          text !== ""
                }

                // Action buttons
                Row {
                    id:      actionsRow
                    spacing: 6
                    visible: card.tActions.length > 0

                    Repeater {
                        model: card.tActions
                        delegate: ApexPressable {
                            id: actBtn
                            required property var modelData
                            width:  actionLbl.width + 20
                            height: card.actionH
                            radius: 3
                            hitMargin: 5
                            activeFocusOnTab: card.keyed
                            Accessible.name: (modelData?.text ?? "") !== "" ? modelData.text : "Action"
                            onActivated: modelData?.invoke()

                            Rectangle {
                                anchors.fill: parent
                                radius:       parent.radius
                                color:        actBtn.hovered
                                              ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.15)
                                              : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07)
                                Behavior on color { MotionColor {} }
                            }
                            Text {
                                id:               actionLbl
                                anchors.centerIn: parent
                                text:             modelData?.text ?? ""
                                color:            Theme.text
                                font.pixelSize:   theme.fs(11)
                            }
                            ApexFocusRing { target: actBtn }
                        }
                    }
                }
            }

            // Dismiss ✕
            ApexPressable {
                id:     dismissBtn
                width:  24
                height: 24
                radius: 12
                hitMargin: 4
                activeFocusOnTab: card.keyed
                Accessible.name: "Dismiss notification"
                onActivated: root._dismissCard(card.notification?.id)

                Rectangle {
                    anchors.fill: parent
                    radius:       parent.radius
                    color:        dismissBtn.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.12) : "transparent"
                    Behavior on color { MotionColor {} }
                }
                Text {
                    anchors.centerIn: parent
                    text:             "✕"
                    color:            Theme.subtext
                    font.pixelSize:   theme.fs(10)
                }
                ApexFocusRing { target: dismissBtn }
            }
        }
        }

        HoverHandler { id: cardHover }

        // Keyboard-focus ring — outside face, so it does not travel with the
        // card during a drag-to-dismiss.
        Rectangle {
            anchors.fill: parent; anchors.margins: -2
            color: "transparent"; border.width: 2; border.color: Theme.accentText
            visible: card.keyed && contentList.activeFocus
        }
    }
}
