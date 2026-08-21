#!/usr/bin/env bash
# Run the display-scaling test.
#
# Quickshell refuses to import QML modules from outside the directory holding the
# entry point, so the test cannot live in tests/ and import ../src. It is staged
# into the repo root for the duration of the run and removed afterwards.
#
# Requires a Wayland session (quickshell needs a compositor). Skips cleanly with
# status 0 when there is none, so CI without a display does not fail the build.
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

staged="$root/.scaling-test.qml"
cleanup() { rm -f "$staged"; }
trap cleanup EXIT

cp "$here/scaling-test.qml" "$staged"

out="$(QT_LOGGING_RULES="qml=true" timeout 60 quickshell -p "$staged" 2>&1 || true)"
echo "$out" | grep -E "PASS|FAIL|^\[|passed=" || true

if echo "$out" | grep -q "Failed to load configuration"; then
    echo "$out" | tail -20
    echo "RESULT: the test config failed to load"
    exit 1
fi

if ! echo "$out" | grep -q "passed="; then
    echo "$out" | tail -20
    echo "RESULT: test did not run to completion"
    exit 1
fi

if echo "$out" | grep -q "FAIL"; then
    echo "RESULT: failing assertions"
    exit 1
fi

echo "RESULT: all assertions passed"
