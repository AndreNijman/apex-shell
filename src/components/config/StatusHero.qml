import QtQuick
import "../../"

// ─────────────────────────────────────────────────────────────────────────────
// StatusHero — the one-line answer at the top of a status page (UI/UX roadmap
// v3 Phase 17; visual roadmap §28, "define these once").
//
// Firewall, Privacy and Closing the Lid each hand-rolled this: a glyph in the
// state's colour, a sentence that answers the page's question, a technical
// line saying what was actually read, and a Re-check. Three copies meant three
// geometries — Firewall's in a tinted bordered box whose mono line ran to 0–4 px
// of its button, the other two 10 px inside the content edge with the line
// unbounded. This is the one version: no box (the state is the glyph's colour
// and the words; a box would be a third channel), on the content edge, the
// detail bounded by whatever sits at the trailing end so it wraps or elides
// instead of running under it.
//
//     StatusHero {
//         glyph: "󰕥"; tone: Theme.active
//         title: "Incoming connections are blocked"
//         detail: "apex-firewall.service: active"
//         CfgButton { label: "Re-check"; onClicked: … }   // trailing actions
//     }
//
// The glyph is decoration and carries no accessible role (the recovery page's
// rule, tests/check-recovery-a11y.sh: a private-use codepoint read aloud is
// "private use character"). The title names itself explicitly rather than
// leaning on Qt's fallback from `text`.
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }

    property string glyph:  ""
    property color  tone:   Theme.textSecondary
    property string title:  ""
    property string detail: ""
    property color  detailColor: Theme.textSecondary
    // Wrap (a sentence that must be read whole — Lid's reason) or elide (a
    // status line with a command in it — Firewall's).
    property bool   detailWraps: false
    property alias  titleItem:  titleText
    property alias  detailItem: detailText
    default property alias actions: actionRow.data

    width:  parent ? parent.width : implicitWidth
    implicitHeight: Math.max(theme.px(62), textCol.implicitHeight + theme.spaceL)

    Text {
        id: glyphText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        visible: root.glyph !== ""
        text: root.glyph
        font.pixelSize: theme.fs(28)
        color: root.tone
        Behavior on color { MotionColor { role: "state" } }
    }

    Column {
        id: textCol
        anchors.left: glyphText.visible ? glyphText.right : parent.left
        anchors.leftMargin: glyphText.visible ? theme.spaceM : 0
        anchors.right: actionRow.left
        anchors.rightMargin: actionRow.width > 0 ? theme.spaceL : 0
        anchors.verticalCenter: parent.verticalCenter
        spacing: theme.px(3)

        Text {
            id: titleText
            width: parent.width
            text: root.title
            font.family: Theme.fontUi
            font.pixelSize: theme.typeHeading
            font.weight: Font.DemiBold
            color: Theme.textPrimary
            wrapMode: Text.WordWrap
            Accessible.role: Accessible.StaticText
            Accessible.name: titleText.text
        }
        Text {
            id: detailText
            width: parent.width
            visible: text !== ""
            text: root.detail
            font.family: Theme.fontMono
            font.pixelSize: theme.typeCaption
            color: root.detailColor
            wrapMode: root.detailWraps ? Text.WordWrap : Text.NoWrap
            elide: root.detailWraps ? Text.ElideNone : Text.ElideRight
        }
    }

    Row {
        id: actionRow
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: theme.spaceS
    }
}
