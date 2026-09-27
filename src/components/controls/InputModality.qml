pragma Singleton
import QtQuick

// ─────────────────────────────────────────────────────────────────────────────
// InputModality — was the keyboard the last thing the user used? The rule a
// browser calls :focus-visible, for every focus ring in the shell.
//
// A ring shows only for an item with active focus AND `keyboard` true. Focus
// alone was not enough: a surface that sets focus itself as it opens (a list,
// a tab bar, the settings column) lit its ring for a user who had only moved
// the mouse (Andre, 2026-09-27: "why is the keyboard navigation showing before
// i try keyboard navigating … annoying if the selection circle shows when
// using mouse navigation").
//
//   key(event)   called from key handlers on the way through (they do not
//                accept for it): a navigation key makes it true
//   pointer()    a press with the pointer makes it false
//   surfaceOpened()  a surface opening makes it false: whatever focus it sets
//                on the way in is the surface's doing, not the user's; their
//                first Tab or arrow brings the ring back
// ─────────────────────────────────────────────────────────────────────────────
QtObject {
    property bool keyboard: false

    function key(event) {
        switch (event.key) {
        case Qt.Key_Tab: case Qt.Key_Backtab:
        case Qt.Key_Up: case Qt.Key_Down: case Qt.Key_Left: case Qt.Key_Right:
        case Qt.Key_Home: case Qt.Key_End: case Qt.Key_PageUp: case Qt.Key_PageDown:
        case Qt.Key_Space: case Qt.Key_Return: case Qt.Key_Enter:
            keyboard = true
        }
    }
    function pointer() { keyboard = false }
    function surfaceOpened() { keyboard = false }
}
