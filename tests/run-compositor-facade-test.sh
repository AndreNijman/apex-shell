#!/usr/bin/env bash
# Run the CompositorService (§17 adapter facade) behavioural test.
#
# Quickshell refuses to import QML modules from outside the directory holding the
# entry point, so the test cannot live in tests/ and import ../src. It is staged
# into the repo root for the duration of the run and removed afterwards — the
# same arrangement run-service-tier-test.sh uses.
#
# ── What it now measures, which is not quite what it used to ─────────────────
#
# This suite reads live compositor state. It used to read the DEVELOPER'S live
# compositor state, over the inherited WAYLAND_DISPLAY, and open its window on
# their desktop while doing so. It now stands up a headless labwc (or sway) from
# tests/lib/headless.sh and reads that.
#
# That is a coverage change and worth saying plainly: on a Hyprland desktop this
# used to exercise the Hyprland adapter, and now it exercises the wlroots one.
# Hyprland-specific facade coverage lives behind
# APEX_TEST_ALLOW_NESTED_ON_DESK=1 in tests/run-hypr-configerrors-test.sh; there
# is no way to get it without a Hyprland instance, and no way to get a Hyprland
# instance without a session to nest in (0.56.2 will not start headless on a GPU
# box with no DRM master — measured on katana, twice).
#
# The test deliberately never mutates the compositor it reads; see the .qml.
#
# Skips cleanly (status 0) without quickshell or without a compositor to host it.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"

headless_require quickshell

staged="$root/.compositor-facade-test.qml"
cleanup() {
    rm -f "$staged"
    rm -rf "${XDG_RUNTIME_DIR:-/tmp}/apex-compositor-test"
    headless_cleanup
}
trap cleanup EXIT INT TERM

headless_begin
headless_start || exit 0

# The suite asserts a toplevel exists before it reads the window list. An empty
# compositor would turn ten assertions into vacuous passes.
headless_filler || exit 1

cp "$here/compositor-facade-test.qml" "$staged"

out="$(QT_LOGGING_RULES="qml=true" timeout 120 quickshell -p "$staged" 2>&1 || true)"
echo "$out" | grep -E "PASS|FAIL|^\[|passed=" || true

if echo "$out" | grep -q "Failed to load configuration"; then
    echo "$out" | tail -30
    echo "RESULT: the test config failed to load"
    exit 1
fi

summary="$(echo "$out" | grep -o "passed=[0-9]* failed=[0-9]*" | tail -1)"
if [[ -z "$summary" ]]; then
    echo "$out" | tail -30
    echo "RESULT: the test never reached its summary"
    exit 1
fi

failed="${summary##*failed=}"
echo "RESULT: $summary"
[[ "$failed" -eq 0 ]]
