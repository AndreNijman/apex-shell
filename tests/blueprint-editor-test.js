#!/usr/bin/env node
// Tests §10's blueprint editor logic against the file the shell actually loads
// (src/services/config_tab/blueprint.js), not a copy of it.
//
//   node tests/blueprint-editor-test.js
//
// ── WHY THIS SUITE CANNOT SKIP ───────────────────────────────────────────────
// No CI runner has a compositor, so a behavioural QML suite always skips there,
// and a suite that skips proves nothing — this repo has already shipped
// assertions that passed because they never ran. So the deciding logic lives in
// a plain module with no process spawning and no filesystem access, and every
// fixture below is inline. There is nothing here that CAN skip: it either runs
// and passes, or runs and fails.
//
// In particular this file never invokes `apex`. It could not, usefully: no
// merged image carries the P1 verbs yet. Shelling out would have meant a suite
// that skips on every runner, which is the outcome the instruction forbids.

"use strict";

const path = require("path");
const BP = require(path.join(__dirname, "..", "src", "services", "config_tab", "blueprint.js"));

let failed = 0;
function check(name, got, want) {
    const ok = JSON.stringify(got) === JSON.stringify(want);
    if (!ok) {
        failed++;
        console.error(`FAIL ${name}\n  got:  ${JSON.stringify(got)}\n  want: ${JSON.stringify(want)}`);
    } else {
        console.log(`ok   ${name}`);
    }
}

// ── vocabularies mirror apexd-core ───────────────────────────────────────────
// Asserted exactly, so an edit to the dropdown lists is loud instead of being a
// page that silently offers a value the CLI will refuse. The Rust side is the
// authority; check-blueprint-editor.sh compares the two when apex-os is
// checked out beside the shell.
check("compositors mirror COMPOSITORS", BP.COMPOSITORS,
      ["hyprland", "niri", "labwc"]);
check("themes mirror THEMES", BP.THEMES,
      ["content", "tonal-spot", "fidelity", "fruit-salad", "neutral", "monochrome"]);
check("agents mirror AGENTS", BP.AGENTS,
      ["claude", "opencode", "codex", "gemini", "kimi", "generic"]);
check("sandbox policies mirror SANDBOX_POLICIES", BP.SANDBOXES,
      ["unrestricted", "project", "strict"]);
check("languages mirror LANGUAGES", BP.LANGUAGES,
      ["c", "cpp", "go", "javascript", "python", "rust", "shell", "typescript"]);

// ── readShow() ───────────────────────────────────────────────────────────────
const showJson = (over) => JSON.stringify(Object.assign({
    schema: 1,
    source: "/home/u/.config/apex/blueprint.toml",
    digest: "abc123",
    blueprint: { desktop: { compositor: "hyprland" } },
    applied: null,
    paths: {
        user: "/home/u/.config/apex/blueprint.toml",
        site: "/etc/apex/blueprint.toml",
        applied_state: "/home/u/.local/state/apex/blueprint-state.toml"
    }
}, over || {}));

check("a show payload is read", BP.readShow(showJson()).ok, true);
check("the blueprint comes through verbatim",
      BP.readShow(showJson()).blueprint, { desktop: { compositor: "hyprland" } });
check("the digest comes through", BP.readShow(showJson()).digest, "abc123");

// "could not read" and "manages nothing" must never look alike: saving the
// second over the first would erase a blueprint the page failed to load.
check("empty output is not ok",      BP.readShow("").ok, false);
check("empty output yields no draft", BP.readShow("").blueprint, null);
check("unparseable output is not ok", BP.readShow("not json").ok, false);
check("unparseable output yields no draft", BP.readShow("not json").blueprint, null);
check("a payload with no blueprint key is not ok",
      BP.readShow('{"schema":1,"digest":"x"}').ok, false);
check("a failed read carries a reason",
      BP.readShow("not json").error !== "", true);
// A blueprint that manages nothing IS a successful read — it is the state of a
// machine nobody has configured, not an error.
check("an empty blueprint is a successful read",
      BP.readShow(showJson({ blueprint: {} })).ok, true);
check("an empty blueprint reads as an empty object",
      BP.readShow(showJson({ blueprint: {} })).blueprint, {});

// ── saveNotice(): the three provenance states ────────────────────────────────
// `set` writes paths.user unconditionally, so a save from the site default
// forks it and site updates stop reaching that user. The page must say so.
check("editing your own file says so",
      /Editing your own blueprint/.test(BP.saveNotice(BP.readShow(showJson()))), true);
check("nothing on disk says a save creates the file",
      /Saving creates/.test(BP.saveNotice(BP.readShow(showJson({ source: null })))), true);
const siteShow = BP.readShow(showJson({ source: "/etc/apex/blueprint.toml" }));
check("the site default warns about forking",
      /no longer reach you/.test(BP.saveNotice(siteShow)), true);
