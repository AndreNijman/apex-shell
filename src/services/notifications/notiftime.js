// ─── notiftime.js ────────────────────────────────────────────────────────────
// When a notification arrived, said the way the centre says it (UI/UX roadmap
// v3 Phase 17; visual roadmap §25). Pure, so node drives it in
// tests/notif-time-test.js: no Qt, no Date formatting that depends on the
// locale the test happens to run in.
//
//   under a minute     "now"
//   under an hour      "12 min"
//   the same day       "14:05"
//   the day before     "Yesterday"
//   older              "Sep 24"
//
// `ts` and `now` are epoch milliseconds. A missing or future arrival time (a
// clock step backwards) says nothing rather than something wrong; one up to a
// minute ahead is the reader's own clock lagging, and reads "now".

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
              "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function pad2(n) { return (n < 10 ? "0" : "") + n; }

function sameDay(a, b) {
    return a.getFullYear() === b.getFullYear()
        && a.getMonth() === b.getMonth()
        && a.getDate() === b.getDate();
}

function ago(ts, now) {
    if (!ts || ts <= 0 || !now) return "";
    var d = now - ts;
    // A few seconds ahead is the reader's clock lagging the arrival (it ticks
    // every 30 s): that is "now". Further ahead is a clock step: say nothing.
    if (d < 0) return d > -60 * 1000 ? "now" : "";
    if (d < 60 * 1000) return "now";
    if (d < 60 * 60 * 1000) return Math.floor(d / 60000) + " min";
    var t = new Date(ts), n = new Date(now);
    if (sameDay(t, n)) return pad2(t.getHours()) + ":" + pad2(t.getMinutes());
    var y = new Date(now); y.setDate(y.getDate() - 1);
    if (sameDay(t, y)) return "Yesterday";
    return MONTHS[t.getMonth()] + " " + t.getDate();
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = { ago: ago };
}
