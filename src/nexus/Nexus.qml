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
// It shares its page set with the dashboard tab through PageRegistry — one
// declaration, two presentations — so neither can drift from the other.
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
        id: life
        open:          root.live
        enterDuration: Motion.page
        exitDuration:  Motion.surfaceExitSmall
        enterCurve:    Motion.emphasizedDecel
        exitCurve:     Motion.standardAccel
        contentDelay:  0
        // The sheet leaves on the scrim's beat. On the content beat (70 ms) it
        // was gone while the scrim still dimmed an empty desk for another
        // 65 ms (design review 2). Under Reduce Motion that beat is 0 and the
        // alpha takes it too, so the short fade stays.
        contentOut:    Motion.reduced ? Motion.fadeOut : Motion.surfaceExitSmall
    }

    // The window stays mapped for the duration of the close animation.
    readonly property bool windowVisible: life.mapped

    // Pages move in the direction of the nav order (Phase 7): the pages bind
    // to `shownPage`, set only after `pageDir` is.
    property int    pageDir: 1
    property int    _pageIdx: 0
    property string shownPage: NexusState.page
    function _indexOf(id) {
        const list = PageRegistry.pages
        for (let i = 0; i < list.length; i++) if (list[i].id === id) return i
        return 0
    }
    Connections {
        target: NexusState
        function onPageChanged() {
            const i = root._indexOf(NexusState.page)
            root.pageDir = i >= root._pageIdx ? 1 : -1
            root._pageIdx = i
            root.shownPage = NexusState.page
        }
    }
    Component.onCompleted: root._pageIdx = root._indexOf(NexusState.page)

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

            // ── Left: navigation ────────────────────────────────────────────
            NavPane {
                id: nav
                anchors {
                    left: parent.left
                    top: parent.top
                    bottom: parent.bottom
                }
                currentPage: NexusState.page
                onPageSelected: function (id) { NexusState.page = id }
            }

            Rectangle {
                anchors {
                    left: nav.right
                    top: parent.top
                    bottom: parent.bottom
                    topMargin: theme.px(10)
                    bottomMargin: theme.px(10)
                }
                width: 1
                color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07)
            }

            // ── Right: header + page ────────────────────────────────────────
            Item {
                id: pane

                anchors {
                    left: nav.right
                    right: parent.right
                    top: parent.top
                    bottom: parent.bottom
                    leftMargin: theme.px(1)
                }

                readonly property var current: PageRegistry.pageFor(NexusState.page)

                Item {
                    id: header
                    anchors {
                        left: parent.left
                        right: parent.right
                        top: parent.top
                    }
                    height: theme.px(58)

                    Text {
                        id: title
                        anchors {
                            left: parent.left
                            leftMargin: theme.px(18)
                            top: parent.top
                            topMargin: theme.px(12)
                        }
                        text: pane.current ? pane.current.title : ""
                        color: Theme.textPrimary
                        font.pixelSize: theme.typePageTitle
                        font.weight: Font.DemiBold
                    }

                    Text {
                        anchors {
                            left: parent.left
                            leftMargin: theme.px(18)
                            top: title.bottom
                            topMargin: theme.px(2)
                            right: closeBtn.left
                            rightMargin: theme.px(8)
                        }
                        text: pane.current ? pane.current.subtitle : ""
                        color: Theme.textSecondary
                        font.pixelSize: theme.typeCaption
                        elide: Text.ElideRight
                    }

                    ApexIconButton {
                        id: closeBtn
                        anchors {
                            right: parent.right
                            rightMargin: theme.px(12)
                            top: parent.top
                            topMargin: theme.px(12)
                        }
                        glyph: "󰅖"
                        label: "Close settings"
                        radius: height / 2
                        onActivated: NexusState.close()
                    }
                }

                // One LazyPage per registered page: built on first visit, kept
                // afterwards so scroll position and sub-page state survive
                // switching away and back.
                Repeater {
                    model: PageRegistry.pages

                    delegate: LazyPage {
                        required property var modelData

                        anchors {
                            left: parent.left
                            right: parent.right
                            top: header.bottom
                            bottom: parent.bottom
                            leftMargin: theme.px(8)
                            rightMargin: theme.px(8)
                            bottomMargin: theme.px(8)
                        }

                        shown: root.shownPage === modelData.id
                        direction: root.pageDir
                        sourceComponent: modelData.component

                        // Pages that consume refcounted telemetry need to know
                        // whether a user can actually see them; without this a
                        // poller started here would run until logout.
                        onLoaded: if (modelData.needsScreen && item)
                            item.onScreen = Qt.binding(() => root.windowVisible
                                                             && root.live
                                                             && NexusState.page === modelData.id
                                                             && !LockState.locked)
                    }
                }
            }
        }
    }
}
