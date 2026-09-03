// ─────────────────────────────────────────────────────────────────────────────
// APEX Search — the decision half of the unified command surface (roadmap §15).
//
// §15 asks the launcher to stop being an app list and become "a universal
// command surface": apps, files, settings, windows, clipboard, calculator,
// commands, projects, agents, SSH hosts and package search, all behind one
// text field, with "clear permissions and previews before destructive system
// changes".
//
// Everything in this file answers one of seven questions and nothing else:
//
//   parseQuery()       what did the user actually ask for?
//   providerWants()    which providers is that worth asking, and which not?
//   score()            how well does one candidate answer it?
//   rowsFrom()         what of a provider's output may the shell render?
//   actionArgv()       exactly what argv does an action run — never a string?
//   commitDecision()   may THIS keystroke commit THIS action right now?
//   plan()             which subprocesses start, which get cancelled, and
//                      which arriving answers are stale?
//
// It is plain JavaScript rather than QML for the reason answer.js and
// manifest.js are: the QML engine loads this file with
// `import "search.js" as Search`, and Node `require`s the very same file in
// tests/search-test.js. Not a copy — the file the shell actually runs.
//
// That matters more here than anywhere else in the shell, because no CI runner
// has a compositor and every behavioural QML suite in this repo skips there.
// A launcher that can restart a service or install a package, reached by fuzzy
// match while typing, cannot have its safety rules live in a QML binding that
// nothing checks. So the rules live here and the QML is an adapter.
//
// ─────────────────────────────────────────────────────────────────────────────
//  THE CONTRACT, AND WHY THE BUILT-INS DO NOT GET A PRIVATE DOOR
// ─────────────────────────────────────────────────────────────────────────────
//
// P1's §16 work shipped a `launcher-provider` plugin extension point, so §15's
// "provider API so third parties can add results" already exists. What was
// missing was the set of BUILT-IN providers, and they go through the same
// contract a third-party provider uses:
//
//     property string query      written by the host, debounced
//     property var    results    read by the host
//     function activate(index)   optional; called on the host's say-so
//
// That is character-for-character the contract in PluginLauncher.qml's header.
// A built-in provider declares those three members and nothing else, and the
// host reads it through a sanitiser exactly as it reads a plugin.
//
// ── Where the two DIVERGE, which is a finding about the contract ─────────────
//
// The query→rows half is shared and identical. The ACTIVATION half is not, and
// it cannot be:
//
//   A plugin row's only action is "copy the title". That is deliberate —
//   manifest.js's launcherResults() builds each row from a four-key allowlist
//   precisely so a row cannot arrive carrying `exec` or `entry`, which
//   AppLauncher.activate() dispatches on. A provider that could name a command
//   would hold the `system` permission, which manifest.js refuses at load with
//   a reason worth re-reading: "No permission may grant a capability that
//   subsumes the others."
//
//   Every §15 command row — restart Bluetooth, install Blender, reboot —
//   has to DO something. So the built-ins need exactly one thing the plugin
//   contract cannot express.
//
// The extension is one field, and it is enumerable rather than open:
//
//     action:  an id in the ACTIONS table below
//
// Not a command. Not an argv. An ID into a closed, host-owned table that also
// owns the argv, the privilege it needs, the preview text and the class. A row
// names an action; it cannot invent one, cannot alter one, and cannot pass
// anything but one capped string as its argument. The sanitiser DROPS `action`
// from any row whose provider descriptor is not built in, so a plugin row that
// tried to carry one gets silence.
//
// That is the same shelf manifest.js put `system` on, and the note it left
// there is the door: "Until there is a specific, enumerable set of system
// ACTIONS to expose (set brightness, toggle a profile) rather than a general
// escape hatch, apiVersion 1 offers none of it." ACTIONS below IS that set.
// Handing it to plugins is therefore a permission question and not an
// architecture one — a future apiVersion can implement an `actions` permission
// over this same table, scoped to the classes it is willing to grant, without
// anything here changing shape. What it must not do is what this file
// deliberately does not do: let a provider supply the command.
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
//  QUERY PARSING
// ─────────────────────────────────────────────────────────────────────────────
//
// A universal surface has to decide what the user meant before it decides who
// to ask, because "who to ask" is where the money goes: asking the package
// index means a subprocess and possibly a metadata refresh over the network.
//
// Three kinds of query:
//
//   a SIGIL query   "?…" "=…" ">…" "~/…" "/…" "./…"
//   a VERB query    "install blender", "ssh katana", "open apex-os"
//   a PLAIN query   everything else
//
// A plain query goes only to providers that answer from data the shell already
// holds. Nothing that costs a process is reachable without either a verb the
// user typed on purpose or a path they started to spell — which is the whole
// mechanism behind "no provider may reach the network implicitly".

// "?" is NOT handled here. It is the pre-existing Wolfram|Alpha answer mode
// (see answer.js and AppLauncher), it is the one query shape that leaves this
// machine, and it stays exactly where it was: AppLauncher returns answerRows()
// and nothing else for it, and manifest.js's launcherWantsProviders() refuses
// to consult plugins on it. This file's job is to keep that true by routing
// "?" to a scope every provider gate below says no to.
var SCOPE = {
    ANSWER:   "answer",     // "?…"  — Wolfram, handled by AppLauncher alone
    ALL:      "all",        // a plain query
    CALC:     "calc",       // "=…"  — arithmetic and unit conversion only
    COMMANDS: "commands",   // ">…"  — the ACTIONS table only
    FILES:    "files",      // "~/…", "/…", "./…"
    PACKAGES: "packages",   // "install …", "remove …", "search …"
    HOSTS:    "hosts",      // "ssh …"
    PROJECTS: "projects"    // "open …"
};

// A verb is a whole word followed by a space. Requiring the space is what stops
// "installer" from being read as `install` + "er", and typing "install" alone
// from firing a package search for the empty string.
//
// `intent` is carried separately from the scope because "install blender" and
// "remove blender" ask the same index and offer different actions.
var VERBS = {
    "install":   { scope: SCOPE.PACKAGES, intent: "install" },
    "remove":    { scope: SCOPE.PACKAGES, intent: "remove" },
    "uninstall": { scope: SCOPE.PACKAGES, intent: "remove" },
    "search":    { scope: SCOPE.PACKAGES, intent: "search" },
    "pkg":       { scope: SCOPE.PACKAGES, intent: "search" },
    "ssh":       { scope: SCOPE.HOSTS,    intent: "ssh" },
    "open":      { scope: SCOPE.PROJECTS, intent: "open" }
};

// Below this, a query is too broad to spend anything on: on one character
// nearly every provider matches nearly everything. Same number and same reason
// as manifest.js's MIN_PROVIDER_QUERY, deliberately — a built-in provider that
// answered at one character while a plugin provider did not would be the
// built-ins quietly getting a better deal.
var MIN_QUERY = 2;

// parseQuery(raw) → { raw, scope, term, intent, sigil }
//
// `term` is what the matcher sees: the query with the sigil or verb removed.
// It is never undefined and never null, so no caller has to check.
function parseQuery(raw) {
    var s = String(raw === undefined || raw === null ? "" : raw);
    var q = s.replace(/^[ \t]+|[ \t]+$/g, "");

    if (q === "")
        return { raw: s, scope: SCOPE.ALL, term: "", intent: "", sigil: "" };

    var c0 = q.charAt(0);

    // Sigils first: a single leading character is unambiguous and cannot
    // collide with a word somebody wanted to search for.
    if (c0 === "?")
        return { raw: s, scope: SCOPE.ANSWER, term: q.slice(1).replace(/^ +/, ""),
                 intent: "", sigil: "?" };
    if (c0 === "=")
        return { raw: s, scope: SCOPE.CALC, term: q.slice(1).replace(/^ +/, ""),
                 intent: "", sigil: "=" };
    if (c0 === ">")
        return { raw: s, scope: SCOPE.COMMANDS, term: q.slice(1).replace(/^ +/, ""),
                 intent: "", sigil: ">" };

    // A path is its own sigil. "~" alone is a home directory listing, which is
    // useful; "~x" is not a path and falls through to a plain search.
    if (c0 === "/" || q.slice(0, 2) === "./" || q === "~" || q.slice(0, 2) === "~/")
        return { raw: s, scope: SCOPE.FILES, term: q, intent: "", sigil: "path" };

    var sp = q.indexOf(" ");
    if (sp > 0) {
        var head = q.slice(0, sp).toLowerCase();
        var v = VERBS[head];
        // Explicitly `!== undefined`. A capability table read for truthiness is
        // how a missing key becomes a granted one; this repo has shipped that
        // bug and the plugin platform's `on === true` note explains why.
        if (v !== undefined) {
            var rest = q.slice(sp + 1).replace(/^ +/, "");
            if (rest !== "")
                return { raw: s, scope: v.scope, term: rest, intent: v.intent,
                         sigil: head };
        }
    }

    return { raw: s, scope: SCOPE.ALL, term: q, intent: "", sigil: "" };
}

