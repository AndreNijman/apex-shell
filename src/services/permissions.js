// ─── permissions.js ──────────────────────────────────────────────────────────
// Pure logic behind PermissionsService and Config → Privacy & Permissions
// (roadmap P1-061): reading `apex permissions list --json` and turning it into
// something the page can render without holding any of the reasoning itself.
//
// Kept out of the QML for the reason recovery.js is: this is the part with the
// edge cases, and tests/permissions-test.js exercises THIS file — the one the
// shell loads — rather than a copy of it. Nothing here does I/O and every
// function is data → data, so node can drive all of it.
//
// ── THE ONE RULE THIS FILE EXISTS TO ENFORCE ────────────────────────────────
//
// A Flatpak's camera access may be enforced by the portal. A native binary's
// is enforced by nothing at all. And a Flatpak whose manifest carries
// `devices=all` is in the native case, not the sandboxed one — it opens
// /dev/video0 directly and the portal never sees the request.
//
// A page that showed all three as "allowed" with the same tick would be a lie
// about the machine, and it is the lie this item exists to prevent. So there
// is no function here that returns a boolean for a row. `rowView` returns the
// state AND the enforcer AND what a revocation would do, and `controlsFor`
// returns an EMPTY list wherever nothing can be revoked — never a disabled
// switch, which invites the owner to wonder what is broken about their machine
// instead of telling them the truth.
//
// ── AND THE SECOND: A FAILED READ IS NOT AN EMPTY MACHINE ───────────────────
//
// `parseList` distinguishes "no applications hold permissions" from "the
// command could not be run", because a page that rendered both as a blank list
// would tell an owner their machine is clean at exactly the moment it has
// stopped being able to check. The standing lesson in these repositories is
// that permission denied is not absence; a permissions page is the last place
// to forget it.

// Enforcer strength, strongest first. The page orders by this rather than
// alphabetically so that everything the machine actually controls sits above
// everything it merely observes, and the owner reads the real controls before
// the explanations.
var ENFORCER_RANK = {
    portal_store: 0,
    portal_prompt: 1,
    document_portal: 2,
    sandbox_context: 3,
    logind_acl: 4,
    nothing: 5
};

// What the owner is told about who is doing the enforcing. Short, because the
// row already carries the long sentence from the OS side in `enforcer_why`.
var ENFORCER_LABEL = {
    portal_store: "desktop portal",
    portal_prompt: "asked every time",
    document_portal: "per file",
    sandbox_context: "sandbox, at launch",
    logind_acl: "your login session",
    nothing: "nothing"
};

// The four states, kept four. `no_primitive` is NOT a synonym for `denied`:
// one is a mechanism refusing and the other is no mechanism at all.
var STATE_TONE = {
    granted: "active",
    denied: "danger",
    never_asked: "dim",
    no_primitive: "dim"
};

function rank(enforcer) {
    return Object.prototype.hasOwnProperty.call(ENFORCER_RANK, enforcer)
        ? ENFORCER_RANK[enforcer]
        : 99;
}

function enforcerLabel(enforcer) {
    return Object.prototype.hasOwnProperty.call(ENFORCER_LABEL, enforcer)
        ? ENFORCER_LABEL[enforcer]
        : enforcer;
}

function stateTone(state) {
    return Object.prototype.hasOwnProperty.call(STATE_TONE, state)
        ? STATE_TONE[state]
        : "dim";
}

// Read `apex permissions list --json`.
//
// The exit code informs only the "could not run it at all" branch. The
// decision is made on the text, so a future non-zero exit that still printed a
// complete report does not blank the page.
function parseList(text, exitCode) {
    var empty = {
        ok: false,
        reason: "",
        session: null,
        apps: []
    };
    if (typeof text !== "string" || text.trim() === "") {
        empty.reason = exitCode === 127
            ? "apex is not on PATH, so nothing could be checked"
            : "apex permissions produced no output, so nothing could be checked";
        return empty;
    }
    var doc;
    try {
        doc = JSON.parse(text);
    } catch (e) {
        empty.reason = "apex permissions produced output this could not read";
        return empty;
    }
    if (!doc || !Array.isArray(doc.grants)) {
        empty.reason = "apex permissions produced no grants field";
        return empty;
    }

    var byApp = {};
    var native = {};
    var order = [];
    for (var i = 0; i < doc.grants.length; i++) {
        var g = doc.grants[i];
        var id = g.app || "";
        if (!Object.prototype.hasOwnProperty.call(byApp, id)) {
            byApp[id] = [];
            native[id] = g.native === true;
            order.push(id);
        }
        byApp[id].push(rowView(g));
    }

    var apps = [];
    for (var j = 0; j < order.length; j++) {
        apps.push(appView(order[j], byApp[order[j]], native[order[j]]));
    }

    return {
        ok: true,
        reason: "",
        session: sessionView(doc.session),
        apps: apps
    };
}

