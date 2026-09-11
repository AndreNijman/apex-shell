#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Run tests/nav-geometry-test.qml — where Qt puts the dashboard's six tabs, the
#  settings navigation's rows, and the rows of every settings page, at every
#  width, height and scale factor the shell supports.
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
#  ── AND FAKES FOR EVERYTHING A PAGE SHELLS OUT TO ───────────────────────────
#
#  The page block builds real settings pages, and a real settings page asks the
#  real machine: `apex recover status`, `hyprctl`, `wlr-randr`, `git describe`,
#  a wallpaper scan. Left alone this suite would interrogate — and the
#  Appearance page could apply from — the developer's own desktop while
#  measuring rectangles. So stubs go first on PATH. The pages under test are the
#  shipped files; only the machine they interrogate is a stub.
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

# The output size and the compositor are both selectable, because "verified at
# 1440p" has to mean the shell was told it was on a 1440p output rather than
# that a number was typed into a test. The matrix inside the QML drives the
# scale factor by hand and is the same everywhere; the block it runs first is
# not — that one asks Metrics what this output deserves and grades the answer.
#
#   NAV_GEOMETRY_MODE=2560x1080  NAV_GEOMETRY_COMP=sway  ./tests/run-nav-geometry-test.sh
mode="${NAV_GEOMETRY_MODE:-1920x1080}"
[[ "$mode" =~ ^[0-9]+x[0-9]+$ ]] || { echo "FAIL: NAV_GEOMETRY_MODE must be WxH"; exit 2; }

comp="${NAV_GEOMETRY_COMP:-}"
if [[ -n "$comp" ]]; then
    command -v "$comp" >/dev/null 2>&1 || { echo "SKIP: $comp is not installed"; exit 0; }
else
    for c in labwc sway; do
        command -v "$c" >/dev/null 2>&1 && { comp="$c"; break; }
    done
fi
[[ -n "$comp" ]] || { echo "SKIP: no wlroots compositor (labwc or sway) to host the test"; exit 0; }

W="$(mktemp -d)"
staged="$root/.nav-geometry-test.qml"
comp_pid=""
nested_pid=""
# Killed by pid, never by name: a pkill for a compositor on a developer's
# machine takes down the session they are working in.
cleanup() {
    [[ -n "$nested_pid" ]] && kill "$nested_pid" 2>/dev/null
    [[ -n "$comp_pid" ]]   && kill "$comp_pid" 2>/dev/null
    sleep 0.3
    [[ -n "$nested_pid" ]] && kill -9 "$nested_pid" 2>/dev/null
    [[ -n "$comp_pid" ]]   && kill -9 "$comp_pid" 2>/dev/null
    rm -f "$staged"
    rm -rf "$W"
    return 0
}
trap cleanup EXIT INT TERM

cp "$here/nav-geometry-test.qml" "$staged"

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

real_home="$(getent passwd "$(id -u)" | cut -d: -f6)"

export XDG_RUNTIME_DIR="$W/run"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"
export HOME="$W/home"
mkdir -p "$HOME/.config/apex-shell/src/user_data" "$HOME/.local/share" "$HOME/Pictures/Wallpapers"
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
export WLR_HEADLESS_OUTPUTS=1
export XDG_SESSION_TYPE=wayland
export QT_QPA_PLATFORM=wayland

# Sockets in the private runtime dir. Diffed rather than scraped from a log,
# because a nested compositor announces its display nowhere.
list_sockets() {
    local f b
    for f in "$XDG_RUNTIME_DIR"/wayland-*; do
        [[ -S "$f" ]] || continue
        b="${f##*/}"
        case "${b#wayland-}" in '' | *[!0-9]*) continue ;; esac
        printf '%s\n' "$b"
    done | sort
}

wait_for_new_socket() {
    local before="$1" got=""
    for _ in $(seq 1 60); do
        got="$(comm -13 <(printf '%s\n' "$before") <(list_sockets) | head -1)"
        [[ -n "$got" ]] && break
        sleep 0.25
    done
    printf '%s' "$got"
}

before="$(list_sockets)"

