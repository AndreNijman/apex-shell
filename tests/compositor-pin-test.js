#!/usr/bin/env node
// When a Settings → Misc → Compositor pin may beat the environment, tested
// against the file the shell actually loads (src/state/compositorPin.js).
//
//   node tests/compositor-pin-test.js
//
// Case 2 is the regression: on 2026-09-29 a "Scrolling" (niri) pin on a
// Hyprland desktop won, and the bar lost its workspace dots, its layout button
// and SUPER+TAB. The others exist so a fix cannot pass by dropping pins
// altogether: a pin must still win where the compositor is really there, and
// where nothing was detected.
const P = require("../src/state/compositorPin.js");

let pass = 0, fail = 0;
function is(name, got, want) {
    const g = JSON.stringify(got), w = JSON.stringify(want);
    if (g === w) { console.log("PASS  " + name); pass++; }
    else { console.log("FAIL  " + name + "\n      want " + w + "\n      got  " + g); fail++; }
}

const hyprOnly = { hyprland: true,  niri: false, labwc: false };
const niriOnly = { hyprland: false, niri: true,  labwc: false };
const both     = { hyprland: true,  niri: true,  labwc: false };
const none     = { hyprland: false, niri: false, labwc: false };

// 1. No pin: detection, and nothing is ignored.
is("no pin follows detection",
   P.resolve("hyprland", "", hyprOnly), { name: "hyprland", ignored: false });

// 2. The regression: a niri pin on a Hyprland desktop.
is("a pin for a compositor that is not running is ignored",
   P.resolve("hyprland", "niri", hyprOnly), { name: "hyprland", ignored: true });
is("…and so is a Floating pin on niri",
   P.resolve("niri", "labwc", niriOnly), { name: "niri", ignored: true });

// 3. A pin that agrees with detection is honoured (and is not "ignored").
is("a pin for the running compositor is honoured",
   P.resolve("hyprland", "hyprland", hyprOnly), { name: "hyprland", ignored: false });

// 4. Both signals present (a nested niri in Hyprland): detection says
//    hyprland, and the pin is how the user says which one the shell is for.
is("a pin settles a session that carries two compositors' signals",
   P.resolve("hyprland", "niri", both), { name: "niri", ignored: false });

// 5. Nothing detected (a shell started without the session environment):
//    the pin is the only information there is.
is("with nothing detected, the pin is used",
   P.resolve("", "labwc", none), { name: "labwc", ignored: false });
is("with nothing detected and no pin, the compositor stays unknown",
   P.resolve("", "", none), { name: "", ignored: false });

// 6. A missing signal map must not let a pin through on a detected session.
is("no signal map: a detected session keeps its compositor",
   P.resolve("hyprland", "niri", undefined), { name: "hyprland", ignored: true });

console.log("\npassed=" + pass + " failed=" + fail);
process.exit(fail === 0 ? 0 : 1);
