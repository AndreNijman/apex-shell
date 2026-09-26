import QtQuick
import "../"
import "controls"

// ─────────────────────────────────────────────────────────────────────────────
// IconBtn — a glyph button in the bar.
//
// ApexIconButton in bar mode (UI/UX roadmap v3 Phase 15; brief §D.3, §D.6):
// a 15 px glyph in its icon font, in a 20 px box with a 24 px target, and no
// fill at all — hover turns the glyph to the primary text colour, a press to
// the accent, and the press dips it to .96. It used to fill the whole box with
// the accent on hover, which in a bar of eight of these was the loudest thing
// on screen for the least important state.
//
// `textColor` is the glyph's colour at rest: the passive icon colour unless
// the caller has a state to show (a panel it opened, the brand mark).
// ─────────────────────────────────────────────────────────────────────────────
ApexIconButton {
    id: root

    property string text: ""
    property color  textColor: Theme.iconDefault
    signal clicked()

    bar: true
    glyph: root.text
    glyphColor: root.pressed ? Theme.accentText
              : root.hovered ? Theme.textPrimary
              : root.textColor
    onActivated: root.clicked()
}
