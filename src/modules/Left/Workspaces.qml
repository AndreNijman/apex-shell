import QtQuick
import Quickshell
import "../../"

Rectangle {
    id: root

    // ── One model, one delegate ───────────────────────────────────────────────
    // This used to be three Repeaters with near-identical delegates — a fixed
    // 1..10 Hyprland grid reading the Hyprland singleton, a dynamic niri list
    // reading NiriService, and a dynamic ext-workspace list for labwc — plus a
    // four-branch dispatchWorkspace() and a Hyprland raw-event listener for the
    // scratchpad. Roughly 150 lines of view code that knew which compositor it
    // was running on.
    //
    // CompositorService publishes one workspace model. The only thing that still
    // differs is whether the compositor presents a fixed grid of slots
    // (Hyprland: 10, including empty ones you can still switch to) or creates
    // workspaces on demand (niri, labwc), and that is one integer.
    //
    // `ref` is carried in each entry rather than reconstructed at the click,
    // because it is genuinely a different kind of value per compositor — an id,
    // a 1-based index, a list position — and the view has no business knowing
    // which one it is holding.
    readonly property var workspaceModel: {
        const live  = CompositorService.workspaces
        const slots = CompositorService.workspaceSlots
        if (slots <= 0)
            return live                     // dynamic: exactly what exists

        // Fixed grid: slot n is workspace n, occupied only if it is in the live
        // list. An empty slot is still a place the user can click to.
        const byId = ({})
        for (let i = 0; i < live.length; i++) byId[live[i].id] = live[i]

        const out = []
        for (let n = 1; n <= slots; n++) {
            const w = byId[n]
            out.push(w ? w : {
                id: n, idx: n, ref: n, name: String(n), output: "",
                isActive: false, isFocused: false, isUrgent: false,
                occupied: false
            })
        }
        return out
    }

    // The scratchpad overlay. Hyprland is the only compositor APEX ships that
    // has the concept, and the capability says so rather than a name check.
    readonly property bool isScratchpad: CompositorService.specialWorkspaceOpen

    // --- 1. Capsule Container ---
    color: Theme.wsBackground
    radius: Theme.wsRadius

    // Auto-size
    width: workspaceRow.width + (Theme.wsPadding * 2)
    height: Theme.wsDotSize + (Theme.wsPadding * 2)

    property bool scrollBusy: false

    Timer {
        id: scrollCooldown
        interval: 300   // ms — tune up if still too fast, down if sluggish
        repeat:   false
        onTriggered: root.scrollBusy = false
    }

    // --- Wheel: cycle through occupied workspaces ---
    // One implementation now. It cycles the *occupied* ones, which on a dynamic
    // compositor is the whole list and on Hyprland skips the empty slots —
    // matching what each did separately before.
    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: function(event) {
            if (root.scrollBusy) return
            root.scrollBusy = true
            scrollCooldown.restart()

            const occupied = root.workspaceModel.filter(w => w.occupied)
            if (occupied.length === 0) return

            let idx = occupied.findIndex(w => w.isFocused)
            if (idx === -1) idx = 0

            // Inverted scroll: up goes to the previous workspace, down the next.
            if (event.angleDelta.y < 0) idx = (idx + 1) % occupied.length
            else                        idx = (idx - 1 + occupied.length) % occupied.length

            CompositorService.focusWorkspace(occupied[idx].ref)
        }
    }

    // --- 3. Workspace Dots ---
    Row {
        id: workspaceRow
        anchors.centerIn: parent
        spacing: Theme.wsSpacing

        // Logic: Fade out dots when Scratchpad is active
        opacity: root.isScratchpad ? 0 : 1
        scale:   root.isScratchpad ? 0.8 : 1
        visible: opacity > 0

        Behavior on opacity { NumberAnimation { duration: 200 } }
        Behavior on scale   { NumberAnimation { duration: 200 } }

        Repeater {
            model: root.workspaceModel

            delegate: Rectangle {
                id: dot

                required property var modelData

                // Focused, not active: on a multi-monitor Hyprland setup every
                // output has an active workspace, and highlighting all of them
                // is not what the bar means by "you are here".
                readonly property bool isFocused:  dot.modelData.isFocused
                readonly property bool isUrgent:   dot.modelData.isUrgent
                readonly property bool isOccupied: dot.modelData.occupied

                height: Theme.wsDotSize
                radius: height / 2
                width:  isFocused ? Theme.wsActiveWidth : Theme.wsDotSize

                color: {
                    if (dot.isFocused)  return Theme.wsActive
                    if (dot.isUrgent)   return Theme.wsUrgent
                    if (dot.isOccupied) return Theme.wsOccupied
                    return Theme.wsEmpty
                }

                Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }
                Behavior on color { ColorAnimation  { duration: 200 } }

                // --- Urgent pulse ---
                SequentialAnimation {
                    running: dot.isUrgent && !dot.isFocused
                    loops:   Animation.Infinite

                    NumberAnimation {
                        target:   dot
                        property: "scale"
                        to:       1.35
                        duration: 400
                        easing.type: Easing.InOutSine
                    }
                    NumberAnimation {
                        target:   dot
                        property: "scale"
                        to:       1.0
                        duration: 400
                        easing.type: Easing.InOutSine
                    }
                }

                // Reset scale when no longer urgent
                onIsUrgentChanged: if (!dot.isUrgent) dot.scale = 1.0

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: CompositorService.focusWorkspace(dot.modelData.ref)
                }
            }
        }
    }

    // --- 4. Scratchpad Overlay ---
    Rectangle {
        id: overlay
        anchors.fill: parent
        radius: root.radius
        color: Theme.wsOverlay
        z: 99

        // Only where a scratchpad exists at all. The capability answers that;
        // the old `!isNiri && !isExtWorkspace` was a double negative that also
        // said yes on sway, river and KDE.
        visible: CompositorService.can.specialWorkspace && opacity > 0
        opacity: root.isScratchpad ? 1 : 0

        Behavior on opacity { NumberAnimation { duration: 200 } }

        Text {
            anchors.centerIn: parent
            text: ""
            color: "#FFFFFF"
            font.pixelSize: Theme.fs(14)
        }

        MouseArea {
            anchors.fill: parent
            onClicked: CompositorService.toggleSpecialWorkspace("magic")
        }
    }
}
