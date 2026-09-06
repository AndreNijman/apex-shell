#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-dashboard-nav-test.sh — dashboard navigation geometry, at every size a
#  supported desk can be.
#
#  tests/dashboard-nav-test.qml measures one output. This drives it across a
#  matrix, by standing up a headless compositor and reconfiguring its output
#  between runs. Nothing is drawn on anybody's desktop and nothing is
#  screenshotted: the assertions read rendered x and width out of the scene
#  graph, so a failure names the two tabs that overlapped and by how much.
#
#  The matrix is two halves, because "scaling" means two different things here
#  and only one of them is the compositor's:
#
#    output   the compositor's own scale. 1920x1080 at 150% is an 1280x720
#             logical output, and the shell's windows are sized in those logical
#             pixels. This is what a user sets in Display settings.
#    shell    APEX's own factor (Config -> Layout, or Metrics.autoScale). It
#             multiplies every font and every token, so it is the half that
#             makes a tab's contents outgrow its share of the bar.
#
#  Outputs cover 720p/1080p/1440p/4K, plus the two panels this was reported on:
#  1920x1200 and a 2560x1080 ultrawide, which is short rather than narrow and so
#  runs the dashboard out of vertical room first.
#
#  ── The two compositors ─────────────────────────────────────────────────────
#  sway runs headless directly, and `swaymsg output` gives both the mode and a
#  fractional scale, which is the whole matrix in two commands.
#
#  Hyprland cannot: aquamarine has no headless fallback on a machine with no
#  seat and no DRM master, and `Hyprland -c` over ssh dies in
#  CBackend::create(). So it is nested inside a headless sway instead — the same
#  trick tests/run-nested-labwc.sh uses — and its output is WL-1 rather than
#  HEADLESS-1. This is worth doing because it is what the reporter runs, even
#  though the layout under test is the shell's own and not the compositor's.
#
#  usage: tests/run-dashboard-nav-test.sh [sway|hyprland]
#  env:   APEX_NAV_MATRIX=quick   one scale per output instead of the full sweep
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

compositor="${1:-sway}"

command -v quickshell >/dev/null 2>&1 || { echo "SKIP: quickshell not installed"; exit 0; }
command -v "$compositor" >/dev/null 2>&1 \
    || command -v "${compositor^}" >/dev/null 2>&1 \
    || { echo "SKIP: $compositor not installed"; exit 0; }
: "${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR must be set}"

# Quickshell refuses to import QML from outside the directory holding the entry
# point, so the test cannot live in tests/ and import ../src.
staged="$root/.dashboard-nav-test.qml"
cp "$here/dashboard-nav-test.qml" "$staged"

# The shell persists settings, and this test changes the scale factor. A
# throwaway HOME is what keeps it from writing into a real one.
fakehome="$(mktemp -d)"
comp_log="$(mktemp)"
comp_pid=""
host_pid=""

cleanup() {
    [[ -n "$comp_pid" ]] && kill "$comp_pid" 2>/dev/null
    [[ -n "$comp_pid" ]] && wait "$comp_pid" 2>/dev/null
    [[ -n "$host_pid" ]] && kill "$host_pid" 2>/dev/null
    [[ -n "$host_pid" ]] && wait "$host_pid" 2>/dev/null
    rm -f "$staged" "$comp_log"
    rm -rf "$fakehome"
    return 0
}
trap cleanup EXIT INT TERM

# Sockets that appeared while the nested compositor was starting. Diffed rather
# than scraped, because neither compositor announces its display name in a shape
# worth parsing.
list_sockets() {
    local f name suffix
    for f in "$XDG_RUNTIME_DIR"/wayland-*; do
        [ -S "$f" ] || continue
        name="${f##*/}"
        suffix="${name#wayland-}"
        case "$suffix" in
            '' | *[!0-9]*) continue ;;
        esac
        printf '%s\n' "$name"
    done | sort
}

before="$(list_sockets)"

case "$compositor" in
sway)
    cfg="$(mktemp)"
    cat > "$cfg" <<'SWAY'
