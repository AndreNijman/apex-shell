#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
//  The settings vocabulary, and the pages that have to speak it (P0-023).
//
//      node tests/settings-semantics-test.js
//      APEX_SHELL_SRC=/path/to/other/src node tests/settings-semantics-test.js
//
//  ── Why a node suite as well as two QML ones ────────────────────────────────
//
//  tests/run-settings-pages-test.sh builds the ten real pages and asks each one
//  what it is; tests/run-settings-controls-test.sh presses the shared controls.
//  Both need a compositor, and both SKIP without one — which is every CI runner
//  this project has. A suite that skips proves nothing, and this repository has
//  already shipped assertions that passed because they never ran.
//
//  So the properties a refactor would quietly undo are checked here too, with
//  nothing but a file reader: that the vocabulary defines what it claims to,
//  that its words are distinct from each other, and that no settings page
//  reaches for a word outside it. It reads src/components/config/
//  settings-semantics.js — the file the shell loads — rather than a copy.
//
//  ── What "outside it" means ─────────────────────────────────────────────────
//
//  A LABEL, not prose. "Discard the draft" in a description is a sentence; a
//  button that says Discard is a fifth verb next to four that already exist,
//  and readers click a fifth word to find out what it does. So the scan looks
//  only at `label:` in code position, comments stripped.
// ─────────────────────────────────────────────────────────────────────────────

"use strict";

const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const SRC = process.env.APEX_SHELL_SRC || path.join(root, "src");

let passed = 0;
let failed = 0;
function ok(name) { passed++; console.log(`ok   ${name}`); }
function bad(name, detail) {
    failed++;
    console.log(`FAIL ${name}${detail ? `\n       ${detail}` : ""}`);
}
function check(name, cond, detail) { cond ? ok(name) : bad(name, detail); }

const semanticsPath = path.join(SRC, "components/config/settings-semantics.js");
if (!fs.existsSync(semanticsPath)) {
    console.log(`FAIL there is no ${semanticsPath}; the vocabulary has no definition`);
    process.exit(1);
}
const S = require(semanticsPath);

// ── 1. the four states ──────────────────────────────────────────────────────
{
    const want = ["live", "staged", "applied", "saved"];
    check("the vocabulary defines exactly the four states a setting can be in",
          Object.keys(S.STATES).length === want.length
          && want.every(k => S.STATES[k] !== undefined),
          Object.keys(S.STATES).join(", "));

    const labels = want.map(k => S.stateLabel(k));
    const blurbs = want.map(k => S.stateBlurb(k));
    check("each state has a name of its own",
          new Set(labels).size === want.length, labels.join(" / "));
    check("each state has a sentence of its own",
          new Set(blurbs).size === want.length);
    check("every one of those sentences is a sentence",
          blurbs.every(b => b.length > 20 && b.trim().endsWith(".")),
          blurbs.find(b => !(b.length > 20 && b.trim().endsWith("."))));

    check("a state the vocabulary does not define renders nothing",
          S.stateLabel("sideways") === "" && S.stateBlurb("sideways") === "");
}

// ── 2. the four verbs ───────────────────────────────────────────────────────
{
    const want = ["apply", "save", "revert", "reset"];
    check("the vocabulary defines exactly the four verbs",
          Object.keys(S.VERBS).length === want.length
          && want.every(k => S.VERBS[k] !== undefined),
          Object.keys(S.VERBS).join(", "));

    const labels = want.map(k => S.verbLabel(k));
    check("no two verbs are the same word",
          new Set(labels).size === want.length, labels.join(" / "));
    check("each verb promises something different",
          new Set(want.map(k => S.verbBlurb(k))).size === want.length);

    // Reset is the one that is NOT about the user's own change, and conflating
    // it with Revert is how somebody loses a year of settings by clicking the
    // button that was supposed to undo the last thirty seconds.
    check("Revert and Reset do not promise the same thing",
          S.verbBlurb("revert") !== S.verbBlurb("reset"));
    check("Revert is about what was there before",
          /before/i.test(S.verbBlurb("revert")), S.verbBlurb("revert"));
    check("Reset is about the shipped default",
          /default/i.test(S.verbBlurb("reset")), S.verbBlurb("reset"));
}

