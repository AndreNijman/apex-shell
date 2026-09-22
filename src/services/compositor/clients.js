// ─── clients.js ──────────────────────────────────────────────────────────────
// The one decision behind the window list: what a `hyprctl -j clients` result
// MEANS, and the mapping from Hyprland's client record to the adapter record
// CompositorService.windows exposes.
//
// It lives here rather than inline in HyprlandBackend.qml for the reason
// title.js does — so tests/clients-test.js drives the file the shell actually
// loads instead of a copy of it. The bug below was invisible for exactly the
// same reason the title one was: the logic sat inside a StdioCollector handler
// that nothing could call.
//
// ── The bug this exists to prevent ───────────────────────────────────────────
//
// It is the title flash again, one property along, and the fix for the title
// (06b1308) did not touch it.
//
// HyprlandBackend._refreshWindows() does `running = false; running = true`,
// which that file's own comment states plainly TERMINATES whatever is currently
// running, and the raw-event listener calls it on EVERY Hyprland event —
// Hyprland "emits a raw event for essentially every state change". So on a busy
// desktop the next refresh kills the previous `hyprctl -j clients` mid-flight.
//
// The killed process still delivers onStreamFinished, with empty or partial
// text. The old code caught the JSON.parse exception, set `out = []`, and
// assigned it: `root.windows = []`. Every window row vanished from the
// launcher, the next poll put them all back, and the list under the user's
// eyes FLASHED. Andre reported it 2026-09-22: "when i type something the
// bottom few start flashing between a bunch of options".
//
// Why the LAUNCHER is where it shows and the bar is not: window rows only
// exist while something holds CompositorService.windowsRef (AppLauncher does,
// while it is on screen) and only for a non-empty query — every provider
// returns [] for "". So an empty launcher shows apps alone and looks fine, and
// the instant a character is typed the window rows join the ranked list and
// start blinking in and out. They rank below a typed prefix on an application
// name, which is why it is the BOTTOM of the list that churns: each time the
// window rows vanish, everything under them moves up.
//
// A failure to read is not a measurement. This repository already records that
// as "permission denied is not absence"; this is the same rule for a window
// list.
//
// ── The distinction that makes it non-trivial ────────────────────────────────
//
// `[]` is NOT a failure. It is exactly what Hyprland returns when no window is
// open, it parses cleanly, and it must still clear the list — otherwise closing
// the last window would strand its row in the launcher forever. So "ignore
// empty output" is the wrong rule. The rule is: did the text PARSE as an array?
//
// This mirrors title.js, where `{}` is a real answer meaning "nothing focused"
// and only an unparseable read is refused. The shapes differ because the two
// hyprctl subcommands answer with different shapes, and reading one off the
// other is how a reflex `Array.isArray` check lands in the wrong place — see
// HostsProvider's own "shape trap" note about `apex host list --json`.

// readClients(text) → an array of adapter window records, or null for "no
// answer". Never throws: this runs on a render path and the failure mode has to
// be "the list did not change", never "the shell stopped tracking windows".
function readClients(text) {
    let d = null;
    try {
        d = JSON.parse(text);
    } catch (e) {
        // Killed, truncated, or not JSON at all. No answer — say so.
        return null;
    }
    // `[]` is a real answer: no windows are open. A non-array that parsed is
    // not this command's output at all (an error object, a string, a number),
    // and guessing at it would be inventing a window list.
    if (!Array.isArray(d)) return null;

    const out = [];
    for (let i = 0; i < d.length; i++) {
        const c = d[i];
        // A client can be an unmapped placeholder — no surface on screen, so
        // no row. Anything that is not an object at all is not a client.
        if (!c || typeof c !== "object" || Array.isArray(c)) continue;
        if (!c.mapped) continue;
        out.push({
            handle:      c.address,
            title:       c.title || "",
            appId:       c.class || "",
            workspaceId: c.workspace ? c.workspace.id : -1,
            output:      c.monitor !== undefined ? String(c.monitor) : "",
            focused:     false,
            x:           c.at   ? c.at[0]   : 0,
            y:           c.at   ? c.at[1]   : 0,
            width:       c.size ? c.size[0] : 0,
            height:      c.size ? c.size[1] : 0
        });
    }
    return out;
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = { readClients: readClients };
}
