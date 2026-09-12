#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  test-headless-lib.sh — tests/lib/headless.sh answering for itself.
#
#  ── Why this file exists ────────────────────────────────────────────────────
#  tests/check-headless-runners.sh scans the THIRTEEN runners that use the
#  library and proves none of them can reach the ambient display. It is a
#  static scan, and it necessarily takes the library's own behaviour on trust.
#  Two defects lived in that blind spot until they were measured on 2026-09-12:
#
#    1. The mode was announced and never applied. HEADLESS_MODE defaulted to a
#       hard-coded 1920x1080 that was not measured from anything; wlroots'
#       headless backend hands out 1280x720. Every runner printed
#       "at 1920x1080" over an output that was 1280x720. Worse, the apply path
#       was guarded `[ "$mode" != "1920x1080" ]` and then resolved wlr-randr
#       through a PATH whose first entry is the library's OWN stub — so the one
#       case that reached it did nothing at all, silently, while the header
#       comment said the shadowing "is fine: the default headless output is
#       1920x1080 and that is the default mode". The branch is entered only
#       when the mode is NOT 1920x1080, so the comment's reason excluded the
#       only case it governed, and its premise was false besides.
#
#    2. headless_assert_private compared DISPLAY NAMES where it meant identity.
#       A compositor in a fresh private runtime dir numbers its socket from that
#       empty directory, so it collides with the desk's number whenever the
#       desk's is low. Measured here with the desk on wayland-1, sway came up on
#       its own $HEADLESS_W/run/wayland-1 and was refused as "the ambient one" —
#       return 2, a hard FAIL, for a run that had done everything right. labwc
#       takes wayland-0 in the same dir, so on a machine whose desk is
#       wayland-0 every one of the thirteen would have failed that way.
#
#  Both are the same defect wearing different clothes: a claim about the machine
#  that nothing measured. So the assertions below are all read-backs. Nothing
#  here trusts a variable the library set; it asks the compositor, or it builds
#  the exact filesystem shape the refusal is about and calls the refusal.
#
#  ── What it needs, and what it does instead of needing it ───────────────────
#  Part 1 is pure filesystem and runs anywhere — no compositor, no wlr-randr,
#  no display of any kind. Part 2 needs labwc and wlr-randr and SKIPs without
#  them, which is why the parts are ordered that way: the half that can always
#  run always runs.
#
#  Headless throughout. Nothing here can open a window on anybody's desktop:
#  the whole point of the library under test is that it cannot.
#
#  Run from anywhere: ./tests/test-headless-lib.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

