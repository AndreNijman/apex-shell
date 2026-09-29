.pragma library

// ─── The tiling layouts, in words ───────────────────────────────────────────
// What the bar's layout button and its menu call each Hyprland layout.
//
// The button used to show `><`, `M`, `|3|` and `<3>` and cycle blindly on a
// click (Andre, 2026-09-29: "its so hard to understand what each option does,
// it has to be intuitive"). Every description below was measured in a nested
// Hyprland 0.56.2 with three and four windows, not taken from the wiki:
//
//   dwindle    the first window takes the left half, each next one halves the
//              window that has focus.
//   master     one window takes about 55 % on the left, the rest stack on the
//              right.
//   monocle    every window gets the whole work area, on top of each other.
//              SUPER+arrow moves NOTHING here (focus stays put), so without the
//              hint a person who picks it seems to lose every other window.
//              Alt+Tab (the shell's switcher, which focuses by address) and
//              `layoutmsg cyclenext` both reach them.
//   scrolling  half-width columns in a row wider than the screen; SUPER+arrow
//              moves along it and the view scrolls with focus.
//
// The shortcuts named are rime-os keybindings.lua's defaults.
// ────────────────────────────────────────────────────────────────────────────

var INFO = {
    dwindle:   { name: "Split",
                 detail: "Each new window halves the one you're in" },
    master:    { name: "Main + stack",
                 detail: "One large window, the rest stacked beside it" },
    monocle:   { name: "One at a time",
                 detail: "Each window fills the screen. Alt+Tab switches between them" },
    scrolling: { name: "Scrolling",
                 detail: "A row of windows wider than the screen. Super+←/→ scrolls it" }
}

function _info(id) { return INFO[String(id || "").toLowerCase()] || null }

// A layout Hyprland reports that this file has no words for is shown by its
// own name rather than as "Unknown".
function name(id)   { const i = _info(id); return i ? i.name : String(id || "") }
function detail(id) { const i = _info(id); return i ? i.detail : "" }
