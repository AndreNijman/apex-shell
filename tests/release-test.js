// tests/release-test.js — what the shell does about the release it booted
// (src/services/release.js): open its rimeos.com page once, say nothing, or say
// it rolled back.
//
//     node tests/release-test.js
"use strict";
const R = require("../src/services/release.js");

let pass = 0, fail = 0;
function check(name, ok, detail) {
    if (ok) { pass++; console.log("  ok   " + name); }
    else    { fail++; console.log("  FAIL " + name + (detail ? " — " + detail : "")); }
}
const rel = id => ({ id, notes: "https://rimeos.com/updates/" + id });
const J = o => JSON.stringify(o);

console.log("── IDs ──");
check("date IDs order by day, then by suffix (a plain date is the day's first)",
      R.compare("2026.09.29", "2026.09.28.4") > 0 && R.compare("2026.09.29.2", "2026.09.29") > 0
      && R.compare("2026.09.29.10", "2026.09.29.9") > 0 && R.compare("2026.10.01", "2026.09.30.5") > 0);
check("a pre-rename apex-vX.Y.Z is older than every date ID, and they order among themselves",
      R.compare("apex-v2.1.0", "2026.01.01") < 0 && R.compare("apex-v2.1.0", "apex-v2.0.9") > 0);
check("dev, a label, .1 and garbage are not IDs",
      R.parseId("dev") === null && R.parseId("rime") === null && R.parseId("2026.09.29.1") === null
      && R.parseId("") === null && isNaN(R.compare("dev", "2026.09.29")));
check("the notes URL carries ?from= only for a real ID",
      R.notesUrl("https://rimeos.com/updates/2026.09.29", "2026.09.28.4") === "https://rimeos.com/updates/2026.09.29?from=2026.09.28.4"
      && R.notesUrl("https://rimeos.com/updates/2026.09.29", "") === "https://rimeos.com/updates/2026.09.29"
      && R.notesUrl("https://rimeos.com/updates/2026.09.29", "dev") === "https://rimeos.com/updates/2026.09.29");

console.log("── first boot of the feature ──");
let d = R.decide(rel("2026.09.29"), null, false, true);
check("no state and no deployment to roll back to: a first install — record, show nothing",
      d.action === "record" && d.state.lastOpenedNotes === "2026.09.29", J(d));
d = R.decide(rel("2026.09.29"), null, true, true);
check("no state but a previous deployment: the first update to an image that says what it is — open the page",
      d.action === "open" && d.url === "https://rimeos.com/updates/2026.09.29" && d.state.pending === "2026.09.29", J(d));
check("…and it is not marked seen until it has actually been opened", d.state.lastOpenedNotes === "", J(d.state));
check("a dev image (no notes) does nothing at all", R.decide({ id: "dev", notes: "" }, null, true, true).action === "none");
check("no release.json at all does nothing", R.decide(null, { lastBooted: "2026.09.29" }, true, true).action === "none");

console.log("── updates ──");
const seen28 = { lastBooted: "2026.09.28.4", lastOpenedNotes: "2026.09.28.4", pending: "" };
d = R.decide(rel("2026.09.29"), seen28, true, true);
check("a forward update opens the new page with ?from= the release before it",
      d.action === "open" && d.url === "https://rimeos.com/updates/2026.09.29?from=2026.09.28.4", J(d));
let after = R.opened(d.state, "2026.09.29");
check("opened() records it as seen and clears the pending",
      after.lastOpenedNotes === "2026.09.29" && after.pending === "" && after.lastBooted === "2026.09.29", J(after));
check("the next start of the same release does nothing", R.decide(rel("2026.09.29"), after, true, true).action === "none");
d = R.decide(rel("2026.10.03.2"), after, true, true);
check("skipping releases: the newest page with ?from= the last one seen (the page merges what was crossed)",
      d.url === "https://rimeos.com/updates/2026.10.03.2?from=2026.09.29", d.url);

console.log("── the page is not reachable yet ──");
const pend = R.decide(rel("2026.09.29"), seen28, true, true).state;   // opened() never called
d = R.decide(rel("2026.09.29"), pend, true, true);
check("a pending page is tried again on the next start, still from the last one seen",
      d.action === "open" && d.url === "https://rimeos.com/updates/2026.09.29?from=2026.09.28.4", J(d));
d = R.decide(rel("2026.09.30"), pend, true, true);
check("superseded by a newer release before it opened: the newer page, from the last one SEEN, not the one skipped",
      d.url === "https://rimeos.com/updates/2026.09.30?from=2026.09.28.4" && d.state.pending === "2026.09.30", J(d));
const firstPend = R.decide(rel("2026.09.29"), null, true, true).state;
d = R.decide(rel("2026.09.29"), firstPend, true, true);
check("the feature's first page pending: retried without ?from= (nothing before it was seen)",
      d.action === "open" && d.url === "https://rimeos.com/updates/2026.09.29", J(d));

console.log("── rollbacks ──");
const on30 = R.opened(R.decide(rel("2026.09.30"), seen28, true, true).state, "2026.09.30");
d = R.decide(rel("2026.09.29"), on30, true, true);
check("booting an older release is a rollback: a notice, never a \"what's new\"",
      d.action === "rollback" && d.state.lastBooted === "2026.09.29", J(d));
check("…once: the next start on it does nothing", R.decide(rel("2026.09.29"), d.state, true, true).action === "none");
d = R.decide(rel("2026.09.30"), d.state, true, true);
check("rolling forward again to a release already seen replays nothing", d.action === "none", J(d));
const pend30 = R.decide(rel("2026.09.30"), seen28, true, true).state;   // 09.30 pending, never opened
d = R.decide(rel("2026.09.29"), pend30, true, true);
check("a rollback drops the pending page of the newer release it left", d.action === "rollback" && d.state.pending === "", J(d));
d = R.decide(rel("2026.09.30"), d.state, true, true);
check("…and going forward to it again opens it, from the last one seen",
      d.action === "open" && d.url === "https://rimeos.com/updates/2026.09.30?from=2026.09.28.4", J(d));

console.log("── notes turned off ──");
d = R.decide(rel("2026.09.29"), seen28, true, false);
check("with the setting off, a notification offers the page instead", d.action === "notify" && d.url.indexOf("?from=2026.09.28.4") > 0, J(d));
check("a first install with it off is still silent", R.decide(rel("2026.09.29"), null, false, false).action === "record");

console.log("");
console.log("release: passed=" + pass + " failed=" + fail);
process.exit(fail === 0 ? 0 : 1);