check("the site default names the user's own path",
      /\/home\/u\/\.config\/apex\/blueprint\.toml/.test(BP.saveNotice(siteShow)), true);
check("a failed read has no save notice",
      BP.saveNotice(BP.readShow("")), "");

// ── classify(): the three disjoint buckets ───────────────────────────────────
const plan = (converged, changes) => JSON.stringify({
    schema: 1, source: "/home/u/.config/apex/blueprint.toml",
    digest: "abc123", converged: converged, changes: changes
});

const userChange = { what: "[desktop] theme", current: "content", desired: "neutral",
                     step: "set colour scheme to neutral", domain: "user", blocked: null };
const rootChange = { what: "[desktop] compositor", current: "hyprland", desired: "niri",
                     step: "select session niri", domain: "root", blocked: null };
const blockedChange = { what: "[gaming] enabled", current: "false", desired: "true",
                        step: null, domain: null,
                        blocked: "gaming provisioning comes from a Gaming edition image" };

let p = BP.classify(plan(false, [userChange, rootChange, blockedChange]));
check("a mixed plan is read",            p.ok, true);
check("one user change is classified",   p.user.length, 1);
check("one root change is classified",   p.root.length, 1);
check("one blocked change is classified", p.blocked.length, 1);
check("nothing lands in unknown",        p.unknown.length, 0);
check("the user change is the themed one", p.user[0].what, "[desktop] theme");
check("the blocked change carries its reason",
      /Gaming edition image/.test(p.blocked[0].blocked), true);

// THE TRAP: is_converged() is all(step.is_none()), so a plan whose only changes
// are blocked reports converged: true. The page must report convergence and
// blocked-ness as two separate facts, or it hides the changes nobody can fix.
p = BP.classify(plan(true, [blockedChange]));
check("a blocked-only plan is converged",     p.converged, true);
check("a blocked-only plan still lists it",   p.blocked.length, 1);
check("a blocked-only plan has no actionable changes",
      p.user.length + p.root.length, 0);
check("a blocked-only summary says both things",
      BP.summary(p),
      "This machine matches the blueprint. 1 thing APEX cannot converge.");

p = BP.classify(plan(false, [rootChange]));
check("a root-only plan is not converged", p.converged, false);
check("a root-only plan has no user work",  p.user.length, 0);

p = BP.classify(plan(true, []));
check("an empty plan is converged",  p.converged, true);
check("an empty plan has no rows",
      p.user.length + p.root.length + p.blocked.length, 0);
check("a converged summary says so",
      BP.summary(p), "This machine matches the blueprint.");

// A change with neither a blocked reason nor a domain is a shape this build does
// not understand. It must be surfaced, not dropped — silently discarding a row
// would under-report what apply is about to do.
p = BP.classify(plan(false, [{ what: "[future] thing", current: "a", desired: "b",
                               step: "do something", domain: null, blocked: null }]));
check("an unknown-domain change is surfaced", p.unknown.length, 1);
check("an unknown-domain change is not counted as root", p.root.length, 0);
check("an unknown-domain change is not counted as user", p.user.length, 0);
check("an unknown-domain change is counted in the summary",
      /1 change to make/.test(BP.summary(p)), true);

check("an unreadable plan is not ok",  BP.classify("not json").ok, false);
check("an empty plan output is not ok", BP.classify("").ok, false);
check("an unreadable plan explains itself",
      BP.summary(BP.classify("not json")) !== "", true);

// ── rootNotice(): information, never a button ────────────────────────────────
check("no root changes means no notice",
      BP.rootNotice(BP.classify(plan(false, [userChange]))), "");
check("one root change is singular",
      BP.rootNotice(BP.classify(plan(false, [rootChange]))),
      "1 change needs root — run `sudo apex apply`");
check("two root changes are plural",
      BP.rootNotice(BP.classify(plan(false, [rootChange, {
          what: "[apps] install", current: "", desired: "firefox",
          step: "install packages: firefox", domain: "root", blocked: null }]))),
      "2 changes need root — run `sudo apex apply`");
// The notice tells the user to run sudo themselves. It must never read as
// something the page is about to do for them.
check("the notice names the command, not an action",
      /run `sudo apex apply`/.test(
          BP.rootNotice(BP.classify(plan(false, [rootChange])))), true);

// ── draftFrom(): the draft IS show's object, cloned ─────────────────────────
// Blueprint serialises with skip_serializing_if on every field, so a
// synthesised draft would add a `version = 1` line to a file that never had one
// and make every save a visible diff against a hand-written file.
const show = BP.readShow(showJson({
    blueprint: { desktop: { compositor: "hyprland", theme: "neutral" },
                 apps: { install: ["firefox"] } }
}));
check("the draft matches show's blueprint exactly",
      BP.draftFrom(show),
      { desktop: { compositor: "hyprland", theme: "neutral" },
        apps: { install: ["firefox"] } });
