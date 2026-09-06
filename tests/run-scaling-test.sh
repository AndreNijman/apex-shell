#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-scaling-test.sh — P1-040. What the shell resolves on the outputs it has.
#
#  ── It runs on a compositor of its own, and it brings TWO outputs ───────────
#
#  Two rules meet in this file and both are load-bearing.
#
#  The first is the harness rule. quickshell opens a window, and this runner
#  used to open it on the inherited WAYLAND_DISPLAY — the developer's session,
#  whenever there was one. Nine runners did. They now all take a headless
#  wlroots compositor from tests/lib/headless.sh, with a private HOME and a
#  private XDG_RUNTIME_DIR, and abort if the socket they end up talking to is
#  not inside it. This suite wants that more than most: it drives Theme.scale
#  through SettingsService, SettingsService persists, and a crash midway used
#  to leave the live shell at whatever scale the matrix had reached.
#
#  The second is what P1-040 is actually about. A mixed-DPI desk needs two
#  outputs with different densities, and there is no mixed-DPI desk here, so
#  the compositor is asked for two headless outputs and wlr-randr gives them
#  different modes. Defaults are 3840x2160 and 1920x1080, the pair the roadmap
#  names.
#
#    SCALING_MODES="3840x2160 1920x1080"   the modes, in output order
#    SCALING_SCALES="2 1"                  compositor scales to apply first
#    SCALING_OUTPUTS=1                     one output, for the single-panel case
#    SCALING_COMP=sway                     pin the compositor
#
#  What one factor DOES to two densities is arithmetic, and it is asserted in
#  tests/scaling-test.js, which needs no compositor at all. What is asserted
#  here is what only a session can say: which output the shell picked, what it
#  resolved, and that naming an output moves the factor to that output's.
#
#  Skips cleanly (status 0) without quickshell or without a compositor.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"

headless_require quickshell

staged="$root/.scaling-test.qml"
cleanup() { rm -f "$staged"; headless_cleanup; }
trap cleanup EXIT INT TERM

headless_begin

# headless_begin asks the backend for one output. This suite is the reason the
# count is a variable.
export WLR_HEADLESS_OUTPUTS="${SCALING_OUTPUTS:-2}"

# The real wlr-randr, named as an exception rather than left as a hole: the
# harness stubs it so a settings page cannot reconfigure the machine somebody
# is using, and this runner is the one that has to set modes with it.
headless_unstub wlr-randr
randr="$(command -v wlr-randr 2>/dev/null || true)"

# gammastep and hyprsunset: the Display page now carries night light and the
# service behind it spawns whichever of them is present. Stubbed here and NOT
# in headless.sh, deliberately — a stub that exits 0 would tell the night-light
# mechanism table that a mechanism exists, and that table is the subject of
# another suite, which reads it off the live registry.
ln -sf "$HEADLESS_W/bin/_stub" "$HEADLESS_W/bin/gammastep"
ln -sf "$HEADLESS_W/bin/_stub" "$HEADLESS_W/bin/hyprsunset"

headless_start "${SCALING_COMP:-}" || exit 0

# Quickshell refuses to import QML from outside the directory holding the entry
# point, so the test is staged into the repo root for the run.
cp "$here/scaling-test.qml" "$staged"

# ── Give the outputs their modes ─────────────────────────────────────────────
if [ -n "$randr" ]; then
    mapfile -t names < <("$randr" 2>/dev/null | awk '/^[A-Za-z]/{print $1}')
    i=0
    for m in ${SCALING_MODES:-3840x2160 1920x1080}; do
        [ -n "${names[$i]:-}" ] && \
            "$randr" --output "${names[$i]}" --custom-mode "$m" >/dev/null 2>&1
        i=$((i + 1))
    done
    if [ -n "${SCALING_SCALES:-}" ]; then
        i=0
        for s in $SCALING_SCALES; do
            [ -n "${names[$i]:-}" ] && \
                "$randr" --output "${names[$i]}" --scale "$s" >/dev/null 2>&1
            i=$((i + 1))
        done
    fi
    sleep 1
    echo "outputs:"
    "$randr" 2>/dev/null \
        | awk '/^[A-Za-z]/{n=$1} /px \(current\)/{m=$1} /Scale:/{printf "  %s %s scale %s\n", n, m, $2}'
else
    echo "note: wlr-randr is missing, so the outputs keep the backend's default mode"
fi

out="$(QT_LOGGING_RULES="qml=true" timeout 120 quickshell -p "$staged" 2>&1 \
       | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^[[:space:]]*DEBUG qml: //')"
echo "$out" | grep -E "PASS|FAIL|^\[|passed=" || true

if echo "$out" | grep -q "Failed to load configuration"; then
    echo "$out" | tail -20
    echo "RESULT: the test config failed to load"
    exit 1
fi

summary="$(echo "$out" | grep -oE 'passed=[0-9]+ failed=[0-9]+' | tail -1)"
if [[ -z "$summary" ]]; then
    echo "$out" | tail -20
    echo "RESULT: test did not run to completion"
    exit 1
fi

# Graded on the count the run reported, never on whether a FAIL line survived a
# grep: a summary that says failed=7 and a filter that prints none of them is
# how a red run gets reported green.
failed="${summary##*failed=}"
if [[ "$failed" -ne 0 ]]; then
    echo "RESULT: $failed failing assertion(s)"
    exit 1
fi

echo "RESULT: all assertions passed"
