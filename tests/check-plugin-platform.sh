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
#                                   wired to anything, and that the shipped
#                                   plugin obeys its own rules. Headless.
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
want "the bar-widget host exists"                test -s "$root/src/modules/Right/PluginWidgets.qml"
want "the plugin docs exist"                     test -s "$root/docs/plugins.md"
want "the headless decision suite exists"        test -s "$root/tests/plugin-manifest-test.js"
want "the behavioural harness is executable"     test -x "$root/tests/run-plugin-host-test.sh"
want "the behavioural test exists"               test -s "$root/tests/plugin-host-test.qml"

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
if grep -nE '^\s*interval:\s*[0-9]+' "$dir/PluginService.qml" \
     | grep -vE 'interval: 200'; then
    bad "PluginService has a poll interval; discovery must be one-shot"
else
    ok "PluginService has no poll timer"
fi

if grep -nE '^\s*repeat:\s*true' "$dir/PluginService.qml"; then
    bad "PluginService has a repeating timer; discovery must be one-shot"
else
    ok "PluginService has no repeating timer"
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
want "each plugin sits in its own Loader" \
    grep -q "Loader {" "$root/src/modules/Right/PluginWidgets.qml"
want "the Loader handles the error status" \
    grep -q "Loader.Error" "$root/src/modules/Right/PluginWidgets.qml"
want "a load failure is recorded against the plugin" \
    grep -q "reportLoadError" "$root/src/modules/Right/PluginWidgets.qml"
want "PluginService can receive a load failure" \
    grep -q "function reportLoadError" "$dir/PluginService.qml"
# The bar is the always-mapped window; a plugin must not be able to stall its
# first paint.
want "plugins load asynchronously" \
    grep -q "asynchronous: true" "$root/src/modules/Right/PluginWidgets.qml"
# A widget claiming ten thousand pixels must not push the clock off screen.
want "a plugin's width is clamped" \
    grep -q "maxWidgetWidth" "$root/src/modules/Right/PluginWidgets.qml"

# ── Plugins are loaded by URL, never by type name ────────────────────────────
# A bare type name cannot work for a plugin — it is not in any qmldir — and the
# "is not a type" failure mode has already cost this repo a debugging session
# via the Agent Center and again via the compositor backends.
want "the host loads plugins from a URL" \
    grep -q "source: mount.modelData ? mount.modelData.entryUrl" \
        "$root/src/modules/Right/PluginWidgets.qml"
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

# ── The shipped plugin obeys its own rules ───────────────────────────────────
# The reference plugin is the one plugin whose validity this repo controls, so
# it is checked against the very validator it will meet at runtime. It has been
# refused by its own scan once already — for documenting, in a comment, the
# constructs plugins may not use.
example="$root/plugins/apex-worldclock"
want "the example plugin has a manifest" test -s "$example/plugin.json"
want "the example plugin has its entry"  test -s "$example/Widget.qml"

n_qml="$(find "$example" -maxdepth 1 -name '*.qml' -type f | wc -l)"
want "the example plugin is a single .qml (apiVersion 1 allows one)" \
    test "$n_qml" -eq 1

if command -v node >/dev/null 2>&1; then
    if node -e '
        const fs = require("fs"), path = require("path");
        const M = require(path.join(process.argv[1], "src/services/plugins/manifest.js"));
        const d = path.join(process.argv[1], "plugins/apex-worldclock");
        const g = M.validateManifest(fs.readFileSync(path.join(d, "plugin.json"), "utf8"),
                                     "apex-worldclock");
        if (!g.ok) { console.error("manifest refused: " + g.reason + " " + g.detail); process.exit(1) }
        const s = M.scanSource(fs.readFileSync(path.join(d, g.entry), "utf8"));
        if (!s.ok) { console.error("source refused: " + s.reason + " " + s.detail); process.exit(1) }
        if (g.permissions.indexOf("files") < 0) {
            console.error("the example no longer demonstrates a permission"); process.exit(1)
        }
        if (g.permissions.indexOf("network") >= 0) {
            console.error("the example must not ship a live network call in the bar");
            process.exit(1)
        }
    ' "$root"; then
        ok "the example plugin validates against the real validator"
    else
        bad "the example plugin is refused by its own platform"
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
