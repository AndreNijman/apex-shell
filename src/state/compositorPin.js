// ─── compositorPin.js ────────────────────────────────────────────────────────
// The one decision behind Settings → Misc → Compositor: when a pin in
// config_Provider.json is allowed to beat what the environment says.
//
// It lives here rather than inline in Compositor.qml for the reason title.js
// does — so tests/compositor-pin-test.js drives the file the shell actually
// loads instead of a copy of it.
//
// ── The bug this exists to prevent ───────────────────────────────────────────
//
// A pin used to win unconditionally. It does not switch the compositor — it
// only tells the shell which ADAPTER to load — so a pin naming a compositor
// that is not running points every compositor call at nothing. Andre clicked
// "Scrolling" there on 2026-09-29 (15:41) while on Hyprland; the bar kept its
// ✦ and the background-apps toggle and lost everything else: no workspace dots
// (the niri adapter streams nothing without a niri socket), no layout button,
// SUPER+TAB silent (the overview asked niri for its own), and the About row
// said "niri 26.04" on a Hyprland desktop. The same pin survived the reboot.
//
// "Scrolling" was an easy click to make for the wrong reason: the bar's layout
// menu offers a Hyprland layout called Scrolling too.
//
// ── The rule ─────────────────────────────────────────────────────────────────
//
// A pin chooses among compositors that are actually here. It wins when the
// environment carries that compositor's own signal (a nested niri inside
// Hyprland carries both, and there the pin is the only way to say which one
// the shell belongs to), and when nothing was detected at all (a shell
// started from a unit that inherited no session environment). Otherwise the
// environment wins and the pin is reported as ignored, never silently obeyed
// and never silently deleted: the file is the user's, and the next login on
// the pinned compositor honours it again.

// `detected` is Compositor.detected ("" when unknown). `pin` is a VALID id or
// "" — the caller has already applied isValidName(). `present` maps each id to
// whether the environment carries that compositor's own signal.
function resolve(detected, pin, present) {
    const pinned = pin !== "" && pin !== undefined && pin !== null
    const ignored = pinned && detected !== "" && !(present && present[pin] === true)
    return {
        name:    pinned && !ignored ? pin : detected,
        ignored: ignored
    }
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = { resolve: resolve };
}
