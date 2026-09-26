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
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


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
    implicitHeight: !root._shown ? 0
                  : root.error !== "" ? errText.implicitHeight + theme.px(14)
                  : Math.max(chip.height, text.implicitHeight) + theme.px(4)
    height: implicitHeight

    // ── The promise: a chip and one line, no box (UI/UX Phase 17) ────────────
    // It was a bordered box on every page, 50 px tall, repeating one sentence
    // above the first section — the heaviest thing on pages with nothing to
    // change. P0-023 pins the promise where the reader sees it; it does not ask
    // for a box. The state's name is a chip in the accent container, the
    // vocabulary's sentence beside it in the caption role, on the page's
    // content edge.
    Rectangle {
        id: chip
        visible: root.error === "" && root.lifecycle !== ""
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.topMargin: theme.px(1)
        width: chipText.implicitWidth + theme.px(12)
        height: theme.px(18)
        radius: theme.radiusXS
        color: Theme.accentContainer
        Text {
            id: chipText
            anchors.centerIn: parent
            text: Semantics.stateLabel(root.lifecycle)
            font.pixelSize: theme.typeCaption
            font.weight: Font.DemiBold
            color: Theme.textOnAccentContainer
        }
    }
    Text {
        id: text
        visible: root.error === ""
        anchors.left: chip.right
        anchors.leftMargin: theme.px(8)
        anchors.right: parent.right
        anchors.verticalCenter: chip.verticalCenter
        text: root.error === "" ? root._blurb : ""   // never beside the failure it no longer keeps
        font.pixelSize: theme.typeCaption
        color: Theme.textSecondary
        wrapMode: Text.WordWrap
    }

    // ── A failed write keeps a box: it is the one thing here that is wrong ───
    Rectangle {
        visible: root.error !== ""
        anchors.fill: parent
        radius: theme.radiusS
        color: Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.06)
        border.color: Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.18)
        border.width: 1
        Text {
            id: errText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: theme.px(10)
            anchors.rightMargin: theme.px(10)
            text: root.error
            font.pixelSize: theme.typeCaption
            color: Theme.danger
            wrapMode: Text.WordWrap
        }
    }
}
