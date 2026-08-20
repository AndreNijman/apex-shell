import QtQuick

// ─────────────────────────────────────────────────────────────────────────────
// LazyPage — a page that is not built until it is first looked at.
//
// The dashboard used to instantiate every page eagerly, per screen: the home
// cards, the full stats grid, the Kanban board, the launcher, and the whole
// config tree with all of its sub-pages, all constructed at shell startup
// whether or not the dashboard was ever opened. On a two-monitor machine that
// was two of everything.
//
// ── Why it keeps the instance once built ────────────────────────────────────
// `active` latches on first reveal and never goes back to false. Unloading on
// hide would also be valid and would return the memory, but it throws away page
// state that users notice: Kanban scroll offset, which config sub-page you were
// on, a half-typed card title. The expensive part of a page is not its existence
// but its *pollers*, and those are handled properly by ServiceRef gating on
// actual on-screen state — so a built-but-hidden page costs essentially nothing.
//
// Pair the two: LazyPage for construction cost, ServiceRef for running cost.
// ─────────────────────────────────────────────────────────────────────────────

Loader {
    id: root

    // Whether this page is the selected one right now.
    required property bool shown

    property bool _everShown: false

    active: root._everShown
    visible: root.shown

    onShownChanged: if (root.shown)
        root._everShown = true

    Component.onCompleted: if (root.shown)
        root._everShown = true
}
