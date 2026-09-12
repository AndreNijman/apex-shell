import QtQuick
import "../../"
import "settings-semantics.js" as Semantics

// The one line at the top of a settings page that says what touching a control
// on it will do (roadmap P0-023, criteria 1 and 4).
//
// ── Why every page carries one ──────────────────────────────────────────────
//
// Before this, a user could not tell the three kinds of settings page apart by
// looking at them. Appearance wrote as you dragged; Display held the change
// until you pressed Apply; Blueprint held it until you pressed Save and then
// still did nothing to the machine until you pressed Apply. All three drew the
// same rows with the same sliders, and none of them said which they were.
//
// So the page declares it, once, and the words come from settings-semantics.js
// rather than from whoever wrote the page.
//
// ── And why the error lives here ────────────────────────────────────────────
//
// The live pages had nowhere to put a failure. SettingsService debounces a
// write 350ms after the slider stops and never reads the exit code, so a home
// directory that could not be written to looked exactly like one that could
// until the next login threw the changes away. A page-level line is the right
// place for that: the failure is not about one row, it is about whether this
// page's writes are landing at all.
Item {
    id: root
    readonly property ThemeSet theme: Theme.setForHeight(Screen.height)   // P1-040: this output's sizes


    // One of settings-semantics.js's STATES: "live", "staged", "applied",
    // "saved". An unrecognised value renders nothing rather than guessing,
    // because a wrong promise is worse than an absent one.
    property string lifecycle: ""

    // Non-empty when the page's own backend refused a write. Replaces the
    // blurb, in the danger tone, because a page whose writes are failing is not
    // doing what the blurb says it does.
    property string error: ""

    readonly property string _blurb: Semantics.stateBlurb(root.lifecycle)
    readonly property bool _shown: root._blurb !== "" || root.error !== ""

    width: parent ? parent.width : 0
    visible: root._shown
    implicitHeight: root._shown ? Math.max(theme.px(30), text.implicitHeight + theme.px(14)) : 0
    height: implicitHeight

    readonly property color _tone: root.error !== "" ? Theme.danger : Theme.active

    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: 10
        anchors.rightMargin: 2
        radius: 8
        color: Qt.rgba(root._tone.r, root._tone.g, root._tone.b, 0.06)
        border.color: Qt.rgba(root._tone.r, root._tone.g, root._tone.b, 0.18)
        border.width: 1
        Behavior on color { ColorAnimation { duration: 140 } }
        Behavior on border.color { ColorAnimation { duration: 140 } }

        Row {
            anchors {
                left: parent.left
                right: parent.right
                verticalCenter: parent.verticalCenter
                leftMargin: 10
                rightMargin: 10
            }
            spacing: 8

            // The state's own name, so the reader learns the word and can carry
            // it to the next page.
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: chip.implicitWidth + theme.px(12)
                height: theme.px(17)
                radius: 5
                visible: root.error === "" && root.lifecycle !== ""
                color: Qt.rgba(root._tone.r, root._tone.g, root._tone.b, 0.14)
                Text {
                    id: chip
                    anchors.centerIn: parent
                    text: Semantics.stateLabel(root.lifecycle)
                    font.pixelSize: theme.fs(9)
                    font.weight: Font.Bold
                    color: root._tone
                }
            }

            Text {
                id: text
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - (root.error === "" && root.lifecycle !== ""
                                       ? chip.implicitWidth + theme.px(20) : 0)
                text: root.error !== "" ? root.error : root._blurb
                font.pixelSize: theme.fs(10)
                color: root.error !== "" ? Theme.danger : Theme.subtext
                wrapMode: Text.WordWrap
            }
        }
    }
}
