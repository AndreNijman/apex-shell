import QtQuick
import QtQuick.Controls
import "../../"
import "../../components/controls"

// The permanent way into the guide (roadmap §43), in the Agents panel's
// header: a help button, one click from anywhere on the page.
//
// It was a full-width bordered row above everything, on every visit — the
// first thing the eye landed on, long after the reader had learned what it
// said. Andre: it should not always be displayed, but it should be easy to get
// back to. So it keeps its place and its reach (always there, Tab + Return, the
// guide's keyboard close hands the keys back here) and gives up the row: a
// glyph with the full sentence as its tooltip and its accessible name. The
// first-run card below it is still what introduces the guide to a newcomer.
ApexIconButton {
    id: entry

    glyph: "󰋗"
    label: AgentHelpContent.entryLabel
    glyphColor: entry.hovered ? Theme.textPrimary : Theme.accentText
    onActivated: AgentHelp.open("start")

    ToolTip.visible: entry.hovered
    ToolTip.text: AgentHelpContent.entryLabel
    ToolTip.delay: 400

    Component.onCompleted: console.info("AgentHelp: entry row shown")
}
