#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Run tests/nav-geometry-test.qml — where Qt puts the dashboard's six tabs and
#  the settings navigation's nine rows, at every width, height and scale factor
#  the shell supports.
#
#  ── It brings its own compositor, and its own home directory ────────────────
#
#  Always, not "if there is no WAYLAND_DISPLAY". A headless wlroots compositor
#  in a private XDG_RUNTIME_DIR, because this test opens a window: a Row lays
#  its children out in a polish pass, a polish pass needs a QQuickWindow, and
#  without one every delegate keeps x = 0 and the run reports a perfect overlap
#  that is not there. Nesting inside the developer's session instead would put
#  that window on their desktop.
#
#  The home directory is private too, and that is not tidiness. The test drives
#  Theme.scale through SettingsService, SettingsService persists to
#  $HOME/.config/apex-shell/src/user_data/settings.json, and a crash midway
#  through would otherwise leave the developer's live shell at 200%.
#
#  Fonts are the one thing the private home borrows back. fontconfig finds user
#  fonts through HOME, and a run that cannot see them measures .notdef boxes —
#  every width in the report would be fiction. Symlinked read-only; nothing else
#  is shared.
#
#  Skips cleanly (status 0) without quickshell or without a headless compositor,
#  so CI on a machine with neither does not fail the build.
#
#  Quickshell refuses to import QML from outside the directory holding the entry
#  point, so the test is staged into the repo root for the run and removed
#  afterwards — the same arrangement tests/run-scaling-test.sh uses.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

command -v quickshell >/dev/null 2>&1 || { echo "SKIP: quickshell not installed"; exit 0; }

[[ -f "$root/src/state/DashboardLayout.qml" ]] || {
    echo "FAIL: this tree has no src/state/DashboardLayout.qml, so the tab list"
    echo "      and the page width are still literals inside a PanelWindow and"
    echo "      cannot be measured without standing up the whole shell."
    exit 1; }

grep -q "^singleton DashboardLayout" "$root/src/qmldir" || {
    echo "FAIL: DashboardLayout is not registered in src/qmldir, so nothing that"
    echo "      imports src/ can see it."
    exit 1; }

comp=""
for c in labwc sway; do
    command -v "$c" >/dev/null 2>&1 && { comp="$c"; break; }
done
[[ -n "$comp" ]] || { echo "SKIP: no wlroots compositor (labwc or sway) to host the test"; exit 0; }

W="$(mktemp -d)"
staged="$root/.nav-geometry-test.qml"
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

cp "$here/nav-geometry-test.qml" "$staged"

real_home="$(getent passwd "$(id -u)" | cut -d: -f6)"

export XDG_RUNTIME_DIR="$W/run"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"
export HOME="$W/home"
mkdir -p "$HOME/.config" "$HOME/.local/share"
export XDG_STATE_HOME="$W/state"
export XDG_CACHE_HOME="$W/cache"
mkdir -p "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
ln -sfn "$real_home/.local/share/fonts" "$HOME/.local/share/fonts" 2>/dev/null
ln -sfn "$real_home/.config/fontconfig" "$HOME/.config/fontconfig" 2>/dev/null

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
        mkdir -p "$W/cfg/labwc"
        cp "$here/labwc-test-rc.xml" "$W/cfg/labwc/rc.xml" 2>/dev/null || true
        XDG_CONFIG_HOME="$W/cfg" "$comp" > "$W/comp.log" 2>&1 &
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

# The window this test opens must land on the compositor above and nowhere else.
[[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]] || {
    echo "FAIL: WAYLAND_DISPLAY does not name a socket in the private runtime dir"
    exit 1; }
echo "host: $comp on $WAYLAND_DISPLAY (headless, private XDG_RUNTIME_DIR and HOME)"

# quickshell stamps every console.log with a level and a category. Stripped, so
# the assertion lines below are the shape the QML wrote them in.
out="$(QT_LOGGING_RULES="qml=true" timeout 600 quickshell -p "$staged" 2>&1 \
       | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^[[:space:]]*DEBUG qml: //')"

# The per-point FAIL lines are deliberately not echoed: 312 matrix points times
# a dozen assertions buries the one defect nobody has noticed yet. The QML tally
# names every distinct assertion that failed, with a count and one example. Set
# NAV_GEOMETRY_VERBOSE=1 to see which points, which is what you want when you
# are looking for the threshold rather than the verdict.
if [[ "${NAV_GEOMETRY_VERBOSE:-0}" == "1" ]]; then
    echo "$out" | grep -E "^  FAIL" || true
fi
echo "$out" | grep -E "^(\[rig\]|failures by assertion:|  [0-9]+x  |        e\.g\. |nav-geometry: )" || true

if echo "$out" | grep -q "Failed to load configuration"; then
    echo "$out" | tail -25
    echo "RESULT: the test config failed to load"
    exit 1
fi

summary="$(echo "$out" | grep -o 'nav-geometry: passed=[0-9]* failed=[0-9]*' | tail -1)"
if [[ -z "$summary" ]]; then
    echo "$out" | tail -25
    echo "RESULT: the test did not run to completion"
    exit 1
fi

# Graded on the count the run reported, not on whether a FAIL line survived a
# grep. A summary that says failed=497 and a filter that prints none of them is
# how a red run gets reported green.
failed="${summary##*failed=}"
if [[ "$failed" -ne 0 ]]; then
    echo "RESULT: $failed assertion(s) failed — the navigation overlaps, clips"
    echo "        or loses its hit targets"
    exit 1
fi

echo "RESULT: no overlap, no clipping and no unhittable target anywhere in the matrix"
