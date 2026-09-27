#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Run tests/locked-hint-test.qml — the shell half of P0-015's lock-state
#  policy (ROADMAP.md §7).
#
#  APEX Shell locks the session with ext-session-lock and, until 8d081ff, told
#  logind nothing about it: `loginctl show-session -p LockedHint` answered "no"
#  on a session that had been locked for an hour, which is what it answers on
#  one nobody has touched. apex-agentd polls exactly that property to decide
#  whether Remote Control keeps running and whether a short-lived root grant
#  survives, so the value is load-bearing rather than cosmetic.
#
#  That fix shipped with no test of any kind. This is it.
#
#  ── IT BRINGS ITS OWN COMPOSITOR, ALWAYS ────────────────────────────────────
#
#  Not "if there is no WAYLAND_DISPLAY". Always. A headless wlroots compositor
#  in a private XDG_RUNTIME_DIR with WAYLAND_DISPLAY and DISPLAY unset, because
#  the last phase drives a REAL ext-session-lock and the one thing that must
#  never happen is that lock landing on the developer's session.
#
#  ── AND ITS OWN loginctl AND busctl, WHICH IS THE POINT ─────────────────────
#
#  Both are stubs, first on PATH, that record their argv and answer from a
#  control file this run rewrites between phases. Nothing here reads or writes
#  the real logind. The stub's GetSession prints the escaped object path logind
#  actually returns — session "3" is /org/freedesktop/login1/session/_33,
#  confirmed live — because the service asking logind for that path instead of
#  building it is one of the things under test.
#
#  Stubs for everything else the lock screen reaches for go first on PATH too:
#  it builds a real settings surface, and a real settings surface interrogates
#  the machine.
#
#  ── WHAT IT PROVES THAT READING THE FILE CANNOT ─────────────────────────────
#
#   * the shell says something to logind AT STARTUP. `onSecureStateChanged`
#     fires on a change, so without an initial push a shell restarted while
#     logind believed the session locked leaves the hint stale — and a stale
#     `yes` holds Remote Control and revokes root grants while the owner is
#     sitting in front of the machine.
#   * the three calls happen, in order, with the right argv.
#   * a lock/unlock/lock flicker makes one trailing call, not three.
#   * a failure at each of the three steps stops the chain and does not retry
#     WHEN NOTHING NEWER WAS ASKED FOR — and does the opposite when something
#     was. A lock that arrives while a chain is in flight is only recorded in
#     `_desired`; if that chain then fails, the lock has never been tried at
#     all, and dropping it is a lock the user engaged that logind is never
#     told about. apex-agentd polls exactly that property.
#   * neither direction is measurable in the same process: the drop is only
#     observable while `_confirmed` is undefined (see the second scenario),
#     and a process whose startup sync succeeded can never return to that
#     state. So this runs quickshell TWICE.
#   * `WlSessionLock.secure` flips on a compositor that has acknowledged the
#     lock, and that is what reaches logind.
#
#  Skips cleanly (status 0) without quickshell or a headless compositor.
#
#  Run from the repository root: ./tests/run-locked-hint-test.sh
# ─────────────────────────────────────────────────────────────────────────────
. "$(dirname "${BASH_SOURCE[0]}")/lib/private-bus.sh"   # the session bus is ours, not the desktop's
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

command -v quickshell >/dev/null 2>&1 || { echo "SKIP: quickshell not installed"; exit 0; }

# Say what is missing rather than letting QML report it as an unknown type.
for f in src/services/system/LockedHintService.qml \
         src/windows/Lockscreen.qml \
         src/state/LockState.qml; do
    [[ -f "$root/$f" ]] || { echo "FAIL: this tree has no $f"; exit 1; }
done
grep -q "^singleton LockedHintService " "$root/src/services/qmldir" || {
    echo "FAIL: LockedHintService is not registered in src/services/qmldir, so"
    echo "      nothing that imports src/services can see it."
    exit 1; }

comp=""
for c in sway labwc; do
    command -v "$c" >/dev/null 2>&1 && { comp="$c"; break; }
done
[[ -n "$comp" ]] || { echo "SKIP: no wlroots compositor (sway or labwc) to host the test"; exit 0; }

W="$(mktemp -d)"
staged="$root/.locked-hint-test.qml"
comp_pid=""
# Killed by pid, never by name: a pkill for a compositor on a developer's
# machine takes down the session they are working in.
cleanup() {
    [[ -n "$comp_pid" ]] && kill "$comp_pid" 2>/dev/null
    sleep 0.3
    [[ -n "$comp_pid" ]] && kill -9 "$comp_pid" 2>/dev/null
    rm -f "$staged"
    rm -rf "$W"
    return 0
}
trap cleanup EXIT INT TERM

