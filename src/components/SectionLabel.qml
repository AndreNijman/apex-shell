import QtQuick
import "../"

// ─────────────────────────────────────────────────────────────────────────────
// SectionLabel — the one section heading (UI/UX roadmap v3 Phase 17; visual
// roadmap §14: "page title and section heading must not be interchangeable").
//
// There were six: the settings pages' 9 px bold accent at .55 in Title case
// (2.37:1 on the light sheet — under even the 3:1 floor), the Agents list's
// 9 px uppercase subtext, the network panes' 9 px uppercase in accent or
// tertiary (two colours in one pane), the Home card's 9 px bold, the System
// cards' 11 px centred and the Kanban headers' 12 px accent. This is the
// type ladder's section role — 11 px, 600, uppercase, +0.6 tracking — in the
// palette's secondary text, which roles.js holds at 4.5:1 or better on every
// shipped palette (6.19:1 on that same light sheet).
// ─────────────────────────────────────────────────────────────────────────────
Text {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }

    font.family:         Theme.fontUi
    font.pixelSize:      theme.typeSection
    font.weight:         Font.DemiBold
    font.capitalization: Font.AllUppercase
    font.letterSpacing:  0.6
    color:               Theme.textSecondary
    elide:               Text.ElideRight
    Accessible.role:     Accessible.Heading
    Accessible.name:     root.text
}
