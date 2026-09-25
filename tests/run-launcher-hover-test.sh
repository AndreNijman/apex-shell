#!/usr/bin/env bash
# A pointer resting over the launcher must not pick the row Enter opens; a
# pointer that moves must. See tests/launcher-hover-test.qml.
#
#     ./tests/run-launcher-hover-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"

headless_require quickshell labwc

# Quickshell resolves imports only inside the config's own folder, so the test
# runs from a copy at the repository root, where src/ is inside it.
staged="$root/.launcher-hover-test.qml"
sed 's#"\.\./src/services"#"src/services"#' "$here/launcher-hover-test.qml" >"$staged"

cleanup() { rm -f "$staged"; headless_cleanup; }
trap cleanup EXIT INT TERM

headless_begin
headless_start labwc || exit 0

log="$HEADLESS_W/shell.log"
timeout 40 quickshell -p "$staged" >"$log" 2>&1

probe() { sed -n "s/.*PROBE $1=//p" "$log" | tail -1; }

pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

rows="$(probe rows)"
if [ -z "$rows" ]; then
    echo "--- shell output ---"; sed 's/\x1b\[[0-9;]*m//g' "$log" | tail -40
    echo "FAIL: the launcher never listed six rows ($(probe result))"; exit 1
fi

[ "$(probe rest.sel)" = "0" ] \
    && ok "launcher opened under a resting pointer keeps row 0 selected" \
    || bad "launcher opened under a resting pointer selected row $(probe rest.sel), not 0"

[ "$(probe refilt.sel)" = "0" ] \
    && ok "refiltering under a resting pointer keeps the first result ($(probe refilt.rows) rows)" \
    || bad "refiltering under a resting pointer selected row $(probe refilt.sel), not 0"

[ "$(probe moved.sel)" = "2" ] \
    && ok "moving the pointer onto row 2 selects it" \
    || bad "moving the pointer onto row 2 left row $(probe moved.sel) selected"

echo "--- $pass passed, $fail failed ---"
[ "$fail" -eq 0 ]
