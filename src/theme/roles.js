// ─── roles.js ────────────────────────────────────────────────────────────────
// APEX Shell's surface and text roles (UI/UX roadmap v3 Phase 2; design brief
// §C.5), as pure functions of the palette: background B, accent A, text T.
//
// The shell has drawn with the palette's three raw colours and a scatter of
// translucent whites — `Qt.rgba(1, 1, 1, α)`, 211 of them — which read on a
// dark surface and vanish on a light one. These are the named roles those
// become: every one a mix of the palette's own colours, so they follow the
// wallpaper and the scheme, and every one checked for contrast against the
// surfaces it is drawn on, for all twelve shipped palettes (six wallpapers,
// both matugen schemes), in tests/color-roles-test.js.
//
//   mix(a, b, k) = a·(1 − k) + b·k, per sRGB channel
//
// The FALLBACK RULE runs once per palette: where a role would miss its
// contrast target on this palette, it is replaced by a stronger mix, and the
// replacement is reported (Colors.qml logs it) so a palette that needs one is
// visible rather than silently different.
//
// Colours are {r, g, b} with channels 0..1 — the shape a QML `color` has — so
// QML and node run the same arithmetic. No `.pragma library`: node reads this
// file too, and it keeps no state.
// ─────────────────────────────────────────────────────────────────────────────

function rgb(c) { return { r: c.r, g: c.g, b: c.b }; }
function mix(a, b, k) {
    return { r: a.r * (1 - k) + b.r * k, g: a.g * (1 - k) + b.g * k, b: a.b * (1 - k) + b.b * k };
}

// WCAG 2.1 relative luminance (gamma undone first) and contrast ratio.
function channel(v) { return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }
function luminance(c) { return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b); }
function contrast(a, b) {
    var x = luminance(a), y = luminance(b);
    return x > y ? (x + 0.05) / (y + 0.05) : (y + 0.05) / (x + 0.05);
}

// The targets the roles are held to (brief §C.5).
var TARGETS = {
    textPrimary:   7.0,     // body text, on every surface it lands on
    textSecondary: 4.5,     // secondary text, on every surface except accentContainer
    textTertiary:  3.0,     // placeholders and disabled only — never information
    icon:          3.0,     // glyphs (non-text contrast)
    accentOnBase:  3.0,     // the accent used as a label or icon colour
    containerStep: 1.3      // accentContainer distinguishable from the base surface
};

// The two state layers, over whatever surface a control is on.
function hover(surface, text)   { return mix(surface, text, 0.06); }
function pressed(surface, text) { return mix(surface, text, 0.10); }

function resolve(p) {
    var B = rgb(p.background), A = rgb(p.active), T = rgb(p.text);
    var r = {
        surfaceBase:     B,
        surfaceRaised:   mix(B, T, 0.05),
        surfaceOverlay:  mix(B, T, 0.08),
        surfaceHigh:     mix(B, T, 0.12),
        surfaceSelected: mix(B, A, 0.16),
        accentContainer: mix(B, A, 0.26),
        outlineSoft:     mix(B, T, 0.12),
        outlineStrong:   mix(B, T, 0.24),
        hairline:        mix(B, T, 0.10),
        textPrimary:     T,
        textSecondary:   mix(T, B, 0.35),
        textTertiary:    mix(T, B, 0.55),
        accent:          A,
        // The accent as a FOREGROUND (a label, a glyph). Fills keep `accent`.
        accentText:      A
    };
    var fired = [];
    // Secondary text is checked on the two most demanding surfaces it is drawn
    // on, not only the highest: measured, the default wallpaper's pale accent
    // lifts surfaceSelected enough that .35 reads 4.38:1 there (the brief's own
    // sample palette gave 4.7 and checked surfaceHigh alone).
    if (Math.min(contrast(r.textSecondary, r.surfaceHigh),
                 contrast(r.textSecondary, r.surfaceSelected)) < TARGETS.textSecondary) {
        r.textSecondary = mix(T, B, 0.25);
        fired.push("textSecondary: mix(T, B, .25)");
    }
    // Tertiary had no fallback in the brief; one light palette (default-1)
    // reads 2.83:1 on its base at .55.
    if (contrast(r.textTertiary, B) < TARGETS.textTertiary) {
        r.textTertiary = mix(T, B, 0.45);
        fired.push("textTertiary: mix(T, B, .45)");
    }
    if (contrast(A, B) < TARGETS.accentOnBase) {
        r.accentText = mix(A, T, 0.3);
        fired.push("accentText: mix(A, T, .3)");
    }
    if (contrast(r.accentContainer, B) < TARGETS.containerStep) {
        r.accentContainer = mix(B, A, 0.40);
        fired.push("accentContainer: mix(B, A, .40)");
    }
    r.onAccentContainer = contrast(r.accentText, r.accentContainer) >= TARGETS.textSecondary
                          ? r.accentText : T;
    r.iconDefault = r.textSecondary;
    r.iconActive  = r.accentText;
    return { roles: r, fired: fired };
}

if (typeof module !== "undefined" && module.exports)
    module.exports = {
        rgb: rgb, mix: mix, channel: channel, luminance: luminance, contrast: contrast,
        TARGETS: TARGETS, hover: hover, pressed: pressed, resolve: resolve
    };
