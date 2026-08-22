import QtQuick
import Quickshell
import "../../components"
import "../../windows"
import "../../"
import "../Right"

Row {
	id: root
	property string screenName: ""
	spacing: 5
	// Note: Do NOT add anchors.centerIn: parent here. TopBar handles that.

	// 1. Arch Icon (Power Menu Trigger)
	ControlPanel { id: controlPanel }

	// 2. Workspaces
	Workspaces { id: workspaces }
	
	//3. LayoutDisplay
	LayoutDisplayer { id: layoutDisplayer }

	// 4. Background applications
	SysTray { id: sysTray }

	// 5. Pinned and running applications for the stacking labwc session.
	AppDock {
		screenName: root.screenName
		// Reserve the maximum possible inter-item spacing. The dock turns the
		// remaining width into a whole-number icon capacity.
		availableWidth: Math.max(0,
			Theme.lNotchMaxWidth - Theme.notchPadding * 2
			- controlPanel.width - workspaces.width
			- (layoutDisplayer.visible ? layoutDisplayer.width : 0)
			- (sysTray.visible ? sysTray.width : 0)
			- root.spacing * 4)
	}

}
