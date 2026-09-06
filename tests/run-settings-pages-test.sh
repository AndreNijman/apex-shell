#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Run tests/settings-pages-test.qml — build every settings page PageRegistry
#  declares, and ask each one what it is (P0-024 criteria 1 and 2).
#
#  ── Every page, not a sample ────────────────────────────────────────────────
#
#  The model is PageRegistry itself, so a page added tomorrow is exercised the
#  day it is added and cannot be forgotten here. That is criterion 1's whole
#  content: "every settings page", enforced by construction rather than by a
#  list somebody has to remember to extend.
#
#  ── It brings its own compositor, always ────────────────────────────────────
#
#  Not "if there is no WAYLAND_DISPLAY". Always. quickshell needs a compositor,
#  and nesting inside whatever session is running puts the test one mistake
#  away from drawing on the developer's desktop. So this starts a headless
#  wlroots compositor in a private XDG_RUNTIME_DIR with WAYLAND_DISPLAY and
#  DISPLAY unset. The QML opens no window of its own either.
#
#  ── AND ITS OWN EVERYTHING ELSE ─────────────────────────────────────────────
#
#  Building all ten pages at once instantiates most of the shell's services.
#  Left alone they would run `apex recover status`, `hyprctl`, `wlr-randr`,
#  `git describe`, `df`, a matugen wallpaper scan and a package count against
#  the developer's own machine, and the Appearance page would list — and could
#  apply — his wallpapers. So a scratch home, a scratch config root, and fakes
#  first on PATH for everything a page shells out to. The pages under test are
#  the shipped files; only the machine they interrogate is a stub.
#
#  Skips cleanly (status 0) without quickshell or a headless compositor.
#
#  Run from the repository root: ./tests/run-settings-pages-test.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

command -v quickshell >/dev/null 2>&1 || { echo "SKIP: quickshell not installed"; exit 0; }

[[ -f "$root/src/nexus/PageRegistry.qml" ]] || {
    echo "FAIL: this tree has no src/nexus/PageRegistry.qml, so there is no"
    echo "      declaration of the settings pages to drive."
    exit 1; }
grep -q "^CfgCommit " "$root/src/components/config/qmldir" || {
    echo "FAIL: CfgCommit is not registered in src/components/config/qmldir, so"
    echo "      any page importing it fails to load and takes the shell with it."
    exit 1; }
grep -q "^CfgLifecycle " "$root/src/components/config/qmldir" || {
    echo "FAIL: CfgLifecycle is not registered in src/components/config/qmldir"
    exit 1; }

comp=""
for c in labwc sway; do
    command -v "$c" >/dev/null 2>&1 && { comp="$c"; break; }
done
[[ -n "$comp" ]] || { echo "SKIP: no wlroots compositor (labwc or sway) to host the test"; exit 0; }

W="$(mktemp -d)"
staged="$root/.settings-pages-test.qml"
comp_pid=""
cleanup() {
    [[ -n "$comp_pid" ]] && kill "$comp_pid" 2>/dev/null
    sleep 0.2
    [[ -n "$comp_pid" ]] && kill -9 "$comp_pid" 2>/dev/null
    rm -f "$staged"
    rm -rf "$W"
    return 0
}
trap cleanup EXIT INT TERM

cp "$here/settings-pages-test.qml" "$staged"

# ── the fakes ────────────────────────────────────────────────────────────────
# One script, many names. Each prints empty JSON for anything asking for JSON
# and nothing otherwise, which is what every one of these looks like on a
# machine that has none of what the page is asking about.
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
for n in apex hyprctl wlr-randr niri matugen xdg-open playerctl wpctl \
         brightnessctl pkcheck notify-send swww; do
    ln -sf "$W/bin/_stub" "$W/bin/$n"
done
# git is real elsewhere in the suite; here it must not read the developer's
# checkout, so `git describe` answers with a fixed string.
cat > "$W/bin/git" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
    *describe*) echo "v0.0.0-test" ;;
    *)          : ;;
esac
exit 0
FAKE
chmod +x "$W/bin/git"
export PATH="$W/bin:$PATH"

