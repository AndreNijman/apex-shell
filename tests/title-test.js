#!/usr/bin/env node
// The notch's focused-application label, tested against the file the shell
// actually loads (src/services/compositor/title.js), not a copy of it.
//
//   node tests/title-test.js
//
// Andre reported the notch FLASHING between the focused application and
// "Desktop" on 2026-09-22. The cause is in HyprlandBackend: _refreshTitle()
// does `running = false; running = true`, which that file's own comment says
// TERMINATES the running process, and Hyprland emits a raw event for
// essentially every state change — so a busy desktop kills its own in-flight
// `hyprctl activewindow -j` repeatedly. The killed process still delivers
// onStreamFinished with empty or partial text, and the old code wrote
// "Desktop" for it.
//
// Case 3 is the regression. Cases 1 and 2 exist so a fix cannot pass by
// refusing to update at all, and case 2 specifically because `{}` is a real
// answer meaning nothing is focused — "ignore empty output" would strand a
// stale title on an empty desktop.
const T = require("../src/services/compositor/title.js");

let pass = 0, fail = 0;
function is(name, got, want) {
    const g = JSON.stringify(got), w = JSON.stringify(want);
    if (g === w) { console.log("PASS  " + name); pass++; }
    else { console.log("FAIL  " + name + "\n      want " + w + "\n      got  " + g); fail++; }
}

// 1. A real focused window updates both fields.
is("a focused window sets the title and the app name",
   T.readActiveWindow(JSON.stringify({ title: "vim — notes", initialTitle: "kitty" })),
   { title: "vim — notes", appName: "kitty" });

// 2. `{}` is Hyprland's answer for "nothing focused" and MUST give Desktop.
is("an empty object is a real answer: nothing is focused",
   T.readActiveWindow("{}"),
   { title: "Desktop", appName: "Desktop" });

// 3. THE REGRESSION. A killed or truncated read is not an answer.
is("empty output is not an answer",            T.readActiveWindow(""),                    null);
is("truncated JSON is not an answer",          T.readActiveWindow('{"title":"vi'),        null);
is("whitespace is not an answer",              T.readActiveWindow("   \n"),               null);
is("a non-JSON error line is not an answer",   T.readActiveWindow("Couldn't connect"),    null);

// 4. Shapes that parse but are not a window object.
is("a JSON array is not a window",             T.readActiveWindow("[]"),                  null);
is("JSON null is not a window",                T.readActiveWindow("null"),                null);

// 5. A window with blank strings still resolves to Desktop rather than "".
is("blank fields fall back to Desktop",
   T.readActiveWindow(JSON.stringify({ title: "", initialTitle: "" })),
   { title: "Desktop", appName: "Desktop" });

console.log("\ntitle: " + pass + " passed, " + fail + " failed");
process.exit(fail === 0 ? 0 : 1);
