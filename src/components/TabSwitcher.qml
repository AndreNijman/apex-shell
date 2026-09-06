import QtQuick
import "../"

// Unified tab switcher — horizontal or vertical.
//
// orientation: "horizontal" (default) — Row, fills parent width, tabs spaced equally
//              "vertical"             — Column, fills parent height, tabs spaced equally
//
// Horizontal: icon + label pill, bottom divider. Used by Dashboard.
// Vertical:   icon-only solid pill. Used by ArchMenu, and icon + label by the
//             Config tab.
//
// Model: [{ key: string, icon: string, label?: string }]
// label is optional — only rendered in horizontal orientation.
//
// Sizing contract:
//   Horizontal — parent MUST set width.  implicitHeight is Theme.px(40).
//   Vertical   — parent MUST set height. implicitWidth  is Theme.px(40).
//
// ─────────────────────────────────────────────────────────────────────────────
//  What goes wrong here, and what stops it
//
//  Every size in this file used to be a literal calibrated against a 1080p
//  panel — a 40px bar, a 60px row, a 24px pill padding — while every font in it
//  went through Theme.fs() and grew with the scale factor. Text that grows
//  inside a box that does not is the whole of P0-017, and it showed up twice:
//
//   1. The horizontal pill was as wide as its own icon and label and nothing
//      capped it, so once the text outgrew a sixth of the bar the pills grew
//      into each other. On the launcher page, which is the narrow one, that is
//      every scale factor from 1.35 up.
//
//   2. The vertical column spread its rows with
//          spacing = (height - n * 60) / (n - 1)
//      which is NEGATIVE as soon as the rows do not fit, and negative spacing
//      in a Column is rows drawn on top of each other. Nine settings pages in a
//      381px column at scale 1.0 — the default dashboard on a 1080p desk —
//      overlapped by 19.9px each. That is the reported bug.
//
//  So: the box is scaled like the text, the pill can never be wider than the
//  slot it sits in, the labels come off the whole bar together when the widest
//  of them stops fitting, and a row is never shorter than a thing you can hit.
//  tests/run-nav-geometry-test.sh measures all of it as Qt lays it out.
// ─────────────────────────────────────────────────────────────────────────────

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

	// ── Shared tokens ─────────────────────────────────────────────────────────
	// A pointer target below about 24 logical pixels is a miss waiting to
	// happen. Scaled, because a pixel at scale 2 is half the size of one at 1.
	readonly property int minTouch: Theme.px(24)

	// ── Horizontal metrics ────────────────────────────────────────────────────
	readonly property int  hIconSize:  Theme.fs(14)
	readonly property int  hLabelSize: Theme.fs(12)
	readonly property int  hIconGap:   Theme.px(6)   // between icon and label
	readonly property int  hGutter:    Theme.px(4)   // between neighbouring pills
	readonly property int  hPadMax:    Theme.px(9)   // pill padding, each side
	readonly property int  hPadMin:    Theme.px(4)   // below this, drop the labels

	readonly property real hSlotWidth:
		root.model.length > 0 ? root.width / root.model.length : root.width

	// The room a pill may occupy without touching its neighbour. Everything
	// below is clamped to it, which is what makes an overlap unrepresentable
	// rather than unlikely.
	readonly property real hSlotRoom: Math.max(0, root.hSlotWidth - root.hGutter)

	// ── Measuring the widest tab ──────────────────────────────────────────────
	// The labels are kept or dropped for the WHOLE bar — a row where "Home" is
	// spelt out and "Agents" is a bare icon reads as a rendering fault — so the
	// decision needs the widest tab, not each tab's own width. Qt has no
	// aggregate binding over a Repeater, so the probes bump a counter that the
	// aggregate reads as a dependency.
	//
	// Probes rather than FontMetrics.advanceWidth(): the icons are private-use
	// glyphs that arrive through font fallback, and advanceWidth() would measure
	// them in the primary family, where they are not.
	property int _measureTick: 0

	readonly property real hWidestLabelled: {
		root._measureTick               // a probe finished measuring
		root.hIconSize; root.hLabelSize // the probes are about to change
		var m = 0
		for (var i = 0; i < probes.count; i++) {
			var p = probes.itemAt(i)
			if (p)
				m = Math.max(m, p.labelledWidth)
		}
		return m
	}

	readonly property bool hShowLabels:
		root.orientation === "horizontal"
		&& root.hWidestLabelled > 0
		&& root.hWidestLabelled + 2 * root.hPadMin <= root.hSlotRoom

	Item {
		id: probeHost
		visible: false
		Repeater {
			id: probes
			model: root.orientation === "horizontal" ? root.model : []
			delegate: Item {
				readonly property real labelledWidth:
					pIcon.implicitWidth
					+ (pLabel.text !== "" ? root.hIconGap + pLabel.implicitWidth : 0)
				readonly property real iconWidth: pIcon.implicitWidth

				onLabelledWidthChanged: root._measureTick++
				Component.onCompleted:  root._measureTick++

				Text {
					id: pIcon
					text: modelData.icon
					font.pixelSize: root.hIconSize
				}
				Text {
					id: pLabel
					text: modelData.label ?? ""
					font.pixelSize: root.hLabelSize
					// Measured at the weight the ACTIVE tab uses, which is the
					// wider of the two. Sizing off Normal would let the tab the
					// user selected grow past the slot it was measured into.
					font.weight: Font.Medium
				}
			}
		}
	}

	// ── Scroll cooldown ───────────────────────────────────────────────────────
	property bool scrollBusy: false

	Timer {
		id: scrollCooldown
		interval: 300
		repeat:   false
		onTriggered: root.scrollBusy = false
	}

	// Cycling pages is navigation, not editing a value, which is why P0-020 left
	// this one in place. It stands down for the one case where the wheel has
	// somewhere better to go: a settings column with more rows than room, where
	// the user means "show me the ones below".
	//
	// The comment sits above the handler rather than inside it because
	// tests/check-wheel-value.sh pairs an onWheel with the WheelHandler within
	// six lines of it, and a comment in between makes them two sites.
	WheelHandler {
		acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
		enabled: !vFlick.interactive
		onWheel: function(event) {
			if (root.scrollBusy) return
			root.scrollBusy = true
			scrollCooldown.restart()
			var keys = root.model.map(function(m) { return m.key })
			var idx  = keys.indexOf(root.currentPage)
			if (event.angleDelta.y < 0)
			idx = (idx + 1) % keys.length
			else
			idx = (idx - 1 + keys.length) % keys.length
			root.pageChanged(keys[idx])
		}
	}

	// ── HORIZONTAL layout — Row ───────────────────────────────────────────────
	Row {
		id: hRow
		anchors.fill: parent
		visible: root.orientation === "horizontal"

		Repeater {
			model: root.orientation === "horizontal" ? root.model : []

			delegate: Item {
				id: hTab
				readonly property bool isActive: root.currentPage === modelData.key

				width:  root.hSlotWidth
				height: hRow.height

				// What this tab wants to draw, at the bar's current verbosity.
				readonly property real contentWidth:
					hIcon.implicitWidth
					+ (hLabel.visible ? root.hIconGap + hLabel.implicitWidth : 0)

				// Padding gives way before the content does, and the content
				// gives way before the slot does. Only a slot too narrow for a
				// bare icon reaches the clip, and then the clip is the honest
				// answer: half a glyph beats two tabs on top of each other.
				readonly property real pad:
					Math.max(0, Math.min(root.hPadMax,
					                     (root.hSlotRoom - contentWidth) / 2))

				// Pill background
				Rectangle {
					id: hBg
					anchors.centerIn: parent
					width:  Math.min(root.hSlotRoom, hTab.contentWidth + 2 * hTab.pad)
					height: Math.max(0, parent.height - Theme.px(8))
					radius: height / 2
					clip:   true

					color: hTab.isActive
					? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.18)
					: (hHov.hovered ? Qt.rgba(1, 1, 1, 0.07) : "transparent")

					Behavior on color { ColorAnimation { duration: 120 } }

					// Icon + label, drawn INSIDE the pill so the clip above is
					// the last word on where a glyph may land.
					Row {
						anchors.centerIn: parent
						spacing: hLabel.visible ? root.hIconGap : 0

						Text {
							id: hIcon
							text:           modelData.icon
							font.pixelSize: root.hIconSize
							anchors.verticalCenter: parent.verticalCenter
							color: hTab.isActive
							? Theme.active
							: (hHov.hovered ? Qt.rgba(1, 1, 1, 0.75) : Qt.rgba(1, 1, 1, 0.4))
							Behavior on color { ColorAnimation { duration: 120 } }
						}

						Text {
							id: hLabel
							visible:        root.hShowLabels && modelData.label !== undefined
							text:           modelData.label ?? ""
							font.pixelSize: root.hLabelSize
							font.weight:    hTab.isActive ? Font.Medium : Font.Normal
							anchors.verticalCenter: parent.verticalCenter
							color: hTab.isActive
							? Theme.active
							: (hHov.hovered ? Qt.rgba(1, 1, 1, 0.75) : Qt.rgba(1, 1, 1, 0.4))
							Behavior on color { ColorAnimation { duration: 120 } }
						}
					}
				}

				HoverHandler { id: hHov; cursorShape: Qt.PointingHandCursor }
				// Fills the SLOT, not the pill. A tab whose pill has shrunk to
				// an icon is still clicked anywhere in its sixth of the bar.
				MouseArea {
					anchors.fill: parent
					onClicked:    root.pageChanged(modelData.key)
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
		color:          Qt.rgba(1, 1, 1, 0.07)
	}

	// ── VERTICAL metrics ──────────────────────────────────────────────────────
	readonly property int vRowPreferred: Theme.px(60)
	readonly property int vRowMin:       Math.max(root.minTouch, Theme.px(30))
	readonly property int vGap:          Theme.px(4)
	readonly property int vLeftPad:      Theme.px(16)
	readonly property int vIconGap:      Theme.px(12)

	// A row is as tall as its share of the column, between a floor you can still
	// hit and the 60px it has always been. Only the floor is new: the old code
	// pinned the height at 60 and spread whatever was left over as spacing, so
	// nine rows in a 381px column asked for -19.9px of spacing and Qt obliged.
	readonly property int vRowHeight: {
		var n = root.model.length
		if (n <= 0)
			return root.vRowPreferred
		var fit = Math.floor((root.height - (n - 1) * root.vGap) / n)
		return Math.max(root.vRowMin, Math.min(root.vRowPreferred, fit))
	}

	// Slack still goes into the gaps, so a switcher with room to spare looks
	// exactly as it did — three audio tabs down the side of the popup are spread
	// over the whole height, not bunched in the middle. What is new is the floor
	// under it, which is where the overlap used to come from.
	readonly property int vSpacing: {
		var n = root.model.length
		if (n <= 1)
			return 0
		var slack = root.height - n * root.vRowHeight
		return Math.max(root.vGap, Math.floor(slack / (n - 1)))
	}

	readonly property int vContentHeight:
		root.model.length > 0
			? root.model.length * root.vRowHeight
			  + (root.model.length - 1) * root.vSpacing
			: 0

	// ── VERTICAL layout — Column in a Flickable ───────────────────────────────
	// The Flickable is the deliberate answer to "more rows than room": below the
	// floor the list scrolls instead of compressing further. It is inert — not
	// interactive, not clipping anything — whenever everything fits, which is
	// every default configuration.
	Flickable {
		id: vFlick
		anchors.fill: parent
		visible: root.orientation === "vertical"
		contentWidth:  width
		contentHeight: root.vContentHeight
		interactive:   root.orientation === "vertical"
		               && root.vContentHeight > root.height
		boundsBehavior: Flickable.StopAtBounds
		clip: interactive

		Column {
			id: vCol
			width:   vFlick.width
			spacing: root.vSpacing
			// Centred while there is slack, so a short list keeps the balanced
			// look it had; pinned to the top once it scrolls, because a
			// centred list you can scroll starts halfway through itself.
			y: vFlick.interactive
			   ? 0
			   : Math.max(0, (root.height - root.vContentHeight) / 2)

			readonly property bool hasLabels:
				root.model.length > 0 &&
				root.model[0].label !== undefined &&
				root.model[0].label !== ""

			Repeater {
				model: root.orientation === "vertical" ? root.model : []

				delegate: Rectangle {
					id: vTab
					readonly property bool isActive: root.currentPage === modelData.key

					width:  vCol.width
					height: root.vRowHeight
					radius: Theme.cornerRadius * 2
					clip:   true

					color: vTab.isActive
						? Theme.active
						: (vHov.hovered ? Qt.rgba(1, 1, 1, 0.08) : "transparent")

					Behavior on color { ColorAnimation { duration: 120 } }

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
							right:          parent.right
							leftMargin:     root.vLeftPad
							rightMargin:    root.vLeftPad
							verticalCenter: parent.verticalCenter
						}
						spacing: root.vIconGap

						Text {
							id: vIcon
							text:           modelData.icon
							font.pixelSize: Theme.fs(15)
							anchors.verticalCenter: parent.verticalCenter
							color: vTab.isActive
								? Theme.background
								: (vHov.hovered ? Qt.rgba(1, 1, 1, 0.80) : Qt.rgba(1, 1, 1, 0.42))
							Behavior on color { ColorAnimation { duration: 120 } }
						}

						Text {
							// "Layout & Behavior" is wider than a 30% column at
							// any scale, and an unbounded Text would draw it
							// straight out of the pane.
							width: Math.max(0, vTab.width - 2 * root.vLeftPad
							                   - vIcon.implicitWidth - root.vIconGap)
							elide: Text.ElideRight
							text:           modelData.label ?? ""
							font.pixelSize: Theme.fs(12)
							font.weight:    vTab.isActive ? Font.Medium : Font.Normal
							anchors.verticalCenter: parent.verticalCenter
							color: vTab.isActive
								? Theme.background
								: (vHov.hovered ? Qt.rgba(1, 1, 1, 0.80) : Qt.rgba(1, 1, 1, 0.42))
							Behavior on color { ColorAnimation { duration: 120 } }
						}
					}

					HoverHandler { id: vHov; cursorShape: Qt.PointingHandCursor }
					MouseArea {
						anchors.fill: parent
						onClicked:    root.pageChanged(modelData.key)
					}
				}
			}
		}
	}
}
