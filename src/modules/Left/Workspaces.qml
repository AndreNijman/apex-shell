import QtQuick
import Quickshell
import "../../"

Rectangle {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


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
    // The bar shows only what is there (Andre, 2026-09-27: "make this dynamic
    // instead of constantly a bunch of dots"): a workspace with windows, the one
    // you are on, an urgent one. On Hyprland the grid is still built slot by slot
    // — its delegates must outlive a switch (see the Repeater) — and an empty
    // slot collapses to nothing on a spring rather than being dropped from the
    // model, so dots grow in and fold away instead of popping. A slot past the
    // grid (a workspace 11 opened by a bind or a script) extends it.
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

        let last = slots
        for (let i = 0; i < live.length; i++)
            if (live[i].id > last && live[i].id <= 99) last = live[i].id
        const out = []
        for (let n = 1; n <= last; n++) {
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
    radius: theme.wsRadius

    // Auto-size. Every slot carries half a gap on each side (so a collapsing
    // one takes its gap with it), which puts half a gap inside each end too.
    width: workspaceRow.width + (theme.wsPadding - theme.wsSpacing / 2) * 2
    height: theme.wsDotSize + (theme.wsPadding * 2)

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
        spacing: 0

        // Logic: Fade out dots when Scratchpad is active
        opacity: root.isScratchpad ? 0 : 1
        scale:   root.isScratchpad ? 0.8 : 1
        visible: opacity > 0

        Behavior on opacity { MotionFade {} }
        Behavior on scale   { MotionMove { role: "surfaceEnterSmall" } }

        // ── Why the model is a COUNT and the entry is looked up ───────────────
        // `model: <JS array>` recreates every delegate whenever the array's
        // contents change — measured on Qt 6.10.3: a 3-element model reports
        // created=6, destroyed=3 after one content change. Workspace switches
        // change `isFocused` on every entry, so every dot was destroyed and
        // rebuilt on every switch, and a Behavior does not animate a freshly
        // created object's initial binding. The width and colour Behaviors below
        // silently stopped running, and the urgent pulse restarted from zero on
        // every workspace event.
        //
        // Before the three Repeaters were unified, Hyprland's model was the
        // constant `10`, so its delegates persisted for the session and the
        // animations worked. An integer model restores that: the count is stable
        // across a workspace switch, so the delegates survive and only their
        // bindings update.
        Repeater {
            model: root.workspaceModel.length

            delegate: Item {
                id: slot

                required property int index
                readonly property var modelData: root.workspaceModel[slot.index]

                // Focused, not active. The three delegates disagreed about this
                // and the unified one had to pick: Hyprland highlighted
                // `focusedWorkspace` and labwc highlighted the single active
                // windowset — both mean "you are here" — while niri used its
                // per-output `is_active`, which on a multi-output niri session
                // lit one dot per monitor.
                //
                // So this is behaviour-neutral on Hyprland and labwc, and on
                // multi-monitor niri it deliberately drops a second highlight in
                // favour of the bar meaning one thing everywhere. Flagged rather
                // than buried: it is a real visual change on a configuration
                // this checkout cannot test.
                readonly property bool isFocused:  slot.modelData ? slot.modelData.isFocused : false
                readonly property bool isUrgent:   slot.modelData ? slot.modelData.isUrgent : false
                readonly property bool isOccupied: slot.modelData ? slot.modelData.occupied : false
                // What the bar shows: somewhere with windows, where you are, or
                // somewhere asking for you. An empty slot folds away.
                readonly property bool shown: slot.isFocused || slot.isOccupied || slot.isUrgent

                // 0 folded away, 1 fully there; a whisper over on the way in.
                readonly property real presence: Math.max(0, presenceF.value)
                SpringFollower { id: presenceF; target: slot.shown ? 1 : 0; epsilon: 0.002 }

                height: theme.wsDotSize
                width:  slot.presence * (dotW.value + theme.wsSpacing)
                visible: slot.presence > 0.001
                // The focused dot's width on a spring that bends toward a second
                // workspace change mid-travel (SpringFollower).
                SpringFollower { id: dotW; target: slot.isFocused ? theme.wsActiveWidth : theme.wsDotSize }

                Rectangle {
                    id: dot
                    anchors.centerIn: parent
                    height: theme.wsDotSize
                    width:  dotW.value
                    radius: height / 2
                    // Grows out of its own centre while its slot opens; the
                    // urgent pulse below owns `scale`, so presence is a transform.
                    opacity: Math.min(1, slot.presence)
                    transform: Scale {
                        origin.x: dot.width / 2; origin.y: dot.height / 2
                        xScale: Math.min(1, slot.presence); yScale: Math.min(1, slot.presence)
                    }

                    color: {
                        if (slot.isFocused)  return Theme.wsActive
                        if (slot.isUrgent)   return Theme.wsUrgent
                        if (slot.isOccupied) return Theme.wsOccupied
                        return Theme.wsEmpty
                    }

                    Behavior on color { MotionColor { role: "state" } }

                    // Its number, in the capsule's own colour: dark on a light
                    // dot in the dark theme, light on a dark one in the light.
                    Text {
                        anchors.centerIn: parent
                        text: slot.modelData ? String(slot.modelData.idx !== undefined ? slot.modelData.idx : slot.modelData.name) : ""
                        color: Theme.wsBackground
                        font.family: Theme.fontUi
                        font.pixelSize: theme.fs(10)
                        font.weight: slot.isFocused ? Font.Bold : Font.DemiBold
                        font.features: { "tnum": 1 }
                    }

                    // --- Urgent pulse ---
                    SequentialAnimation {
                        running: slot.isUrgent && !slot.isFocused && Motion.ambient
                        // Finish the current beat when gated off, so it rests at its
                        // end value instead of freezing mid-fade (Reduce Motion mid-pulse).
                        alwaysRunToEnd: true
                        loops:   Animation.Infinite

                        NumberAnimation {
                            target:   dot
                            property: "scale"
                            to:       1.35
                            duration: Motion.pulseHalf
                            easing.type: Easing.InOutSine
                        }
                        NumberAnimation {
                            target:   dot
                            property: "scale"
                            to:       1.0
                            duration: Motion.pulseHalf
                            easing.type: Easing.InOutSine
                        }
                    }
                }

                // Reset scale when no longer urgent
                onIsUrgentChanged: if (!slot.isUrgent) dot.scale = 1.0

                MouseArea {
                    anchors.fill: parent
                    enabled: slot.shown
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (slot.modelData) CompositorService.focusWorkspace(slot.modelData.ref)
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

        Behavior on opacity { MotionFade {} }

        Text {
            anchors.centerIn: parent
            text: ""
            color: Theme.fixedLight
            font.pixelSize: theme.fs(14)
        }

        MouseArea {
            anchors.fill: parent
            onClicked: CompositorService.toggleSpecialWorkspace("magic")
        }
    }
}