cp "$here/locked-hint-test.qml" "$staged"

# ── the fakes ────────────────────────────────────────────────────────────────
mkdir -p "$W/bin"
export HINT_LOG="$W/calls.log"
export HINT_CTL="$W/mode"
: > "$HINT_LOG"
printf 'ok' > "$HINT_CTL"

cat > "$W/bin/loginctl" <<'FAKE'
#!/usr/bin/env bash
# Records the call, then answers per the control file. Never touches logind.
printf 'loginctl %s\n' "$*" >> "$HINT_LOG"
mode="$(cat "$HINT_CTL" 2>/dev/null || echo ok)"
case "$mode" in
    fail-showuser)  echo "Failed to look up user: No such process" >&2; exit 1 ;;
    # Exit 0 and nothing on stdout: what a user with no graphical session
    # looks like. It must not be read as a session id.
    empty-display)  exit 0 ;;
    # Answers correctly, slowly. The only way to make "a call is in flight"
    # observable from outside: a second request arriving during the sleep
    # either waits its turn or restarts this step, and the two are told apart
    # by how many times this line runs.
    slow)           sleep 0.3 ;;
    # Slow AND then fails. The mode is read ABOVE the sleep, on purpose: the
    # test switches the control file back to `ok` while this is sleeping, so
    # the chain already in flight still fails and only the follow-up chain
    # meets working tools. Without that, "the request that arrived mid-chain
    # was retried" and "the failing step was retried until it worked" would
    # look the same in the log.
    slow-fail-showuser)
        sleep 0.3
        echo "Failed to look up user: No such process" >&2; exit 1 ;;
esac
echo "3"
exit 0
FAKE

cat > "$W/bin/busctl" <<'FAKE'
#!/usr/bin/env bash
printf 'busctl %s\n' "$*" >> "$HINT_LOG"
mode="$(cat "$HINT_CTL" 2>/dev/null || echo ok)"
case "$*" in
    *GetSession*)
        [[ "$mode" == "fail-getsession" ]] && { echo "no session" >&2; exit 1; }
        # The escaped path logind really returns for session "3".
        printf 'o "/org/freedesktop/login1/session/_33"\n'
        ;;
    *SetLockedHint*)
        [[ "$mode" == "fail-sethint" ]] && { echo "refused" >&2; exit 1; }
        ;;
esac
exit 0
FAKE

# The lock screen builds a real background, a real settings read and a real
# clock. Left alone it would interrogate — and the wallpaper path could apply
# from — the developer's own desktop while this measures argv.
cat > "$W/bin/_stub" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
    *--json*|*json*) echo "{}" ;;
    *)               : ;;
esac
exit 0
FAKE
chmod +x "$W/bin/loginctl" "$W/bin/busctl" "$W/bin/_stub"
for n in apex hyprctl wlr-randr niri matugen xdg-open playerctl wpctl \
         brightnessctl pkcheck notify-send swww hypridle; do
    ln -sf "$W/bin/_stub" "$W/bin/$n"
done
export PATH="$W/bin:$PATH"

# ── private everything ───────────────────────────────────────────────────────
real_home="$(getent passwd "$(id -u)" | cut -d: -f6)"
export XDG_RUNTIME_DIR="$W/run"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"
export HOME="$W/home"
mkdir -p "$HOME/.config/apex-shell/src/user_data" "$HOME/.local/share" "$HOME/Pictures/Wallpapers"
export XDG_STATE_HOME="$W/state"
export XDG_CONFIG_HOME="$W/config"
export XDG_CACHE_HOME="$W/cache"
mkdir -p "$XDG_STATE_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
# fontconfig finds user fonts through HOME, and a run that cannot see them
# measures .notdef boxes. Read-only symlinks; nothing else is shared.
ln -sfn "$real_home/.local/share/fonts" "$HOME/.local/share/fonts" 2>/dev/null
ln -sfn "$real_home/.config/fontconfig" "$HOME/.config/fontconfig" 2>/dev/null

unset WAYLAND_DISPLAY
unset DISPLAY
unset HYPRLAND_INSTANCE_SIGNATURE
unset NIRI_SOCKET
export WLR_BACKENDS=headless
export WLR_LIBINPUT_NO_DEVICES=1
export WLR_RENDERER=pixman
export WLR_HEADLESS_OUTPUTS=1
export XDG_SESSION_TYPE=wayland
export QT_QPA_PLATFORM=wayland

list_sockets() {
    local f b
    for f in "$XDG_RUNTIME_DIR"/wayland-*; do
        [[ -S "$f" ]] || continue
        b="${f##*/}"
        case "${b#wayland-}" in '' | *[!0-9]*) continue ;; esac
        printf '%s\n' "$b"
    done | sort
}