check("no version key is invented",
      Object.prototype.hasOwnProperty.call(BP.draftFrom(show), "version"), false);
check("an empty blueprint drafts as an empty object",
      BP.draftFrom(BP.readShow(showJson({ blueprint: {} }))), {});
check("a failed read yields no draft", BP.draftFrom(BP.readShow("")), null);
// A version the user DID write must survive, or saving would silently drop it.
check("a version the user wrote is preserved",
      BP.draftFrom(BP.readShow(showJson({ blueprint: { version: 1, gaming: { enabled: true } } }))),
      { version: 1, gaming: { enabled: true } });

// The draft must be a copy: mutating it must not reach into show's object.
const d0 = BP.draftFrom(show);
BP.setField(d0, "desktop", "theme", "content");
check("setField does not mutate its input", d0.desktop.theme, "neutral");
check("the draft is a copy of show's blueprint",
      show.blueprint.desktop.theme, "neutral");

// ── setField / setList: CLEARING OMITS THE KEY, NEVER NULLS IT ──────────────
// #[serde(default)] fires on an ABSENT field, not on an explicit null.
// "install": null and "languages": null are hard deserialisation errors, so a
// cleared list must disappear from the object entirely.
let d = { desktop: { compositor: "hyprland", theme: "neutral" } };
check("a scalar is set",
      BP.setField(d, "desktop", "theme", "content"),
      { desktop: { compositor: "hyprland", theme: "content" } });
check("clearing a scalar omits the key, and the sibling survives",
      BP.setField(d, "desktop", "theme", ""),
      { desktop: { compositor: "hyprland" } });
check("clearing the last key drops the whole section",
      BP.setField({ desktop: { theme: "content" } }, "desktop", "theme", ""),
      {});
check("clearing with null also omits",
      BP.setField({ gaming: { enabled: true } }, "gaming", "enabled", null),
      {});
check("a section is created on demand",
      BP.setField({}, "agent", "default", "claude"),
      { agent: { default: "claude" } });
check("false is a value, not a clear",
      BP.setField({}, "gaming", "enabled", false),
      { gaming: { enabled: false } });

// No key anywhere may be an explicit null: the CLI would refuse the payload.
const nullFree = (obj) => !/:null/.test(JSON.stringify(obj).replace(/\s/g, ""));
check("a cleared scalar leaves no null in the payload",
      nullFree(BP.setField({ desktop: { theme: "content", compositor: "niri" } },
                           "desktop", "theme", "")), true);

check("a list is set",
      BP.setList({}, "apps", "install", ["firefox", "git"]),
      { apps: { install: ["firefox", "git"] } });
check("an empty list omits the key rather than writing null",
      BP.setList({ apps: { install: ["firefox"] } }, "apps", "install", []),
      {});
check("an emptied list leaves no null in the payload",
      nullFree(BP.setList({ apps: { install: ["firefox"] } }, "apps", "install", [])), true);
check("a list dedupes preserving first-seen order",
      BP.setList({}, "apps", "install", ["git", "firefox", "git"]),
      { apps: { install: ["git", "firefox"] } });
check("blank entries are dropped from a list",
      BP.setList({}, "apps", "install", ["git", "", "firefox"]),
      { apps: { install: ["git", "firefox"] } });
check("adding to an absent list creates it",
      BP.addToList({}, "development", "languages", "rust"),
      { development: { languages: ["rust"] } });
check("adding a duplicate is a no-op",
      BP.addToList({ apps: { install: ["git"] } }, "apps", "install", "git"),
      { apps: { install: ["git"] } });
check("removing the only entry drops the section",
      BP.removeFromList({ apps: { install: ["git"] } }, "apps", "install", "git"),
      {});
check("removing one entry keeps the others",
      BP.removeFromList({ apps: { install: ["git", "firefox"] } }, "apps", "install", "git"),
      { apps: { install: ["firefox"] } });

// ── fieldOf / listOf: unmanaged is not a default ────────────────────────────
check("an absent scalar reads as unmanaged",
      BP.fieldOf({}, "desktop", "theme"), "");
check("an absent section reads as unmanaged",
      BP.fieldOf({ apps: { install: ["git"] } }, "desktop", "theme"), "");
check("a set scalar reads back",
      BP.fieldOf({ desktop: { theme: "neutral" } }, "desktop", "theme"), "neutral");
check("enabled=false reads back as false, not as unmanaged",
      BP.fieldOf({ gaming: { enabled: false } }, "gaming", "enabled"), false);
check("an absent list reads as empty", BP.listOf({}, "apps", "install"), []);

