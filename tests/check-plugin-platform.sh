#!/usr/bin/env bash
# Static invariants for the APEX Shell plugin platform (roadmap §16).
#
# ── Why this exists next to the other two ────────────────────────────────────
# §16's coverage is in three parts, and this is the part that holds the wiring:
#
#   tests/plugin-manifest-test.js   the DECISIONS — manifest validation, the
#                                   apiVersion policy, the source scan, the
#                                   network allowlist. Runs headless, on every
#                                   push, and carries the security weight.
#   tests/check-plugin-platform.sh  this file — that the decisions are actually
#                                   wired to anything, that every extension
#                                   point has exactly one host, and that the
#                                   shipped plugins obey their own rules.
#                                   Headless.
#   tests/run-plugin-host-test.sh   the BEHAVIOUR — discovery on a real
#                                   filesystem and crash isolation in a real
#                                   Loader. Needs Wayland, so it SKIPS on CI.
#
# That last line is why the first two are not optional. No CI runner has a
# compositor, so the behavioural suite always skips there, and a suite that
# skips proves nothing. This repo has shipped assertions that passed because
# they never ran, three separate times.
#
# Everything here is grep-able or a node invocation, and runs with no display.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
dir="$root/src/services/plugins"

pass=0
fail=0
ok()   { echo "  PASS  $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail + 1)); }

# want <description> <command...> — runs the command and records the verdict.
# Deliberately not `cmd; check $?`: ShellCheck SC2319 is right that a $? read
# after a `[ ]` is a trap waiting for someone to insert a line between them.
want() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

# ── The pieces exist ─────────────────────────────────────────────────────────
want "manifest.js exists and is non-empty"       test -s "$dir/manifest.js"
want "PluginService.qml exists and is non-empty" test -s "$dir/PluginService.qml"
want "the plugin docs exist"                     test -s "$root/docs/plugins.md"
want "the headless decision suite exists"        test -s "$root/tests/plugin-manifest-test.js"
want "the behavioural harness is executable"     test -x "$root/tests/run-plugin-host-test.sh"
want "the behavioural test exists"               test -s "$root/tests/plugin-host-test.qml"

# ── One host per extension point, and no name without one ────────────────────
# EXTENSION_POINTS in manifest.js is what a manifest is validated against, so a
# name on that list with no host behind it is a plugin that loads, is granted,
# and is then mounted by nothing — indistinguishable to its author from a bug in
# their own code. The pairing is asserted in both directions below: every host
# file exists and mounts the point it claims, and every name on the list appears
# in exactly one host.
bar_host="$root/src/modules/Right/PluginWidgets.qml"
launcher_host="$root/src/services/PluginLauncher.qml"
tile_host="$root/src/services/home/PluginTiles.qml"

want "the bar-widget host exists"           test -s "$bar_host"
want "the launcher-provider host exists"    test -s "$launcher_host"
want "the quick-settings-tile host exists"  test -s "$tile_host"

want "the bar-widget host mounts bar-widget" \
    grep -q 'pluginsFor("bar-widget")' "$bar_host"
want "the launcher host mounts launcher-provider" \
    grep -q 'pluginsFor("launcher-provider")' "$launcher_host"
want "the tile host mounts quick-settings-tile" \
    grep -q 'pluginsFor("quick-settings-tile")' "$tile_host"

# The other direction: read the list out of the shipped file rather than
# repeating it here, so adding a name to manifest.js without writing a host
# fails this loop instead of passing a check that was never updated.
points="$(sed -n 's/^var EXTENSION_POINTS = \[\(.*\)\];$/\1/p' "$dir/manifest.js" \
          | tr -d '" ' | tr ',' ' ')"
if [ -z "$points" ]; then
    bad "EXTENSION_POINTS could not be read out of manifest.js"
else
    ok "EXTENSION_POINTS is readable from manifest.js ($points)"
    for p in $points; do
        n="$(grep -l "pluginsFor(\"$p\")" "$bar_host" "$launcher_host" "$tile_host" \
             2>/dev/null | wc -l)"
        if [ "$n" -eq 1 ]; then
            ok "$p is mounted by exactly one host"
        else
            bad "$p is mounted by $n hosts; every extension point needs exactly one"
        fi
        want "$p is documented" grep -q -- "$p" "$root/docs/plugins.md"
    done
fi

# ── Registration of the two new hosts ────────────────────────────────────────
# Both are loaded THROUGH a qmldir — AppLauncher through src/services/qmldir and
# QuickSettings through src/services/home/qmldir — so their own directories are
# not on the import path and implicit sibling resolution gives "is not a type".
# That failure has already cost this repo two debugging sessions, via the Agent
# Center and again via the compositor backends.
want "PluginLauncher is declared in src/services/qmldir" \
    grep -q "^PluginLauncher PluginLauncher.qml$" "$root/src/services/qmldir"
want "PluginTiles is declared in src/services/home/qmldir" \
    grep -qE "^PluginTiles +PluginTiles.qml$" "$root/src/services/home/qmldir"

want "the launcher host is instantiated by AppLauncher" \
    grep -q "PluginLauncher {" "$root/src/services/AppLauncher.qml"
want "provider rows reach the launcher's result list" \
    grep -q "concat(providers.rows)" "$root/src/services/AppLauncher.qml"
want "the tile host is instantiated by QuickSettings" \
    grep -q "PluginTiles { id: pluginTiles }" "$root/src/services/home/QuickSettings.qml"
want "plugin tiles reach the quick-settings grid" \
    grep -q "model: pluginTiles.tiles" "$root/src/services/home/QuickSettings.qml"

# ── Registration ─────────────────────────────────────────────────────────────
# PluginService goes in src/qmldir, next to CompositorService — that is the
# module the bar host reaches through "../../". Registering it in
# src/services/qmldir instead gives "Member not found on type" for every
# binding, which reads as a dozen separate mistakes rather than one.
want "PluginService is a singleton in src/qmldir" \
    grep -q "^singleton PluginService 1.0 services/plugins/PluginService.qml$" "$root/src/qmldir"

if grep -q "^singleton PluginService " "$root/src/services/qmldir" 2>/dev/null; then
    bad "PluginService is registered in two modules"
else
    ok "PluginService is registered in exactly one module"
fi

# The host is a plain sibling of the other bar widgets, so it resolves
# implicitly from src/modules/Right/ — no qmldir entry, and none wanted.
want "the bar-widget host is mounted in the bar" \
    grep -q "PluginWidgets" "$root/src/modules/Right/RightContent.qml"

# ── One source of truth for the decisions ────────────────────────────────────
# The whole point of manifest.js is that the shell and the tests run the same
# file. A second copy of any of this logic in QML would drift, and the drift
# would be silent and security-relevant.
want "PluginService imports the shared decision logic" \
    grep -q 'import "manifest.js" as Manifest' "$dir/PluginService.qml"

for fn in validateManifest scanSource permitsUrl permitsPath curlArgv validId; do
    want "PluginService routes $fn through manifest.js" \
        grep -q "Manifest\.$fn(" "$dir/PluginService.qml"
done

# The same rule for the two hosts that render plugin-supplied strings. Each
# imports the shipped manifest.js by relative path and calls its sanitiser;
# a host that filtered rows or tiles itself would be a second copy of the
# allowlist, free to drift from the one the node suite exercises.
want "the launcher host imports the shared decision logic" \
    grep -q 'import "plugins/manifest.js" as Manifest' "$launcher_host"
want "the tile host imports the shared decision logic" \
    grep -q 'import "../plugins/manifest.js" as Manifest' "$tile_host"
want "the launcher host routes rows through launcherResults()" \
    grep -q "Manifest.launcherResults(" "$launcher_host"
want "the launcher host routes the consult decision through manifest.js" \
    grep -q "Manifest.launcherWantsProviders(" "$launcher_host"
want "the tile host routes tiles through quickTile()" \
    grep -q "Manifest.quickTile(" "$tile_host"

# The hosts must not build their own row or tile objects. `kind: "plugin"` is
# set inside launcherResults() and is what AppLauncher dispatches on, so a host
# writing it would be choosing which branch of activate() runs.
for f in "$launcher_host" "$tile_host"; do
    if grep -nE '(kind|pluginId)\s*:\s*"' "$f"; then
        bad "$(basename "$f") builds its own row/tile object; it must call manifest.js"
    else
        ok "$(basename "$f") builds no row or tile object of its own"
    fi
done

# ── A plugin row must never reach the launcher's exec paths ──────────────────
# AppLauncher.activate() dispatches on the fields it finds on a row: `entry`
# runs a DesktopEntry, and falling through hands `exec` to
# `bash -c "setsid " + exec`. A provider row that reached either branch would be
# arbitrary command execution granted to a plugin that declared no permissions —
# the `system` permission this shell refuses at load, through the back door.
#
# launcherResults() cannot emit a row carrying `entry` or `exec` (asserted in
# the node suite, which builds a row out of an allowlist). This is the second
# lock on the same door: the plugin branch has to come FIRST.
al="$root/src/services/AppLauncher.qml"
want "the launcher has a branch for plugin rows" \
    grep -q 'entry.kind === "plugin"' "$al"

n_plugin="$(grep -n 'entry.kind === "plugin"' "$al" | head -1 | cut -d: -f1)"
n_entry="$(grep -n 'if (entry.entry)' "$al" | head -1 | cut -d: -f1)"
n_launch="$(grep -n 'launch(entry.exec)' "$al" | head -1 | cut -d: -f1)"
if [ -n "$n_plugin" ] && [ -n "$n_entry" ] && [ -n "$n_launch" ] \
   && [ "$n_plugin" -lt "$n_entry" ] && [ "$n_plugin" -lt "$n_launch" ]; then
    ok "the plugin branch precedes both exec paths (line $n_plugin < $n_entry, $n_launch)"
else
    bad "the plugin branch does not precede the DesktopEntry and Exec paths (plugin=$n_plugin entry=$n_entry launch=$n_launch)"
fi

# Activation copies the row's TITLE — the string the user just read. A row has
# no hidden value field, so there is nothing that could put something other
# than the visible text on the clipboard.
want "activating a plugin row copies the visible title" \
    grep -q "ClipboardService.copyText(entry.name)" "$al"

# ── Plugin tiles go last in the quick-settings grid ──────────────────────────
# The shell's own tiles keep the positions users have muscle memory for; a
# plugin appearing must not move Wi-Fi. The shell's tiles all bind `on:` to a
# `root.` or `ShellState.` expression, and the plugin delegate binds to
# `modelData.on`, so the ordering is a line-number comparison.
qs="$root/src/services/home/QuickSettings.qml"
n_pluginrow="$(grep -n 'on: *modelData.on' "$qs" | head -1 | cut -d: -f1)"
n_lastown="$(grep -nE '^\s+on: *(root\.|ShellState\.)' "$qs" | tail -1 | cut -d: -f1)"
if [ -n "$n_pluginrow" ] && [ -n "$n_lastown" ] && [ "$n_pluginrow" -gt "$n_lastown" ]; then
    ok "plugin tiles come after every shell tile (line $n_pluginrow > $n_lastown)"
else
    bad "plugin tiles are not last in the grid (plugin=$n_pluginrow lastown=$n_lastown)"
fi

# ── Idle cost, for the hosts too ─────────────────────────────────────────────
# The launcher host debounces third-party code off the keystroke path. That
# timer is one-shot; a repeating timer here would poll every provider forever
# while the launcher is closed, which is exactly what the PluginService check
# below exists to prevent and there is no reason the hosts get an exemption.
for f in "$launcher_host" "$tile_host" "$bar_host"; do
    if grep -nE '^\s*repeat:\s*true' "$f"; then
        bad "$(basename "$f") has a repeating timer"
    else
        ok "$(basename "$f") has no repeating timer"
    fi
done

n_hint="$(grep -cE '^\s*interval:\s*[0-9]+' "$launcher_host")"
n_hshot="$(grep -cE '^\s*repeat:\s*false' "$launcher_host")"
if [ "$n_hint" -eq "$n_hshot" ]; then
    ok "every timer in the launcher host is explicitly one-shot"
else
    bad "the launcher host has $n_hint timers but $n_hshot say repeat: false"
fi

# ── A data plugin must not be able to paint ──────────────────────────────────
# The whole difference between bar-widget and the other two points is that a
# launcher provider and a tile plugin hand back DATA and the shell draws it. If
# their hosts were visible, a plugin's root item would be in a rendered scene
# and could paint over whatever the host happens to sit on top of — in the
# tile's case, the quick-settings grid, which is the worst surface in the shell
# to let third-party code draw on.
for f in "$launcher_host" "$tile_host"; do
    n_invisible="$(grep -cE '^\s*visible: false' "$f")"
    if [ "$n_invisible" -ge 2 ]; then
        ok "$(basename "$f") is invisible, and so is each plugin mount"
    else
        bad "$(basename "$f") has $n_invisible 'visible: false' declarations; want the host and each mount"
    fi
done

# No hand-rolled second implementation. If any of these appear in the QML, the
# decision has been copied out of the file the tests exercise.
if grep -nE 'indexOf\("@"\)|\.endsWith\(|scheme\s*!==' "$dir/PluginService.qml"; then
    bad "PluginService re-implements URL parsing; it must call manifest.js"
else
    ok "PluginService does not re-implement URL parsing"
fi

# ── The network gate cannot be routed around ─────────────────────────────────
# The plugin never spawns anything; the host builds the argv. If PluginService
# ever constructs its own curl command, the --max-redirs 0 / --proto =https
# guarantees in curlArgv() stop being guarantees.
want "the fetch argv comes from curlArgv()" \
    grep -q "Manifest.curlArgv(url)" "$dir/PluginService.qml"

if grep -nE '"(curl|wget)"' "$dir/PluginService.qml"; then
    bad "PluginService names a fetch binary directly; use Manifest.curlArgv()"
else
    ok "PluginService names no fetch binary of its own"
fi

# Redirects defeat a URL allowlist completely and only ever against a hostile
# server, so nothing in ordinary testing reveals it. Asserted in the node suite
# too; duplicated here because it is the single easiest thing to lose.
want "curlArgv refuses to follow redirects" \
    grep -q '"--max-redirs", "0"' "$dir/manifest.js"
want "curlArgv pins the protocol to https" \
    grep -q '"--proto", "=https"' "$dir/manifest.js"

if grep -nE '"-L"|"--location"' "$dir/manifest.js"; then
    bad "curlArgv follows redirects; the host allowlist would be decorative"
else
    ok "curlArgv has no -L"
fi

# No plugin-controlled value may reach a shell. The repo already carries this
# invariant for InputService and DisplayService; here the data is a URL chosen
# by third-party code, which is strictly worse.
if grep -nE '"bash", *"-c",[^]]*\+' "$dir/PluginService.qml"; then
    bad "PluginService splices a value into a shell command"
else
    ok "PluginService splices nothing into a shell command"
fi

# ── Idle cost ────────────────────────────────────────────────────────────────
# The telemetry services were rewritten to stop forking at idle. A plugin
# rescan on a timer would put that straight back, with no visible symptom
# beyond a battery complaint weeks later. The only intervals allowed here are
# the one-shot settle timers that stop a callback waiting forever on a process
# that never started.
# Checked by repeat, not by interval. An earlier version whitelisted
# `interval: 200` and flagged everything else, which is wrong in both
# directions: changing a settle timer to 250 would fail the build with "poll
# interval", and a genuine poller set to 200 would sail through. A one-shot
# timer cannot poll whatever its interval is, so `repeat` is the property that
# carries the meaning.
if grep -nE '^\s*repeat:\s*true' "$dir/PluginService.qml"; then
    bad "PluginService has a repeating timer; discovery must be one-shot"
else
    ok "PluginService has no repeating timer"
fi

n_interval="$(grep -cE '^\s*interval:\s*[0-9]+' "$dir/PluginService.qml")"
n_oneshot="$(grep -cE '^\s*repeat:\s*false' "$dir/PluginService.qml")"
if [ "$n_interval" -eq "$n_oneshot" ]; then
    ok "every timer in PluginService is explicitly one-shot"
else
    bad "PluginService has $n_interval timers but $n_oneshot say repeat: false"
fi

if grep -qE 'property var _[A-Za-z]+:\s*PluginService\b' "$root/shell.qml"; then
    bad "PluginService is force-loaded in shell.qml"
else
    ok "PluginService is not force-instantiated at startup"
fi

# ── Crash isolation ──────────────────────────────────────────────────────────
# §16's "crash isolation where practical". The practical mechanism is a Loader
# per plugin whose Error status is handled; without the handler a broken plugin
# is a silent blank in the bar and gets retried on every layout pass.
# Applied to every host, not just the first one written. A point that mounts
# plugins without a Loader per plugin is a point where one bad plugin is a shell
# fault, and "the new host forgot the isolation the old host has" is the exact
# shape of regression this loop exists to catch.
for f in "$bar_host" "$launcher_host" "$tile_host"; do
    b="$(basename "$f")"
    want "$b gives each plugin its own Loader" grep -q "Loader {" "$f"
    want "$b handles the error status"          grep -q "Loader.Error" "$f"
    want "$b records a load failure"            grep -q "reportLoadError" "$f"
    # The bar is the always-mapped window and the launcher is on the keystroke
    # path; a plugin must not be able to stall either.
    want "$b loads plugins asynchronously"      grep -q "asynchronous: true" "$f"
done
want "PluginService can receive a load failure" \
    grep -q "function reportLoadError" "$dir/PluginService.qml"
# A widget claiming ten thousand pixels must not push the clock off screen.
# Only the bar-widget point needs this: a provider and a tile do not paint, so
# there is no size for them to lie about.
want "a bar widget's width is clamped" grep -q "maxWidgetWidth" "$bar_host"

# ── Plugins are loaded by URL, never by type name ────────────────────────────
# A bare type name cannot work for a plugin — it is not in any qmldir — and the
# "is not a type" failure mode has already cost this repo a debugging session
# via the Agent Center and again via the compositor backends.
for f in "$bar_host" "$launcher_host" "$tile_host"; do
    want "$(basename "$f") loads plugins from a URL" \
        grep -q "source: mount.modelData ? mount.modelData.entryUrl" "$f"
done
want "a refused plugin has no URL to load" \
    grep -q 'rec.state === "loaded"' "$dir/PluginService.qml"

# ── The honesty paragraph ────────────────────────────────────────────────────
# The one claim that must never drift. QML plugins run in-process; the model
# gates the API and the scan defends the API's monopoly, and neither confines
# hostile code. If someone deletes this because it reads as pessimistic, the
# platform starts promising something it does not do.
for f in "$dir/manifest.js" "$dir/PluginService.qml" "$root/docs/plugins.md"; do
    want "$(basename "$f") states that this is not a sandbox" \
        grep -qi "not a sandbox" "$f"
done
want "the docs name the permissions that are not implemented" \
    grep -qi "not implemented" "$root/docs/plugins.md"

# ── The shipped plugins obey their own rules ─────────────────────────────────
# These are the only plugins whose validity this repo controls, so each is
# checked against the very validator it will meet at runtime. One of them has
# been refused by its own scan already — for documenting, in a comment, the
# constructs plugins may not use.
#
# There is one example per extension point, and that is checked below rather
# than assumed: a point whose example is missing is a point nobody has run a
# plugin against, which is the state §16's first round deliberately avoided.
#
# The symlink count is the `files` permission's structural half, repeated here
# for the shipped plugins. A plugin directory may contain NO symlink at any
# depth: permitsPath() rejects "..", absolute paths and dot-components, and none
# of that resolves links, so a shipped `data` symlink would read outside the
# plugin while containing nothing any string check could object to.
for e in "$root"/plugins/*/; do
    e="${e%/}"
    id="$(basename "$e")"
    want "$id has a manifest" test -s "$e/plugin.json"
    n_qml="$(find "$e" -maxdepth 1 -name '*.qml' -type f | wc -l)"
    want "$id is a single .qml (apiVersion 1 allows one)" test "$n_qml" -eq 1
    n_link="$(find "$e" -type l 2>/dev/null | wc -l)"
    want "$id ships no symlink" test "$n_link" -eq 0
done

if command -v node >/dev/null 2>&1; then
    if node -e '
        const fs = require("fs"), path = require("path");
        const root = process.argv[1];
        const M = require(path.join(root, "src/services/plugins/manifest.js"));
        const dirs = fs.readdirSync(path.join(root, "plugins")).sort();
        const seen = {};
        let bad = 0;
        for (const id of dirs) {
            const d = path.join(root, "plugins", id);
            const g = M.validateManifest(fs.readFileSync(path.join(d, "plugin.json"), "utf8"), id);
            if (!g.ok) { console.error(id + ": manifest refused: " + g.reason + " " + g.detail); bad++; continue }
            const s = M.scanSource(fs.readFileSync(path.join(d, g.entry), "utf8"));
            if (!s.ok) { console.error(id + ": source refused: " + s.reason + " " + s.detail); bad++; continue }
            // No shipped example may make a live network call. These load on a
            // developer machine at shell start; an example that fetched
            // something would be a request nobody asked for, and the granted
            // network path is checked by shape rather than by fetching
            // everywhere else in this suite for the same reason.
            if (g.permissions.indexOf("network") >= 0) {
                console.error(id + ": a shipped example must not hold `network`"); bad++;
            }
            if (M.EXTENSION_POINTS.indexOf(g.extensionPoint) < 0) {
                console.error(id + ": unknown extension point " + g.extensionPoint); bad++;
            }
            seen[g.extensionPoint] = id;
        }
        // One example per point, so every point has been run against a real
        // plugin rather than only against fixtures a test wrote.
        for (const p of M.EXTENSION_POINTS)
            if (!seen[p]) { console.error("no shipped example for " + p); bad++ }
        // And at least one of them must still demonstrate a permission, or the
        // permission model is exercised by nothing this repo ships.
        const demo = dirs.some((id) => {
            const g = M.validateManifest(
                fs.readFileSync(path.join(root, "plugins", id, "plugin.json"), "utf8"), id);
            return g.ok && g.permissions.length > 0;
        });
        if (!demo) { console.error("no shipped example demonstrates a permission"); bad++ }
        if (bad > 0) process.exit(1);
    ' "$root"; then
        ok "every shipped plugin validates against the real validator"
    else
        bad "a shipped plugin is refused by its own platform"
    fi

    # ── The launcher allowlist, duplicated here on purpose ───────────────────
    # Asserted in the node suite too. It is repeated here for the same reason
    # curlArgv's --max-redirs is: it is the single easiest thing to lose, and
    # losing it is invisible — a row carrying `exec` looks like any other row
    # right up until AppLauncher hands it to `bash -c`.
    if node -e '
        const path = require("path");
        const M = require(path.join(process.argv[1], "src/services/plugins/manifest.js"));
        const g = M.validateManifest({ id: "p", name: "P", version: "1.0", apiVersion: "1.1",
                                       entry: "P.qml", extensionPoint: "launcher-provider" }, "p");
        if (!g.ok) { console.error("fixture invalid: " + g.reason); process.exit(1) }
        const row = M.launcherResults(g, [{ title: "t", exec: "poweroff",
                                            entry: {}, command: ["sh"], kind: "app" }])[0];
        if (!row) { console.error("a valid row was dropped"); process.exit(1) }
        for (const k of ["exec", "entry", "command", "value", "id"])
            if (row[k] !== undefined) { console.error("a row carried " + k); process.exit(1) }
        if (row.kind !== "plugin") { console.error("a plugin chose its own row kind"); process.exit(1) }
        const t = M.validateManifest({ id: "t", name: "T", version: "1.0", apiVersion: "1.1",
                                       entry: "T.qml", extensionPoint: "quick-settings-tile" }, "t");
        const tile = M.quickTile(t, { label: "L", command: ["nmcli"], exec: "poweroff" });
        for (const k of ["command", "exec"])
            if (tile[k] !== undefined) { console.error("a tile carried " + k); process.exit(1) }
        if (tile.on !== false) { console.error("a tile with no `on` is not off"); process.exit(1) }
    ' "$root"; then
        ok "plugin output cannot carry an exec, an entry or a command"
    else
        bad "plugin output can smuggle a field the shell dispatches on"
    fi

    # The decision suite itself. Running it from here as well means one command
    # gives a complete headless verdict on §16.
    if node "$root/tests/plugin-manifest-test.js" >/dev/null 2>&1; then
        ok "the headless decision suite passes"
    else
        bad "the headless decision suite fails; run node tests/plugin-manifest-test.js"
    fi
else
    bad "node is not installed; the decision suite cannot run"
fi

# ── The plugin directory is a documented location, not a guess ───────────────
want "PluginService looks under ~/.config/apex-shell/plugins" \
    grep -q '/.config/apex-shell/plugins' "$dir/PluginService.qml"
want "the plugin directory is overridable so tests need not use the real one" \
    grep -q "property string pluginDir" "$dir/PluginService.qml"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