# ── the scratch machine ──────────────────────────────────────────────────────
real_home="$(getent passwd "$(id -u)" | cut -d: -f6)"
export HOME="$W/home"
export XDG_CONFIG_HOME="$W/home/.config"
export XDG_STATE_HOME="$W/state"
export XDG_CACHE_HOME="$W/cache"
mkdir -p "$HOME/.config/apex-shell/src/user_data" "$HOME/.local/share" \
         "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$HOME/Pictures/Wallpapers"
ln -sfn "$real_home/.local/share/fonts" "$HOME/.local/share/fonts" 2>/dev/null

# ── the compositor ───────────────────────────────────────────────────────────
export XDG_RUNTIME_DIR="$W/run"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"
unset WAYLAND_DISPLAY
unset DISPLAY
unset HYPRLAND_INSTANCE_SIGNATURE
unset NIRI_SOCKET
export WLR_BACKENDS=headless
export WLR_LIBINPUT_NO_DEVICES=1
export WLR_RENDERER=pixman
export XDG_SESSION_TYPE=wayland
export QT_QPA_PLATFORM=wayland

case "$comp" in
    labwc)
        mkdir -p "$W/labwc/labwc"
        cp "$here/labwc-test-rc.xml" "$W/labwc/labwc/rc.xml" 2>/dev/null || true
        XDG_CONFIG_HOME="$W/labwc" "$comp" > "$W/comp.log" 2>&1 &
        ;;
    sway)
        printf 'output HEADLESS-1 mode 1920x1080\n' > "$W/sway.cfg"
        "$comp" -c "$W/sway.cfg" > "$W/comp.log" 2>&1 &
        ;;
esac
comp_pid=$!

sock=""
for _ in $(seq 1 60); do
    for f in "$XDG_RUNTIME_DIR"/wayland-*; do
        [[ -S "$f" ]] || continue
        sock="$(basename "$f")"
        break
    done
    [[ -n "$sock" ]] && break
    sleep 0.25
done
[[ -n "$sock" ]] || {
    echo "SKIP: $comp did not come up headless"; tail -5 "$W/comp.log"; exit 0; }
export WAYLAND_DISPLAY="$sock"

[[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]] || {
    echo "FAIL: WAYLAND_DISPLAY does not name a socket in the private runtime dir"
    exit 1; }

echo "host: $comp on $WAYLAND_DISPLAY (headless, private XDG_RUNTIME_DIR)"
echo "home: $HOME"

out="$(QT_LOGGING_RULES="qml=true" timeout 120 quickshell -p "$staged" 2>&1 \
       | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^[[:space:]]*DEBUG qml: //')"

echo "$out" | grep -E "^(  PASS|  FAIL|        |settings-pages: )" || true

if echo "$out" | grep -q "Failed to load configuration"; then
    echo "$out" | tail -30
    echo "RESULT: the test config failed to load"
    exit 1
fi

# A page that fails to build reports as a QML error, not as a missing PASS, and
# the summary below would otherwise be green with a page missing.
if echo "$out" | grep -qE "is not a type|Cannot assign|Unable to assign"; then
    echo "$out" | grep -E "is not a type|Cannot assign|Unable to assign" | head -10
    echo "RESULT: a settings page failed to build"
    exit 1
fi

summary="$(echo "$out" | grep -o 'settings-pages: passed=[0-9]* failed=[0-9]*' | tail -1)"
if [[ -z "$summary" ]]; then
    echo "$out" | tail -30
    echo "RESULT: the test did not run to completion"
    exit 1
fi

passed="${summary#*passed=}"; passed="${passed%% *}"
failed="${summary##*failed=}"

# One assertion per page plus five suite-wide ones. Fewer means the registry
# shrank or the driver stopped early, and either is a red run reported green.
if [[ "$passed" -lt 12 ]]; then
    echo "RESULT: only $passed assertions ran; the registry or the driver is short"
    exit 1
fi

if [[ "$failed" -ne 0 ]]; then
    echo "RESULT: $failed assertion(s) failed — a page does not say what it does,"
    echo "        or a control is labelled with a word that means something else"
    exit 1
fi

echo "RESULT: every settings page builds, says which of the four states its"
echo "        controls are in, and labels them with the four verbs only"
