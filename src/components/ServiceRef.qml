import QtQuick

// ─────────────────────────────────────────────────────────────────────────────
// ServiceRef — declarative demand marker for a refcounted service.
//
// A service that costs something to run (a poll timer, a subprocess, a FileView
// reload loop) exposes `property int refCount: 0` and gates its timer on
// `refCount > 0`. Anything needing live data from that service declares a
// ServiceRef. The service runs while at least one ref is held and stops
// completely when the last one is handed back.
//
// ── Why a component and not `service.subscribers++` at the call site ────────
// A hand-rolled counter drifts. It misses the initial value, double-counts when
// an item is reparented or re-created, and never decrements when the consumer is
// destroyed. A drifted counter fails SILENTLY in both directions — a service
// that never starts (dead UI) or one that never stops (the fork storm this
// replaces) — so the failure only ever shows up as a battery complaint weeks
// later. `_heldService` makes the accounting idempotent: an instance contributes
// exactly 0 or 1 to exactly one service at all times, in whatever order the
// bindings happen to settle.
//
// ── Usage ───────────────────────────────────────────────────────────────────
//   ServiceRef { service: CpuService; active: root.onScreen }
//
// Bind `active` to "is my consumer genuinely on screen right now" — window
// visibility AND page selection AND not locked. Item `visible` alone is NOT
// enough: an Item inside a hidden window still reports visible, which is exactly
// how the stats page kept six pollers running after the dashboard was closed.
// ─────────────────────────────────────────────────────────────────────────────

QtObject {
    id: root

    // The service to hold a reference on. Must expose `int refCount`.
    required property var service

    // Whether this consumer currently wants the service running.
    property bool active: true

    // The service this instance is currently counted against, or null. Single
    // source of truth for the accounting — never derive it from `active`.
    property var _heldService: null

    function _sync() {
        const want = root.active ? root.service : null

        if (root._heldService === want)
            return

        if (root._heldService)
            root._heldService.refCount--

        root._heldService = want

        if (want)
            want.refCount++
    }

    onActiveChanged: _sync()

    // Service swapped under us: hand the old one back before adopting the new
    // one, or it keeps a reference for the lifetime of the shell.
    onServiceChanged: _sync()

    Component.onCompleted: _sync()

    Component.onDestruction: {
        if (root._heldService) {
            root._heldService.refCount--
            root._heldService = null
        }
    }
}
