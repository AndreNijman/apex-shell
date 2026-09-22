#!/usr/bin/env bash
# Run a QML entry point on a labwc of its own and print what it said.
#
#     ./tests/run-nested-labwc.sh shell.qml 20
#
# This is how labwc support is verified without rebooting into a labwc session,
# and it is the harness the compositor-facade suite used before that suite grew
# its own.
#
# ── Headless, not nested in your session ─────────────────────────────────────
#
# It used to start labwc inside the current Wayland session, which put a
# compositor window — and then a whole shell inside it — on whatever desktop the
# person running it was using. It now goes through tests/lib/headless.sh: labwc
# on the wlroots headless backend, in a runtime directory this run created, with
# a private HOME. The library refuses to continue if the display it ends up on
# is the ambient one.
#
# The name still says "nested" because that is what the QML under test sees: a
# labwc it is the only client of, rather than the session it was launched from.
set -uo pipefail

entry="${1:?usage: run-nested-labwc.sh <qml> [seconds]}"
secs="${2:-12}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/lib/headless.sh"

headless_require quickshell labwc

cleanup() { headless_cleanup; }
trap cleanup EXIT INT TERM

headless_begin
headless_start labwc || exit 0

# A compositor with nothing running inside it is not a session: the app dock has
# nothing to list, the foreign-toplevel feed nothing to publish, and any
# assertion over the window list is an empty loop that passes without testing
# anything. A filler toplevel goes up first, and a filler that died is a failure
# rather than a skip.
headless_filler || exit 1

shell_log="$HEADLESS_W/shell.log"
QT_LOGGING_RULES="qml=true" timeout "$secs" quickshell -p "$entry" >"$shell_log" 2>&1

echo "--- shell output ---"
# Generous line budget: a truncated run hides the summary line, which is the one
# line that says whether it passed.
sed 's/\x1b\[[0-9;]*m//g' "$shell_log" \
    | grep -vE "qt.qpa.wayland.textinput|Registration will|notification server" \
    | head -120
echo "--- labwc errors ---"
grep -iE "error|fail" "$HEADLESS_W/comp.log" 2>/dev/null | head -10
echo "--- ERROR count: $(grep -c 'ERROR' "$shell_log") ---"
