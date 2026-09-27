import QtQuick
import "../../"
import "../"

// A titled group of rows. Matches the Keybinds tab's group headers — bare rows,
// no card, so every Config tab reads as one consistent surface.
Column {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes

    property string title: ""
    property bool   first: false
    default property alias content: inner.data

    // ── What a screen reader gets from a settings page, and why it is here ───
    //
    // Measured 2026-09-19 over real AT-SPI, with the shell running on a nested
    // headless labwc and Qt's accessibility factory restored by the round-30
    // shim: the Nexus window published its controls as a FLAT list at one
    // depth, mixing several pages' controls together — Colour's `Rescan` and
    // `tonal-spot` sitting beside Recovery's `Re-check` and `Open`. Nothing in
    // the tree said which page was on screen, and nothing grouped a row with
    // the heading it belongs under.
    //
    // That is not Qt flattening anything. QAccessibleQuickItem::childItems()
    // skips items that are not accessible, so every marked leaf becomes a
    // direct child of the frame — the sections and the scroll views in between
    // simply were not there. Marking the section IS the structure.
    //
    // Grouping rather than a Heading on the title Text: a heading would leave
    // the tree flat and interleave labels, where a group makes "these rows
    // belong to Factory reset" a fact a reader can navigate and a test can
    // assert. The title is the group's name, so the words are not duplicated.
    //
    // No focus change: this adds no activeFocusOnTab and no key handling, so
    // the tab order is exactly what it was.
    Accessible.role: Accessible.Grouping
    Accessible.name: root.title

    width:   parent ? parent.width : 0
    spacing: 2

    // The shared section label (UI/UX Phase 17): it was 9 px bold accent at
    // .55 in Title case — 2.37:1 on the light sheet.
    Item {
        width:  parent.width
        height: root.first ? 18 : 30
        SectionLabel {
            anchors.bottom:       parent.bottom
            anchors.bottomMargin: 6
            width:                parent.width
            text:                 root.title
        }
    }

    Column {
        id: inner
        width:   parent.width
        spacing: 2
    }
}