// ── the empty-blueprint erase guard ─────────────────────────────────────────
// `{}` is the one input `set` accepts that it arguably should not: it clears the
// empty-stdin guard, deserialises to Blueprint::default(), renders to an empty
// string and atomically writes an empty file — erasing everything the user had
// declared. This editor is its only caller, so the page gates that save.
check("an empty object manages nothing",   BP.managesNothing({}), true);
check("a null draft manages nothing",      BP.managesNothing(null), true);
check("an empty section manages nothing",  BP.managesNothing({ desktop: {} }), true);
check("a set field is managing something",
      BP.managesNothing({ desktop: { theme: "content" } }), false);
check("a populated list is managing something",
      BP.managesNothing({ apps: { install: ["git"] } }), false);
check("gaming=false is still managing gaming",
      BP.managesNothing({ gaming: { enabled: false } }), false);

check("clearing the last field of a real blueprint needs a confirm",
      BP.wouldEraseEverything({ desktop: { theme: "content" } }, {}), true);
check("editing a field does not need the erase confirm",
      BP.wouldEraseEverything({ desktop: { theme: "content" } },
                              { desktop: { theme: "neutral" } }), false);
check("saving nothing over nothing is not an erase",
      BP.wouldEraseEverything({}, {}), false);
check("filling in an empty blueprint is not an erase",
      BP.wouldEraseEverything({}, { desktop: { theme: "content" } }), false);

// ── pendingChanges(): the field-level list that replaces a TOML preview ─────
// There is no verb that renders an unsaved draft to TOML, and building one in
// the shell is the forbidden thing. So pending state is described field by
// field, and displayed TOML is only ever the saved file.
check("no edits means nothing pending",
      BP.pendingChanges({ desktop: { theme: "content" } },
                        { desktop: { theme: "content" } }), []);
check("a changed scalar is described",
      BP.pendingChanges({ desktop: { theme: "content" } },
                        { desktop: { theme: "neutral" } }),
      [{ what: "[desktop] theme", before: "content", after: "neutral" }]);
check("a newly managed field reads from 'not managed'",
      BP.pendingChanges({}, { desktop: { theme: "neutral" } }),
      [{ what: "[desktop] theme", before: "not managed", after: "neutral" }]);
check("a cleared field reads to 'not managed'",
      BP.pendingChanges({ desktop: { theme: "neutral" } }, {}),
      [{ what: "[desktop] theme", before: "neutral", after: "not managed" }]);
check("a changed list is joined for display",
      BP.pendingChanges({ apps: { install: ["git"] } },
                        { apps: { install: ["git", "firefox"] } }),
      [{ what: "[apps] install", before: "git", after: "git, firefox" }]);
check("several sections are all reported",
      BP.pendingChanges({}, { desktop: { theme: "neutral" }, gaming: { enabled: true } }).length, 2);
check("isDirty follows pendingChanges",
      BP.isDirty({ desktop: { theme: "content" } }, { desktop: { theme: "neutral" } }), true);
check("an unedited draft is not dirty",
      BP.isDirty({ desktop: { theme: "content" } }, { desktop: { theme: "content" } }), false);
// A version key the user wrote is not an editable field and must not show up as
// a pending change on load.
check("a preserved version is not a pending change",
      BP.pendingChanges({ version: 1, gaming: { enabled: true } },
                        { version: 1, gaming: { enabled: true } }), []);

// ── the stale-write guard ───────────────────────────────────────────────────
// `set` has no compare-and-swap and the file is hand-editable while the page is
// open, so the page re-reads the digest immediately before writing.
check("the same digest is not stale",   BP.isStale("abc123", "abc123"), false);
check("a changed digest is stale",      BP.isStale("abc123", "def456"), true);
// A read that produced no digest must count as stale: writing on the strength
// of a read that did not happen is what this guard prevents.
check("a missing fresh digest is stale", BP.isStale("abc123", ""), true);
check("a null fresh digest is stale",    BP.isStale("abc123", null), true);
check("the stale notice says nothing was written",
      /Nothing was written/.test(BP.staleNotice()), true);

// ── toStdin(): what goes down the pipe ──────────────────────────────────────
check("the draft is serialised as JSON",
      BP.toStdin({ desktop: { theme: "neutral" } }), '{"desktop":{"theme":"neutral"}}');
check("an empty draft serialises as an empty object", BP.toStdin({}), "{}");
// The payload is never a bare TOML string: this editor writes JSON, and the CLI
// owns every byte of TOML that reaches the file.
check("the payload parses back as JSON",
      JSON.parse(BP.toStdin({ apps: { install: ["git"] } })),
      { apps: { install: ["git"] } });

if (failed > 0) {
    console.error(`\n${failed} assertion(s) failed`);
    process.exit(1);
}
console.log("\nall assertions passed");