// ─────────────────────────────────────────────────────────────────────────────
//  THE PROVIDER GATE
// ─────────────────────────────────────────────────────────────────────────────
//
// One row per built-in provider, and every key is present on every row.
// `undefined` reads as truthy-ish in enough places that a table with holes in
// it is a table that grants things by accident — so `spawns` and `scopes` are
// spelled out even where they are the boring value.
//
//   order   the tie-break position in a merged list. Lower wins when two rows
//           score the same. Not a priority: score decides first.
//   scopes  every scope this provider answers. SCOPE.ANSWER appears in none of
//           them, which is how "?" stays Wolfram's alone.
//   min     the shortest term worth asking about.
//   spawns  whether answering can cost a subprocess. Every `true` here is a
//           provider whose scope list excludes SCOPE.ALL, except the two whose
//           argv does not depend on the term at all — see `constantArgv`.
//   constantArgv
//           the argv is the same for every query, so the FIRST keystroke pays
//           for it and every later one is a cache hit. That is what lets
//           projects and hosts appear in a plain search without turning a
//           keystroke into a process.
//   net     whether the subprocess can reach the network. Only the package
//           index can, and it is reachable only from a verb the user typed.
var PROVIDERS = {
    calc: {
        order: 0, min: 1, spawns: false, constantArgv: false, net: false,
        scopes: [SCOPE.ALL, SCOPE.CALC]
    },
    apps: {
        order: 1, min: 1, spawns: false, constantArgv: false, net: false,
        scopes: [SCOPE.ALL]
    },
    commands: {
        order: 2, min: 1, spawns: false, constantArgv: false, net: false,
        scopes: [SCOPE.ALL, SCOPE.COMMANDS]
    },
    windows: {
        order: 3, min: 1, spawns: false, constantArgv: false, net: false,
        scopes: [SCOPE.ALL]
    },
    settings: {
        order: 4, min: 2, spawns: false, constantArgv: false, net: false,
        scopes: [SCOPE.ALL]
    },
    agents: {
        order: 5, min: 2, spawns: false, constantArgv: false, net: false,
        scopes: [SCOPE.ALL]
    },
    clipboard: {
        order: 6, min: 2, spawns: false, constantArgv: false, net: false,
        scopes: [SCOPE.ALL]
    },
    projects: {
        order: 7, min: 2, spawns: true, constantArgv: true, net: false,
        scopes: [SCOPE.ALL, SCOPE.PROJECTS]
    },
    hosts: {
        order: 8, min: 2, spawns: true, constantArgv: true, net: false,
        scopes: [SCOPE.ALL, SCOPE.HOSTS]
    },
    files: {
        order: 9, min: 1, spawns: true, constantArgv: false, net: false,
        scopes: [SCOPE.FILES]
    },
    packages: {
        order: 10, min: 2, spawns: true, constantArgv: false, net: true,
        scopes: [SCOPE.PACKAGES]
    }
};

var PROVIDER_IDS = ["calc", "apps", "commands", "windows", "settings",
                    "agents", "clipboard", "projects", "hosts", "files",
                    "packages"];

// providerWants(id, parsed) → bool
//
// The single gate. Every provider asks it; none of them decides for itself.
// Keeping the predicate here rather than in a QML binding is the same choice
// manifest.js made with launcherWantsProviders(), and for the same reason: a
// condition only a compositor can evaluate is a condition nothing checks.
function providerWants(id, parsed) {
    var p = PROVIDERS[id];
    if (p === undefined) return false;
    if (!parsed || typeof parsed !== "object") return false;

    var term = typeof parsed.term === "string" ? parsed.term : "";
    if (term === "") return false;
    if (term.length < p.min) return false;
    if (term.length < MIN_QUERY && p.spawns) return false;

    return _has(p.scopes, parsed.scope);
}

// Every provider that can reach the network, for the check that asserts none of
// them is reachable from a plain query. A list rather than a filter at the call
// site so the suite and the shell agree on what "reaches the network" means.
function networkProviders() {
    var out = [];
    for (var i = 0; i < PROVIDER_IDS.length; i++)
        if (PROVIDERS[PROVIDER_IDS[i]].net === true) out.push(PROVIDER_IDS[i]);
    return out;
}

// requestArgv(id, parsed, ctx) → the argv the host should run for this
// provider and this query, or [] for "nothing to run".
//
// Every subprocess the search surface can start is built HERE, from a
// provider id and a parsed query, and nowhere else. The providers themselves
// own no Process and compose no command — a static check asserts that no file
// under src/services/search/ so much as names one — so this function plus the
// ACTIONS table is the complete list of things this feature can execute.
//
//   projects   a constant argv. Fetched once per launcher session, because the
//   hosts      cache is keyed by argv and this one never changes.
//   files      the argv is the DIRECTORY, not the query, so typing a file name
//              inside a directory is a cache hit rather than a process.
//   packages   the only one whose argv contains what the user typed, and the
//              only one reachable exclusively from a verb they typed on
//              purpose. `apex search` runs `dnf5 search`, which may refresh
//              repository metadata over the network — so it is never on the
//              path of a plain query.
function requestArgv(id, parsed, ctx) {
    if (!providerWants(id, parsed)) return [];
    var term = parsed.term;

    if (id === "projects") return ["apex", "project", "list", "--json"];
    if (id === "hosts")    return ["apex", "host", "list", "--json"];
    if (id === "files") {
        var argv = listDirArgv(splitPath(term).dir,
                               ctx && typeof ctx.home === "string" ? ctx.home : "");
        return argv === null ? [] : argv;
    }
    if (id === "packages") {
        var v = _plain(term, MAX_ARG);
        // A leading "-" would be read as a flag by dnf5 however many layers
        // down it goes. Refuse rather than strip: a search for "-x" that
        // silently became a search for "x" is a search that lied.
        if (v === "" || v.charAt(0) === "-") return [];
        return ["apex", "search", v];
    }
    return [];
}

// ─────────────────────────────────────────────────────────────────────────────
//  THE SETTINGS INDEX
// ─────────────────────────────────────────────────────────────────────────────
//
// §15's example is "APEX setting: 144 Hz", which is a search for a VALUE, not
// for a page title. Nothing in PageRegistry contains the string "144 Hz" — the
// page is called "Display" — so a settings provider that only matched page
// titles would answer that example with nothing.
//
// This table is the missing half: the settings a person would go looking for,
// each pointing at the page that holds it, each carrying the words they would
// actually type. `page` is a PageRegistry id and the suite asserts every one of
// them still exists, so a renamed page fails a test rather than producing a row
// that opens nothing.
//
// It is a hand-written index rather than something derived from the pages,
// because the pages are QML and their controls have no machine-readable names.
// Deliberately shallow: it points at a page, it does not change a value. A
// launcher that could set a refresh rate from a fuzzy match would be a
// launcher that changes hardware state on Enter, which is the thing §15's
// fourth bullet is about.
var SETTINGS = [
    { page: "appearance", name: "Wallpaper",            keywords: "wallpaper background image desktop picture" },
    { page: "appearance", name: "Accent colour",        keywords: "accent colour color palette theme material you" },
    { page: "appearance", name: "Lock screen",          keywords: "lock screen lockscreen background hyprlock" },
    { page: "appearance", name: "Shape and corners",    keywords: "shape corner radius rounding notch" },
    { page: "layout",     name: "Interface scaling",    keywords: "scaling scale ui size bigger smaller dpi" },
    { page: "layout",     name: "Bar",                  keywords: "bar panel top bar exclusion gap" },
    { page: "layout",     name: "Motion and animation", keywords: "motion animation reduce motion speed duration" },
    { page: "layout",     name: "Dashboard size",       keywords: "dashboard width height size popup" },
    { page: "data",       name: "Disks",                keywords: "disk storage drive space usage" },
    { page: "data",       name: "Clipboard history",    keywords: "clipboard history cliphist wipe pins" },
    { page: "data",       name: "Notifications",        keywords: "notification toast do not disturb" },
    { page: "input",      name: "Touchpad",             keywords: "touchpad trackpad tap natural scroll" },
    { page: "input",      name: "Mouse",                keywords: "mouse pointer sensitivity acceleration" },
    { page: "input",      name: "Keyboard repeat",      keywords: "keyboard repeat rate delay layout" },
    { page: "display",    name: "Resolution",           keywords: "resolution 1080p 1440p 4k mode pixels" },
    { page: "display",    name: "Refresh rate",         keywords: "refresh rate hz 60 hz 120 hz 144 hz 165 hz 240 hz vrr" },
    { page: "display",    name: "Display scale",        keywords: "display scale hidpi fractional per monitor" },
    { page: "display",    name: "Rotation",             keywords: "rotate rotation portrait landscape orientation" },
    { page: "display",    name: "Monitor arrangement",  keywords: "monitor arrangement position layout second screen" },
    { page: "blueprint",  name: "Blueprint",            keywords: "blueprint declarative apply diff machine" },
    { page: "keybinds",   name: "Keybinds",             keywords: "keybind shortcut hotkey binding keyboard" },
    { page: "misc",       name: "Compositor",           keywords: "compositor hyprland niri labwc session" },
    { page: "misc",       name: "Updates",              keywords: "update upgrade version changelog" },
    { page: "misc",       name: "About this machine",   keywords: "about system info kernel distro uptime" }
];

// ─────────────────────────────────────────────────────────────────────────────
//  MATCHING
// ─────────────────────────────────────────────────────────────────────────────
//
// Tiered rather than a single fuzzy distance. A pure subsequence score puts
// "Fractal Design Config" above "Firefox" for "fi", which is the failure that
// makes a launcher feel broken — the thing you typed the start of has to come
// first. So an exact match beats a prefix beats a word-start beats a substring
// beats a subsequence, and the numeric part only orders WITHIN a tier.
//
// Lengths are subtracted so that among equally-tiered candidates the shortest
// wins: for "term", "Terminal" should beat "Terminal Emulator Settings".

var TIER = {
    EXACT:  1000,
    PREFIX:  900,
    WORD:    800,
    SUB:     700,
    FUZZY:   600
};

