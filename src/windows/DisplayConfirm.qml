import QtQuick
import Quickshell
import Quickshell.Wayland
import "../"

// ─── DisplayConfirm ───────────────────────────────────────────────────────────
// The Keep / Put it back question that follows every temporary display apply.
//
// WHY THIS IS A WINDOW AND NOT PART OF THE DISPLAY PAGE
//
// It used to be a section at the top of the Display settings page, and that is
// the bug behind P0-018: the user pressed Apply and no confirmation ever
// appeared, so the layout they wanted was reverted fifteen seconds later.
//
// Three separate reasons, all of them the same mistake — the question was
// parented to a surface the apply itself could take away:
//
//   The Config tab is a popup.  PopupDismiss closes every popup on
//   CompositorService.focusMoved, whose Hyprland source is `workspace`,
//   `activespecial`, `openwindow` and `focusedmon` — and a monitor
//   reconfiguration moves workspaces between outputs, so it can raise two of
//   those. Inferred from the event list rather than watched on hardware; the
//   two below were checked directly.
//
//   The Nexus window scrolls.  Apply is at the bottom of the page and the
//   confirmation was at the top, which is off screen at the moment it appears.
//
//   Both are one-per-output.  shell.qml builds them from Quickshell.screens, so
//   an apply that disables the output the settings window is on destroys the
//   window. Disabling an output really does remove it from Quickshell.screens —
//   checked against a headless wlroots session, not assumed.
//
// So: a layer-shell overlay of its own, built for EVERY output the same way
// ConfirmDialog and UpdatePopup are, driven by a singleton's countdown. One
// instance dying with its output leaves the others up, which is what
// "reachable after the layout changed" has to mean.
//
// The one instance that takes the keyboard is chosen by
// DisplayService.confirmScreen — an output this apply is not turning off.
// ──────────────────────────────────────────────────────────────────────────────

