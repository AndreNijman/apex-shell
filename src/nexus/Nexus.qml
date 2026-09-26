import QtQuick
import Quickshell
import Quickshell.Wayland
import "../"
import "../components"
import "../components/controls"

// ─────────────────────────────────────────────────────────────────────────────
// Nexus — the standalone settings window.
//
// Settings previously existed only as a tab inside the dashboard, which meant
// they shared the dashboard's lifetime and its dismissal rules: click anywhere
// outside and the settings vanished, and any compositor focus change closed
// them. That is correct behaviour for a popup and wrong for a window you edit
// configuration in.
//
// So this is a real window. It has keyboard focus, it survives clicks elsewhere,
// it closes on Escape or its own close button, and it is opened over IPC:
//
//     apex shell nexus            (or: nexus <page>)
//
// Its body — navigation, header and page stack — is SettingsHost, the one host
// of the PageRegistry pages since UI/UX Phase 19 removed the dashboard's Config
// tab (a second host of every page, with its own staged state).
//
// One instance per screen, following the dashboard's pattern; NexusState.
// screenName decides which one is live, so the window opens on the output the
// user is actually looking at instead of always the primary.
//
// ── QUIET_SHEET (UI/UX roadmap v3 Phase 13, brief B.5) ──────────────────────
// A long-lived work surface, so it barely moves: no shape morph. The scrim
// comes up with the lifecycle's progress; the sheet fades in on the content
// channel and scales 0.985 → 1 on emphasizedDecel over the page beat; it
// leaves quicker (surfaceExitSmall, standardAccel), scaling only to 0.99.
// Under Reduce Motion the scale is gone and both fade. Its window's lifetime is
// the lifecycle's `mapped` — completion, not `animDuration + 20`.
// ─────────────────────────────────────────────────────────────────────────────

PanelWindow {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForScreen(root.screen) }   // P1-040: this output's sizes


    required property string screenName

    readonly property bool live: NexusState.open
                                 && NexusState.effectiveScreen === root.screenName

    // A Nexus can be BORN live. shell.qml builds one per entry in
    // Quickshell.screens, so an output arriving or leaving — which is what a
    // display apply does — destroys and rebuilds the whole set while the
    // settings window is open. A handler on `live` never fires for those,
    // because `live` was already true when they were constructed; the
    // lifecycle observes `open` from construction, so a Nexus born live opens
    // itself (tests/surface-lifecycle-test.qml, test_born_open_opens_itself).
    SurfaceLifecycle {
        name: "nexus"
        id: life
        open:          root.live
        enterDuration: Motion.page
        exitDuration:  Motion.surfaceExitSmall
        contentDelay:  0
        // The sheet leaves on the scrim's beat. On the content beat (70 ms) it
        // was gone while the scrim still dimmed an empty desk for another
        // 65 ms (design review 2). Under Reduce Motion that beat is 0 and the
        // alpha takes it too, so the short fade stays.
        contentOut:    Motion.reduced ? Motion.fadeOut : Motion.surfaceExitSmall
    }

    // The window stays mapped for the duration of the close animation.
    readonly property bool windowVisible: life.mapped

    color: "transparent"
    visible: root.windowVisible

    anchors.top: true
    anchors.left: true
    anchors.right: true
    anchors.bottom: true

    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay

    // The whole window takes input while it is live (the backdrop swallows
    // clicks rather than dismissing), and none while it closes: a fullscreen
    // Overlay surface fading out used to eat the clicks that followed it.
    mask: Region { item: root.live ? content : null }

    // Exclusive focus, unlike the popups: there are text fields in here (the
    // lock-background path, the keybind capture) and they must receive keys.
    WlrLayershell.keyboardFocus: root.windowVisible && root.live
                                     ? WlrKeyboardFocus.Exclusive
                                     : WlrKeyboardFocus.None

    // Dim the desktop behind. Deliberately NOT a click-to-dismiss surface:
    // mis-clicking beside a slider should not throw away the settings window.
    // Escape and the close button are the ways out, and both are discoverable.
    Rectangle {
        anchors.fill: parent
        color: "black"
        // With the progress (a fade of its own under Reduce Motion, when the
        // progress jumps and alpha carries the change). Closing, with the
        // sheet's own channel: on the progress (standardAccel, slow to start)
        // the dim outlived the sheet — at 187 ms of a slowed close, 69 % of the
        // scrim was left over 15 % of the sheet (design review 2, measured).
        opacity: 0.35 * (life.closing ? life.content : life.progress) * life.alpha
    }

    Item {
        id: content
        anchors.fill: parent
        focus: true

        Keys.onEscapePressed: NexusState.close()

        // Depth (UI/UX Phase 18b): the modal level. The scrim says the sheet is
        // modal; nothing said it was in front — on the light scheme the sheet sat
        // 3.6:1 over the scrimmed desk with only its hairline for an edge.
        Elevation { target: card; level: "modal" }

        Rectangle {
            id: card

            anchors.centerIn: parent

            width: Math.min(parent.width - theme.px(80), theme.px(920))
            height: Math.min(parent.height - theme.px(80), theme.px(620))

            radius: theme.radiusXL
            color: Theme.background
            border.color: Theme.outlineSoft   // the surface rim, as a role (UI/UX Phase 18b)
            border.width: 1

            opacity: life.content * life.alpha
            // Barely: 0.985 → 1 in, 1 → 0.99 out. `closing`, not `open` — see
            // SurfaceLifecycle on reading `open` beside the lifecycle's values.
            scale: life.closing ? 0.99 + 0.01 * life.progress
                                : 0.985 + 0.015 * life.progress

            // Swallow clicks so they do not reach the backdrop.
            MouseArea {
                anchors.fill: parent
            }

            SettingsHost {
                anchors.fill: parent
                theme: root.theme
                page: NexusState.page
                live: root.windowVisible && root.live
                onPageSelected: function (id) { NexusState.page = id }
                onCloseRequested: NexusState.close()
            }
        }
    }
}