// Case-folded and stripped of the punctuation people do not type: "Wi-Fi"
// should match "wifi", "1Password" should match "1password".
function fold(s) {
    return String(s === undefined || s === null ? "" : s)
        .toLowerCase()
        .replace(/[‐-―]/g, "-");
}

function _squash(s) {
    return fold(s).replace(/[^a-z0-9]+/g, "");
}

// score(text, term) → 0 for no match, higher is better.
function score(text, term) {
    var t = fold(text);
    var q = fold(term);
    if (q === "") return 0;
    if (t === "") return 0;

    if (t === q) return TIER.EXACT;

    var lenPenalty = Math.min(90, t.length);

    if (t.slice(0, q.length) === q)
        return TIER.PREFIX - lenPenalty;

    // Word start: after a space, dash, underscore, dot or slash. This is what
    // makes "settings" find "APEX Shell Settings" and "code" find "VS Code".
    var words = t.split(/[^a-z0-9]+/);
    for (var i = 0; i < words.length; i++)
        if (words[i] !== "" && words[i].slice(0, q.length) === q)
            return TIER.WORD - lenPenalty;

    if (t.indexOf(q) >= 0)
        return TIER.SUB - lenPenalty;

    // Punctuation-insensitive prefix, so "wifi" reaches "Wi-Fi" without the
    // subsequence tier's looseness.
    var sq = _squash(text);
    var qq = _squash(term);
    if (qq !== "" && sq.slice(0, qq.length) === qq)
        return TIER.WORD - lenPenalty - 1;

    // Subsequence, last and lowest. Every character in order, anywhere. Cheap
    // and it is what lets "fzf" find "Fuzzy Finder" — but it also matches
    // almost everything, which is why it sits below every literal tier.
    var j = 0;
    for (var k = 0; k < t.length && j < q.length; k++)
        if (t.charAt(k) === q.charAt(j)) j++;
    if (j === q.length)
        return TIER.FUZZY - lenPenalty;

    return 0;
}

// The best score across a title and its keywords, so "browser" finds Firefox
// through the .desktop Keywords= line. A keyword hit is worth one tier less
// than the same hit on the visible name: matching something the user cannot see
// on the row must not outrank matching something they can.
function scoreFields(name, extra, term) {
    var best = score(name, term);
    var alt = score(extra, term);
    if (alt > 0) {
        var demoted = alt - 100;
        if (demoted > best) best = demoted;
    }
    return best;
}

// ─────────────────────────────────────────────────────────────────────────────
//  ROW SANITISING
// ─────────────────────────────────────────────────────────────────────────────
//
// The same reasoning manifest.js's PLUGIN OUTPUT section gives, applied to the
// built-ins — and it is not a formality here. Look at what these providers read
// from:
//
//   window titles      whatever an application chose to print
//   clipboard previews whatever was last copied, from any page in any browser
//   package summaries  whatever a packager wrote in a spec file
//   file names         whatever anything that can write to $HOME chose
//
// None of that is more trustworthy than a plugin's output. A newline in a row
// draws over two lines and can impersonate the row beneath it; a control
// character can blank what precedes it. So every string a built-in emits is
// stripped and capped, exactly as a plugin's is, and the row the shell renders
// is a FRESH object built from an allowlist rather than the provider's own
// object with the bad keys deleted.
//
// The allowlist matters for one more reason than it does in manifest.js: these
// rows carry `action`, and an allowlist cannot fall behind a table that grows.

var MAX_NAME   = 120;
var MAX_DETAIL = 120;
var MAX_ARG    = 200;
var MAX_GLYPH  = 4;

// A row's icon is an XDG ICON NAME and never a path — the launcher's delegate
// turns a leading "/" into "file://" and hands it to an Image, which makes a
// path a file-existence oracle. Same rule and same regex as manifest.js.
var ICON_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._+-]*$/;

// What a row's `kind` may be. `kind` is what AppLauncher.activate() dispatches
// on, so it is set from the provider DESCRIPTOR and never from the row: a
// provider choosing its own kind would be choosing which branch runs.
var ROW_KINDS = ["app", "answer", "command", "window", "setting", "clip",
                 "agent", "project", "host", "file", "package"];

function _plain(v, max) {
    if (typeof v !== "string") return "";
    var s = v.replace(/[\x00-\x1f\x7f]/g, "");
    s = s.replace(/[ \t]+/g, " ").replace(/^ +| +$/g, "");
    if (s.length > max) s = s.slice(0, max);
    return s;
}

// rowsFrom(desc, raw) → array of rows the launcher may render.
//
// `desc` is a provider descriptor: { id, kind, builtin }. `raw` is whatever the
// provider put on its `results` property.
//
// Never throws and never returns a refusal: this runs on the render path, so
// the failure mode has to be "that row is not shown", never "the launcher
// stopped working".
function rowsFrom(desc, raw, term) {
    if (!desc || typeof desc !== "object") return [];
    if (typeof desc.id !== "string" || PROVIDERS[desc.id] === undefined) return [];
    if (!_has(ROW_KINDS, desc.kind)) return [];
    if (!raw || !Array.isArray(raw)) return [];

    var builtin = desc.builtin === true;
    var out = [];

    for (var i = 0; i < raw.length; i++) {
        var r = raw[i];
        if (!r || typeof r !== "object" || Array.isArray(r)) continue;

        var name = _plain(r.name, MAX_NAME);
        if (name === "") continue;      // a row with no visible text is not a row

        var icon = _plain(r.icon, 64);
        if (!ICON_NAME_RE.test(icon)) icon = "";

        // `action` is the one field the plugin contract cannot express. It is
        // accepted only from a built-in descriptor, and only when it names a
        // row of the ACTIONS table — an unknown id becomes no action rather
        // than an action nobody checked.
        var action = "";
        if (builtin && typeof r.action === "string" && ACTIONS[r.action] !== undefined)
            action = r.action;

        var row = {
            kind:     desc.kind,
            provider: desc.id,
            name:     name,
            detail:   _plain(r.detail, MAX_DETAIL),
            icon:     icon,
            glyph:    _plain(r.glyph, MAX_GLYPH),
            action:   action,
            // One capped string. Not an object, not an array, not an argv: the
            // action decides what to do with it and the table decides where it
            // lands in the command line.
            arg:      _plain(r.arg, MAX_ARG),
            // The host's own handle for this row — a DesktopEntry id, a window
            // handle, a cliphist row id, a settings page id, a path. Opaque to
            // this file.
            payload:  _plain(r.payload, MAX_ARG),
            // Derived from the action, never read off the row. A provider that
            // could set its own class could label a reboot "safe", which is the
            // entire mechanism this file exists to prevent.
            klass:    action === "" ? KLASS.SAFE : ACTIONS[action].klass,
            score:    typeof r.score === "number" && isFinite(r.score)
                          ? r.score
                          : scoreFields(name, r.detail, term),
            index:    i
        };

        // The DesktopEntry object, and ONLY for the app provider. Copied
        // because the launcher launches an app through DesktopEntry.execute(),
        // which honours Terminal=, Path= and Exec field codes — pasting the
        // Exec line into `bash -c` does not. Every other kind gets no `entry`
        // and no `exec` even if the raw row had one, which is what stops a row
        // from reaching AppLauncher's execution branches.
        if (desc.kind === "app" && r.entry)
            row.entry = r.entry;

        out.push(row);
    }
    return out;
}

// merge(groups) → one ranked list.
//
// `groups` is an array of already-sanitised arrays. The sort is total and has
// no dependence on arrival order, which is the property that matters: results
// come back from subprocesses out of order, and a list that reshuffled itself
// depending on which `apex` returned first would move the row under the user's
// finger between keystrokes.
//
// score desc, then provider order asc, then name asc, then index asc. The last
// two exist so the comparator can never return 0 for two different rows.
function merge(groups, limit) {
    var all = [];
    var i;
    for (i = 0; i < (groups || []).length; i++) {
        var g = groups[i];
        if (!Array.isArray(g)) continue;
        for (var j = 0; j < g.length; j++)
            if (g[j] && g[j].score > 0) all.push(g[j]);
    }

    all.sort(function (a, b) {
        if (b.score !== a.score) return b.score - a.score;
        var oa = PROVIDERS[a.provider] ? PROVIDERS[a.provider].order : 99;
        var ob = PROVIDERS[b.provider] ? PROVIDERS[b.provider].order : 99;
        if (oa !== ob) return oa - ob;
        if (a.name !== b.name) return a.name < b.name ? -1 : 1;
        return a.index - b.index;
    });

    var cap = typeof limit === "number" && limit > 0 ? limit : 60;
    return all.length > cap ? all.slice(0, cap) : all;
}