// What the header says about this login. Which portals exist is a property of
// the SESSION, not of the machine: APEX's Hyprland session resolves
// `default=hyprland;gtk` and reaches neither Usb nor Secret, where its niri
// session reaches gnome.portal and gets both. An owner comparing two logins
// deserves to be told that is why.
function sessionView(session) {
    if (!session) {
        return {
            desktop: "",
            brokered: [],
            summary: "could not read what this session brokers"
        };
    }
    var ifaces = Array.isArray(session.portal_interfaces) ? session.portal_interfaces : [];
    var short = [];
    for (var i = 0; i < ifaces.length; i++) {
        short.push(String(ifaces[i]).replace("org.freedesktop.portal.", ""));
    }
    short.sort();
    return {
        desktop: session.desktop || "",
        brokered: short,
        summary: short.length === 0
            ? "no desktop portal answered, so nothing here is being brokered"
            : short.length + " portal interfaces answer in this session"
    };
}

// One capability row, as the page renders it.
//
// Everything a tick would have collapsed is kept separate and named.
function rowView(g) {
    return {
        capability: g.capability || "",
        label: g.capability_label || g.capability || "",
        state: g.state || "",
        headline: g.headline || "",
        tone: stateTone(g.state),
        enforcer: g.enforcer || "",
        enforcerLabel: enforcerLabel(g.enforcer),
        enforcerWhy: g.enforcer_why || "",
        origin: g.origin || "",
        originLabel: g.origin_label || "",
        revocation: g.revocation || "",
        timing: g.timing || "",
        timingLabel: g.timing_label || "",
        offersControl: g.offers_control === true,
        effective: g.effective === true,
        caveat: typeof g.caveat === "string" ? g.caveat : "",
        // The token `apex permissions revoke` takes for this subject. Carried
        // from the OS side rather than rebuilt here: a native id is prefixed
        // and a Flatpak id is not, and reconstructing that rule in two places
        // is how they come to disagree.
        revokeId: g.revoke_id || g.app || "",
        rank: rank(g.enforcer)
    };
}

// The buttons for a row, and the reason there are none.
//
// Two buttons for a store-backed capability, because "never" and "ask me
// again" are two different intentions and one button answers a question the
// owner did not ask. One for a sandbox capability, labelled with the fact that
// it lands at next launch. NONE, ever, for anything the machine cannot take
// from this application alone.
function controlsFor(row) {
    if (!row.offersControl) {
        return [];
    }
    if (row.revocation === "store_deny") {
        return [
            { verb: "deny", label: "Never", args: ["--"], note: row.timingLabel },
            { verb: "forget", label: "Ask again", args: ["--forget"], note: row.timingLabel }
        ];
    }
    if (row.revocation === "store_forget") {
        return [{ verb: "forget", label: "Ask again", args: ["--forget"], note: row.timingLabel }];
    }
    if (row.revocation === "context_edit") {
        return [{ verb: "context", label: "Turn off", args: [], note: row.timingLabel }];
    }
    return [];
}

// The argv for a press. Built here, and only from a row that says it offers a
// control, so the page cannot assemble a revoke for something unrevokable by
// wiring a button to the wrong handler.
function revokeArgv(row, verb) {
    if (!row || !row.offersControl || !row.revokeId) {
        return null;
    }
    var argv = ["apex", "permissions", "revoke", row.revokeId, row.capability];
    if (verb === "forget") {
        argv.push("--forget");
    }
    return argv;
}

// One application, with a summary that counts what is actually enforceable.
//
// The counts are the honest headline: "6 enforced" beside "4 that cannot be
// withdrawn" says more than any per-row tick, and it is the number an owner
// scanning a long list needs.
function appView(id, rows, isNative) {
    var sorted = rows.slice().sort(function (a, b) {
        if (a.rank !== b.rank) {
            return a.rank - b.rank;
        }
        return a.label < b.label ? -1 : (a.label > b.label ? 1 : 0);
    });
    var controllable = 0;
    var unenforceable = 0;
    var unavailable = 0;
    for (var i = 0; i < sorted.length; i++) {
        if (sorted[i].state === "no_primitive") {
            unavailable++;
        } else if (sorted[i].offersControl) {
            controllable++;
        } else {
            unenforceable++;
        }
    }
    return {
        id: id,
        native: isNative === true,
        rows: sorted,
        controllable: controllable,
        unenforceable: unenforceable,
        unavailable: unavailable,
        summary: summaryFor(controllable, unenforceable, unavailable)
    };
}

function summaryFor(controllable, unenforceable, unavailable) {
    var parts = [];
    if (controllable > 0) {
        parts.push(controllable + " you can change");
    }
    if (unenforceable > 0) {
        parts.push(unenforceable + " nothing can withdraw");
    }
    if (unavailable > 0) {
        parts.push(unavailable + " not available in this session");
    }
    return parts.length === 0 ? "nothing to report" : parts.join(" · ");
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        parseList: parseList,
        sessionView: sessionView,
        rowView: rowView,
        appView: appView,
        controlsFor: controlsFor,
        revokeArgv: revokeArgv,
        summaryFor: summaryFor,
        enforcerLabel: enforcerLabel,
        stateTone: stateTone,
        rank: rank
    };
}
