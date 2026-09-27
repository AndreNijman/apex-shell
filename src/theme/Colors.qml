pragma Singleton
import QtQuick
import "."
import "roles.js" as Roles

QtObject {
    id: root

    // ── Color loader — watches matugen output and updates live ────────────────
    // Use a unique ID to avoid namespace collision with the 'Colors' singleton
    property var _loader: ColorLoader { id: internalLoader }

    // ── Colors — bound to loader, update automatically when matugen runs ──────
    property color background: internalLoader.background
    property color active:     internalLoader.active
    property color text:       internalLoader.text
    property color subtext:    internalLoader.subtext
    property color icon:       internalLoader.icon
    property color border:     internalLoader.border
    property color iconFont:   internalLoader.iconFont

    // ── Is the surface we are painting on dark? ───────────────────────────────
    // The one thing a status colour has to know about the palette. Relative
    // luminance per WCAG 2.1, threshold 0.18 — the luminance of a mid grey, so
    // the answer flips where a reader's eye does.
    //
    // Gamma has to be undone first: a colour's .r/.g/.b are sRGB components, and
    // averaging those directly calls #808080 "light" and #767676 "dark" when
    // both are mid grey. That error is invisible on the extremes and wrong
    // exactly where the threshold lives.
    function channelLuminance(v) {
        return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
    }
    function luminance(c) {
        return 0.2126 * channelLuminance(c.r)
             + 0.7152 * channelLuminance(c.g)
             + 0.0722 * channelLuminance(c.b)
    }
    readonly property bool darkSurface: luminance(root.background) < 0.18

    // ── Status ────────────────────────────────────────────────────────────────
    // Fixed hues, chosen per surface lightness. NOT loaded from the palette,
    // and that is the whole point.
    //
    // matugen gives us `error`, so `danger` COULD follow the wallpaper. The
    // others have no Material You role at all — there is no guaranteed-amber or
    // guaranteed-green in an M3 scheme — so sourcing one and fixing the rest
    // would make the status family internally incoherent: a red that moves with
    // the wallpaper next to a green that does not.
    //
    // A status colour also has a job that outranks harmony. "Disk 94% full" and
    // "battery at 4%" have to read as alarming on every wallpaper, including a
    // red one, where a harmonised error colour is at its least legible.
    //
    // WHY THERE ARE TWO OF EACH. Hue is fixed; lightness is not. A #a6e3a1 green
    // is a 11.8:1 read on a dark surface and a 1.3:1 read on a light one, which
    // is not a green a person can see — it is a pale smear. matugen emits a
    // light scheme on request (`-m light`, `surface` #faf9fb), so the pair is
    // the difference between a status family that works on both and one that
    // only ever got looked at on the maintainer's own wallpaper.
    //
    // ── LIGHT MODE ───────────────────────────────────────────────────────────
    //
    // The light values below are measured, not guessed: tests/agent-state-test.js
    // checks all twelve palettes — six shipped wallpapers, both matugen modes —
    // and tests/run-agent-state-render-test.sh drives both through the real
    // Theme in a headless compositor, worst light contrast 4.81:1.
    //
    // For a long time they could not be offered: 212 `color:` bindings across
    // src/ were Qt.rgba(1, 1, 1, α), a translucent white foreground that reads
    // on the dark surface and is invisible on matugen's light one (#fdf9f3 on
    // the default wallpaper) — a Light/Dark toggle would have handed the user a
    // blank Settings window. UI/UX Phase 18 took that count to zero: every one
    // is a palette role now, or a fixed colour on a surface that really is
    // fixed. Every surface tests/visual can open — the bar, each panel and
    // pane, every Dashboard tab and Nexus page, the toast, the stack, the OSD
    // and the lock screen — was captured in both schemes of the default
    // wallpaper; the Clock card's Timer and Alarm tabs were not.
    //
    // WallpaperService passes matugen `-m <mode>` and takes the mode from
    // ~/.config/apex-shell/src/user_data/wallpaper.json (setMode()).
    // tests/check-color-tokens.sh bans the translucent white from coming back.
    //
    // The dark values are byte-identical to the ones already dominant in the
    // tree, so nothing moves on an existing install: `danger` was #f87171 at 12
    // of the 24 red call sites, `warning` #f5c47a at 7 of 13, `success`
    // #a6e3a1 at 2 of 3.
    //
    // Contrast against the surfaces they are actually drawn on — the page
    // background, a card (background + 3% text) and that card hovered
    // (background + 7% text) — measured for both matugen schemes of the shipped
    // default wallpaper, in tests/agent-state-test.js. Every one clears 4.5:1.
    property color danger:    darkSurface ? "#f87171" : "#8c1d18"
    property color warning:   darkSurface ? "#f5c47a" : "#7a4a00"
    property color success:   darkSurface ? "#a6e3a1" : "#17752f"

    // Work in progress, and a hold only a person can release. Both are new with
    // the Agent Center's state colours (roadmap P0-021) and neither duplicates
    // an existing token: `active` is the wallpaper's primary and lands wherever
    // matugen puts it — on the light scheme of the default wallpaper it is
    // #000613, near-black — so it cannot carry a meaning that has to stay
    // recognisable across palettes.
    //
    // Blue and violet rather than two blues: after protanopia and deuteranopia
    // the pair still separates on the blue axis, and their luminances differ by
    // enough to survive greyscale.
    property color info:      darkSurface ? "#89b4fa" : "#0b57d0"
    property color attention: darkSurface ? "#d0bcff" : "#6b3fa0"

    // The foreground for a glyph or label sitting ON one of the fills above.
    //
    // Whichever of the two fixed foregrounds actually measures better, rather
    // than a lightness threshold. A threshold has to be placed, and every place
    // to put one is wrong somewhere: at 0.35 it sends white onto #f87171, which
    // is a 2.8:1 read, while the dark foreground next to it would have been
    // 5.9:1. Comparing the two candidates has no such seam and cannot drift
    // when a token's value changes.
    function contrastRatio(a, b) {
        var ya = luminance(a)
        var yb = luminance(b)
        return ya > yb ? (ya + 0.05) / (yb + 0.05)
                       : (yb + 0.05) / (ya + 0.05)
    }
    function onStatus(fill) {
        return contrastRatio(root.fixedDark, fill)
               >= contrastRatio(root.fixedLight, fill)
               ? root.fixedDark : root.fixedLight
    }

    // ── Fixed-contrast foregrounds ────────────────────────────────────────────
    // For a foreground sitting on something whose colour is NOT the themed
    // background: a knob on a filled slider track, a label on a status chip, a
    // glyph on a fixed dark overlay. Theme.text would follow the palette and
    // could land at the same lightness as the fill underneath it, so these two
    // stay put on purpose. Named for the constraint, not for a surface, so
    // nobody reads them as "the accent's foreground" and reuses them wrongly.
    property color fixedLight: "#ffffff"
    property color fixedDark:  "#1e1e2e"

    // ── Destructive filled control ────────────────────────────────────────────
    // The confirm button on a "this deletes things" dialog. A *fill*, so it is
    // much darker than `danger`, which is a foreground accent — they are not
    // interchangeable. Already identical in ConfirmDialog and KanbanBoard before
    // this became a token; a token is what stops them drifting apart.
    property color dangerFill:      "#993030"
    property color dangerFillHover: "#cc3a3a"

    // ── Surface and text roles (UI/UX roadmap v3 Phase 2; roles.js) ─────────
    // Named roles over the palette's own background, accent and text, each a
    // mix of those three, so they follow the wallpaper AND the scheme — which
    // the translucent whites they replace cannot. Resolved once per palette,
    // with the fallback rule applied and reported; tests/color-roles-test.js
    // holds every one to its contrast target on all twelve shipped palettes.
    readonly property var _roleSet: Roles.resolve({ background: root.background,
                                                    active: root.active, text: root.text })
    function _c(o) { return Qt.rgba(o.r, o.g, o.b, 1) }
    on_RoleSetChanged: if (root._roleSet.fired.length > 0)
        console.info("APEX colour roles: this palette needed a fallback — "
                     + root._roleSet.fired.join("; "))

    readonly property color surfaceBase:       _c(_roleSet.roles.surfaceBase)
    readonly property color surfaceRaised:     _c(_roleSet.roles.surfaceRaised)
    readonly property color surfaceOverlay:    _c(_roleSet.roles.surfaceOverlay)
    readonly property color surfaceHigh:       _c(_roleSet.roles.surfaceHigh)
    readonly property color surfaceSelected:   _c(_roleSet.roles.surfaceSelected)
    readonly property color surfaceOnSelected: _c(_roleSet.roles.surfaceOnSelected)
    readonly property color accentContainer:   _c(_roleSet.roles.accentContainer)
    // NOT `onAccentContainer`, the role's name in roles.js: a QML property called
    // on<X> beside a property called x is never bound — the engine takes the
    // name for handler syntax — so it stayed an invalid colour and drew BLACK:
    // every "on" Home tile's label and glyph, and the lifecycle chip's text, were
    // black on the dark accent container from Phase 2 until 2026-09-26 (found by
    // a light/dark capture of the power-profile choice; measured valid:false).
    // check-color-tokens.sh now fails any on<X> property that shadows one.
    readonly property color textOnAccentContainer: _c(_roleSet.roles.onAccentContainer)
    readonly property color accentText:        _c(_roleSet.roles.accentText)
    readonly property color outlineSoft:       _c(_roleSet.roles.outlineSoft)
    readonly property color outlineStrong:     _c(_roleSet.roles.outlineStrong)
    readonly property color hairline:          _c(_roleSet.roles.hairline)
    readonly property color textPrimary:       _c(_roleSet.roles.textPrimary)
    readonly property color textSecondary:     _c(_roleSet.roles.textSecondary)
    readonly property color textTertiary:      _c(_roleSet.roles.textTertiary)
    readonly property color iconDefault:       _c(_roleSet.roles.iconDefault)
    readonly property color iconActive:        _c(_roleSet.roles.iconActive)
    // The readable foreground on the accent itself (the existing best-of-two).
    readonly property color onAccent:          onStatus(root.active)

    // The two state layers, over whatever surface a control is on.
    function surfaceHover(c)   { return _c(Roles.hover(c, root.text)) }
    function surfacePressed(c) { return _c(Roles.pressed(c, root.text)) }

    // --- Workspace Visuals ---
    // On the palette's roles (brief §C.5): the active workspace was the one
    // pure white in the shell, the others translucent whites that only ever
    // read on a dark surface.
    property color wsBackground: root.surfaceHigh
    property color wsActive:     root.textPrimary
    property color wsOccupied:   root.textSecondary
    property color wsEmpty:      root.outlineStrong
    property color wsOverlay:    "#CC1e1e2e"
    property color wsUrgent:     "#fa6b94"
}