case "$comp" in
    labwc)
        mkdir -p "$W/cfg/labwc"
        cp "$here/labwc-test-rc.xml" "$W/cfg/labwc/rc.xml" 2>/dev/null || true
        WLR_RENDERER=pixman XDG_CONFIG_HOME="$W/cfg" "$comp" > "$W/comp.log" 2>&1 &
        comp_pid=$!
        ;;
    sway)
        printf 'output HEADLESS-1 mode %s\n' "$mode" > "$W/sway.cfg"
        WLR_RENDERER=pixman "$comp" -c "$W/sway.cfg" > "$W/comp.log" 2>&1 &
        comp_pid=$!
        ;;
    Hyprland|hyprland)
        # Hyprland does not speak WLR_BACKENDS — it is aquamarine, not wlroots —
        # and its own headless backend will not create one here. So it runs
        # nested inside a headless labwc, which is what the compositor question
        # wanted anyway: a real Hyprland with its own instance signature laying
        # the shell out, in a runtime dir where the developer's session is
        # neither visible nor reachable.
        #
        # The host labwc must NOT be on the pixman renderer for this. Aquamarine
        # asks it for a dmabuf, a software-rendered host has none to give, and
        # the only symptom is CBackend::create() failing with nothing else said.
        #
        # ── What has been tried, so nobody tries it twice ──────────────────
        # Hyprland 0.56.2 on a box with a GPU but no seat and no DRM master:
        #
        #   AQ_BACKENDS=headless, standalone      CBackend::create() failed
        #   ... with AQ_DRM_DEVICES=renderD128    CBackend::create() failed
        #   ... with AQ_DRM_DEVICES=renderD129    CBackend::create() failed
        #   nested in a headless sway (pixman)    CBackend::create() failed
        #   nested in a headless labwc            comes up, see below
        #   nested labwc + QSG_RENDER_LOOP=basic  comes up, still frozen
        #
        # The one that comes up hands the shell no output at all — Quickshell
        # reports 0x0 and the suite says so — and never asks its Qt client for
        # another frame, so nothing re-polishes. That is a harness limit and
        # not a shell defect, and the distinction is worth being explicit
        # about because the reported overlap is not compositor-dependent: the
        # vertical column's spacing was (height - n * rowHeight) / (n - 1)
        # with no floor under it, which goes negative on arithmetic a
        # compositor has no input to. It reproduces on labwc and on sway, at
        # scale 1.0, on both of the reporter's outputs.
        mkdir -p "$W/cfg/labwc" "$W/cfg/hypr"
        cp "$here/labwc-test-rc.xml" "$W/cfg/labwc/rc.xml" 2>/dev/null || true
        XDG_CONFIG_HOME="$W/cfg" labwc > "$W/comp.log" 2>&1 &
        comp_pid=$!
        host_sock="$(wait_for_new_socket "$before")"
        [[ -n "$host_sock" ]] || {
            echo "SKIP: the host labwc for the nested Hyprland did not come up"
            tail -5 "$W/comp.log"; exit 0; }
        {
            printf 'monitor=,%s@60,0x0,1\n' "$mode"
            printf 'misc:disable_hyprland_logo = true\n'
            printf 'misc:disable_splash_rendering = true\n'
            printf 'animations:enabled = false\n'
            # Tried against the frozen-layout problem below and it did not
            # help, so do not read this as the fix: a nested Hyprland stops
            # asking its Qt client for frames whatever the frame-rate setting
            # says. Kept because constant rendering is the right shape for a
            # test host, and the QML refuses the host outright when the layout
            # never moves.
            printf 'misc:vfr = false\n'
        } > "$W/cfg/hypr/hyprland.conf"
        before="$(list_sockets)"
        env -u WLR_BACKENDS -u WLR_RENDERER \
            WAYLAND_DISPLAY="$host_sock" \
            AQ_BACKENDS=wayland AQ_NO_MODIFIERS=1 \
            XDG_CONFIG_HOME="$W/cfg" \
            "$comp" > "$W/hypr.log" 2>&1 &
        nested_pid=$!
        ;;
esac

sock="$(wait_for_new_socket "$before")"
[[ -n "$sock" ]] || {
    echo "SKIP: $comp did not come up headless"
    tail -5 "$W/comp.log" 2>/dev/null
    [[ -f "$W/hypr.log" ]] && tail -5 "$W/hypr.log"
    exit 0; }
export WAYLAND_DISPLAY="$sock"

# The window this test opens must land on the compositor above and nowhere else.
[[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]] || {
    echo "FAIL: WAYLAND_DISPLAY does not name a socket in the private runtime dir"
    exit 1; }

# labwc has no output stanza in rc.xml, so the mode is set over wlr-output-
# management once it is up. sway and Hyprland take it from their config.
if [[ "$comp" == "labwc" ]] && command -v wlr-randr >/dev/null 2>&1; then
    out="$(wlr-randr 2>/dev/null | awk 'NR==1{print $1}')"
    [[ -n "$out" ]] && wlr-randr --output "$out" --custom-mode "$mode" >/dev/null 2>&1
fi
echo "host: $comp on $WAYLAND_DISPLAY at $mode (headless, private XDG_RUNTIME_DIR and HOME)"

# quickshell stamps every console.log with a level and a category. Stripped, so
# the assertion lines below are the shape the QML wrote them in.
out="$(QT_LOGGING_RULES="qml=true" timeout 900 quickshell -p "$staged" 2>&1 \
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

if grep -q "Failed to load configuration" <<<"$out"; then
    echo "$out" | tail -25
    echo "RESULT: the test config failed to load"
    exit 1
fi

if grep -q "nav-geometry: unusable-host" <<<"$out"; then
    echo "$out" | grep "nav-geometry: unusable-host"
    echo "SKIP: $comp cannot host this suite — Qt's layout never re-polished, so"
    echo "      every rectangle read back would be the previous matrix point."
    exit 0
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
