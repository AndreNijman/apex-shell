#!/usr/bin/env bash
# Run the display-scaling test.
#
# Quickshell refuses to import QML modules from outside the directory holding the
# entry point, so the test cannot live in tests/ and import ../src. It is staged
# into the repo root for the duration of the run and removed afterwards.
#
# ── On a compositor of its own ───────────────────────────────────────────────
#
# quickshell opens a window, and this used to open it on the inherited
# WAYLAND_DISPLAY — the developer's session, whenever there was one. It now
# takes a headless wlroots compositor from tests/lib/headless.sh, with a private
# HOME, which the scaling suite wants anyway: it drives Theme.scale through
# SettingsService, and SettingsService persists, so a crash midway used to leave
# the live shell at whatever scale the matrix had reached.
#
# Skips cleanly (status 0) without quickshell or without a compositor to host it.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"

headless_require quickshell

staged="$root/.scaling-test.qml"
cleanup() { rm -f "$staged"; headless_cleanup; }
trap cleanup EXIT INT TERM

headless_begin
headless_start || exit 0

cp "$here/scaling-test.qml" "$staged"

out="$(QT_LOGGING_RULES="qml=true" timeout 120 quickshell -p "$staged" 2>&1 || true)"
echo "$out" | grep -E "PASS|FAIL|^\[|passed=" || true

if echo "$out" | grep -q "Failed to load configuration"; then
    echo "$out" | tail -20
    echo "RESULT: the test config failed to load"
    exit 1
fi

summary="$(echo "$out" | grep -o 'passed=[0-9]* failed=[0-9]*' | tail -1)"
if [[ -z "$summary" ]]; then
    echo "$out" | tail -20
    echo "RESULT: test did not run to completion"
    exit 1
fi

failed="${summary##*failed=}"
echo "RESULT: $summary"
[[ "$failed" -eq 0 ]]
