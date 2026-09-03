#!/usr/bin/env bash
# Run the CompositorService (§17 adapter facade) behavioural test.
#
# Quickshell refuses to import QML modules from outside the directory holding the
# entry point, so the test cannot live in tests/ and import ../src. It is staged
# into the repo root for the duration of the run and removed afterwards — the
# same arrangement run-service-tier-test.sh uses.
#
# Requires a Wayland session. Skips cleanly with status 0 when there is none, so
# CI without a display does not fail the build. The test reads live compositor
# state and deliberately never mutates it; see the header of the .qml.
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

staged="$root/.compositor-facade-test.qml"
cleanup() { rm -f "$staged"; rm -rf "${XDG_RUNTIME_DIR:-/tmp}/apex-compositor-test"; }
trap cleanup EXIT

cp "$here/compositor-facade-test.qml" "$staged"

out="$(QT_LOGGING_RULES="qml=true" timeout 90 quickshell -p "$staged" 2>&1 || true)"
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
