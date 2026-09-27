import QtQuick
import Quickshell
import "../../components"
import "../../windows"
import "../../"
import "../Right"

Row {
	id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes

	property string screenName: ""
	spacing: 5
	// Note: Do NOT add anchors.centerIn: parent here. TopBar handles that.
	//
	// A Row lines its children up by their TOP edges: the 20 px buttons sat
	// high beside the taller workspace pill, the tray toggle most visibly
	// (Andre, 2026-09-27: "why is background tasks not aligned"). Every child
	// is centred on the row's middle instead.

	// 1. Arch Icon (Power Menu Trigger)
	ControlPanel { id: controlPanel; anchors.verticalCenter: parent.verticalCenter }
	// 2. Workspaces
	Workspaces { id: workspaces; anchors.verticalCenter: parent.verticalCenter }
	//3. LayoutDisplay
	LayoutDisplayer { id: layoutDisplayer; screenName: root.screenName; anchors.verticalCenter: parent.verticalCenter }
	// 4. Background applications
	SysTray { id: sysTray; anchors.verticalCenter: parent.verticalCenter }
	// 5. Pinned and running applications for the stacking labwc session.
	AppDock {
		anchors.verticalCenter: parent.verticalCenter
		screenName: root.screenName
		// Reserve the maximum possible inter-item spacing. The dock turns the
		// remaining width into a whole-number icon capacity.
		availableWidth: Math.max(0,
			theme.lNotchMaxWidth - theme.notchPadding * 2
			- controlPanel.width - workspaces.width
			- (layoutDisplayer.visible ? layoutDisplayer.width : 0)
			- (sysTray.visible ? sysTray.width : 0)
			- root.spacing * 4)
	}

}