// ─────────────────────────────────────────────────────────────────────────────
//  THE ACTION REGISTRY
// ─────────────────────────────────────────────────────────────────────────────
//
// §15's fourth bullet is the one with teeth: "Actions should have clear
// permissions and previews before destructive system changes." A launcher that
// can `install Blender` or `restart Bluetooth` is a command surface with system
// reach, reached by fuzzy match while typing.
//
// Three classes, and the class is a property of the ACTION, not of the row:
//
//   safe         nothing persists that the user would have to undo. Launching
//                an app, focusing a window, copying text, opening a settings
//                page, opening a terminal. Enter runs these.
//   changes      alters the system or the session in a way the user would
//                notice and might not have wanted. Restarting a service,
//                installing a package, locking the screen. Enter does NOT run
//                these; it shows the preview.
//   destructive  irreversible, or ends the session, or throws away work.
//                Reboot, shut down, log out, remove a package, roll back the
//                OS, kill an agent. Enter does not run these either, and the
//                preview says plainly that it cannot be undone.
//
// ── HOW THE PRIVILEGED HALF ACTUALLY RUNS, AND WHY NOT IN-PROCESS ────────────
//
// Two mechanisms, chosen per action rather than one blanket answer:
//
//   pkexec       for a single, named, non-interactive system call — restarting
//                a unit. The polkit dialog names the program and asks for a
//                password, which is a clear permission surface in its own
//                right, and there is no output worth reading afterwards.
//
//   a terminal   for anything with a transaction to watch: package install and
//                remove, `apex update`, `apex rollback`. This is the house rule
//                the agent runtime already follows — /usr/libexec/apex-agent-
//                review opens a terminal "because approving PERFORMS the
//                operation, with the reviewing human's own root, so the
//                decision has to happen somewhere sudo can authenticate and
//                where the full prompt and the resulting output are visible."
//                A launcher that swallowed a package transaction into a
//                subprocess with no window would be hiding exactly the part
//                worth seeing — including the part where it fails.
//
// Both go through src/scripts/SearchRun.sh, which takes a VERB from a closed
// set and validates its arguments before it runs anything. That is the second
// lock on the same door: even a bug in QML that passed the wrong argument
// cannot turn a verb into a different command, because the script never
// composes one from what it was given.
//
// ── NO STRINGS. EVER. ────────────────────────────────────────────────────────
//
// argv() returns an ARRAY, and every caller must keep it one. This repo already
// has a CI invariant about not splicing model data into a `bash -c` string, and
// here the data is a package name a user typed into a search box. Arguments
// arrive as positional argv and are never interpolated into a command line.

var KLASS = {
    SAFE:        "safe",
    CHANGES:     "changes",
    DESTRUCTIVE: "destructive"
};

// Human-readable class labels for the row badge. Short, because they sit on a
// 46-pixel row next to a name that also has to fit.
var KLASS_LABELS = {
    safe:        "",
    changes:     "Changes system",
    destructive: "Cannot be undone"
};

// Every value `permission` may take. A closed vocabulary so the preview cannot
// invent a reassuring phrase, and so the suite can assert that every action
// names one of them.
var PERMISSION = {
    NONE:    "your session",
    USER:    "your own user services",
    POLKIT:  "root, via a polkit password prompt",
    SUDO:    "root, via sudo in a terminal you can watch",
    RUNTIME: "the APEX agent runtime"
};

// `ctx` is what the host knows and this file must not guess:
//   shellDir  Quickshell.shellDir — where PowerControl.sh and SearchRun.sh live
// A missing ctx yields null rather than a command built against "undefined".
function _script(ctx, name) {
    if (!ctx || typeof ctx.shellDir !== "string" || ctx.shellDir === "")
        return null;
    return ctx.shellDir + "/src/scripts/" + name;
}

// ── The table ────────────────────────────────────────────────────────────────
//
// Every row has every key. `arg` says whether the action takes one and what it
// is called in the preview; an action declaring `arg: ""` is refused an
// argument rather than silently ignoring it.
//
// `undoes` is prose the preview shows for a `changes` action: what the user
// would type to put it back. An action that cannot answer it is destructive by
// definition, and the suite asserts that correspondence rather than trusting
// each row to have been classified by hand.
var ACTIONS = {
    // ── system services ─────────────────────────────────────────────────────
    "bluetooth.restart": {
        title: "Restart Bluetooth",
        keywords: "bluetooth bt pair reconnect radio",
        klass: KLASS.CHANGES,
        permission: PERMISSION.POLKIT,
        arg: "",
        titleWith: "",
        undoes: "systemctl restart bluetooth",
        what: "Restarts the bluetooth service. Paired devices reconnect on "
            + "their own; anything mid-transfer is dropped.",
        argv: function (arg, ctx) {
            var s = _script(ctx, "SearchRun.sh");
            return s === null ? null : ["bash", s, "unit-restart", "bluetooth"];
        }
    },
    "network.restart": {
        title: "Restart networking",
        keywords: "network networkmanager wifi wi-fi ethernet reconnect dns",
        klass: KLASS.CHANGES,
        permission: PERMISSION.POLKIT,
        arg: "",
        titleWith: "",
        undoes: "systemctl restart NetworkManager",
        what: "Restarts NetworkManager. Every connection drops and comes back; "
            + "a download in flight will not survive it.",
        argv: function (arg, ctx) {
            var s = _script(ctx, "SearchRun.sh");
            return s === null ? null : ["bash", s, "unit-restart", "NetworkManager"];
        }
    },
    "audio.restart": {
        title: "Restart audio",
        keywords: "audio sound pipewire wireplumber pulse no sound",
        klass: KLASS.CHANGES,
        // PipeWire is a per-user unit, so this needs no root at all — which is
        // worth showing the user rather than lumping it in with the others.
        permission: PERMISSION.USER,
        arg: "",
        titleWith: "",
        undoes: "systemctl --user restart pipewire",
        what: "Restarts PipeWire and WirePlumber for your session. Playing "
            + "audio stops; applications reconnect within a second or two.",
        argv: function (arg, ctx) {
            var s = _script(ctx, "SearchRun.sh");
            return s === null ? null : ["bash", s, "audio-restart"];
        }
    },

    // ── session and power ───────────────────────────────────────────────────
    // Routed through PowerControl.sh, the same script the power menu and the
    // confirm dialog use, so the privileged call lives in exactly one place.
    "session.lock": {
        title: "Lock the session",
        keywords: "lock screen away screensaver",
        klass: KLASS.CHANGES,
        permission: PERMISSION.NONE,
        arg: "",
        titleWith: "",
        undoes: "unlock with your password",
        what: "Locks the screen. Everything keeps running.",
        argv: function (arg, ctx) {
            var s = _script(ctx, "PowerControl.sh");
            return s === null ? null : ["bash", s, "lock"];
        }
    },
    "session.suspend": {
        title: "Suspend",
        keywords: "suspend sleep standby",
        klass: KLASS.CHANGES,
        permission: PERMISSION.NONE,
        arg: "",
        titleWith: "",
        undoes: "press a key to wake",
        what: "Suspends to RAM. Open applications survive.",
        argv: function (arg, ctx) {
            var s = _script(ctx, "PowerControl.sh");
            return s === null ? null : ["bash", s, "suspend"];
        }
    },
    "session.logout": {
        title: "Log out",
        keywords: "logout log out sign out end session",
        klass: KLASS.DESTRUCTIVE,
        permission: PERMISSION.NONE,
        arg: "",
        titleWith: "",
        undoes: "",
        what: "Ends this session. Unsaved work in any open application is lost.",
        argv: function (arg, ctx) {
            var s = _script(ctx, "PowerControl.sh");
            return s === null ? null : ["bash", s, "logout"];
        }
    },
    "system.reboot": {
        title: "Restart",
        keywords: "reboot restart reset boot",
        klass: KLASS.DESTRUCTIVE,
        permission: PERMISSION.NONE,
        arg: "",
        titleWith: "",
        undoes: "",
        what: "Restarts the machine. Unsaved work in any open application is "
            + "lost.",
        argv: function (arg, ctx) {
            var s = _script(ctx, "PowerControl.sh");
            return s === null ? null : ["bash", s, "reboot"];
        }
    },
    "system.shutdown": {
        title: "Shut down",
        keywords: "shutdown power off poweroff halt",
        klass: KLASS.DESTRUCTIVE,
        permission: PERMISSION.NONE,
        arg: "",
        titleWith: "",
        undoes: "",
        what: "Powers the machine off. Unsaved work in any open application is "
            + "lost.",
        argv: function (arg, ctx) {
            var s = _script(ctx, "PowerControl.sh");
            return s === null ? null : ["bash", s, "shutdown"];
        }
    },

    // ── packages (§9) ───────────────────────────────────────────────────────
    // The preview for these is not prose this file wrote: it is the output of
    // `apex resolve <name>`, which exists for exactly this purpose and says so
    // in its own help — "Read-only, so it needs no root: 'what would this do'
    // should never cost a password."
    "pkg.install": {
        title: "Install a package",
        keywords: "install add package software app",
        klass: KLASS.CHANGES,
        permission: PERMISSION.SUDO,
        arg: "package",
        titleWith: "Install %s",
        undoes: "sudo apex remove <package>",
        what: "Adds the package to this machine's system extension. The OS "
            + "keeps updating normally and `apex rollback` still works.",
        argv: function (arg, ctx) {
            var s = _script(ctx, "SearchRun.sh");
            if (s === null || !arg) return null;
            return ["bash", s, "install", String(arg)];
        }
    },
    "pkg.remove": {
        title: "Remove a package",
        keywords: "remove uninstall delete package",
        klass: KLASS.DESTRUCTIVE,
        permission: PERMISSION.SUDO,
        arg: "package",
        titleWith: "Remove %s",
        undoes: "",
        what: "Removes the package and rebuilds the system extension. Anything "
            + "the package created outside the package itself stays.",
        argv: function (arg, ctx) {
            var s = _script(ctx, "SearchRun.sh");
            if (s === null || !arg) return null;
            return ["bash", s, "remove", String(arg)];
        }
    },
    "os.update": {
        title: "Update the OS",
        keywords: "update upgrade bootc firmware",
        klass: KLASS.CHANGES,
        permission: PERMISSION.SUDO,
        arg: "",
        titleWith: "",
        undoes: "sudo apex rollback",
        what: "Fetches the next image and stages it for the next boot. Nothing "
            + "changes until you restart, and `apex rollback` returns to this "
            + "deployment.",
        argv: function (arg, ctx) {
            var s = _script(ctx, "SearchRun.sh");
            return s === null ? null : ["bash", s, "os-update"];
        }
    },
    "os.rollback": {
        title: "Roll back the OS",
        keywords: "rollback revert previous deployment undo update",
        klass: KLASS.DESTRUCTIVE,
        permission: PERMISSION.SUDO,
        arg: "",
        titleWith: "",
        undoes: "",
        what: "Makes the previous deployment the default and restarts into it. "
            + "Anything staged for the current one is discarded.",
        argv: function (arg, ctx) {
            var s = _script(ctx, "SearchRun.sh");
            return s === null ? null : ["bash", s, "os-rollback"];
        }
    },

    // ── the things a search RESULT does ─────────────────────────────────────
    // These exist in the table rather than as ad-hoc QML because the class
    // system has to cover every action the launcher can take, not only the
    // scary ones. An action missing from here would be an action with no
    // class, and a row with no class renders as safe.
    "host.terminal": {
        title: "Open a terminal on a device",
        keywords: "ssh remote device host shell terminal",
        klass: KLASS.SAFE,
        permission: PERMISSION.NONE,
        arg: "device",
        titleWith: "Open a terminal on %s",
        undoes: "close the terminal",
        what: "Opens a terminal and connects with ssh. Nothing is probed until "
            + "you do.",
        argv: function (arg, ctx) {
            var s = _script(ctx, "SearchRun.sh");
            if (s === null || !arg) return null;
            return ["bash", s, "ssh", String(arg)];
        }
    },
    "agent.attach": {
        title: "Attach to an agent session",
        keywords: "agent attach session terminal claude codex",
        klass: KLASS.SAFE,
        permission: PERMISSION.RUNTIME,
        arg: "session",
        titleWith: "Attach to session %s",
        undoes: "detach",
        what: "Opens the session's real terminal. The Agent Center is a "
            + "navigator, not a replacement for it.",
        argv: function (arg, ctx) {
            if (!arg) return null;
            return ["/usr/libexec/apex-agent-focus", String(arg)];
        }
    },
    "agent.kill": {
        title: "Stop an agent session",
        keywords: "kill stop agent session terminate",
        klass: KLASS.DESTRUCTIVE,
        permission: PERMISSION.RUNTIME,
        arg: "session",
        titleWith: "Stop session %s",
        undoes: "",
        what: "Kills the session's process tree. Whatever it was part-way "
            + "through is not resumed.",
        argv: function (arg, ctx) {
            if (!arg) return null;
            return ["apex", "agent", "kill", String(arg)];
        }
    },
    "project.open": {
        title: "Go to a project",
        keywords: "project open switch workspace",
        klass: KLASS.SAFE,
        permission: PERMISSION.RUNTIME,
        arg: "project",
        titleWith: "Go to %s",
        undoes: "switch back",
        what: "Switches to the workspace this project's windows are on.",
        argv: function (arg, ctx) {
            if (!arg) return null;
            return ["apex", "project", "switch", String(arg)];
        }
    },
    "file.open": {
        title: "Open a file or folder",
        keywords: "open file folder directory",
        klass: KLASS.SAFE,
        permission: PERMISSION.NONE,
        arg: "path",
        titleWith: "Open %s",
        undoes: "close it",
        what: "Hands the path to the desktop's default handler.",
        argv: function (arg, ctx) {
            if (!arg) return null;
            return ["xdg-open", String(arg)];
        }
    },
    "window.close": {
        title: "Close a window",
        keywords: "close window quit kill",
        // Not destructive — the application decides, and a well-behaved one
        // asks about unsaved work. But it is not `safe` either: the launcher
        // must not close a window because a fuzzy match put it under Enter.
        klass: KLASS.CHANGES,
        permission: PERMISSION.NONE,
        arg: "window",
        titleWith: "Close %s",
        undoes: "reopen the application",
        what: "Asks the window to close, the same as its own close button. The "
            + "application decides what to do about unsaved work.",
        argv: function (arg, ctx) { return null; }
    }
};

