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
	ControlPanel{}

	// 2. Workspaces
	Workspaces {} 
	
	//3. LayoutDisplay
	LayoutDisplayer {}

	// 4. Background applications
	SysTray {}

	// 5. Pinned and running applications for the stacking labwc session.
	AppDock { screenName: root.screenName }

}
