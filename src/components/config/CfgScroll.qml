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
