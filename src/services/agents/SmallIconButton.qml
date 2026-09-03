import QtQuick
import QtQuick.Controls
import "../../"

// A compact icon button for a session row.
//
// Its own component rather than components/IconBtn.qml because these sit inside
// a row that is itself tappable: the button has to CONSUME the tap, or clicking
// Stop would also focus the terminal. `gesturePolicy: TapHandler.ReleaseWithinBounds`
// on the row is not enough — the handlers are siblings in the same item tree, so
// the inner one has to claim the point.

Rectangle {
    id: btn

    property string icon: ""
    property string tip: ""
    signal activated()

    width: Theme.px(26)
    height: Theme.px(26)
    radius: Theme.px(5)
    color: hover.hovered ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.14)
                         : "transparent"

    Behavior on color { ColorAnimation { duration: 90 } }

    Text {
        anchors.centerIn: parent
        text: btn.icon
        font.pixelSize: Theme.fs(12)
        color: hover.hovered ? Theme.text : Theme.subtext
    }

    HoverHandler { id: hover }

    TapHandler {
        // Claiming the grab is what stops the tap reaching the row underneath.
        gesturePolicy: TapHandler.WithinBounds
        onTapped: function(point) {
            btn.activated()
        }
    }

    ToolTip.visible: hover.hovered && btn.tip !== ""
    ToolTip.text: btn.tip
    ToolTip.delay: 400
}