var ACTION_IDS = (function () {
    var out = [];
    for (var k in ACTIONS) out.push(k);
    out.sort();
    return out;
})();

// `window.close` is performed through the compositor adapter rather than a
// subprocess, so its argv() is null by design and the "every action has an
// argv" check has to know that rather than treating it as an omission.
var COMPOSITOR_ACTIONS = ["window.close"];

// actionArgv(id, arg, ctx) → array, or null when it cannot be built.
//
// Returns null rather than a partial command for every reason it might fail: an
// unknown id, a missing argument an action requires, a ctx with no shellDir. A
// caller that gets null must do nothing; there is no "best effort" here.
function actionArgv(id, arg, ctx) {
    var a = ACTIONS[id];
    if (a === undefined) return null;
    var v = _plain(arg, MAX_ARG);
    if (a.arg !== "" && v === "") return null;
    if (a.arg === "" && v !== "") return null;
    var out = a.argv(v, ctx);
    if (!Array.isArray(out) || out.length === 0) return null;
    for (var i = 0; i < out.length; i++)
        if (typeof out[i] !== "string" || out[i] === "") return null;
    return out;
}

// actionPreview(id, arg, ctx) → what the user reads BEFORE anything runs.
//
// The command line is shown as the argv joined for display only. The launcher
// runs the array, never this string — and the suite asserts that the display
// form is not what gets executed, because "we show you the command" is worth
// nothing if the shown command and the run command are built separately.
function actionPreview(id, arg, ctx) {
    var a = ACTIONS[id];
    if (a === undefined) return null;
    var argv = actionArgv(id, arg, ctx);
    var v = _plain(arg, MAX_ARG);

    return {
        id:         id,
        // The headline names the target. Built from the action's own explicit
        // template rather than by rewriting its title with a regex: the regex
        // version fired for "Install a package" and for nothing else, so a
        // destructive preview read "Stop an agent session" without ever naming
        // the session. On a surface whose whole justification is showing what
        // will happen before it is committed, the headline has to say to what.
        title:      (v === "" || a.titleWith === "")
                        ? a.title
                        : a.titleWith.replace("%s", v),
        klass:      a.klass,
        klassLabel: KLASS_LABELS[a.klass],
        permission: a.permission,
        what:       a.what,
        // Empty for a destructive action, and that emptiness is the message:
        // the panel renders "This cannot be undone." rather than a blank line.
        undoes:     a.undoes,
        argv:       argv,
        // For display. Arguments are quoted so a name with a space in it reads
        // as one argument rather than as two.
        commandLine: argv === null ? "" : argv.map(_shellish).join(" "),
        // Whether the action needs a second, deliberate gesture. Derived, so a
        // new action cannot forget to ask for one.
        needsCommit: a.klass !== KLASS.SAFE,
        // Whether the preview itself can be filled in by running something
        // read-only first. Only the package actions can, through `apex resolve`.
        resolves:    id === "pkg.install" || id === "pkg.remove"
    };
}

