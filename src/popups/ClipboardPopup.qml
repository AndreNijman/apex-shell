import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../shapes"
import "../components"
import "../"

PanelWindow {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForScreen(root.screen) }   // P1-040: this output's sizes


    readonly property int popupWidth:  420
    readonly property int popupHeight: 560
    readonly property int fw: theme.cornerRadius
    readonly property int fh: theme.cornerRadius

    anchors.right:  true
    anchors.bottom: true

    implicitWidth:  popupWidth  + fw
    implicitHeight: popupHeight + fh

    exclusionMode: ExclusionMode.Ignore
    color:         "transparent"

    WlrLayershell.layer:         WlrLayer.Overlay
    // The keyboard while it is open (UI/UX Phase 21): it was OnDemand, which a
    // compositor may grant only on a click — measured, typed keys reached
    // nothing — and it had no Escape of its own.
    WlrLayershell.keyboardFocus: Popups.clipboardOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    mask: Region { item: maskProxy }
    Item {
        id: maskProxy
        x:      root.implicitWidth  - sizer.width
        y:      root.implicitHeight - sizer.height
        width:  sizer.width
        height: sizer.height
    }

    // On the shared lifecycle (UI/UX roadmap v3 Phase 21): the sheet grows out
    // of its corner on the progress, its content arrives on its own channel,
    // and the window is mapped until the close has finished — not for a guessed
    // `animDuration + 20`. It ran on the legacy duration, which is 0 under
    // Reduce Motion, so there it popped in and out with no fade at all
    // (measured); now the shape holds while alpha fades, as every surface does.
    SurfaceLifecycle {
        name: "clipboard"
        id: life
        open:          Popups.clipboardOpen
        enterDuration: Motion.morphEnter
        exitDuration:  Motion.morphExit
        enterCurve:    Motion.emphasizedDecel
        exitCurve:     Motion.standardAccel
    }
    readonly property bool windowVisible: life.mapped
    visible: life.mapped

    // LazyPopup calls this right after building the window; the lifecycle is
    // born open and opens itself, so there is nothing left to apply.
    function applyOpenState() {}
    
    Item {
        id: sizer
        anchors.right:  parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: theme.borderWidth
        anchors.bottomMargin: theme.borderWidth
        clip: true

        width:  (root.popupWidth  + root.fw) * life.progress
        height: (root.popupHeight + root.fh) * life.progress
        opacity: life.alpha

        PopupShape {
            anchors.fill: parent
            attachedEdge: "bottom-right"
            color:        Theme.background
            radius:       theme.cornerRadius
            flareWidth:   root.fw
            flareHeight:  root.fh
        }

        Item {
            id: content
            // Escape from anywhere inside (keys travel up from the focused item),
            // and before any Tab: it holds focus itself when the popup opens.
            focus: true
            Keys.onEscapePressed: Popups.clipboardOpen = false
            anchors {
                fill:         parent
                topMargin:    root.fh + 8
                leftMargin:   root.fw + 10
                bottomMargin: 8
            }

            opacity: life.content

            HistoryTab { anchors.fill: parent }
        }
    }
}