// ── 3. the banned labels ────────────────────────────────────────────────────
{
    const banned = Object.keys(S.BANNED_LABELS);
    check("the vocabulary names the words a control may not carry",
          banned.length > 0, banned.join(", "));
    check("every banned word says which of the four to say instead",
          banned.every(w => String(S.BANNED_LABELS[w]).length > 4),
          banned.find(w => String(S.BANNED_LABELS[w]).length <= 4));

    const verbs = Object.keys(S.VERBS).map(k => S.verbLabel(k));
    check("no banned word is also one of the four",
          banned.every(w => !verbs.includes(w)),
          banned.find(w => verbs.includes(w)));
}

// ── 4. when a change reaches the machine ────────────────────────────────────
{
    check("the default effect renders nothing",
          S.effectNote("now") === "" && S.effectNote("") === "");
    const later = Object.keys(S.EFFECTS).filter(k => k !== "now");
    check("every other effect is a sentence saying when",
          later.length > 0
          && later.every(k => S.effectNote(k).length > 10
                              && S.effectNote(k).trim().endsWith(".")),
          later.find(k => !(S.effectNote(k).length > 10)));
    check("relogin and reboot are told apart",
          S.effectNote("relogin") !== S.effectNote("reboot"));
    check("an effect the vocabulary does not define renders nothing",
          S.effectNote("eventually") === "");
}

// ── 5. the sentence on a commit bar ─────────────────────────────────────────
{
    check("nothing staged says so", S.stagedLine(0, "change") === "Nothing staged");
    check("one staged change is singular",
          S.stagedLine(1, "change") === "1 staged change", S.stagedLine(1, "change"));
    check("two are plural",
          S.stagedLine(2, "change") === "2 staged changes", S.stagedLine(2, "change"));
    check("the page's own noun is used",
          S.stagedLine(1, "shortcut") === "1 staged shortcut"
          && S.stagedLine(3, "shortcut") === "3 staged shortcuts");

    // Three page shapes, three hints. A page that offers only Apply must not be
    // told that Save writes it without touching anything.
    const both = S.stagedHint(true, true);
    const applyOnly = S.stagedHint(true, false);
    const saveOnly = S.stagedHint(false, true);
    check("each set of acts gets its own hint",
          new Set([both, applyOnly, saveOnly]).size === 3);
    check("a page with no Save is not told about Save",
          !/\bSave\b/.test(applyOnly), applyOnly);
    check("a page with no Apply is not told that Apply confirms",
          !/\bApply\b/.test(saveOnly), saveOnly);
}

// ── 6. every settings page says which state its controls are in ─────────────
//
// The QML suite asks the built object; this asks the file, so it still runs on
// a machine with no compositor. Both directions are asserted, because a page
// that gains a declaration must leave the owed list or the list rots.
{
    const AWAITING = {
        "InputPage.qml":
            "P0-019 owns InputPage and is rewriting it on another branch; the " +
            "declaration lands with that branch"
    };

    const pagesDir = path.join(SRC, "services/config_tab/pages");
    const files = fs.readdirSync(pagesDir).filter(f => f.endsWith("Page.qml"));
    // KeybindsPage sits a directory up, beside the service that holds its draft.
    const extra = path.join(SRC, "services/config_tab/KeybindsPage.qml");

    const all = files.map(f => [f, path.join(pagesDir, f)]);
    if (fs.existsSync(extra)) all.push(["KeybindsPage.qml", extra]);

    check("there are settings pages to check", all.length >= 10, `${all.length} found`);

    const missing = [];
    const stale = [];
    for (const [name, file] of all) {
        const text = strip(fs.readFileSync(file, "utf8"));
        // Either `lifecycle: "x"` on a CfgScroll, or a CfgLifecycle placed by
        // hand — the Keybinds page has its own Flickable and does the latter.
        const declared = /\blifecycle:\s*"(\w+)"/.test(text);
        if (AWAITING[name] !== undefined) {
            if (declared) stale.push(`${name} — ${AWAITING[name]}; delete its row here`);
            continue;
        }
        if (!declared) missing.push(name);
    }
    check("every settings page says which state its controls are in",
          missing.length === 0, missing.join(", "));
    check("no page is still excused after it stopped needing to be",
          stale.length === 0, stale.join("; "));

    // And the value has to be one the vocabulary knows.
    const bogus = [];
    for (const [name, file] of all) {
        const text = strip(fs.readFileSync(file, "utf8"));
        for (const m of text.matchAll(/\blifecycle:\s*"(\w+)"/g))
            if (S.STATES[m[1]] === undefined) bogus.push(`${name}: ${m[1]}`);
    }
    check("and says one the vocabulary defines", bogus.length === 0, bogus.join(", "));
}

