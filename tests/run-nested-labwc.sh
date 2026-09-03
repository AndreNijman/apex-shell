#!/usr/bin/env bash
# Run labwc nested inside the current Wayland session and exercise a QML config
# inside it. This is the only way to verify labwc support without rebooting into
# a labwc session.
#
# A throwaway toplevel is started inside the nested display before the entry
# point runs — see "the filler" below.
#
# usage: labwc-nested.sh <qml-entry-point> [seconds]
set -uo pipefail

entry="${1:?usage: labwc-nested.sh <qml> [seconds]}"
secs="${2:-12}"
cfg="$(mktemp -d)"
cp "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/labwc-test-rc.xml" "$cfg/rc.xml"
log="$(mktemp)"
shell_log="$(mktemp)"

# ── The filler ───────────────────────────────────────────────────────────────
# A nested compositor with nothing running inside it is not a session, and the
# difference is not cosmetic: the app dock has nothing to list, the
# foreign-toplevel feed nothing to publish, and any assertion over the window
# list is an empty loop that passes without testing anything. The facade suite
# asserts the presence of a toplevel as an explicit precondition for exactly
# that reason, so the harness has to provide one.
#
# quickshell rather than a terminal emulator: it is already a hard requirement
# of every harness in here, so this adds no dependency and works anywhere the
# shell itself runs.
filler_qml="$(mktemp --suffix=.qml)"
cat > "$filler_qml" <<'FILLER'
import Quickshell
import QtQuick

ShellRoot {
    FloatingWindow {
        title:          "apex-nested-filler"
        visible:        true
        implicitWidth:  360
        implicitHeight: 240
        Rectangle { anchors.fill: parent; color: "#1b1b1b" }
    }
}
FILLER

: > "$log"
: > "$shell_log"

# labwc logs nothing about its socket, so find it by diffing the runtime dir
# rather than scraping output.
#
# Globbed rather than `ls | grep`: requiring an actual socket (-S) is both more
# correct and cheaper than filtering names, since it drops the .lock file and
# the per-app sockets (wayland-1-awww-daemon.sock) for free.
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

# Nested labwc must NOT inherit Hyprland's identity, or the shell under test
# will detect the wrong compositor.
env -u HYPRLAND_INSTANCE_SIGNATURE -u NIRI_SOCKET \
    XDG_CURRENT_DESKTOP=labwc:wlroots \
    labwc -C "$cfg" >"$log" 2>&1 &
labwc_pid=$!

filler_pid=""

cleanup() {
    if [[ -n "$filler_pid" ]]; then
        kill "$filler_pid" 2>/dev/null
        wait "$filler_pid" 2>/dev/null
    fi
    kill "$labwc_pid" 2>/dev/null
    wait "$labwc_pid" 2>/dev/null
    rm -rf "$cfg" "$log" "$shell_log" "$filler_qml"
    return 0
}
trap cleanup EXIT INT TERM

nested=""
for _ in $(seq 1 60); do
    after="$(list_sockets)"
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
    quickshell -p "$filler_qml" >/dev/null 2>&1 &
filler_pid=$!

# The window has to be mapped and published over foreign-toplevel before the
# entry point reads the window list, and nothing announces either step. A fixed
# wait is the honest option; the check afterwards is what matters, because a
# filler that died turns every window assertion into an empty loop and the
# caller has to hear about that rather than read a green run.
sleep 2

if ! kill -0 "$filler_pid" 2>/dev/null; then
    echo "FAIL: the filler toplevel did not stay up; window assertions would be vacuous"
    exit 1
fi

env -u HYPRLAND_INSTANCE_SIGNATURE -u NIRI_SOCKET \
    WAYLAND_DISPLAY="$nested" \
    XDG_CURRENT_DESKTOP=labwc:wlroots \
    QT_LOGGING_RULES="qml=true" \
    timeout "$secs" quickshell -p "$entry" >"$shell_log" 2>&1

echo "--- shell output ---"
# Generous line budget: this harness is also how the compositor facade suite is
# exercised against labwc, and a truncated run hides its summary line — which
# is the one line that says whether it passed.
sed 's/\x1b\[[0-9;]*m//g' "$shell_log" | grep -vE "qt.qpa.wayland.textinput|Registration will|notification server" | head -120
echo "--- labwc errors ---"
grep -iE "error|fail" "$log" | head -10
echo "--- ERROR count: $(grep -c 'ERROR' "$shell_log") ---"
