#!/usr/bin/env node
// ─── notif-time-test.js ──────────────────────────────────────────────────────
// src/services/notifications/notiftime.js: when a notification arrived, as the
// centre says it. Run by tests/check-notification-stack.sh.
//
// Times are built with local-time constructors so the "same day" and
// "yesterday" boundaries hold in whatever zone the runner is in.

const path = require("path");
const T = require(path.join(__dirname, "..", "src", "services", "notifications", "notiftime.js"));

let pass = 0, fail = 0;
function eq(name, got, want) {
    if (got === want) { pass++; console.log("  ok   " + name); }
    else { fail++; console.log("  FAIL " + name + ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)); }
}

const now = new Date(2026, 8, 26, 15, 30, 0).getTime();   // Sep 26 2026, 15:30 local
const at = (d, h, m, s) => new Date(2026, 8, d, h, m, s || 0).getTime();

eq("no arrival time says nothing", T.ago(0, now), "");
eq("seconds ahead is the reader's clock lagging: now", T.ago(now + 5000, now), "now");
eq("a minute or more ahead is a clock step: nothing", T.ago(now + 2 * 60 * 1000, now), "");
eq("seconds ago is now", T.ago(now - 20 * 1000, now), "now");
eq("59 s is still now", T.ago(now - 59 * 1000, now), "now");
eq("one minute", T.ago(now - 60 * 1000, now), "1 min");
eq("minutes, floored", T.ago(now - (12 * 60 + 40) * 1000, now), "12 min");
eq("59 min stays relative", T.ago(now - 59 * 60 * 1000, now), "59 min");
eq("an hour or more today is a clock time", T.ago(at(26, 14, 5), now), "14:05");
eq("the morning, zero-padded", T.ago(at(26, 7, 3), now), "07:03");
eq("just after midnight today", T.ago(at(26, 0, 1), now), "00:01");
eq("late yesterday is Yesterday, not a time", T.ago(at(25, 23, 58), now), "Yesterday");
eq("early yesterday", T.ago(at(25, 0, 10), now), "Yesterday");
eq("older is a date", T.ago(at(24, 9, 0), now), "Sep 24");
eq("across a month", T.ago(new Date(2026, 7, 31, 12, 0).getTime(), now), "Aug 31");

console.log("\nnotif-time: passed=" + pass + " failed=" + fail);
process.exit(fail === 0 ? 0 : 1);