// ── 7. no control is labelled with a word that means something else ─────────
{
    const dirs = [
        path.join(SRC, "services/config_tab"),
        path.join(SRC, "components/config"),
        path.join(SRC, "windows")
    ];
    const hits = [];
    for (const d of dirs) {
        if (!fs.existsSync(d)) continue;
        for (const file of walk(d)) {
            if (!file.endsWith(".qml")) continue;
            const text = strip(fs.readFileSync(file, "utf8"));
            for (const m of text.matchAll(/\blabel:\s*"([^"]+)"/g))
                if (S.BANNED_LABELS[m[1]] !== undefined)
                    hits.push(`${path.relative(root, file)}: "${m[1]}" — say ` +
                              S.BANNED_LABELS[m[1]]);
        }
    }
    check("no settings control is labelled with a word the vocabulary bans",
          hits.length === 0, hits.join("\n       "));
}

// ── 8. the three staging pages reach the shared bar ─────────────────────────
//
// Structural rather than about words: a page that draws its own Apply/Save/
// Revert row is a page whose vocabulary can drift again, and this is the
// specific thing P0-023 was for.
{
    const staging = {
        "services/config_tab/pages/DisplayPage.qml": "Display",
        "services/config_tab/pages/BlueprintPage.qml": "Blueprint",
        "services/config_tab/KeybindsPage.qml": "Keybinds"
    };
    const notUsing = [];
    for (const rel of Object.keys(staging)) {
        const file = path.join(SRC, rel);
        if (!fs.existsSync(file)) { notUsing.push(`${rel} is missing`); continue; }
        const text = strip(fs.readFileSync(file, "utf8"));
        if (!/\bCfgCommit\s*\{/.test(text)) notUsing.push(staging[rel]);
    }
    check("every page that holds a draft offers the same way out",
          notUsing.length === 0, notUsing.join(", "));
}

// ── helpers ─────────────────────────────────────────────────────────────────

// Comments removed with a scanner that tracks string state, so a banned word
// named in a `//` or `/* */` explanation — and this tree explains itself at
// length — can neither satisfy nor trip anything above. Newlines are kept.
function strip(t) {
    let out = "";
    let i = 0;
    let quote = null;
    while (i < t.length) {
        const c = t[i];
        if (quote) {
            out += c;
            if (c === "\\" && i + 1 < t.length) { out += t[i + 1]; i += 2; continue; }
            if (c === quote) quote = null;
            i++;
            continue;
        }
        if (c === '"' || c === "'" || c === "`") { quote = c; out += c; i++; continue; }
        if (c === "/" && t[i + 1] === "/") {
            while (i < t.length && t[i] !== "\n") i++;
            continue;
        }
        if (c === "/" && t[i + 1] === "*") {
            i += 2;
            while (i + 1 < t.length && !(t[i] === "*" && t[i + 1] === "/")) {
                if (t[i] === "\n") out += "\n";
                i++;
            }
            i += 2;
            continue;
        }
        out += c;
        i++;
    }
    return out;
}

function walk(dir) {
    const out = [];
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) out.push(...walk(p));
        else out.push(p);
    }
    return out;
}

// ── the inverse check: prose must not be able to satisfy or trip section 7 ──
{
    const prose = `
import QtQuick
// A comment naming label: "Discard" and label: "Undo" deliberately.
/* And a block one:
       label: "Restore"
*/
Item { label: "Apply" }
`;
    const stripped = strip(prose);
    const found = [...stripped.matchAll(/\blabel:\s*"([^"]+)"/g)].map(m => m[1]);
    check("self-test: a banned word in a comment is invisible to the scan",
          !found.includes("Discard") && !found.includes("Undo")
          && !found.includes("Restore"), found.join(", "));
    check("self-test: a real label is still seen",
          found.includes("Apply"), found.join(", "));
}

console.log(`\nsettings-semantics: passed=${passed} failed=${failed}`);
process.exit(failed === 0 ? 0 : 1);