before="$(list_sockets)"
case "$comp" in
    sway)
        printf 'output HEADLESS-1 mode 1920x1080\n' > "$W/sway.cfg"
        "$comp" -c "$W/sway.cfg" > "$W/comp.log" 2>&1 &
        ;;
    labwc)
        mkdir -p "$W/labwc/labwc"
        cp "$here/labwc-test-rc.xml" "$W/labwc/labwc/rc.xml" 2>/dev/null || true
        XDG_CONFIG_HOME="$W/labwc" "$comp" > "$W/comp.log" 2>&1 &
        ;;
esac
comp_pid=$!

sock=""
for _ in $(seq 1 60); do
    sock="$(comm -13 <(printf '%s\n' "$before") <(list_sockets) | head -1)"
    [[ -n "$sock" ]] && break
    sleep 0.25
done
[[ -n "$sock" ]] || {
    echo "SKIP: $comp did not come up headless"; tail -5 "$W/comp.log"; exit 0; }
export WAYLAND_DISPLAY="$sock"

# The session lock the last phase engages must land on the compositor above and
# nowhere else.
[[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]] || {
    echo "FAIL: WAYLAND_DISPLAY does not name a socket in the private runtime dir"
    exit 1; }
echo "host: $comp on $WAYLAND_DISPLAY (headless, private XDG_RUNTIME_DIR and HOME)"
echo "calls: $HINT_LOG"

# ── one scenario, one quickshell run ─────────────────────────────────────────
#
# Both scenarios share this compositor, these stubs and this staged file; only
# $HINT_SCENARIO and the mode the tools start in differ. The second run exists
# because its assertions need a service that has NEVER successfully reached
# logind, and there is no way back into that state inside a process whose
# startup sync worked.
total_pass=0
total_fail=0
broke=0

run_scenario() {
    local scenario="$1" mode="$2" title="$3"
    : > "$HINT_LOG"
    printf '%s' "$mode" > "$HINT_CTL"
    echo
    echo "── $scenario — $title (tools start in mode '$mode')"

    local out
    out="$(HINT_SCENARIO="$scenario" QT_LOGGING_RULES="qml=true" \
           timeout 180 quickshell -p "$staged" 2>&1 \
           | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^[[:space:]]*DEBUG qml: //')"

    printf '%s\n' "$out" | grep -E "^( *PASS| *FAIL| *note:|locked-hint:)" || true

    # `[[ == * ]]` rather than `grep -q`: under `set -o pipefail` a `grep -q`
    # that MATCHES can return 141 — it exits before the writer is finished and
    # the writer takes SIGPIPE — so a match reads as a non-match. That has
    # mis-seeded suites in this repository before.
    if [[ "$out" == *"Failed to load configuration"* ]]; then
        printf '%s\n' "$out" | tail -30
        echo "RESULT: the test config failed to load ($scenario)"
        broke=1
        return 1
    fi

    local summary
    summary="$(printf '%s\n' "$out" | grep -o 'locked-hint: passed=[0-9]* failed=[0-9]*' | tail -1)"
    if [[ -z "$summary" ]]; then
        printf '%s\n' "$out" | tail -30
        echo "RESULT: the $scenario run did not run to completion"
        broke=1
        return 1
    fi

    if [[ "$out" == *"locked-hint: compositor-did-not-acknowledge"* ]]; then
        echo "NOTE: $comp never acknowledged the ext-session-lock, so the end-to-end"
        echo "      phase was not measured. Every other phase still counts."
    fi

    # Graded on the count the run reported, not on whether a FAIL line survived
    # a grep. A summary saying failed=4 and a filter that prints none of them is
    # how a red run gets reported green.
    local passed="${summary#*passed=}"; passed="${passed%% *}"
    local failed="${summary##*failed=}"
    total_pass=$(( total_pass + passed ))
    total_fail=$(( total_fail + failed ))
    if [[ "$failed" -ne 0 ]]; then
        echo "RESULT: $failed assertion(s) failed in the $scenario run"
        return 1
    fi
    return 0
}

# Both always run: a red first scenario must not hide the second one's result.
run_scenario main ok \
    "the shipped service and lock screen, every step, ending on a real session lock"
run_scenario startup-drop fail-showuser \
    "nothing confirmed yet and the first sync failing — where a dropped request bites"

if [[ "$broke" -ne 0 || "$total_fail" -ne 0 ]]; then
    echo
    echo "RESULT: $total_fail assertion(s) failed across the two runs"
    exit 1
fi

echo
echo "RESULT: locked-hint: passed=$total_pass failed=0 — logind hears the lock, the"
echo "        unlock, the shell starting, and the lock asked for while a chain was"
echo "        in flight that then failed"