PanelWindow {
    id: root

    required property string screenName

    // ── This output's sizes (P1-040) ─────────────────────────────────────────
    // Not Theme's. Theme carries ONE factor for the whole shell — the reference
    // output's — so on a desk whose monitors have different densities it is
    // wrong for at least one of them. This modal is built per output (shell.qml
    // creates one from Quickshell.screens), it is anchored to nothing but its
    // own screen, and nothing outside it reads its size, so it can answer for
    // itself instead.
    //
    // `root.screen` is exact from construction — measured on quickshell 0.3.1
    // with two headless outputs of different densities, each PanelWindow's
    // screen.height is that output's height at t=0, before the surface is
    // mapped. No transient, so no first-frame resize.
    //
    // Colours stay on Theme deliberately: a palette belongs to the shell, not
    // to an output. Sizes come from `theme`, colours from `Theme`, and the
    // split is visible at every call site below.
    // The set is SHARED, not built here. theme/OutputScale keeps one ThemeSet
    // per factor the breakpoint table can answer — five objects for the whole
    // shell — because a token set is a pure function of its factor and a
    // hundred migrated files each constructing their own would build a hundred
    // copies of the same forty bindings onto SettingsService.
    readonly property ThemeSet theme: Theme.setForScreen(root.screen)

    // Whether this copy is the one that answers the keyboard. Every copy is
    // visible; only one may hold focus, or the two would fight over it and
    // Enter would reach neither.
    readonly property bool owner: DisplayService.confirmScreen === root.screenName
                                  || DisplayService.confirmScreen === ""

    color: "transparent"
    visible: DisplayService.pending

    anchors { top: true; left: true; right: true; bottom: true }
    exclusionMode: ExclusionMode.Ignore

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.visible && root.owner
                                     ? WlrKeyboardFocus.Exclusive
                                     : WlrKeyboardFocus.None

    // A flat scrim, not a themed one. The palette is generated from the
    // wallpaper, so a themed scrim over the wallpaper it came from stops
    // reading as modal — the same reason ConfirmDialog hardcodes its own.
    Rectangle {
        anchors.fill: parent
        color: "#99000000"
        // Swallows clicks without dismissing. There is no "click away" answer
        // to this question: doing nothing is already an answer, and it is the
        // one that undoes your change.
        MouseArea { anchors.fill: parent }
    }

    Rectangle {
        id: card

        // Named so the scaling suite can assert the size this output actually
        // laid out at, rather than re-deriving it from the same factor the card
        // used — a test that recomputes its subject asserts nothing. The suite
        // also asserts that exactly one card is found per output, so removing
        // this name fails the run instead of quietly emptying it.
        objectName: "apex-display-confirm-card"

        anchors.centerIn: parent
        width:  theme.px(400)
        height: col.implicitHeight + theme.px(48)
        radius: theme.notchRadius
        color:  Theme.background
        border.color: Qt.rgba(1, 1, 1, 0.08)
        border.width: 1

        MouseArea { anchors.fill: parent }

        Column {
            id: col
            anchors {
                top:         parent.top
                left:        parent.left
                right:       parent.right
                topMargin:   theme.px(24)
                leftMargin:  theme.px(24)
                rightMargin: theme.px(24)
            }
            spacing: theme.px(14)

            Text {
                text: "󰍹"
                anchors.horizontalCenter: parent.horizontalCenter
                color: Theme.text
                font.pixelSize: theme.fs(28)
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Keep this display layout?"
                color: Theme.text
                font.pixelSize: theme.fs(15)
                font.bold: true
            }

            // The inaction sentence. A user who cannot read the screen has to
            // know that waiting is safe, and a user who CAN read it has to know
            // that waiting is not "accept". Both need it stated, not implied.
            Text {
                width: parent.width
                text: "If you do nothing, the previous layout comes back in "
                      + DisplayService.confirmSeconds
                      + (DisplayService.confirmSeconds === 1 ? " second." : " seconds.")
                color: Theme.subtext
                font.pixelSize: theme.fs(12)
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                lineHeight: 1.35
            }

            // Time left, drawn rather than only counted. The number above is
            // the promise; this is the same promise at a glance, for someone
            // reading a screen that has just changed size under them.
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width:  parent.width
                height: theme.px(4)
                radius: height / 2
                color:  Qt.rgba(1, 1, 1, 0.08)

                Rectangle {
                    height: parent.height
                    radius: parent.radius
                    color:  Theme.danger
                    width: parent.width * (DisplayService.confirmTotal > 0
                        ? Math.max(0, Math.min(1, DisplayService.confirmSeconds
                                                  / DisplayService.confirmTotal))
                        : 0)
                    Behavior on width { NumberAnimation { duration: 240; easing.type: Easing.Linear } }
                }
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: theme.px(10)

                Rectangle {
                    width:  theme.px(160)
                    height: theme.px(38)
                    radius: theme.cornerRadius
                    color:  revertHov.hovered ? Theme.dangerFillHover : Theme.dangerFill

                    Behavior on color { ColorAnimation { duration: 120 } }

                    Text {
                        anchors.centerIn: parent
                        text: "Put it back now"
                        color: Theme.fixedLight
                        font.pixelSize: theme.fs(13)
                    }

                    HoverHandler { id: revertHov; cursorShape: Qt.PointingHandCursor }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: DisplayService.revertApplied()
                    }
                }

                Rectangle {
                    width:  theme.px(160)
                    height: theme.px(38)
                    radius: theme.cornerRadius
                    color:  keepHov.hovered ? Qt.rgba(1, 1, 1, 0.16) : Qt.rgba(1, 1, 1, 0.09)

                    Behavior on color { ColorAnimation { duration: 120 } }

                    Text {
                        anchors.centerIn: parent
                        text: "Keep it"
                        color: Theme.text
                        font.pixelSize: theme.fs(13)
                        font.bold: true
                    }

                    HoverHandler { id: keepHov; cursorShape: Qt.PointingHandCursor }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: DisplayService.confirm()
                    }
                }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Enter keeps it. Escape puts it back."
                color: Qt.rgba(1, 1, 1, 0.3)
                font.pixelSize: theme.fs(11)
            }
        }
    }

    // Keys reach the owning copy only. A pointer that ended up on a monitor the
    // user cannot see is exactly the situation this window exists for, so the
    // keyboard has to work without one.
    Item {
        anchors.fill: parent
        focus: root.visible && root.owner
        Keys.onReturnPressed: DisplayService.confirm()
        Keys.onEnterPressed:  DisplayService.confirm()
        Keys.onEscapePressed: DisplayService.revertApplied()
    }

    // A line per mapped copy, so the nested suite can assert WHICH outputs the
    // question actually reached. There is no other way to see that from
    // outside the shell, and "the countdown is running" is not the same claim
    // as "the user can answer it".
    onVisibleChanged: console.log("apex-display-confirm: "
                                  + (root.visible ? "shown on " : "hidden on ")
                                  + root.screenName)
}
