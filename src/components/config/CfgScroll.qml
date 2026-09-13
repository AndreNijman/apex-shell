import QtQuick
import QtQuick.Controls
import "../../"

// Scroll container matching the Keybinds page — flick + thin 3px scrollbar.
// Drop a stack of CfgSection children inside; they lay out top-to-bottom.
//
// `lifecycle` is how a page says what touching a control on it does. It is
// PINNED above the flickable rather than dropped in as the first child, because
// a promise about the whole page that scrolls off the top of it is a promise
// the reader sees once (roadmap P0-023, criterion 1).
Item {
    id: root
    default property alias content: col.data

    // ── right-to-left (roadmap P2-004) ────────────────────────────────────────
    // RTL in this shell was recorded for nineteen rounds as "the image cannot
    // render it". Round 20 measured that and it is false: Arabic, Hebrew, Thai
    // and Devanagari all fall out of the hardcoded JetBrains Mono into
    // image-owned fonts that cover them. What was actually missing is LAYOUT —
    // zero `LayoutMirroring` and zero `layoutDirection` in the whole tree — so
    // a reader of those scripts got a row whose label sat on the wrong side of
    // the side they read from.
    //
    // The switch is the application's own direction, which Qt takes from the
    // locale. Measured rather than assumed, because the image installs
    // `glibc-langpack-en` only: `Qt.application.layoutDirection` is
    // RightToLeft under LANG=ar_EG.UTF-8 and he_IL.UTF-8 and LeftToRight with
    // LANG unset, because QLocale parses the locale NAME itself instead of
    // asking the C library for a catalogue it does not have.
    //
    // `childrenInherit`, because the row's own anchors are half of it: the
    // control it holds anchors itself inside the row's right-hand slot.
    //
    // What this does NOT reach is recorded by tests/run-rtl-test.sh rather than
    // implied here — mirroring acts on anchors and positioners and cannot touch
    // an explicit `x:`.
    LayoutMirroring.enabled: Qt.application.layoutDirection === Qt.RightToLeft
    LayoutMirroring.childrenInherit: true
    property int contentSpacing: 2

    // One of settings-semantics.js's STATES. Empty renders nothing, so a page
    // that has not declared one is visibly undeclared rather than quietly
    // claiming to be live.
    property alias lifecycle: banner.lifecycle

    // The page's own backend error, if its writes are failing. Shown in place
    // of the lifecycle blurb — see CfgLifecycle.
    property alias lifecycleError: banner.error

    // Sized rather than anchored: CfgLifecycle binds its own width to its
    // parent's the way every other Cfg component does, and left+right anchors
    // on top of that is two rules for one number.
    CfgLifecycle {
        id: banner
        x:     2
        y:     banner.visible ? 8 : 0
        width: root.width - 14
    }

    Flickable {
        id: flick
        anchors.top:         parent.top
        anchors.topMargin:   banner.visible ? banner.height + 12 : 6
        anchors.left:        parent.left
        anchors.right:       parent.right
        anchors.bottom:      parent.bottom
        anchors.leftMargin:  12
        anchors.rightMargin: 12
        anchors.bottomMargin: 12
        contentWidth:  width
        contentHeight: col.implicitHeight + 16
        clip:          true
        boundsBehavior: Flickable.StopAtBounds

        ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
            contentItem: Rectangle { implicitWidth: 3; implicitHeight: 40; radius: 1.5; color: Qt.rgba(1,1,1,0.22) }
            background: Item {}
        }

        Column {
            id: col
            width:   flick.width - 12
            spacing: root.contentSpacing
        }
    }
}
