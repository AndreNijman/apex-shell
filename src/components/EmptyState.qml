import QtQuick
import "../"

// ─────────────────────────────────────────────────────────────────────────────
// EmptyState — what a surface says when it has nothing to show (UI/UX roadmap
// v3 Phase 17; visual roadmap §28, "define these once").
//
// There were six treatments: the Agents panel's centred 42 px glyph, title and
// hint; Appearance's one tertiary line; VPN's 36 px glyph, two lines and a
// bordered code chip; a CfgRow's label and description on Display and the
// pairing pages; and, on Recovery, a heading over nothing. This is the one
// version:
//
//     EmptyState {
//         glyph: "󰚩"; title: "No agent sessions"
//         hint: "Start one with a terminal command:"
//         command: "apex agent run"
//     }
//
// centred in the free area of a surface, or with `inline: true` left-aligned
// on a settings page's content edge, without the glyph (a page is already
// labelled by its section; a big glyph in a list of rows reads as an error).
// Children go under the text: an optional button.
//
// The glyph is decoration: outlineStrong, the Phase 18a colour for a glyph
// that stands for nothing interactive, and no accessible role. The title and
// hint name themselves, and the command is text a reader can copy.
// ─────────────────────────────────────────────────────────────────────────────
Column {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }

    property string glyph:   ""
    property string title:   ""
    property string hint:    ""
    property string command: ""
    property bool   inline:  false
    default property alias actions: actionRow.data

    readonly property int _align: root.inline ? Text.AlignLeft : Text.AlignHCenter

    spacing: theme.spaceS

    Text {
        visible: root.glyph !== "" && !root.inline
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.glyph
        font.pixelSize: theme.fs(28)
        color: Theme.outlineStrong
        bottomPadding: theme.spaceXS
    }
    Text {
        width: parent.width
        visible: text !== ""
        text: root.title
        horizontalAlignment: root._align
        wrapMode: Text.WordWrap
        font.family: Theme.fontUi
        font.pixelSize: theme.typeBody
        font.weight: Font.Medium
        color: Theme.textPrimary
        Accessible.role: Accessible.StaticText
        Accessible.name: text
    }
    Text {
        width: parent.width
        visible: text !== ""
        text: root.hint
        horizontalAlignment: root._align
        wrapMode: Text.WordWrap
        font.family: Theme.fontUi
        font.pixelSize: theme.typeCaption
        color: Theme.textSecondary
        lineHeight: 1.2
        Accessible.role: Accessible.StaticText
        Accessible.name: text
    }
    Rectangle {
        visible: root.command !== ""
        anchors.horizontalCenter: root.inline ? undefined : parent.horizontalCenter
        width: Math.min(parent.width, cmdText.implicitWidth + theme.spaceL)
        height: cmdText.implicitHeight + theme.spaceS
        radius: theme.radiusXS
        color: Theme.surfaceHigh
        Text {
            id: cmdText
            anchors.centerIn: parent
            width: Math.min(implicitWidth, parent.width - theme.spaceL)
            elide: Text.ElideRight
            text: root.command
            font.family: Theme.fontMono
            font.pixelSize: theme.typeMono
            color: Theme.textPrimary
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }
    }
    Row {
        id: actionRow
        visible: children.length > 0
        anchors.horizontalCenter: root.inline ? undefined : parent.horizontalCenter
        topPadding: theme.spaceXS
        spacing: theme.spaceS
    }
}
