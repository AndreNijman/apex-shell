#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-scaling-test.sh — P1-040. What the shell resolves on the outputs it has.
#
#  ── It brings its own compositor and its own home ───────────────────────────
#
#  It did neither. It ran `quickshell -p` on the inherited WAYLAND_DISPLAY — the
#  developer's live session — and the suite it runs calls
#  `SettingsService.set("scaleManual", 1.5)`, which persists to
#  `$HOME/.config/apex-shell/src/user_data/settings.json`. A crash between
#  setting and restoring left the developer's real shell at 150%, and the
#  version that skipped "when there is no WAYLAND_DISPLAY" only ever ran in the
#  one case where that mattered. tests/run-nav-geometry-test.sh is the model and
#  this now follows it.
#
#  ── And it brings TWO outputs ───────────────────────────────────────────────
#
#  P1-040 is about a mixed-DPI desk and there is no mixed-DPI desk here, so the
#  compositor is asked for two headless outputs and wlr-randr gives them
#  different modes. Defaults are a 3840x2160 and a 1920x1080, which is the pair
#  the roadmap names.
#
#    SCALING_MODES="3840x2160 1920x1080"   the modes, in output order
#    SCALING_SCALES="2 1"                  compositor scales to apply first
#    SCALING_OUTPUTS=1                     one output, for the single-panel case
#
#  What one factor DOES to two densities is arithmetic, and it is asserted in
#  tests/scaling-test.js, which needs no compositor at all. What is asserted
#  here is what only a session can say: which output the shell picked, what it
#  resolved, and that naming an output moves the factor to that output's.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

command -v quickshell >/dev/null 2>&1 || { echo "SKIP: quickshell not installed"; exit 0; }

comp="${SCALING_COMP:-}"
if [[ -n "$comp" ]]; then
    command -v "$comp" >/dev/null 2>&1 || { echo "SKIP: $comp is not installed"; exit 0; }
else
    for c in labwc sway; do
        command -v "$c" >/dev/null 2>&1 && { comp="$c"; break; }
    done
fi
[[ -n "$comp" ]] || { echo "SKIP: no wlroots compositor (labwc or sway) to host the test"; exit 0; }

W="$(mktemp -d)"
staged="$root/.scaling-test.qml"
comp_pid=""
# By pid, never by name: a pkill for a compositor on a developer's machine takes
# down the session they are working in.
cleanup() {
    [[ -n "$comp_pid" ]] && kill "$comp_pid" 2>/dev/null
    sleep 0.3
    [[ -n "$comp_pid" ]] && kill -9 "$comp_pid" 2>/dev/null
    rm -f "$staged"
    rm -rf "$W"
    return 0
}
trap cleanup EXIT INT TERM

# Quickshell refuses to import QML from outside the directory holding the entry
# point, so the test is staged into the repo root for the run.
cp "$here/scaling-test.qml" "$staged"

# Stubs first on PATH: SettingsService and the services the singletons pull in
# must not interrogate — or reconfigure — the real machine while this measures
# numbers.
mkdir -p "$W/bin"
cat > "$W/bin/_stub" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
    *--json*|*-j*|*json*) echo "{}" ;;
    *)                    : ;;
esac
exit 0
FAKE
chmod +x "$W/bin/_stub"
for n in apex hyprctl niri matugen xdg-open playerctl wpctl brightnessctl \
         pkcheck notify-send swww gammastep hyprsunset; do
    ln -sf "$W/bin/_stub" "$W/bin/$n"
done
# wlr-randr is NOT stubbed: this script uses the real one to set the modes.
REAL_PATH="$PATH"
export PATH="$W/bin:$PATH"

real_home="$(getent passwd "$(id -u)" | cut -d: -f6)"

export XDG_RUNTIME_DIR="$W/run"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"
export HOME="$W/home"
mkdir -p "$HOME/.config/apex-shell/src/user_data" "$HOME/.local/share" "$HOME/Pictures/Wallpapers"
export XDG_STATE_HOME="$W/state"; export XDG_CACHE_HOME="$W/cache"; export XDG_CONFIG_HOME="$W/cfg"
mkdir -p "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME/labwc"
# Fonts are the one thing the private home borrows back: a run that cannot see
# them measures .notdef boxes.
ln -sfn "$real_home/.local/share/fonts" "$HOME/.local/share/fonts" 2>/dev/null
ln -sfn "$real_home/.config/fontconfig" "$HOME/.config/fontconfig" 2>/dev/null
cp "$here/labwc-test-rc.xml" "$XDG_CONFIG_HOME/labwc/rc.xml" 2>/dev/null || true

unset WAYLAND_DISPLAY DISPLAY HYPRLAND_INSTANCE_SIGNATURE NIRI_SOCKET
export XDG_CURRENT_DESKTOP="labwc:wlroots"
export XDG_SESSION_TYPE=wayland
export QT_QPA_PLATFORM=wayland
export WLR_BACKENDS=headless
export WLR_LIBINPUT_NO_DEVICES=1
export WLR_HEADLESS_OUTPUTS="${SCALING_OUTPUTS:-2}"

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
    labwc) WLR_RENDERER=pixman "$comp" > "$W/comp.log" 2>&1 & comp_pid=$! ;;
    sway)  : > "$W/sway.cfg"
           WLR_RENDERER=pixman "$comp" -c "$W/sway.cfg" > "$W/comp.log" 2>&1 & comp_pid=$! ;;
esac

sock=""
for _ in $(seq 1 60); do
    sock="$(comm -13 <(printf '%s\n' "$before") <(list_sockets) | head -1)"
    [[ -n "$sock" ]] && break
    sleep 0.25
done
[[ -n "$sock" ]] || { echo "SKIP: $comp did not come up headless"; tail -5 "$W/comp.log"; exit 0; }
export WAYLAND_DISPLAY="$sock"

# The window this test opens must land on the compositor above and nowhere else.
[[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]] || {
    echo "FAIL: WAYLAND_DISPLAY does not name a socket in the private runtime dir"
    exit 1; }

# ── Give the outputs their modes ─────────────────────────────────────────────
if command -v wlr-randr >/dev/null 2>&1; then
    mapfile -t names < <(PATH="$REAL_PATH" wlr-randr 2>/dev/null | awk '/^[A-Za-z]/{print $1}')
    i=0
    for m in ${SCALING_MODES:-3840x2160 1920x1080}; do
        [[ -n "${names[$i]:-}" ]] && \
            PATH="$REAL_PATH" wlr-randr --output "${names[$i]}" --custom-mode "$m" >/dev/null 2>&1
        i=$((i + 1))
    done
    if [[ -n "${SCALING_SCALES:-}" ]]; then
        i=0
        for s in $SCALING_SCALES; do
            [[ -n "${names[$i]:-}" ]] && \
                PATH="$REAL_PATH" wlr-randr --output "${names[$i]}" --scale "$s" >/dev/null 2>&1
            i=$((i + 1))
        done
    fi
    sleep 1
    echo "outputs:"
    PATH="$REAL_PATH" wlr-randr 2>/dev/null \
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
# grep: a summary that says failed=7 and a filter that prints none of them is how
# a red run gets reported green.
failed="${summary##*failed=}"
if [[ "$failed" -ne 0 ]]; then
    echo "RESULT: $failed failing assertion(s)"
    exit 1
fi

echo "RESULT: all assertions passed"
