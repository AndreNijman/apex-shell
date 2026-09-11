#!/usr/bin/env bash
# Run the refcounted-service-tier behavioural test.
#
# Quickshell refuses to import QML modules from outside the directory holding the
# entry point, so the test cannot live in tests/ and import ../src. It is staged
# into the repo root for the duration of the run and removed afterwards.
#
# ── On a compositor of its own ───────────────────────────────────────────────
#
# This suite instantiates the popup fleet, and a PopupWindow is a window. Until
# tests/lib/headless.sh existed it opened those on whatever WAYLAND_DISPLAY it
# inherited, which on a workstation is the session somebody is using. It now
# brings a headless wlroots compositor and a private HOME; the library refuses
# to continue if the socket it ends up on is not one this run created.
#
# Skips cleanly (status 0) without quickshell or without a compositor to host it.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"

headless_require quickshell

staged="$root/.service-tier-test.qml"
cleanup() { rm -f "$staged"; headless_cleanup; }
trap cleanup EXIT INT TERM

headless_begin
headless_start || exit 0

cp "$here/service-tier-test.qml" "$staged"

out="$(QT_LOGGING_RULES="qml=true" timeout 120 quickshell -p "$staged" 2>&1 || true)"
echo "$out" | grep -E "PASS|FAIL|^\[|passed=" || true

if grep -q "Failed to load configuration" <<<"$out"; then
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

# Graded on the count the run reported, not on whether a FAIL line survived a
# grep: a summary that says failed=12 and a filter that prints none of them is
# how a red run gets reported green.
failed="${summary##*failed=}"
echo "RESULT: $summary"
[[ "$failed" -eq 0 ]]
