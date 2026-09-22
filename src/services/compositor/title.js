// ─── title.js ────────────────────────────────────────────────────────────────
// The one decision behind the notch's focused-application label: what a
// `hyprctl activewindow -j` result MEANS.
//
// It lives here rather than inline in HyprlandBackend.qml for the reason
// firewall.js does — so tests/title-test.js drives the file the shell actually
// loads instead of a copy of it. The bug below was invisible precisely because
// the logic sat inside a StdioCollector handler that nothing could call.
//
// ── The bug this exists to prevent ───────────────────────────────────────────
//
// HyprlandBackend refreshes the title by `running = false; running = true`,
// which that file's own comment states plainly TERMINATES whatever is currently
// running. Hyprland "emits a raw event for essentially every state change", so
// on a busy desktop the next refresh kills the previous `hyprctl` mid-flight.
//
// The killed process still delivers onStreamFinished, with empty or partial
// text. The old code caught the JSON.parse exception and wrote "Desktop" —
// treating a read that never completed as though it were an answer. The next
// poll wrote the real title back, so the notch FLASHED between the focused
// application and "Desktop". Reported by Andre 2026-09-22 with a screenshot.
//
// A failure to read is not a measurement. This repository already records that
// as "permission denied is not absence"; this is the same rule for a title.
//
// ── The distinction that makes it non-trivial ────────────────────────────────
//
// `{}` is NOT a failure. It is exactly what Hyprland returns when nothing is
// focused, it parses cleanly, and it must still yield "Desktop". So "ignore
// empty output" is the wrong rule and would leave a stale title on an empty
// desktop forever. The rule is: did the text PARSE as an object?
function readActiveWindow(text) {
    let d = null;
    try {
        d = JSON.parse(text);
    } catch (e) {
        // Killed, truncated, or not JSON at all. No answer — say so.
        return null;
    }
    if (d === null || typeof d !== "object" || Array.isArray(d)) return null;

    const t = d.title ? d.title : "";
    const a = d.initialTitle ? d.initialTitle : "";
    return {
        title:   t !== "" ? t : "Desktop",
        appName: a !== "" ? a : "Desktop"
    };
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = { readActiveWindow: readActiveWindow };
}
