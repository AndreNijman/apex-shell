#!/usr/bin/env bash
# Run labwc nested inside the current Wayland session and exercise a QML config
# inside it. This is the only way to verify labwc support without rebooting into
# a labwc session.
#
# usage: labwc-nested.sh <qml-entry-point> [seconds]
set -uo pipefail

entry="${1:?usage: labwc-nested.sh <qml> [seconds]}"
secs="${2:-12}"
cfg="$(mktemp -d)"
cp "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/labwc-test-rc.xml" "$cfg/rc.xml"
log=/tmp/opencode/labwc.log
shell_log=/tmp/opencode/labwc-shell.log

: > "$log"
: > "$shell_log"

# labwc logs nothing about its socket, so find it by diffing the runtime dir
# rather than scraping output.
before="$(ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | sort)"

# Nested labwc must NOT inherit Hyprland's identity, or the shell under test
# will detect the wrong compositor.
env -u HYPRLAND_INSTANCE_SIGNATURE -u NIRI_SOCKET \
    XDG_CURRENT_DESKTOP=labwc:wlroots \
    labwc -C "$cfg" >"$log" 2>&1 &
labwc_pid=$!

cleanup() {
    kill "$labwc_pid" 2>/dev/null
    wait "$labwc_pid" 2>/dev/null
    return 0
}
trap cleanup EXIT INT TERM

nested=""
for _ in $(seq 1 60); do
    after="$(ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | sort)"
    nested="$(comm -13 <(echo "$before") <(echo "$after") | head -1)"
    [[ -n "$nested" ]] && break
    sleep 0.25
done

if [[ -z "$nested" ]]; then
    echo "FAIL: labwc did not report a nested wayland display"
    tail -20 "$log"
    exit 1
fi

echo "labwc running on nested display: $nested (labwc $(labwc --version 2>&1 | head -1))"

env -u HYPRLAND_INSTANCE_SIGNATURE -u NIRI_SOCKET \
    WAYLAND_DISPLAY="$nested" \
    XDG_CURRENT_DESKTOP=labwc:wlroots \
    QT_LOGGING_RULES="qml=true" \
    timeout "$secs" quickshell -p "$entry" >"$shell_log" 2>&1

echo "--- shell output ---"
sed 's/\x1b\[[0-9;]*m//g' "$shell_log" | grep -vE "qt.qpa.wayland.textinput|Registration will|notification server" | head -40
echo "--- labwc errors ---"
grep -iE "error|fail" "$log" | head -10
echo "--- ERROR count: $(grep -c 'ERROR' "$shell_log") ---"