output * bg #000000 solid_color
default_border none
SWAY
    WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
    WLR_HEADLESS_OUTPUTS=1 XDG_CURRENT_DESKTOP=sway:wlroots \
    env -u HYPRLAND_INSTANCE_SIGNATURE -u NIRI_SOCKET -u WAYLAND_DISPLAY \
        sway -c "$cfg" >"$comp_log" 2>&1 &
    comp_pid=$!
    output_name="HEADLESS-1"
    ;;
hyprland)
    # A headless sway to host it, sized large enough that a nested 4K output is
    # not the host's problem.
    hostcfg="$(mktemp)"
    cat > "$hostcfg" <<'SWAY'
output * bg #000000 solid_color
output HEADLESS-1 mode 3840x2160
default_border none
SWAY
    WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
    WLR_HEADLESS_OUTPUTS=1 XDG_CURRENT_DESKTOP=sway:wlroots \
    env -u HYPRLAND_INSTANCE_SIGNATURE -u NIRI_SOCKET -u WAYLAND_DISPLAY \
        sway -c "$hostcfg" >"$comp_log" 2>&1 &
    host_pid=$!

    host=""
    for _ in $(seq 1 80); do
        host="$(comm -13 <(echo "$before") <(list_sockets) | head -1)"
        [[ -n "$host" ]] && break
        sleep 0.25
    done
    if [[ -z "$host" ]]; then
        echo "FAIL: the host sway did not come up"
        tail -20 "$comp_log"
        rm -f "$hostcfg"
        exit 1
    fi
    before="$(list_sockets)"

    cfg="$(mktemp)"
    cat > "$cfg" <<'HYPR'
monitor = WL-1, 1920x1080@60, 0x0, 1
misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
    force_default_wallpaper = 0
}
animations { enabled = false }
decoration { blur { enabled = false } }
HYPR
    XDG_CURRENT_DESKTOP=Hyprland WAYLAND_DISPLAY="$host" \
    env -u NIRI_SOCKET -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY \
        Hyprland -c "$cfg" >>"$comp_log" 2>&1 &
    comp_pid=$!
    rm -f "$hostcfg"
    output_name="WL-1"
    ;;
*)
    echo "FAIL: unsupported compositor '$compositor' (sway or hyprland)"
    exit 2
    ;;
esac

nested=""
for _ in $(seq 1 80); do
    nested="$(comm -13 <(echo "$before") <(list_sockets) | head -1)"
    [[ -n "$nested" ]] && break
    sleep 0.25
done
rm -f "$cfg"

if [[ -z "$nested" ]]; then
    echo "FAIL: $compositor did not come up headless"
    tail -20 "$comp_log"
    exit 1
fi

export WAYLAND_DISPLAY="$nested"

if [[ "$compositor" == "sway" ]]; then
    SWAYSOCK="$(ls -t "$XDG_RUNTIME_DIR"/sway-ipc.*.sock 2>/dev/null | head -1)"
    export SWAYSOCK