pass=0
fail=0
ok()  { printf 'ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "${2-}"; fail=$((fail + 1)); }

# ═════════════════════════════════════════════════════════════════════════════
#  Part 1 — headless_assert_private, on identity rather than on spelling
# ═════════════════════════════════════════════════════════════════════════════
#
# Called directly, against a filesystem built by hand, because the interesting
# cases are ones a real compositor produces only on somebody else's machine.
# Everything the function reads is a variable, so the fixtures set them.

. tests/lib/headless.sh

# A socket, made without a compositor. python3 is already a hard dependency of
# tests/run-scaling-test.sh and tests/run-display-transaction-test.sh.
mksock() {
    python3 - "$1" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
PY
}

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT INT TERM

mkdir -p "$W/desk" "$W/priv" "$W/priv2"
mksock "$W/desk/wayland-1"
mksock "$W/priv/wayland-1"
mksock "$W/priv2/wayland-0"

# The linter cannot see across the `. tests/lib/headless.sh` above:
# headless_assert_private reads these four as plain shell variables in THIS
# shell, and this harness overrides them to drive the library's captured state.
# They are NOT exported on purpose — a child process must not inherit a fake
# ambient session. Hence the four SC2034 suppressions below, which are the only
# honest answer: the variables are used, just not where a linter can look.
# shellcheck disable=SC2034
HEADLESS_AMBIENT_RUNTIME="$W/desk"
# shellcheck disable=SC2034
HEADLESS_AMBIENT_DISPLAY="wayland-1"

# THE REGRESSION. A private socket whose NAME collides with the desk's is not
# the desk's socket, and refusing it is a false FAIL that stops a correct run.
XDG_RUNTIME_DIR="$W/priv"
WAYLAND_DISPLAY="wayland-1"
out="$(headless_assert_private 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
    ok "a private socket that merely shares the desk's display NUMBER is accepted"
else
    bad "a private socket that merely shares the desk's display NUMBER is accepted" \
        "rc=$rc out=$out"
fi

# And the refusal it is not allowed to lose: a private dir holding a symlink to
# the desk's own socket. Same device and inode through the link, so `-ef` sees
# it where a name comparison sees two different names and waves it through.
mkdir -p "$W/sneak"
ln -sf "$W/desk/wayland-1" "$W/sneak/wayland-9"
XDG_RUNTIME_DIR="$W/sneak"
WAYLAND_DISPLAY="wayland-9"
out="$(headless_assert_private 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'symlink'; then
    ok "a private path that is a symlink to the desk's socket is refused, and named"
else
    bad "a private path that is a symlink to the desk's socket is refused" \
        "rc=$rc out=$out"
fi

# The same reach, without a symlink to give it away: a bind mount or a hard
# link cannot be told apart by name at all, and this is the case the identity
# test exists for. Simulated with the runtime dir pointed straight at the desk's
# directory under a different spelling — same file, different path.
ln -sfn "$W/desk" "$W/deskalias"
XDG_RUNTIME_DIR="$W/deskalias"
WAYLAND_DISPLAY="wayland-1"
out="$(headless_assert_private 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'ambient'; then
    ok "a runtime dir aliased to the desk's is refused on identity, not spelling"
else
    bad "a runtime dir aliased to the desk's is refused on identity, not spelling" \
        "rc=$rc out=$out"
fi

# The first refusal still fires: the runtime dir IS the desk's, spelled the
# same way.
XDG_RUNTIME_DIR="$W/desk"
WAYLAND_DISPLAY="wayland-1"
out="$(headless_assert_private 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'XDG_RUNTIME_DIR'; then
    ok "the desk's own runtime dir is still refused by name"
else
    bad "the desk's own runtime dir is still refused by name" "rc=$rc out=$out"
fi

# A WAYLAND_DISPLAY naming nothing is a could-not-run, not a pass.
# shellcheck disable=SC2034
XDG_RUNTIME_DIR="$W/priv2"
# shellcheck disable=SC2034
WAYLAND_DISPLAY="wayland-7"
out="$(headless_assert_private 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'does not name a socket'; then
    ok "a display that names no socket in the private dir is refused"
else
    bad "a display that names no socket in the private dir is refused" "rc=$rc out=$out"
fi

# ═════════════════════════════════════════════════════════════════════════════
#  Part 2 — the mode is the mode the output actually has
# ═════════════════════════════════════════════════════════════════════════════
#
# Each case is a whole begin/start/cleanup cycle in a subshell, because
# headless_begin rewrites HOME, PATH and every XDG_* of the shell it runs in and
# the cases must not inherit each other's.

if ! command -v labwc >/dev/null 2>&1 || ! command -v wlr-randr >/dev/null 2>&1; then
    printf 'SKIP  the mode half needs labwc and wlr-randr\n'
    printf '\n%d passed, %d failed\n' "$pass" "$fail"
    [ "$fail" -eq 0 ] || exit 1
    exit 0
fi

# The witness: the real wlr-randr, resolved BEFORE headless_begin puts its stub
# in front of it, so the read-back cannot be answered by the thing under test.
REAL_RANDR="$(command -v wlr-randr)"
export REAL_RANDR

# Prints: <rc> <HEADLESS_MODE> <what the compositor really has>
run_mode_case() {
    (
        set +e
        . tests/lib/headless.sh
        headless_begin
        if [ -n "${1-}" ]; then headless_start labwc "$1"; else headless_start labwc; fi
        rc=$?
        got="$("$REAL_RANDR" 2>/dev/null | awk '/\(current\)/ { print $1; exit }')"
        printf '%s %s %s\n' "$rc" "${HEADLESS_MODE:-EMPTY}" "${got:-NONE}"
        headless_cleanup >/dev/null 2>&1
    ) 2>/dev/null | tail -1
}

# No mode asked for: HEADLESS_MODE must be what the backend actually gave,
# never a fabricated default. This is the case that was wrong for every runner.
read -r rc mode got <<<"$(run_mode_case '')"
if [ "$rc" = 0 ] && [ "$mode" = "$got" ] && [ "$mode" != EMPTY ] && [ "$got" != NONE ]; then
    ok "with no mode asked for, HEADLESS_MODE is the mode the output really has ($got)"
else
    bad "with no mode asked for, HEADLESS_MODE is the mode the output really has" \
        "rc=$rc HEADLESS_MODE=$mode actual=$got"
fi

# The old fabricated default, asserted as an absence: reporting 1920x1080 over
# a 1280x720 output is the exact defect, so the value is only allowed to appear
# when it is true.
if [ "$mode" = "$got" ]; then
    ok "HEADLESS_MODE is never 1920x1080 unless the output is (it is $got)"
else
    bad "HEADLESS_MODE is never 1920x1080 unless the output is" "mode=$mode got=$got"
fi

# A mode that IS asked for must actually be applied — through the real
# wlr-randr, past the library's own stub.
read -r rc mode got <<<"$(run_mode_case '1600x900')"
if [ "$rc" = 0 ] && [ "$mode" = 1600x900 ] && [ "$got" = 1600x900 ]; then
    ok "a mode asked for is applied, and read back from the compositor"
else
    bad "a mode asked for is applied, and read back from the compositor" \
        "rc=$rc HEADLESS_MODE=$mode actual=$got"
fi

# A second one, different from both the backend default and the old hard-coded
# default, so a pass cannot come from either coincidence.
read -r rc mode got <<<"$(run_mode_case '1024x768')"
if [ "$rc" = 0 ] && [ "$mode" = 1024x768 ] && [ "$got" = 1024x768 ]; then
    ok "a second asked-for mode is applied too, so neither default can fake a pass"
else
    bad "a second asked-for mode is applied too" "rc=$rc HEADLESS_MODE=$mode actual=$got"
fi

# Garbage is still refused before anything starts.
out="$( (. tests/lib/headless.sh; headless_begin; headless_start labwc 'enormous'; \
        headless_cleanup) 2>&1 )"
if printf '%s' "$out" | grep -q 'mode must be WxH'; then
    ok "a mode that is not WxH is refused before a compositor is started"
else
    bad "a mode that is not WxH is refused before a compositor is started" "out=$out"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
