import Quickshell

// ─────────────────────────────────────────────────────────────────────────────
// LazyPopup — a popup window that is not built until it is first opened.
//
// shell.qml instantiates the whole popup fleet per screen, eagerly: the arch
// menu, wallpaper picker, clipboard history, audio panel, quick controls,
// notification centre, toast, screen-recorder strip and the network panel with
// its Wi-Fi/Bluetooth/VPN/hotspot tabs. On a two-monitor machine that is two of
// each, all constructed during login, for windows that are usually never opened
// in a session.
//
// ── Why it latches instead of unloading on close ────────────────────────────
// `active` goes true on first demand and stays true. Unloading on close would
// return the memory, but every popup here animates out: the window stays mapped
// for the duration of a slide/fade after its open flag goes false, and
// destroying the content underneath that animation makes the popup vanish
// instantly instead of closing. Tracking each popup's animation tail from out
// here would mean duplicating state that already lives inside it.
//
// So this buys startup cost and the memory of never-opened popups, which is the
// actual complaint. Recurring cost while a popup is built-but-closed is handled
// separately, by refcounting the services it consumes (see ServiceRef.qml).
// ─────────────────────────────────────────────────────────────────────────────

LazyLoader {
    id: root

    // Bind to the popup's own open flag, e.g. `Popups.networkOpen`.
    required property bool wanted

    // Latch. Starts as a binding on `wanted`, so a popup that is already open at
    // construction loads immediately; the first time `wanted` goes true the
    // imperative assignment breaks that binding and it can never fall back to
    // false.
    //
    // (This is deliberately not `Component.onCompleted` — LazyLoader's own
    // default property is called `component`, which shadows the attached
    // Component type and makes `Component.onCompleted` unresolvable here.)
    property bool _everWanted: root.wanted

    active: root._everWanted

    onWantedChanged: if (root.wanted)
        root._everWanted = true
}
