#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Run tests/settings-staged-test.qml — what happens to a staged settings edit
#  when the user navigates away, opens the other settings surface, or the
#  machine rebuilds the window underneath them (P0-023 criteria 3, 4 and 6).
#
#  ── It brings its own compositor, always ────────────────────────────────────
#
#  Not "if there is no WAYLAND_DISPLAY". Always. quickshell needs a compositor,
#  and nesting inside whatever session is running puts the test one mistake away
#  from drawing on the developer's desktop. So this starts a headless wlroots
#  compositor in a private XDG_RUNTIME_DIR with WAYLAND_DISPLAY and DISPLAY
#  unset. The QML opens no window of its own either.
#
#  ── AND ITS OWN HOME, WHICH IS THE POINT ────────────────────────────────────
#
#  KeybindService resolves every path it writes from $HOME. This suite makes a
#  write FAIL on purpose — it chmods the directory holding keybinds.json to 0500
#  and applies into it — so pointing it at a real home would mean taking the
#  developer's own shortcuts away for the length of a run and putting them back
#  only if nothing crashed. The private home also means the run starts from the
#  shipped defaults every time instead of from whatever the developer has bound.
#
#  ── AND ITS OWN hyprctl ─────────────────────────────────────────────────────
#
#  A fake goes first on PATH. `hyprctl reload` on a developer's machine reloads
#  the compositor they are working in, and `hyprctl binds` would report their
#  session's bindings into a conflict check that is supposed to be about the
#  fixture. The fake prints nothing and exits 0, which is what a session with no
#  Hyprland looks like.
#
#  Skips cleanly (status 0) without quickshell or a headless compositor.
#
#  Run from the repository root: ./tests/run-settings-staged-test.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

command -v quickshell >/dev/null 2>&1 || { echo "SKIP: quickshell not installed"; exit 0; }

# Say what is wrong rather than letting QML report it as a missing type.
for f in src/services/config_tab/KeybindsPage.qml \
         src/services/config_tab/KeybindService.qml \
         src/services/config_tab/ShellConfig.qml \
         src/nexus/PageRegistry.qml; do
    [[ -f "$root/$f" ]] || { echo "FAIL: this tree has no $f"; exit 1; }
done

comp=""
for c in labwc sway; do
    command -v "$c" >/dev/null 2>&1 && { comp="$c"; break; }
done
[[ -n "$comp" ]] || { echo "SKIP: no wlroots compositor (labwc or sway) to host the test"; exit 0; }

W="$(mktemp -d)"
staged="$root/.settings-staged-test.qml"
comp_pid=""
cleanup() {
    [[ -n "$comp_pid" ]] && kill "$comp_pid" 2>/dev/null
    sleep 0.2
    [[ -n "$comp_pid" ]] && kill -9 "$comp_pid" 2>/dev/null
    # The run chmods this to 0500 on purpose. Put it back before rm -rf, or a
    # crash mid-run leaves a directory mktemp's owner cannot delete.
    chmod -R u+rwX "$W" 2>/dev/null
    rm -f "$staged"
    rm -rf "$W"
    return 0
}
trap cleanup EXIT INT TERM

cp "$here/settings-staged-test.qml" "$staged"

# ── the fakes ────────────────────────────────────────────────────────────────
mkdir -p "$W/bin"
cat > "$W/bin/hyprctl" <<'FAKE'
#!/usr/bin/env bash
# A session with no Hyprland: no binds to report, nothing to reload.
exit 0
FAKE
cat > "$W/bin/apex" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
    *json*) echo "{}" ;;
    *)      : ;;
esac
exit 0
FAKE
chmod +x "$W/bin/hyprctl" "$W/bin/apex"
export PATH="$W/bin:$PATH"

# ── the home under test ──────────────────────────────────────────────────────
real_home="$(getent passwd "$(id -u)" | cut -d: -f6)"
export HOME="$W/home"
export XDG_CONFIG_HOME="$W/home/.config"
export XDG_STATE_HOME="$W/state"
export XDG_CACHE_HOME="$W/cache"
# The directory holding keybinds.json has to exist before the run: the failing
# write is a refused REDIRECT into an existing unwritable directory, which is
# what a read-only home or a bad umask actually produces. If mkdir had to create
# it the failure would be a different one.
mkdir -p "$HOME/.config/apex-shell/src/user_data" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
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

# The window this test does not open must be unable to land anywhere else.
[[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]] || {
    echo "FAIL: WAYLAND_DISPLAY does not name a socket in the private runtime dir"
    exit 1; }

echo "host: $comp on $WAYLAND_DISPLAY (headless, private XDG_RUNTIME_DIR)"
echo "home: $HOME"

out="$(QT_LOGGING_RULES="qml=true" timeout 120 quickshell -p "$staged" 2>&1 \
       | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^[[:space:]]*DEBUG qml: //')"

echo "$out" | grep -E "^(  PASS|  FAIL|settings-staged: )" || true

if echo "$out" | grep -q "Failed to load configuration"; then
    echo "$out" | tail -30
    echo "RESULT: the test config failed to load"
    exit 1
fi

summary="$(echo "$out" | grep -o 'settings-staged: passed=[0-9]* failed=[0-9]*' | tail -1)"
if [[ -z "$summary" ]]; then
    echo "$out" | tail -30
    echo "RESULT: the test did not run to completion"
    exit 1
fi

passed="${summary#*passed=}"; passed="${passed%% *}"
failed="${summary##*failed=}"

# A suite that runs but asserts nothing is the failure this line exists to
# catch: every early `return` in the driver is a path that reaches the summary
# with a handful of checks behind it.
if [[ "$passed" -lt 15 ]]; then
    echo "RESULT: only $passed assertions ran; the driver did not reach the end"
    exit 1
fi

if [[ "$failed" -ne 0 ]]; then
    echo "RESULT: $failed assertion(s) failed — a staged settings edit is lost,"
    echo "        or a refused write is silent"
    exit 1
fi

echo "RESULT: staged edits survive navigation and a rebuilt window, a refused"
echo "        write keeps them and says why, and what applied is what is on disk"
