import QtQuick
import Quickshell
import Quickshell.Io
import "../shapes"
import "../components"
import "../services"
import "../"

PopupWindow {
	id: root

	required property var anchorWindow

	readonly property int fw: Theme.cornerRadius
	readonly property int fh: Theme.cornerRadius

	readonly property var pageWidths: ({
		"output": 200,
		"input":  200,
		"mixer":  300
	})

	readonly property int popupHeight: 340

	readonly property int maxWidth: 300

	color:   "transparent"
	visible: slide.windowVisible
	mask: Region { item: maskProxy }

	anchor.window:  anchorWindow
	anchor.rect: Qt.rect(
		Theme.cornerRadius,
		anchorWindow.height / 2,
		0,
		popupHeight
	)
	anchor.gravity: Edges.Left
	
	Item {
	    id:      maskProxy
	    x:       root.maxWidth - sizer.width
	    y:       ((root.popupHeight - sizer.height) / 2) -root.fh
	    width:   sizer.width
	    height:  sizer.height
	}

	implicitWidth:  maxWidth
	implicitHeight: popupHeight
	
	// ── IPC Handle ─────────────────────────────────────────────
	IpcHandler {
    	target: "audioOut-toggle"
    	function toggle() {
			if(Popups.anyOpen && !Popups.audioOpen) {
				Popups.closeAll()
				audioControl.page = "output"
				Popups.audioOpen = true
			} else if (Popups.audioOpen && audioControl.page != "output") {
				audioControl.page = "output"
			} else {
				Popups.audioOpen = !Popups.audioOpen
				audioControl.page = "output"
			}
    	}
    }
	IpcHandler {
    	target: "audioMix-toggle"
    	function toggle() {
			if(Popups.anyOpen && !Popups.audioOpen) {
				Popups.closeAll()
				audioControl.page = "mixer"
				Popups.audioOpen = true
			} else if (Popups.audioOpen && audioControl.page != "mixer") {
				audioControl.page = "mixer"
			} else {
				Popups.audioOpen = !Popups.audioOpen
				audioControl.page = "mixer"
			}
    	}
    }
	IpcHandler {
    	target: "audioIn-toggle"
    	function toggle() {
			if(Popups.anyOpen && !Popups.audioOpen) {
				Popups.closeAll()
				audioControl.page = "input"
				Popups.audioOpen = true
			} else if (Popups.audioOpen && audioControl.page != "input") {
				audioControl.page = "input"
			} else {
				Popups.audioOpen = !Popups.audioOpen
				audioControl.page = "input"
			}
    	}
    }

	PopupSlide {
		id: slide
		anchors.fill: parent
		edge:             "right"
		open:             Popups.audioOpen
		hoverEnabled:     false
		triggerHovered:   Popups.audioTriggerHovered
		onCloseRequested: Popups.audioOpen = false

		Connections {
			target: Popups
			function onAudioOpenChanged() {
				if (!Popups.audioOpen) audioResetTimer.restart()
			}
		}

		Timer {
			id: audioResetTimer
			interval: Theme.animDuration + 20
			onTriggered: audioControl.reset()
		}

		Item {
			id: sizer
			anchors.right:          parent.right
			anchors.verticalCenter: parent.verticalCenter
			clip: true

			width:  (root.pageWidths[audioControl.page] ?? root.maxWidth)
			height: root.popupHeight

			Behavior on width { NumberAnimation { duration: Theme.animDuration; easing.type: Easing.InOutCubic } }

			PopupShape {
				id: bg
				anchors.fill: parent
				attachedEdge: "right"
				color:        Theme.background
				radius:       Theme.cornerRadius
				flareWidth:   root.fw
				flareHeight:  root.fh
			}

			AudioControl {
				id: audioControl
				anchors {
					fill:         parent
					topMargin:    root.fh + 6
					bottomMargin: root.fh + 6
					leftMargin:   10
					rightMargin:  root.fw - 4
				}
			}
		}
	}
}
