#!/usr/bin/env bash
# Run the plugin platform (§16) behavioural test.
#
# Quickshell refuses to import QML modules from outside the directory holding
# the entry point, so the test cannot live in tests/ and import ../src. It is
# staged into the repo root for the duration of the run and removed afterwards —
# the same arrangement run-compositor-facade-test.sh uses.
#
# Requires a Wayland session. Skips cleanly with status 0 when there is none, so
# CI without a display does not fail the build. THE STATIC HALF IS NOT OPTIONAL
# BECAUSE OF THIS: tests/check-plugin-platform.sh and
# tests/plugin-manifest-test.js both run headless and carry the coverage that
# this file cannot, because no CI runner has a compositor and a suite that skips
# proves nothing.
#
# ── This test never touches the real plugin directory ────────────────────────
# Everything below happens in a fixture tree under XDG_RUNTIME_DIR, and the QML
# points PluginService.pluginDir at it. The developer's own
# ~/.config/apex-shell/plugins is read once at singleton construction (a
# directory listing, nothing more) and never written. An earlier suite in this
# repo reconfigured the developer's live desktop; that is not happening again.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

if ! command -v quickshell >/dev/null 2>&1; then
    echo "SKIP: quickshell not installed"
    exit 0
fi

if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
    echo "SKIP: no WAYLAND_DISPLAY; quickshell needs a compositor"
    exit 0
fi

fixtures="${XDG_RUNTIME_DIR:-/tmp}/apex-plugin-test"
staged="$root/.plugin-host-test.qml"
cleanup() { rm -f "$staged"; rm -rf "$fixtures"; }
trap cleanup EXIT

# ── The fixture tree ─────────────────────────────────────────────────────────
# One directory per case. The names are asserted by id in the QML, so adding a
# case here means adding an assertion there — a fixture nobody checks is worse
# than no fixture.
rm -rf "$fixtures"
mkdir -p "$fixtures/plugins"
p="$fixtures/plugins"

manifest() { # manifest <dir> <json>
    mkdir -p "$p/$1"
    printf '%s\n' "$2" > "$p/$1/plugin.json"
}
widget() {  # widget <dir> <file> <qml>
    mkdir -p "$p/$1"
    printf '%s\n' "$3" > "$p/$1/$2"
}

ok_widget='import QtQuick
Item { property var api: null; implicitWidth: 10; implicitHeight: 10 }'

# 1. Valid, holds `files`, and has a config file to read.
manifest good '{"id":"good","name":"Good","version":"1.0.0","apiVersion":"1.0","entry":"Widget.qml","extensionPoint":"bar-widget","permissions":["files"]}'
widget good Widget.qml "$ok_widget"
printf '%s\n' '{"hello":"world"}' > "$p/good/config.json"

# 2. Valid, asks for nothing. The control for every permission assertion.
manifest quiet '{"id":"quiet","name":"Quiet","version":"1.0.0","apiVersion":"1.0","entry":"Widget.qml","extensionPoint":"bar-widget"}'
widget quiet Widget.qml "$ok_widget"

# 3. Valid, holds `network` scoped to one host.
manifest netty '{"id":"netty","name":"Netty","version":"1.0.0","apiVersion":"1.0","entry":"Widget.qml","extensionPoint":"bar-widget","permissions":["network"],"network":["api.github.com"]}'
widget netty Widget.qml "$ok_widget"

# 4. Built against a future API.
manifest oldapi '{"id":"oldapi","name":"Future","version":"1.0.0","apiVersion":"2.0","entry":"Widget.qml","extensionPoint":"bar-widget"}'
widget oldapi Widget.qml "$ok_widget"

# 5. Reaches past the API for raw capability.
manifest sneaky '{"id":"sneaky","name":"Sneaky","version":"1.0.0","apiVersion":"1.0","entry":"Widget.qml","extensionPoint":"bar-widget"}'
widget sneaky Widget.qml 'import QtQuick
import Quickshell.Io
Item { property var api: null }'

# 6. Asks for a permission this shell will not grant.
manifest secretive '{"id":"secretive","name":"Secretive","version":"1.0.0","apiVersion":"1.0","entry":"Widget.qml","extensionPoint":"bar-widget","permissions":["secrets"]}'
widget secretive Widget.qml "$ok_widget"

# 7. More than one .qml — apiVersion 1 allows exactly one.
manifest twofiles '{"id":"twofiles","name":"Two","version":"1.0.0","apiVersion":"1.0","entry":"Widget.qml","extensionPoint":"bar-widget"}'
widget twofiles Widget.qml "$ok_widget"
widget twofiles Helper.qml "$ok_widget"

# 8. Manifest id does not match the directory it sits in.
manifest mismatch '{"id":"somethingelse","name":"Mismatch","version":"1.0.0","apiVersion":"1.0","entry":"Widget.qml","extensionPoint":"bar-widget"}'
widget mismatch Widget.qml "$ok_widget"

# 9. Passes every static check and then fails to load. This is the crash
#    isolation case: NotARealType is not a forbidden construct, so the scan
#    lets it through and the QML engine rejects it at load.
manifest broken '{"id":"broken","name":"Broken","version":"1.0.0","apiVersion":"1.0","entry":"Widget.qml","extensionPoint":"bar-widget"}'
widget broken Widget.qml 'import QtQuick
Item { property var api: null; NotARealType { } }'

# 10. A directory with no manifest is not a plugin and must not be enumerated.
mkdir -p "$p/nomanifest"
widget nomanifest Widget.qml "$ok_widget"

cp "$here/plugin-host-test.qml" "$staged"

# APEX_PLUGIN_REPO points at the plugins this repo ships, so the last phases
# exercise apex-worldclock itself and not another fixture.
out="$(APEX_PLUGIN_FIXTURES="$p" APEX_PLUGIN_REPO="$root/plugins" \
        QT_LOGGING_RULES="qml=true" \
        timeout 90 quickshell -p "$staged" 2>&1 || true)"
echo "$out" | grep -E "PASS|FAIL|^\[|passed=" || true

if echo "$out" | grep -q "Failed to load configuration"; then
    echo "$out" | tail -30
    echo "RESULT: the test config failed to load"
    exit 1
fi

if ! echo "$out" | grep -q "passed="; then
    echo "$out" | tail -30
    echo "RESULT: the test never reached its summary"
    exit 1
fi

# `set +e` around the pipeline: a non-zero grep on a matching line still trips
# pipefail, which is how a passing suite reported failure here before.
set +e
summary="$(echo "$out" | grep -o "passed=[0-9]* failed=[0-9]*" | tail -1)"
failed="$(echo "$summary" | grep -o "failed=[0-9]*" | grep -o "[0-9]*")"
set -e

echo "RESULT: $summary"
[[ "$failed" == "0" ]]