else
    # Crashed runs leave signature directories behind, so wait for one with a
    # socket that actually answers rather than taking the newest name.
    for _ in $(seq 1 40); do
        for sig in $(ls -t "$XDG_RUNTIME_DIR"/hypr 2>/dev/null); do
            [[ -S "$XDG_RUNTIME_DIR/hypr/$sig/.socket.sock" ]] || continue
            if HYPRLAND_INSTANCE_SIGNATURE="$sig" hyprctl monitors >/dev/null 2>&1; then
                export HYPRLAND_INSTANCE_SIGNATURE="$sig"
                break 2
            fi
        done
        sleep 0.25
    done
    if [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
        echo "FAIL: Hyprland came up but its IPC socket never answered"
        tail -20 "$comp_log"
        exit 1
    fi
fi

echo "$compositor headless on $nested, output $output_name"

set_output() {
    local w="$1" h="$2" scale="$3"
    if [[ "$compositor" == "sway" ]]; then
        swaymsg output "$output_name" mode "${w}x${h}" >/dev/null 2>&1 || return 1
        swaymsg output "$output_name" scale "$scale"   >/dev/null 2>&1 || return 1
    else
        hyprctl keyword monitor "$output_name,${w}x${h}@60,0x0,$scale" >/dev/null 2>&1 || return 1
    fi
    sleep 0.6
}

# ── The matrix ──────────────────────────────────────────────────────────────
# 720p is where a scaled-up compositor squeezes hardest; 4K is where the shell
# scales itself up the most. The two in the middle are the panels this was
# reported on.
outputs=(1280x720 1920x1080 1920x1200 2560x1080 2560x1440 3840x2160)
output_scales=(1 1.25 1.5 1.75 2)
shell_scales=(1.5 2.0 3.0)

if [[ "${APEX_NAV_MATRIX:-full}" == "quick" ]]; then
    outputs=(1280x720 1920x1200 2560x1080 3840x2160)
    output_scales=(1 2)
    shell_scales=(3.0)
fi

rows=0
bad_rows=0
failing=()
tiers=""

run_row() {
    local label="$1" mode="$2" oscale="$3" smode="$4" sscale="$5"
    local w="${mode%x*}" h="${mode#*x}"

    if ! set_output "$w" "$h" "$oscale"; then
        echo "  SKIP  $label — the compositor refused ${w}x${h} @ $oscale"
        return 0
    fi

    local out
    out="$(cd "$root" && \
        env HOME="$fakehome" \
            XDG_CONFIG_HOME="$fakehome/.config" \
            QT_QUICK_BACKEND=software \
            QT_LOGGING_RULES="qml=true" \
            APEX_NAV_LABEL="$label" \
            APEX_NAV_SCALE_MODE="$smode" \
            APEX_NAV_SCALE="$sscale" \
            timeout 90 quickshell -p "$staged" 2>&1)"

    out="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')"
    rows=$((rows + 1))

    if ! printf '%s' "$out" | grep -q "passed="; then
        echo "  FAIL  $label — the test did not run to completion"
        printf '%s\n' "$out" | tail -15
        bad_rows=$((bad_rows + 1))
        failing+=("$label")
        return 0
    fi

    tiers+="$(printf '%s' "$out" | grep -o 'tier=[a-z]*' || true)"$'\n'

    local summary
    summary="$(printf '%s' "$out" | grep -o 'row=.*failed=[0-9]*' | tail -1)"
    if printf '%s' "$out" | grep -q "  FAIL  "; then
        bad_rows=$((bad_rows + 1))
        failing+=("$label")
        echo "  FAIL  $label  ($summary)"
        # quickshell prefixes every console.log with its own level tag, so these
        # cannot be anchored to the start of the line.
        printf '%s\n' "$out" \
            | grep -E "FAIL |\[geom\]|\[bar\]|\[list\]" \
            | sed 's/^.*qml: /    /' | head -40
    else
        echo "  ok    $label  ($summary)"
        if [[ -n "${APEX_NAV_VERBOSE:-}" ]]; then
            printf '%s\n' "$out" \
                | grep -E "\[geom\]|\[bar\]|\[list\]" \
                | sed 's/^.*qml: /    /'
        fi
    fi
}

echo
echo "── output scaling (the compositor's) ───────────────────────────────────"
for mode in "${outputs[@]}"; do
    for os in "${output_scales[@]}"; do
        run_row "$mode@${os}x" "$mode" "$os" auto 1.0
    done
done

echo
echo "── shell scaling (APEX's own factor, output at 100%) ───────────────────"
for mode in "${outputs[@]}"; do
    for ss in "${shell_scales[@]}"; do
        run_row "$mode/shell${ss}" "$mode" 1 manual "$ss"
    done
done

echo
echo "── summary ─────────────────────────────────────────────────────────────"
echo "compositor: $compositor"
echo "rows:       $rows"
echo "tab tiers exercised:"
printf '%s' "$tiers" | grep -v '^$' | sort | uniq -c | sed 's/^/  /'

# A matrix that never leaves the roomiest tier has not tested the responsive
# behaviour at all, only that the default look still fits.
if ! printf '%s' "$tiers" | grep -qE 'tier=(compact|icons|squeeze)'; then
    echo "FAIL: no row was narrow enough to leave the comfortable tier;"
    echo "      the responsive path is untested, which is not a pass"
    exit 1
fi

if [[ "$bad_rows" -gt 0 ]]; then
    echo
    echo "RESULT: $bad_rows of $rows rows failed"
    printf '  %s\n' "${failing[@]}"
    exit 1
fi

echo
echo "RESULT: all $rows rows passed"