// Display-only quoting. Not used to build anything that runs.
function _shellish(s) {
    return /^[A-Za-z0-9_.:@%+=\/-]+$/.test(s) ? s : "'" + s.replace(/'/g, "'\\''") + "'";
}

// The read-only command whose output fills in a package preview.
//
// `apex resolve` prints every candidate across the repositories, Flathub and
// the user's capsules, which source APEX would pick and why, and the exact
// command for each alternative. It needs no root, which is the property that
// makes it usable as a preview at all.
//
// It is started by ACTIVATION and never by selection. Arrowing down a list of
// twenty packages must not run twenty of these — `apex resolve` reaches the
// package metadata, and dnf5 may refresh it over the network.
function resolveArgv(name) {
    var v = _plain(name, MAX_ARG);
    if (v === "") return null;
    return ["apex", "resolve", v];
}

// ─────────────────────────────────────────────────────────────────────────────
//  THE COMMIT RULE
// ─────────────────────────────────────────────────────────────────────────────
//
// "Enter on a fuzzy match must never be the thing that reboots, uninstalls, or
// resets."
//
// The rule, in one place, as one pure function:
//
//   safe                     Enter runs it.
//   changes / destructive    Enter shows the preview. Only Ctrl+Enter commits,
//                            and only while the preview on screen is the
//                            preview for the row that is selected.
//
// ── The hole this closes, which the obvious version does not ────────────────
//
// "Enter previews, Ctrl+Enter commits" is not enough on its own. Ctrl+Enter is
// muscle-memory "send" in half the applications on this machine, and nothing in
// that rule stops it being pressed straight from the list with no preview ever
// shown. The preview would then be optional, and an optional preview does not
// meet the requirement.
//
// So commitDecision takes BOTH identities — the row the preview belongs to and
// the row that is selected right now — and requires them to be equal AND
// non-empty. No input where they differ can return "run" for a non-safe class,
// which is a single assertion the suite makes over the whole cross product.
//
// ── Why there is no arming delay ────────────────────────────────────────────
//
// The first draft had one: a destructive action could not be committed until
// its preview had been on screen for 600 ms. It is gone, because it stops
// nothing that the gesture does not already stop. The failure it was aimed at
// is a held Enter repeating through both stages, and that cannot happen when
// the second stage is a different chord. What it would have added is a launcher
// that ignores a deliberate keypress for half a second, which teaches people to
// mash the key. A delay that guards nothing and trains a bad habit is worse
// than no delay.

var COMMIT = {
    RUN:     "run",       // do it now
    PREVIEW: "preview",   // show what it would do; do nothing else
    REFUSE:  "refuse"     // do nothing at all
};

// commitDecision({ klass, key, ctrl, previewedId, selectedId }) → COMMIT.*
//
//   klass        the selected row's class
//   key          "enter", "commit" or "button"
//   ctrl         whether the control modifier was actually held
//   previewedId  the row id the preview panel is currently showing, or ""
//   selectedId   the row id under the selection right now, or ""
//
// `key` and `ctrl` are separate arguments on purpose. A UI that binds a
// "commit" key and forgets to check the modifier is the mistake worth catching,
// so the function checks both and refuses a "commit" that arrived without ctrl.
//
// "button" is the mouse and touch path — §15's third bullet is that the surface
// be "keyboard-first but usable with mouse/touch", and a preview only a chord
// can commit is not that. It is not a weaker gate: the Run control exists only
// inside an open preview, so pressing it IS the second deliberate gesture. It
// carries no `ctrl` because claiming a modifier was held when a finger touched
// a screen would be the function lying to itself about what happened.
function commitDecision(o) {
    var opt = o || {};
    var klass = opt.klass;
    var key = opt.key;
    var ctrl = opt.ctrl === true;
    var previewed = typeof opt.previewedId === "string" ? opt.previewedId : "";
    var selected = typeof opt.selectedId === "string" ? opt.selectedId : "";

    if (selected === "") return COMMIT.REFUSE;
    if (klass !== KLASS.SAFE && klass !== KLASS.CHANGES
        && klass !== KLASS.DESTRUCTIVE)
        return COMMIT.REFUSE;

    if (key === "enter") {
        if (!ctrl && klass === KLASS.SAFE) return COMMIT.RUN;
        // Ctrl+Enter on a safe row is not a shortcut for anything; it does what
        // Enter does. Being liberal here would mean the modifier means one
        // thing on one row and another on the next.
        if (ctrl && klass === KLASS.SAFE) return COMMIT.RUN;
        return COMMIT.PREVIEW;
    }

    if (key === "commit") {
        if (!ctrl) return COMMIT.REFUSE;
        if (klass === KLASS.SAFE) return COMMIT.RUN;
        if (previewed === "") return COMMIT.REFUSE;
        if (previewed !== selected) return COMMIT.REFUSE;
        return COMMIT.RUN;
    }

    if (key === "button") {
        if (klass === KLASS.SAFE) return COMMIT.RUN;
        if (previewed === "") return COMMIT.REFUSE;
        if (previewed !== selected) return COMMIT.REFUSE;
        return COMMIT.RUN;
    }

    return COMMIT.REFUSE;
}

// A row's identity for the rule above. Stable across a re-query that produced
// the same row, and different for two rows that differ in anything the user
// could act on — so a list that changed under the preview cannot leave the
// preview pointing at something else with the same name.
function rowId(row) {
    if (!row || typeof row !== "object") return "";
    var name = typeof row.name === "string" ? row.name : "";
    if (name === "") return "";
    return [row.provider || "", row.kind || "", row.action || "",
            row.arg || "", row.payload || "", name].join("");
}

// ─────────────────────────────────────────────────────────────────────────────
//  THE SCHEDULER
// ─────────────────────────────────────────────────────────────────────────────
//
// "A keystroke must not spawn a process per provider per keystroke."
//
// This is a pure reducer rather than a pile of QML Timers, for one reason: a
// Timer's behaviour can only be observed by running a compositor, and no CI
// runner has one. A reducer can be driven by a fake clock in Node and the
// subprocesses it asks for can be counted. So "typing eleven characters costs
// one subprocess" is a MEASUREMENT in tests/search-test.js, not a claim in a
// comment.
//
// ── The state ───────────────────────────────────────────────────────────────
//
//   on        whether anything is holding demand. false means the launcher is
//             closed, and then there is no timer, no process and no cache.
//   seq       a monotonic token. Every start gets one.
//   pending   { providerId: { seq, argv } } — what is in flight.
//   cache     { providerId: [ { argv, ok, text } ] } — recent answers, newest
//             last, bounded.
//   armed     whether the debounce deadline is outstanding.
//
// ── Why the token is per REQUEST and not a global generation ────────────────
//
// The obvious design is a generation counter bumped on every keystroke, with
// arriving results compared against it. It is wrong here, and subtly: the
// projects and hosts providers run a command that does not depend on the query
// at all. Bumping a generation on each keystroke would discard their in-flight
// answer every time the user typed another character, so a fast typist would
// never see a project. A per-request token discards only what was actually
// superseded — a request whose argv is no longer wanted.
//
// ── Why the cache is keyed by ARGV ──────────────────────────────────────────
//
// Because that is what makes typing free. `apex project list --json` has one
// argv for every query, so it is fetched once per launcher session. A directory
// listing's argv is the DIRECTORY, so walking "~/Doc" → "~/Documents/pro" costs
// one listing per directory rather than one per keystroke. And a package search
// that is retyped after a backspace is a cache hit rather than a second
// process.

// The debounce, in milliseconds. 160 rather than PluginLauncher's 120 because
// what sits behind this one is a subprocess rather than a QML binding: the cost
// of being early is a process that will be thrown away, and the cost of being
// late is 40 ms.
var DEBOUNCE_MS = 160;

// Answers kept per provider. Small: the point is to make a keystroke free, not
// to be a cache. Eight covers backspacing through a word.
var CACHE_PER_PROVIDER = 8;

function initialState() {
    return { on: false, seq: 0, pending: {}, cache: {}, armed: false };
}

function _copyState(s) {
    var out = { on: s.on, seq: s.seq, armed: s.armed, pending: {}, cache: {} };
    var k;
    for (k in s.pending) out.pending[k] = { seq: s.pending[k].seq,
                                            argv: s.pending[k].argv };
    for (k in s.cache) out.cache[k] = s.cache[k].slice();
    return out;
}

function _sameArgv(a, b) {
    if (!Array.isArray(a) || !Array.isArray(b)) return false;
    if (a.length !== b.length) return false;
    for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
    return true;
}

// cached(state, id, argv) → { ok, text } or null.
function cached(state, id, argv) {
    var list = state.cache[id];
    if (!Array.isArray(list) || !Array.isArray(argv)) return null;
    for (var i = list.length - 1; i >= 0; i--)
        if (_sameArgv(list[i].argv, argv))
            return { ok: list[i].ok, text: list[i].text };
    return null;
}

// plan(state, event) → { state, start, cancel, armMs }
//
//   start   [ { id, seq, argv } ] — processes to launch, now
//   cancel  [ id ] — processes to kill. The host clears its slot BEFORE the
//           kill, so the exited() the kill produces is ignored; that ordering
//           is a lesson from §20's remote agent sweep and it is asserted.
//   armMs   restart the one debounce timer with this interval, 0 to stop it
//
// Events:
//   { type: "demand",  on: bool }
//   { type: "query",   wants: [ { id, argv } ] }
//   { type: "deadline",wants: [ { id, argv } ] }
//   { type: "result",  id, seq, ok, text }
//
// `wants` is computed by the host from the providers' own bindings — a provider
// declares the command it would like run for the current query, and this
// decides whether it actually runs. Providers that cost nothing are not in
// `wants` at all and never appear here.
function plan(state, event) {
    var s = _copyState(state || initialState());
    var e = event || {};
    var start = [];
    var cancel = [];
    var armMs = -1;          // -1 means "leave the timer alone"
    var id;

    if (e.type === "demand") {
        if (e.on === true) {
            s.on = true;
            return { state: s, start: [], cancel: [], armMs: 0 };
        }
        // Demand gone: cancel everything in flight, drop the cache, stop the
        // timer. A provider that kept polling with the launcher closed is a
        // defect, and so is a cache that survives to answer a question about a
        // machine that has since changed.
        for (id in s.pending) cancel.push(id);
        s.pending = {};
        s.cache = {};
        s.armed = false;
        s.on = false;
        return { state: s, start: [], cancel: cancel, armMs: 0 };
    }

    if (e.type === "query") {
        var wants = _wantMap(e.wants);
        // Cancel anything in flight that the new query does not want, or wants
        // with a different argv. Nothing STARTS here: that is the debounce.
        for (id in s.pending) {
            var w = wants[id];
            if (w === undefined || !_sameArgv(w, s.pending[id].argv))
                cancel.push(id);
        }
        for (var c = 0; c < cancel.length; c++) delete s.pending[cancel[c]];

        if (!s.on)
            return { state: s, start: [], cancel: cancel, armMs: 0 };

        // Nothing to fetch: stop the timer rather than arming it to do nothing.
        // This is the clause that makes an app-only search cost no timer at all.
        var need = _needList(s, e.wants);
        if (need.length === 0) {
            s.armed = false;
            return { state: s, start: [], cancel: cancel, armMs: 0 };
        }
        s.armed = true;
        return { state: s, start: [], cancel: cancel, armMs: DEBOUNCE_MS };
    }

    if (e.type === "deadline") {
        s.armed = false;
        if (!s.on) return { state: s, start: [], cancel: [], armMs: 0 };
        var due = _needList(s, e.wants);
        for (var i = 0; i < due.length; i++) {
            s.seq = s.seq + 1;
            s.pending[due[i].id] = { seq: s.seq, argv: due[i].argv };
            start.push({ id: due[i].id, seq: s.seq, argv: due[i].argv });
        }
        return { state: s, start: start, cancel: [], armMs: 0 };
    }

    if (e.type === "result") {
        var p = s.pending[e.id];
        // A result for a slot nobody is waiting on, or for a superseded
        // request, is dropped. This is where out-of-order arrival is handled:
        // two answers can come back in either order and only the one whose
        // token still matches is believed.
        if (p === undefined || p.seq !== e.seq)
            return { state: s, start: [], cancel: [], armMs: -1 };

        var argv = p.argv;
        delete s.pending[e.id];
        if (!Array.isArray(s.cache[e.id])) s.cache[e.id] = [];
        s.cache[e.id].push({ argv: argv, ok: e.ok === true,
                             text: typeof e.text === "string" ? e.text : "" });
        while (s.cache[e.id].length > CACHE_PER_PROVIDER)
            s.cache[e.id].shift();
        return { state: s, start: [], cancel: [], armMs: -1 };
    }

    return { state: s, start: [], cancel: [], armMs: armMs };
}

function _wantMap(wants) {
    var m = {};
    for (var i = 0; i < (wants || []).length; i++) {
        var w = wants[i];
        if (!w || typeof w.id !== "string" || !Array.isArray(w.argv)) continue;
        m[w.id] = w.argv;
    }
    return m;
}

// What is wanted, not already in flight with the same argv, and not already
// answered. The three conditions together are the whole reason a keystroke is
// usually free.
function _needList(s, wants) {
    var out = [];
    for (var i = 0; i < (wants || []).length; i++) {
        var w = wants[i];
        if (!w || typeof w.id !== "string" || !Array.isArray(w.argv)) continue;
        if (w.argv.length === 0) continue;
        var p = s.pending[w.id];
        if (p !== undefined && _sameArgv(p.argv, w.argv)) continue;
        if (cached(s, w.id, w.argv) !== null) continue;
        out.push({ id: w.id, argv: w.argv });
    }
    return out;
}

// ─────────────────────────────────────────────────────────────────────────────
//  READING WHAT THE CLI SAID
// ─────────────────────────────────────────────────────────────────────────────

// `apex project list --json` prints a JSON ARRAY of project records. Read from
// the serialiser rather than imagined: apexd/apex/src/agent.rs prints
// `serde_json::to_string_pretty(&project::list())` in its
// `ProjectCmd::List { json: true }` arm, and apexd/apex-agent-core/src/
// project.rs declares the struct — root, name, slug, languages, last_opened,
// and capsule with #[serde(default)] so an older record simply has no key.
//
// An ARRAY here and an OBJECT next door in parseHostRegistry, which is the
// point of having read both.
function parseProjectList(text) {
    var raw = String(text === undefined || text === null ? "" : text).trim();
    if (raw === "") return { ok: false, reason: "empty", projects: [] };

    var doc;
    try { doc = JSON.parse(raw); }
    catch (e) { return { ok: false, reason: "unparsable", projects: [] }; }

    if (!Array.isArray(doc))
        return { ok: false, reason: "not-an-array", projects: [] };

    var out = [];
    for (var i = 0; i < doc.length; i++) {
        var p = doc[i];
        if (!p || typeof p !== "object" || Array.isArray(p)) continue;
        if (typeof p.name !== "string" || p.name === "") continue;
        out.push({
            name: p.name,
            slug: typeof p.slug === "string" ? p.slug : p.name,
            root: typeof p.root === "string" ? p.root : "",
            languages: Array.isArray(p.languages) ? p.languages.map(String) : [],
            lastOpened: typeof p.last_opened === "number" && isFinite(p.last_opened)
                            ? p.last_opened : 0,
            capsule: typeof p.capsule === "string" && p.capsule !== ""
                         ? p.capsule : ""
        });
    }
    return { ok: true, reason: "", projects: out };
}

// `apex host list --json` prints a JSON OBJECT KEYED BY HOST NAME, not an
// array: apexd/apex/src/host.rs builds a `serde_json::Map` from the registry's
// own map in its `HostCmd::List { json: true }` arm.
//
// That is worth stating loudly, because the house pattern next door is
// `if (Array.isArray(fresh))` — AgentService does it twice — and writing that
// here by reflex leaves the section permanently empty with nothing logged. §20's
// RemoteAgentService.parseHostList got this right after nearly getting it
// wrong; a top-level array is therefore refused BY NAME so a change of shape
// fails loudly instead of quietly.
//
// `caps` is null for a host `apex host add --no-probe` registered and nothing
// has looked at since. This provider does not care what a host can do — it
// lists devices so a terminal can be opened on one — but it must not present a
// never-probed host as anything else, and it must never probe one to find out.
// §15's constraint is explicit: an SSH-host provider lists hosts; it must not
// reach them while the user types.
function parseHostRegistry(text) {
    var raw = String(text === undefined || text === null ? "" : text).trim();
    if (raw === "") return { ok: false, reason: "empty", hosts: [] };

    var doc;
    try { doc = JSON.parse(raw); }
    catch (e) { return { ok: false, reason: "unparsable", hosts: [] }; }

    if (Array.isArray(doc))
        return { ok: false, reason: "array-not-object", hosts: [] };
    if (doc === null || typeof doc !== "object")
        return { ok: false, reason: "not-an-object", hosts: [] };

    var names = Object.keys(doc).sort();
    var out = [];
    for (var i = 0; i < names.length; i++) {
        var name = names[i];
        var h = doc[name];
        if (h === null || typeof h !== "object" || Array.isArray(h)) continue;
        var caps = h.caps;
        var probed = caps !== null && caps !== undefined
                     && typeof caps === "object" && !Array.isArray(caps);
        out.push({
            name: name,
            ssh: typeof h.ssh === "string" && h.ssh !== "" ? h.ssh : name,
            note: typeof h.note === "string" ? h.note : "",
            probed: probed,
            // Explicitly `=== true`, never truthiness: a hand-edited cache
            // holding the string "false" is truthy, and this decides what the
            // user is told about their own machine.
            apex: probed && caps.agentd === true
        });
    }
    return { ok: true, reason: "", hosts: out };
}

// `apex search <term>` prints two human-readable sections — `dnf5 search`
// output under a "repository packages" rule, then `flatpak search` under
// another — and there is no --json. So this reads the human form, which is a
// deliberate choice over adding a machine-readable mode to the OS side: this is
// the shell's problem, and a parser that fails yields no rows rather than
// wrong ones.
//
// ── THE SHAPE, TRANSCRIBED RATHER THAN ASSUMED ───────────────────────────────
//
// The first version of this function was written from memory of dnf4, which
// separates the name from the summary with " : ". dnf5 does not. Captured from
// `dnf5 search blender` on dnf5 5.2.18.0, Fedora 43, with cat -A:
//
//     Matched fields: name (exact)$
//      blender.x86_64\t3D modeling, animation, rendering and post-production$
//     Matched fields: name, summary$
//      YafaRay-blender.x86_64\tBlender integration scripts for YafaRay$
//
// A leading space, then `name.arch`, then a TAB. No colon anywhere, and the
// "Matched fields:" header repeats between groups rather than appearing once.
// The dnf4-shaped regex matched NOTHING, so the flagship §15 example —
// "install Blender" — returned the Flatpak and never the RPM that
// `apex install` would actually use for a bare name. It failed silently,
// because "a parser that fails yields no rows" is exactly what it did.
//
// Both separators are accepted now: a TAB where dnf5 puts one, and " : " for
// the dnf4 form, since apex-pkg calls whichever dnf5 is installed and the
// output of a tool is not a contract. The fixtures in tests/search-test.js are
// the captured bytes, not a reconstruction.
//
// flatpak's --columns output is tab-separated, which the same capture confirms:
//     org.blender.Blender\tBlender\tfedora,flathub$
function parsePackageSearch(text) {
    var lines = String(text === undefined || text === null ? "" : text).split("\n");
    var out = [];
    var seen = {};
    var section = "repo";

    for (var i = 0; i < lines.length; i++) {
        var line = lines[i];
        if (line.replace(/^[ \t]+|[ \t]+$/g, "") === "") continue;
        if (line.indexOf("── Flatpak") === 0) { section = "flatpak"; continue; }
        if (line.indexOf("── repository") === 0) { section = "repo"; continue; }
        if (line.indexOf("apex resolve") === 0) continue;
        if (line.indexOf("(no Flatpak remote") === 0) continue;
        // dnf5's own group headers. It prints one per match class, so this is
        // not a once-at-the-top rule — "Matched fields: name, summary" appears
        // in the middle of the list.
        if (/^[ \t]*Matched fields:/.test(line)) continue;
        // A section title that ends at its colon, for any other tool that
        // prints one.
        if (/^[A-Z][^:]*:[ \t]*$/.test(line)) continue;

        var tab = line.indexOf("\t");

        if (section === "flatpak") {
            if (tab < 0) continue;
            var f = line.split("\t");
            var appid = f[0].replace(/^[ \t]+|[ \t]+$/g, "");
            // A Flatpak id is reverse-DNS, so it always has a dot. Anything
            // else in this section is a heading or a stray line.
            if (appid === "" || appid.indexOf(".") < 0) continue;
            if (seen[appid]) continue;
            seen[appid] = true;
            out.push({ name: appid, source: "flatpak",
                       summary: _plain((f[1] || "") + (f[2] ? " — " + f[2] : ""), MAX_DETAIL) });
            continue;
        }

        var nm, summary;
        if (tab >= 0) {
            nm = line.slice(0, tab).replace(/^[ \t]+|[ \t]+$/g, "");
            summary = line.slice(tab + 1);
        } else {
            var m = /^[ \t]*(\S+)[ \t]+:[ \t]+(.*)$/.exec(line);
            if (m === null) continue;
            nm = m[1];
            summary = m[2];
        }

        // Strip the architecture: `apex install` takes a bare name, and a row
        // offering to install "blender.x86_64" would be offering something the
        // user cannot type back.
        nm = nm.replace(/\.(x86_64|noarch|i686|aarch64|src)$/, "");
        if (!/^[A-Za-z0-9][A-Za-z0-9._+-]*$/.test(nm)) continue;
        if (seen[nm]) continue;
        seen[nm] = true;
        out.push({ name: nm, source: "rpm", summary: _plain(summary, MAX_DETAIL) });
    }
    return out;
}

// A directory listing from `ls -1Ap -- <dir>`, which appends "/" to
// directories and needs no parsing beyond that. `-A` so dotfiles appear but
// "." and ".." do not — a launcher that offers ".." as a result is offering the
// user a way to walk to / one Enter at a time.
//
// The listing is the DIRECTORY's, and the leaf the user is still typing is
// matched here rather than passed to the process. That is what makes typing
// inside a directory cost nothing: the argv does not change.
function parseDirListing(text) {
    var lines = String(text === undefined || text === null ? "" : text).split("\n");
    var out = [];
    for (var i = 0; i < lines.length; i++) {
        var n = lines[i];
        if (n === "" || n === "./" || n === "../") continue;
        var dir = n.charAt(n.length - 1) === "/";
        var name = dir ? n.slice(0, -1) : n;
        if (name === "") continue;
        out.push({ name: name, dir: dir });
    }
    return out;
}

// splitPath("~/Doc/pro") → { dir: "~/Doc/", leaf: "pro" }
//
// The split is at the last "/" so the directory is complete and the leaf is
// what is still being typed. A query with no "/" after the "~" is the home
// directory itself.
function splitPath(term) {
    var t = String(term === undefined || term === null ? "" : term);
    var i = t.lastIndexOf("/");
    if (i < 0) return { dir: t, leaf: "" };
    return { dir: t.slice(0, i + 1), leaf: t.slice(i + 1) };
}

// A "~/" prefix is expanded here rather than by a shell, because handing a path
// with a "~" in it to `bash -c` is how a path becomes a command. `home` comes
// from the host.
function expandHome(p, home) {
    var s = String(p === undefined || p === null ? "" : p);
    var h = typeof home === "string" && home !== "" ? home.replace(/\/+$/, "") : "";
    if (s === "~") return h === "" ? "" : h;
    if (s.slice(0, 2) === "~/") return h === "" ? "" : h + s.slice(1);
    return s;
}

// The listing command. An ARRAY, with the directory after `--` so a directory
// whose name begins with "-" cannot be read as a flag.
function listDirArgv(dir, home) {
    var abs = expandHome(dir, home);
    if (abs === "" || abs.charAt(0) !== "/") return null;
    // No ".." components: a path that walks upward out of what the user typed
    // is a path they did not ask for.
    if (abs.indexOf("/../") >= 0 || abs.slice(-3) === "/..") return null;
    return ["ls", "-1Ap", "--", abs];
}

// ─────────────────────────────────────────────────────────────────────────────
//  CALCULATOR AND UNIT CONVERSION
// ─────────────────────────────────────────────────────────────────────────────
//
// §15's example list includes "2.5 GB -> MB", which answer.js's arithmetic
// parser cannot do. It is added here rather than there because answer.js is the
// "?" mode's parser and "?" is the mode that can reach the network; a unit
// conversion must never be a reason to consider asking Wolfram|Alpha.
//
// Deliberately small and deliberately explicit about the one ambiguity that
// matters: GB is 10^9 and GiB is 2^30. A converter that quietly picks one is a
// converter that is wrong half the time, so both spellings exist and neither is
// an alias for the other.

var UNITS = {
    // bytes, decimal
    b: { d: "data", f: 1 },
    kb: { d: "data", f: 1e3 },  mb: { d: "data", f: 1e6 },
    gb: { d: "data", f: 1e9 },  tb: { d: "data", f: 1e12 },
    pb: { d: "data", f: 1e15 },
    // bytes, binary
    kib: { d: "data", f: 1024 },            mib: { d: "data", f: 1048576 },
    gib: { d: "data", f: 1073741824 },      tib: { d: "data", f: 1099511627776 },
    // length
    mm: { d: "length", f: 0.001 }, cm: { d: "length", f: 0.01 },
    m:  { d: "length", f: 1 },     km: { d: "length", f: 1000 },
    in: { d: "length", f: 0.0254 }, ft: { d: "length", f: 0.3048 },
    yd: { d: "length", f: 0.9144 }, mi: { d: "length", f: 1609.344 },
    // mass
    mg: { d: "mass", f: 1e-6 }, g: { d: "mass", f: 0.001 },
    kg: { d: "mass", f: 1 },    t: { d: "mass", f: 1000 },
    oz: { d: "mass", f: 0.0283495231 }, lb: { d: "mass", f: 0.45359237 },
    // time
    ms: { d: "time", f: 0.001 }, s: { d: "time", f: 1 },
    min: { d: "time", f: 60 },   h: { d: "time", f: 3600 },
    d: { d: "time", f: 86400 },  wk: { d: "time", f: 604800 }
};

// Temperature is affine, not a scale factor, so it cannot live in the table
// above and is handled separately rather than approximated into it.
var TEMPS = { c: true, f: true, k: true };

function _fmt(n) {
    if (!isFinite(n)) return "";
    var s = String(Number(n.toPrecision(12)));
    return s;
}

// convert("2.5 GB -> MB") → { valid, expression, formatted } — the same shape
// answer.js's calculate() returns, so the calculator provider can offer either
// through one row without the launcher caring which answered.
function convert(input) {
    var raw = String(input === undefined || input === null ? "" : input).trim();
    if (raw === "") return { valid: false };

    var m = /^(-?[0-9]+(?:\.[0-9]+)?)\s*([A-Za-z°]+)\s*(?:->|=>|>|to|in|as)\s*([A-Za-z°]+)$/
        .exec(raw);
    if (m === null) return { valid: false };

    var n = Number(m[1]);
    var from = m[2].toLowerCase().replace(/[°]/g, "");
    var to = m[3].toLowerCase().replace(/[°]/g, "");
    if (!isFinite(n)) return { valid: false };

    if (TEMPS[from] === true && TEMPS[to] === true) {
        var k = from === "c" ? n + 273.15 : from === "f" ? (n - 32) * 5 / 9 + 273.15 : n;
        var out = to === "c" ? k - 273.15 : to === "f" ? (k - 273.15) * 9 / 5 + 32 : k;
        return { valid: true, expression: raw,
                 formatted: _fmt(out) + " " + m[3].toUpperCase() };
    }

    var a = UNITS[from];
    var b = UNITS[to];
    if (a === undefined || b === undefined) return { valid: false };
    if (a.d !== b.d) return { valid: false };

    return { valid: true, expression: raw,
             formatted: _fmt(n * a.f / b.f) + " " + m[3] };
}

// ── the AI row, and why it is a hand-off and not a feature ───────────────────
//
// §15's example list includes "Claude: explain this screenshot". That is a
// screen capture, an image upload and a model call, which is §14's surface and
// a feature in its own right — not a launcher row. Building a second, worse
// version of it behind a search box would be the same mistake §3 names about
// the Agent Center being "a supervisor and navigator, not a replacement for the
// terminal".
//
// So the launcher NAVIGATES to it: an "ai" query offers a row that opens the
// Agent Center, where sessions actually live. Documented as a deliberate
// non-goal rather than left as a silent gap.
var AI_HANDOFF = {
    name: "Agents and AI",
    detail: "Open the Agent Center — sessions, requests and models",
    keywords: "ai claude codex agent model llm screenshot explain ask"
};

function _has(list, v) {
    for (var i = 0; i < (list || []).length; i++)
        if (list[i] === v) return true;
    return false;
}

// Node (tests) sees `module`; the QML engine does not, and ignores this. Same
// arrangement as answer.js and manifest.js.
if (typeof module !== "undefined" && module.exports)
    module.exports = {
        SCOPE: SCOPE,
        VERBS: VERBS,
        MIN_QUERY: MIN_QUERY,
        DEBOUNCE_MS: DEBOUNCE_MS,
        CACHE_PER_PROVIDER: CACHE_PER_PROVIDER,
        PROVIDERS: PROVIDERS,
        PROVIDER_IDS: PROVIDER_IDS,
        SETTINGS: SETTINGS,
        requestArgv: requestArgv,
        ROW_KINDS: ROW_KINDS,
        TIER: TIER,
        KLASS: KLASS,
        KLASS_LABELS: KLASS_LABELS,
        PERMISSION: PERMISSION,
        ACTIONS: ACTIONS,
        ACTION_IDS: ACTION_IDS,
        COMPOSITOR_ACTIONS: COMPOSITOR_ACTIONS,
        COMMIT: COMMIT,
        AI_HANDOFF: AI_HANDOFF,
        parseQuery: parseQuery,
        providerWants: providerWants,
        networkProviders: networkProviders,
        fold: fold,
        score: score,
        scoreFields: scoreFields,
        rowsFrom: rowsFrom,
        merge: merge,
        actionArgv: actionArgv,
        actionPreview: actionPreview,
        resolveArgv: resolveArgv,
        commitDecision: commitDecision,
        rowId: rowId,
        initialState: initialState,
        plan: plan,
        cached: cached,
        parseProjectList: parseProjectList,
        parseHostRegistry: parseHostRegistry,
        parsePackageSearch: parsePackageSearch,
        parseDirListing: parseDirListing,
        splitPath: splitPath,
        expandHome: expandHome,
        listDirArgv: listDirArgv,
        convert: convert
    };
