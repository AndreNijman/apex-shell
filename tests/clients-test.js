#!/usr/bin/env node
// The window list behind APEX Search's window rows, tested against the file the
// shell actually loads (src/services/compositor/clients.js), not a copy of it.
//
//   node tests/clients-test.js
//
// Andre reported the launcher's lower rows FLASHING between different entries
// while typing, on 2026-09-22: "when i type something the bottom few start
// flashing between a bunch of options". It is the notch flash (tests/
// title-test.js, commit 06b1308) one property along — that fix guarded
// `hyprctl activewindow -j` and left `hyprctl -j clients` exactly as it was.
//
// The cause is in HyprlandBackend: _refreshWindows() does `running = false;
// running = true`, which that file's own comment says TERMINATES the running
// process, and the raw-event listener calls it on EVERY Hyprland event. The
// killed process still delivers onStreamFinished with empty or partial text,
// and the old code caught the JSON.parse exception and assigned `[]` — so every
// window row vanished from the ranked list and the next poll put them all back.
//
// Measured on the reporting machine, idle, 2026-09-22: 16 raw events in 20
// seconds, 9 of the 15 inter-event gaps under 50 ms and the median at 9.1 ms,
// against a `hyprctl -j clients` that takes about 10 ms. A read inside a burst
// is killed before it can answer.
//
// Cases 3 and 4 are the regression. Cases 1, 2 and 6 exist so a fix cannot pass
// by refusing to update at all, and case 2 specifically because `[]` is a real
// answer meaning no window is open — "ignore empty output" would strand a
// closed window's row in the launcher forever.
const C = require("../src/services/compositor/clients.js");

let pass = 0, fail = 0;
function is(name, got, want) {
    const g = JSON.stringify(got), w = JSON.stringify(want);
    if (g === w) { console.log("PASS  " + name); pass++; }
    else { console.log("FAIL  " + name + "\n      want " + w + "\n      got  " + g); fail++; }
}

// A Hyprland client record, trimmed to the keys the adapter reads.
function client(o) {
    return Object.assign({
        address: "0x1", mapped: true, title: "t", class: "c",
        workspace: { id: 1 }, monitor: 0, at: [10, 20], size: [800, 600]
    }, o);
}

// 1. A real answer maps through to adapter records, unchanged from what the
//    handler produced before the guard existed.
is("a mapped client becomes one adapter record",
   C.readClients(JSON.stringify([client({ address: "0xaa", title: "vim — notes",
                                          class: "kitty" })])),
   [{ handle: "0xaa", title: "vim — notes", appId: "kitty", workspaceId: 1,
      output: "0", focused: false, x: 10, y: 20, width: 800, height: 600 }]);

// 2. `[]` is Hyprland's answer for "no windows are open" and MUST clear the
//    list. This is the case that makes "ignore empty output" the wrong rule.
is("an empty array is a real answer: no windows are open",
   C.readClients("[]"), []);

// 3. THE REGRESSION. A killed or truncated read is not an answer, and must not
//    overwrite a known-good list.
is("empty output is not an answer",          C.readClients(""),                       null);
is("truncated JSON is not an answer",        C.readClients('[{"address":"0xaa","ti'), null);
is("whitespace is not an answer",            C.readClients("   \n"),                  null);
is("a non-JSON error line is not an answer", C.readClients("Couldn't connect"),       null);

// 4. Shapes that parse but are not a client list. `hyprctl activewindow -j`
//    answers with an OBJECT and `clients` with an ARRAY; reading one off the
//    other is the shape trap HostsProvider records for `apex host list --json`.
is("a JSON object is not a client list",     C.readClients("{}"),                     null);
is("JSON null is not a client list",         C.readClients("null"),                   null);
is("a bare number is not a client list",     C.readClients("3"),                      null);

// 5. Unmapped clients have no surface on screen, so they are not rows.
is("an unmapped client is dropped",
   C.readClients(JSON.stringify([client({ address: "0xaa", mapped: false }),
                                 client({ address: "0xbb" })]))
       .map(w => w.handle),
   ["0xbb"]);

// 6. The list PARSED, so the read completed: one junk element is not a reason
//    to throw the whole answer away. The old handler's try/catch wrapped the
//    mapping loop as well, so a null element emptied the list — the flash
//    again, from a different direction.
is("a junk element is skipped, not fatal to the list",
   C.readClients('[null, {"address":"0xbb","mapped":true}]').map(w => w.handle),
   ["0xbb"]);

// 7. Missing fields default rather than landing `undefined` in a row. `monitor`
//    is stringified because the adapter's `output` is a name, and 0 is a real
//    monitor index that `||` would turn into "".
is("missing fields default and monitor 0 survives",
   C.readClients('[{"address":"0xcc","mapped":true,"monitor":0}]'),
   [{ handle: "0xcc", title: "", appId: "", workspaceId: -1, output: "0",
      focused: false, x: 0, y: 0, width: 0, height: 0 }]);

console.log("\nclients: " + pass + " passed, " + fail + " failed");
process.exit(fail === 0 ? 0 : 1);
