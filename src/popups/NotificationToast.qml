import QtQuick
import Quickshell.Services.Notifications
import "../services/"
import "../"

// ─────────────────────────────────────────────────────────────────────────────
// NotificationToast — one notification at a time, under the right notch.
//
// A pane of RightPanel (RIGHT_POUR), which draws the body and reveals this at
// its finished layout; `showing` is what asks the bar's right clock to open for
// it (RightPanel pushes it to TopBar.rightToastShowing, per screen). The queue
// logic is unchanged from when this was its own window: one card, the rest
// queued, identity deciding whether a delivery is new.
//
// Two rules are new with the shared surface:
//   * it does not show while the network panel or the notification centre is
//     up (`blocked`) — the body is theirs — and a toast on screen when one of
//     them opens is dismissed; opening the centre drops the queue as well,
//     since the centre lists every one of them;
//   * the next queued toast waits for the surface to have finished closing
//     (`surfaceIdle`) rather than for a timer's guess at how long that takes.
// ─────────────────────────────────────────────────────────────────────────────
Item {
	id: root

	property ThemeSet theme: ThemeSet {}

	readonly property int toastWidth: theme.notificationToastWidth
	readonly property int fw: theme.notchRadius

	// The body's finished size (W1 - the notch radius the pour adds, and D1).
	width:  toastWidth + fw
	readonly property int bodyHeight: cardCol.y + cardCol.implicitHeight + 24

	// Set by RightPanel.
	property bool blocked:     false
	property bool surfaceIdle: true

	property bool showing:       false
	property var  current:       null
	property var  queue:         []
	property bool _advancePending: false

	// Called by LazyPopup right after this window is built. The notification
	// that caused the build was announced before this object existed, so take
	// it from the service rather than waiting for the next one to arrive.
	function applyOpenState() {
		if (root.current !== null) return
		const n = NotificationService.lastToast
		if (!n || !n.tracked) return
		if (root.queue.indexOf(n) !== -1) return
		root.startShow(n)
	}

	Connections {
		target: NotificationService
		function onNotificationAdded(n) {
			if (!n || !n.tracked) return
			// This window may have been built BY this very notification, in
			// which case applyOpenState already claimed it and the signal is a
			// second delivery of the same thing — it showed twice, five seconds
			// apart. Identity decides, so either path may run first.
			if (n === root.current || root.queue.indexOf(n) !== -1) return
			// The centre is open and lists it; a toast afterwards would repeat it.
			if (Popups.notificationsOpen) return
			if (root.current === null && !root.blocked && !root._advancePending) {
				root.startShow(n)
			} else {
				root.queue = [...root.queue, n]
			}
		}
	}

	function startShow(n) {
		root.current       = n
		root.showing       = false
		slideInTimer.restart()
		Popups.notificationToastOpen = false
	}

	function startDismiss() {
		autoTimer.stop()
		slideInTimer.stop()
		root.showing = false
		Popups.notificationToastOpen = false
		root._advancePending = true
		root._advance()
	}

	// The next toast, once the surface this one was on has actually gone.
	function _advance() {
		if (!root._advancePending || !root.surfaceIdle || root.blocked) return
		root._advancePending = false
		if (root.queue.length > 0) {
			const next = root.queue[0]
			root.queue = root.queue.slice(1)
			root.startShow(next)
		} else {
			root.current = null
		}
	}
	onSurfaceIdleChanged: root._advance()
	onBlockedChanged: {
		if (root.blocked) {
			if (Popups.notificationsOpen) root.queue = []
			if (root.current !== null) root.startDismiss()
		} else {
			root._advance()
		}
	}

	Connections {
		target:               root.current
		ignoreUnknownSignals: true
		function onClosed() { if (root.current !== null && !root._advancePending) root.startDismiss() }
	}

	Timer {
		id:          slideInTimer
		interval:    30
		onTriggered: { root.showing = true; Popups.notificationToastOpen = true; autoTimer.restart() }
	}

	Timer {
		id:          autoTimer
		interval:    5000
		onTriggered: root.startDismiss()
	}

	// ── Card ───────────────────────────────────────────────────
	// At its finished size; RightPanel's body is the card's silhouette.
	Item {
		id:            card
		anchors.right: parent.right
		anchors.top:   parent.top
		width:         root.width
		height:        root.bodyHeight

		Rectangle {
			anchors {
				right:        parent.right
				top:          parent.top
				bottom:       parent.bottom
				topMargin:    12
				bottomMargin: 12
				rightMargin:  10
			}
			width:  3
			radius: 2
			// Same urgency accent as NotificationList's card, deliberately: one
			// notification is shown by both surfaces, first as a toast and then in
			// the list, and they used to disagree about it. Critical and Low always
			// matched; normal urgency was #ABB2BF here and Theme.active there, so
			// the accent bar changed colour as the toast expired.
			color: {
				if (!root.current) return Theme.active
				switch (root.current.urgency) {
					case NotificationUrgency.Critical: return Theme.danger
					case NotificationUrgency.Low:      return Qt.rgba(1,1,1,0.25)
					default:                           return Theme.active
				}
			}
		}

		// No fade of its own: the panel's content channel carries it in and out.
		Item {
			anchors.fill: parent
			Rectangle {
				id: progressBar
				anchors {
					right:       parent.right
					rightMargin: 14
					bottom:      cardCol.bottom
					bottomMargin: -10
				}
				height:  2
				radius:  1
				color:   Theme.active
				opacity: 0.5

				property bool running: false

				// Use toastWidth so the bar stays within the visible body, not the flare
				width: running ? 0 : root.toastWidth - 10
				Behavior on width {
					enabled: progressBar.running
					NumberAnimation { duration: 5000; easing.type: Easing.Linear }
				}

				Connections {
					target: root
					function onShowingChanged() {
						if (root.showing) {
							progressBar.running = false
							progressTick.restart()
						} else {
							progressBar.running = false
						}
					}
				}

				Timer {
					id:          progressTick
					interval:    16
					onTriggered: progressBar.running = true
				}
			}

			Column {
				id: cardCol
				anchors {
					left:       parent.left;  leftMargin:  14
					right:      parent.right; rightMargin: 14

				}
				spacing: 2
				bottomPadding: 10
				y: 10
				// No fixed height — sizes to content

				Row {
					id:      headerRow
					width:   parent.width
					height: 40
					spacing: 8

					Item {
						width:  16
						height: 16
						anchors.verticalCenter: parent.verticalCenter

						Image {
							id:           toastIcon
							anchors.fill: parent
							source: {
								var ic = root.current?.appIcon ?? ""
								if (ic === "") return ""
								if (ic.startsWith("/")) return "file://" + ic
								return "image://icon/" + ic
							}
							fillMode:          Image.PreserveAspectFit
							smooth:            true
							visible:           status === Image.Ready
							sourceSize.width:  16
							sourceSize.height: 16
						}
						Rectangle {
							anchors.fill: parent
							radius:       width / 2
							color:        Qt.rgba(1,1,1,0.1)
							visible:      toastIcon.status !== Image.Ready
							Text {
								anchors.centerIn: parent
								text:           (root.current?.appName ?? "?").charAt(0).toUpperCase()
								color:          Theme.text
								font.pixelSize: theme.fs(9)
								font.bold:      true
							}
						}
					}

					Text {
						width:                  parent.width - 16 - 24 - parent.spacing * 2
						anchors.verticalCenter: parent.verticalCenter
						text:                   root.current?.appName ?? ""
						color:                  Theme.subtext
						font.pixelSize:         theme.fs(11)
						elide:                  Text.ElideRight
					}

					Item {
						width:  20
						height: 20
						anchors.verticalCenter: parent.verticalCenter
						Rectangle {
							anchors.fill: parent
							radius:       width / 2
							color:        xHover.containsMouse ? Qt.rgba(1,1,1,0.12) : "transparent"
							Behavior on color { MotionColor {} }
						}
						Text {
							anchors.centerIn: parent
							text:             "✕"
							color:            Theme.subtext
							font.pixelSize:   theme.fs(9)
						}
						HoverHandler { id: xHover }
						TapHandler   { onTapped: root.startDismiss() }
					}
				}

				Text {
					width:            parent.width
					text:             root.current?.summary ?? ""
					color:            Theme.text
					font.pixelSize:   theme.fs(13)
					font.bold:        true
					wrapMode:         Text.WordWrap
					maximumLineCount: 2
					elide:            Text.ElideRight
					visible:          text !== ""
				}

				Text {
					width:            parent.width
					text:             root.current?.body ?? ""
					color:            Theme.subtext
					font.pixelSize:   theme.fs(12)
					wrapMode:         Text.WordWrap
					maximumLineCount: 2
					elide:            Text.ElideRight
					textFormat:       Text.StyledText
					visible:          text !== ""
				}

				Row {
					spacing:    6
					topPadding: 2
					visible:    (root.current?.actions?.length ?? 0) > 0

					Repeater {
						model: root.current?.actions ?? []
						delegate: Item {
							required property var modelData
							width:  actionLbl.width + 20
							height: 24
							Rectangle {
								anchors.fill: parent
								radius:       4
								color:        actHover.containsMouse
								? Qt.rgba(1,1,1,0.18)
								: Qt.rgba(1,1,1,0.08)
								Behavior on color { MotionColor {} }
							}
							Text {
								id:               actionLbl
								anchors.centerIn: parent
								text:             modelData?.text ?? ""
								color:            Theme.text
								font.pixelSize:   theme.fs(11)
							}
							HoverHandler { id: actHover }
							TapHandler {
								onTapped: {
									modelData?.invoke()
									root.startDismiss()
								}
							}
						}
					}
				}
			}
		}
	}
}
